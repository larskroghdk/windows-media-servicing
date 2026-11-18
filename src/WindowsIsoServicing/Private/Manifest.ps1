$script:ManifestSchemaVersion = 1

function Get-ManifestValue {
    <#
    .SYNOPSIS
        Reads a nested property of a manifest by dotted path.

    .DESCRIPTION
        Follows each segment of Path through the object's properties and returns $null as soon as a segment is missing.
        The module runs under Set-StrictMode 3.0, where reading a missing property of a JSON-derived object throws, so
        manifests read from disk are accessed through this function.

    .PARAMETER InputObject
        Manifest or part of a manifest. $null returns $null.

    .PARAMETER Path
        Property path, for example 'operatingSystem.build'.

    .EXAMPLE
        Get-ManifestValue -InputObject $manifest -Path 'validation.passed'

    .OUTPUTS
        System.Object

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,
        [Parameter(Mandatory)]
        [string]$Path
    )
    $current = $InputObject
    foreach ($segment in $Path -split '\.') {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$segment]
        if (-not $property) { return $null }
        $current = $property.Value
    }
    $current
}

function Test-ManifestSchema {
    <#
    .SYNOPSIS
        Checks a manifest against the manifest schema.

    .DESCRIPTION
        Checks the schema version, the required text fields, the lowercase SHA-256 values of the source and output ISO,
        the integer build, the KB number and category of every update, at least one install image index with an integer
        index and a versionAfter, and a boolean validation.passed. Returns one message per problem; an empty result means
        the manifest is valid. The schema is described in docs/architecture.md.

    .PARAMETER Manifest
        Manifest object, for example from ConvertFrom-Json. $null is reported as an empty manifest.

    .EXAMPLE
        Test-ManifestSchema -Manifest (Get-Content -LiteralPath 'D:\IsoServicing\Output\Windows_Server_2025_x64_26100_2026-11.manifest.json' -Raw | ConvertFrom-Json)

    .OUTPUTS
        System.String[]

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Manifest
    )
    if ($null -eq $Manifest) { return [string[]]@('Manifest is empty.') }
    $sha256Pattern = '^[0-9a-f]{64}$'
    $problems = [System.Collections.Generic.List[string]]::new()
    if ((Get-ManifestValue -InputObject $Manifest -Path 'schemaVersion') -ne $script:ManifestSchemaVersion) {
        $problems.Add("schemaVersion must be $script:ManifestSchemaVersion.")
    }
    foreach ($path in 'toolVersion', 'runId', 'createdAt', 'source.fileName', 'operatingSystem.name', 'operatingSystem.architecture', 'output.fileName', 'output.servicingMonth') {
        if ([string]::IsNullOrWhiteSpace([string](Get-ManifestValue -InputObject $Manifest -Path $path))) { $problems.Add("$path is required.") }
    }
    foreach ($path in 'source.sha256', 'output.sha256') {
        if ([string](Get-ManifestValue -InputObject $Manifest -Path $path) -notmatch $sha256Pattern) { $problems.Add("$path must be a lowercase SHA-256 hex string.") }
    }
    $build = Get-ManifestValue -InputObject $Manifest -Path 'operatingSystem.build'
    if ($build -isnot [long] -and $build -isnot [int]) {
        $problems.Add('operatingSystem.build must be an integer.')
    }
    $updates = Get-ManifestValue -InputObject $Manifest -Path 'updates'
    if ($null -eq $updates) {
        $problems.Add('updates is required.')
    }
    else {
        foreach ($update in @($updates)) {
            $kb = Get-ManifestValue -InputObject $update -Path 'kb'
            if ([string]$kb -notmatch '^KB\d+$') { $problems.Add("updates entry has an invalid kb '$kb'.") }
            if ([string](Get-ManifestValue -InputObject $update -Path 'category') -notin $script:UpdateCategories) { $problems.Add("updates entry $kb has an invalid category.") }
        }
    }
    $installImages = @(Get-ManifestValue -InputObject $Manifest -Path 'images.install')
    if ($installImages.Count -eq 0 -or $null -eq $installImages[0]) {
        $problems.Add('images.install must list at least one image index.')
    }
    else {
        foreach ($image in $installImages) {
            $index = Get-ManifestValue -InputObject $image -Path 'index'
            if ($index -isnot [long] -and $index -isnot [int]) { $problems.Add('images.install entry has no integer index.') }
            if ([string]::IsNullOrWhiteSpace([string](Get-ManifestValue -InputObject $image -Path 'versionAfter'))) { $problems.Add("images.install index $index has no versionAfter.") }
        }
    }
    if ((Get-ManifestValue -InputObject $Manifest -Path 'validation.passed') -isnot [bool]) {
        $problems.Add('validation.passed must be a boolean.')
    }
    [string[]]$problems.ToArray()
}

function Read-ServicingManifest {
    <#
    .SYNOPSIS
        Reads a manifest file and throws when it does not match the schema.

    .DESCRIPTION
        Reads the JSON file, checks it with Test-ManifestSchema and returns it. A manifest with schema problems is refused
        with all problems in the error message, so an invalid manifest is never used as a baseline or published.

    .PARAMETER Path
        Path of the manifest JSON file.

    .EXAMPLE
        Read-ServicingManifest -Path 'D:\IsoServicing\Output\Windows_Server_2025_x64_26100_2026-11.manifest.json'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $manifest = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 20
    $problems = @(Test-ManifestSchema -Manifest $manifest)
    if ($problems.Count -gt 0) {
        throw "Manifest '$Path' is invalid: $($problems -join ' ')"
    }
    $manifest
}

function Write-ServicingManifest {
    <#
    .SYNOPSIS
        Writes a manifest file after checking it against the schema.

    .DESCRIPTION
        Converts the manifest to JSON and back, so it is checked in the form it will be read in, and refuses to write it
        when Test-ManifestSchema reports problems. The file is written as UTF-8 without BOM to a temporary file and moved
        over the destination, so a reader never sees a partly written manifest (subject to -WhatIf and -Confirm).

    .PARAMETER Manifest
        Manifest as an ordered dictionary or object.

    .PARAMETER Path
        Path of the manifest JSON file.

    .EXAMPLE
        Write-ServicingManifest -Manifest $manifest -Path "$($context.OutputStagingPath)\Windows_Server_2025_x64_26100_2026-11.manifest.json"

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object]$Manifest,
        [Parameter(Mandatory)]
        [string]$Path
    )
    $problems = @(Test-ManifestSchema -Manifest ([pscustomobject]$Manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20))
    if ($problems.Count -gt 0) {
        throw "Refusing to write an invalid manifest: $($problems -join ' ')"
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Write manifest')) {
        $temporary = "$Path.tmp"
        $Manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
}

function Get-ManifestUpdateSignature {
    <#
    .SYNOPSIS
        Builds the key that identifies what a serviced ISO was built from.

    .DESCRIPTION
        Joins the lowercase source SHA-256, the sorted, distinct, uppercase KB numbers and the sorted, distinct image
        indexes with '|'. Two runs with the same signature produce the same updates, which lets the pipeline skip a run
        that would repeat the latest known-good ISO.

    .PARAMETER SourceSha256
        SHA-256 of the source ISO.

    .PARAMETER Kb
        KB numbers of the applied updates.

    .PARAMETER Index
        Serviced image indexes.

    .EXAMPLE
        Get-ManifestUpdateSignature -SourceSha256 $sourceHash -Kb 'KB5131080', 'KB5130890' -Index 2, 4

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$SourceSha256,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Kb,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$Index
    )
    '{0}|{1}|{2}' -f $SourceSha256.ToLowerInvariant(), (($Kb | ForEach-Object ToUpperInvariant | Sort-Object -Unique) -join ','), (($Index | Sort-Object -Unique) -join ',')
}
