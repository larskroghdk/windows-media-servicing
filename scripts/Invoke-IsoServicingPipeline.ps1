#Requires -Version 7.4

<#
.SYNOPSIS
    Unattended servicing run for CI/CD systems and Windows Task Scheduler.

.DESCRIPTION
    Services every media entry of a configuration file after the monthly Patch Tuesday release (plus a configurable
    delay), skips media whose update set is unchanged since the latest published ISO, publishes validated ISOs to the
    artifact store and writes a servicing summary (Markdown and JSON).
    Exit codes: 0 = all media succeeded or were unchanged, 1 = at least one media entry failed, 2 = configuration error.
    Requires an elevated PowerShell 7.4 session on a host that meets docs/requirements.md, and the
    WindowsIsoServicing module from src, which the script imports. Updates are discovered in the Microsoft Update
    Catalog, or in a local repository when the configuration sets updateSource.repositoryPath. Side effects: serviced
    ISOs and manifests in outputPath, published ISOs in storePath (older ones beyond retainCount are removed by
    Publish-WindowsISO), servicing-summary.json in outputPath, and the Markdown summary appended to SummaryPath. A
    source ISO is never modified, and an ISO that fails validation is never published.

.PARAMETER ConfigurationPath
    JSON configuration file. See config\servicing.example.json.

.PARAMETER Force
    Ignores the Patch Tuesday gate and the published baseline, rebuilding every media entry.

.PARAMETER DelayDays
    Overrides patchTuesdayDelayDays from the configuration.

.PARAMETER SummaryPath
    Markdown summary file. Defaults to $env:GITHUB_STEP_SUMMARY when set.

.PARAMETER Date
    Date used for the Patch Tuesday gate. Defaults to today.

.EXAMPLE
    .\scripts\Invoke-IsoServicingPipeline.ps1 -ConfigurationPath 'D:\IsoServicing\servicing.json'

.EXAMPLE
    .\scripts\Invoke-IsoServicingPipeline.ps1 -ConfigurationPath 'D:\IsoServicing\servicing.json' -Force

.OUTPUTS
    None. The Markdown summary goes to the information stream; the result is the process exit code.

.NOTES
    Author:  Lars Krogh Paulsen
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ConfigurationPath,
    [switch]$Force,
    [ValidateRange(0, 20)]
    [Nullable[int]]$DelayDays,
    [string]$SummaryPath = $env:GITHUB_STEP_SUMMARY,
    [datetime]$Date = [datetime]::Today
)

function Get-PatchTuesday {
    <#
    .SYNOPSIS
        Returns the Patch Tuesday of a month.

    .DESCRIPTION
        Returns the second Tuesday of the month, the day Microsoft releases its monthly security updates.

    .PARAMETER Year
        Year.

    .PARAMETER Month
        Month, 1 to 12.

    .EXAMPLE
        Get-PatchTuesday -Year 2026 -Month 11

    .OUTPUTS
        System.DateTime

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [int]$Year,
        [Parameter(Mandatory)]
        [ValidateRange(1, 12)]
        [int]$Month
    )
    $first = [datetime]::new($Year, $Month, 1)
    $offset = ([int][DayOfWeek]::Tuesday - [int]$first.DayOfWeek + 7) % 7
    $first.AddDays($offset + 7)
}

function Test-ServicingWindowOpen {
    <#
    .SYNOPSIS
        Tests whether the servicing window of the month has opened.

    .DESCRIPTION
        Returns $true when Date is on or after Patch Tuesday of its month plus DelayDays. The delay gives the Catalog time
        to list the month's updates.

    .PARAMETER Date
        Date to test.

    .PARAMETER DelayDays
        Days after Patch Tuesday before servicing starts.

    .EXAMPLE
        Test-ServicingWindowOpen -Date '2026-11-12' -DelayDays 2

    .OUTPUTS
        System.Boolean

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [datetime]$Date,
        [Parameter(Mandatory)]
        [int]$DelayDays
    )
    $Date.Date -ge (Get-PatchTuesday -Year $Date.Year -Month $Date.Month).AddDays($DelayDays)
}

function Read-PipelineConfiguration {
    <#
    .SYNOPSIS
        Reads and checks the pipeline configuration file.

    .DESCRIPTION
        Requires outputPath, storePath and media, and a name and sourceIso in every media entry. updateSource accepts only
        repositoryPath; any other key is refused with the note that WSUS is not supported.

    .PARAMETER Path
        Path of the JSON configuration file.

    .EXAMPLE
        Read-PipelineConfiguration -Path 'D:\IsoServicing\servicing.json'

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
    $configuration = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -Depth 10
    foreach ($required in 'outputPath', 'storePath', 'media') {
        if (-not $configuration.PSObject.Properties[$required]) { throw "Configuration '$Path' is missing '$required'." }
    }
    $source = $configuration.PSObject.Properties['updateSource']?.Value
    if ($source) {
        $unknown = @($source.PSObject.Properties.Name | Where-Object { $_ -ne 'repositoryPath' })
        if ($unknown) {
            throw "updateSource supports only 'repositoryPath' (found: $($unknown -join ', ')). WSUS is not supported; omit updateSource to use the Microsoft Update Catalog."
        }
    }
    foreach ($media in $configuration.media) {
        if (-not $media.PSObject.Properties['name'] -or -not $media.PSObject.Properties['sourceIso']) {
            throw "Every media entry requires 'name' and 'sourceIso'."
        }
    }
    $configuration
}

function Find-BaselineManifest {
    <#
    .SYNOPSIS
        Finds the latest published manifest built from a source ISO.

    .DESCRIPTION
        Reads the latest.json manifest of each artifact store key and returns the newest one with the same source SHA-256
        and, when Index is given, the same serviced indexes. Update-WindowsISO uses it to skip a run whose updates are
        unchanged. Returns nothing when the store does not exist or has no match.

    .PARAMETER StorePath
        Root of the artifact store.

    .PARAMETER SourceSha256
        Lowercase SHA-256 of the source ISO.

    .PARAMETER Index
        Image indexes the run services.

    .EXAMPLE
        Find-BaselineManifest -StorePath 'E:\IsoStore' -SourceSha256 $sourceSha256

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
        [string]$StorePath,
        [Parameter(Mandatory)]
        [string]$SourceSha256,
        [int[]]$Index
    )
    if (-not (Test-Path -LiteralPath $StorePath)) { return }
    $candidates = foreach ($latest in Get-ChildItem -LiteralPath $StorePath -Filter 'latest.json' -Recurse -Depth 1 -File) {
        $manifest = Get-Content -LiteralPath $latest.FullName -Raw | ConvertFrom-Json -Depth 20
        if ($manifest.source.sha256 -ne $SourceSha256) { continue }
        $servicedIndex = @($manifest.images.install | Where-Object serviced | ForEach-Object index)
        if ($Index -and (Compare-Object $servicedIndex $Index)) { continue }
        [pscustomobject]@{ Path = $latest.FullName; CreatedAt = [datetime]$manifest.createdAt }
    }
    $candidates | Sort-Object CreatedAt -Descending | Select-Object -First 1 -ExpandProperty Path
}

function Get-OptionalValue {
    <#
    .SYNOPSIS
        Returns an optional configuration value or a default.

    .DESCRIPTION
        Returns the property value when the property exists and is not $null, otherwise Default. Reading a missing
        property of a JSON object would throw under strict mode.

    .PARAMETER Object
        Configuration object.

    .PARAMETER Name
        Property name.

    .PARAMETER Default
        Value returned when the property is missing or $null.

    .EXAMPLE
        Get-OptionalValue -Object $configuration -Name 'retainCount' -Default 3

    .OUTPUTS
        System.Object

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Object,
        [Parameter(Mandatory)]
        [string]$Name,
        [object]$Default
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) { $property.Value } else { $Default }
}

function Invoke-Pipeline {
    <#
    .SYNOPSIS
        Runs the unattended servicing of every configured media entry.

    .DESCRIPTION
        Reads the configuration and, when the servicing window is open or Force is set, services each media entry with
        Update-WindowsISO and publishes each created ISO with Publish-WindowsISO. Without Force, the latest published
        manifest of the same source is passed as baseline, so unchanged media is skipped. A failing entry is reported and
        the next entry still runs. Writes the Markdown summary to the information stream and SummaryPath, and
        servicing-summary.json to the output folder.

    .PARAMETER ConfigurationPath
        Path of the JSON configuration file.

    .PARAMETER Force
        Ignores the servicing window and the published baseline.

    .PARAMETER DelayDays
        Days after Patch Tuesday before servicing starts. Defaults to patchTuesdayDelayDays from the configuration, or 2.

    .PARAMETER SummaryPath
        File the Markdown summary is appended to.

    .PARAMETER Date
        Date for the servicing window.

    .EXAMPLE
        Invoke-Pipeline -ConfigurationPath 'D:\IsoServicing\servicing.json' -Date ([datetime]::Today)

    .OUTPUTS
        System.Int32. 0 when every entry succeeded or was unchanged, 1 when an entry failed, 2 for a configuration error.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationPath,
        [switch]$Force,
        [Nullable[int]]$DelayDays,
        [string]$SummaryPath,
        [Parameter(Mandatory)]
        [datetime]$Date
    )
    try {
        $configuration = Read-PipelineConfiguration -Path $ConfigurationPath
    }
    catch {
        Write-Error "Configuration error: $_"
        return 2
    }
    $delay = if ($null -ne $DelayDays) { $DelayDays } else { [int](Get-OptionalValue -Object $configuration -Name 'patchTuesdayDelayDays' -Default 2) }
    if (-not $Force -and -not (Test-ServicingWindowOpen -Date $Date -DelayDays $delay)) {
        $opens = (Get-PatchTuesday -Year $Date.Year -Month $Date.Month).AddDays($delay)
        Write-Information "Servicing window for $($Date.ToString('yyyy-MM')) opens $($opens.ToString('yyyy-MM-dd')); nothing to do." -InformationAction Continue
        return 0
    }
    Import-Module (Join-Path $PSScriptRoot '..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force -ErrorAction Stop
    $repositoryPath = Get-OptionalValue -Object (Get-OptionalValue -Object $configuration -Name 'updateSource' -Default ([pscustomobject]@{})) -Name 'repositoryPath'
    $results = foreach ($media in $configuration.media) {
        $entry = [ordered]@{ name = $media.name; status = 'Failed'; isoPath = $null; updates = @(); validation = $null; published = $null; error = $null }
        try {
            $sourceIso = (Resolve-Path -LiteralPath $media.sourceIso -ErrorAction Stop).ProviderPath
            $index = @(Get-OptionalValue -Object $media -Name 'indexes' -Default @())
            if ($null -ne (Get-OptionalValue -Object $media -Name 'noBootPrompt')) {
                Write-Warning "Media '$($media.name)': noBootPrompt is obsolete and ignored; every serviced ISO boots without ""Press any key"". Remove it from the configuration."
            }
            $parameters = @{
                SourceISO   = $sourceIso
                OutputPath  = $configuration.outputPath
                EsuEntitled = [bool](Get-OptionalValue -Object $media -Name 'esuEntitled' -Default $false)
                BootTest    = [bool](Get-OptionalValue -Object $media -Name 'bootTest' -Default $false)
                Force       = $true
                Confirm     = $false
            }
            if ($index) { $parameters.Index = $index }
            foreach ($name in 'workspacePath', 'cachePath', 'oscdimgPath') {
                $value = Get-OptionalValue -Object $configuration -Name $name
                if ($value) { $parameters[$name] = $value }
            }
            if ($repositoryPath) { $parameters.RepositoryPath = $repositoryPath }
            if (-not $Force) {
                $sourceSha256 = (Get-FileHash -LiteralPath $sourceIso -Algorithm SHA256).Hash.ToLowerInvariant()
                $baseline = Find-BaselineManifest -StorePath $configuration.storePath -SourceSha256 $sourceSha256 -Index $index
                if ($baseline) { $parameters.BaselineManifestPath = $baseline }
            }

            $result = Update-WindowsISO @parameters
            $entry.status = $result.Status
            $entry.updates = @($result.Plan.Updates | ForEach-Object { "$($_.Kb) ($($_.Category))" })
            if ($result.Status -eq 'Created') {
                $entry.isoPath = $result.IsoPath
                $manifest = Get-WindowsISOManifest -Path $result.ManifestPath
                $entry.validation = if ($manifest.validation.bootTest.performed) { "Structural + Hyper-V install: $($manifest.validation.bootTest.result)" } else { 'Structural only (no boot test)' }
                $publication = Publish-WindowsISO -ManifestPath $result.ManifestPath -StorePath $configuration.storePath -RetainCount ([int](Get-OptionalValue -Object $configuration -Name 'retainCount' -Default 3)) -Confirm:$false
                $entry.published = $publication.IsoPath
            }
        }
        catch {
            $entry.status = 'Failed'
            $entry.error = "$_"
            Write-Error "Media '$($media.name)' failed: $_" -ErrorAction Continue
        }
        [pscustomobject]$entry
    }
    $summary = [System.Text.StringBuilder]::new()
    $null = $summary.AppendLine("## Windows ISO servicing $($Date.ToString('yyyy-MM-dd'))").AppendLine()
    $null = $summary.AppendLine('| Media | Status | Updates | Validation | Published | Error |').AppendLine('|---|---|---|---|---|---|')
    foreach ($result in $results) {
        $null = $summary.AppendLine("| $($result.name) | $($result.status) | $($result.updates -join '<br>') | $($result.validation) | $($result.published) | $(($result.error -replace '\|', '/' -replace '\r?\n', ' ')) |")
    }
    $markdown = $summary.ToString()
    Write-Information $markdown -InformationAction Continue
    if ($SummaryPath) { Add-Content -LiteralPath $SummaryPath -Value $markdown -Encoding utf8NoBOM }
    $summaryJson = Join-Path $configuration.outputPath 'servicing-summary.json'
    if (Test-Path -LiteralPath $configuration.outputPath) {
        ConvertTo-Json -InputObject @($results) -Depth 5 | Set-Content -LiteralPath $summaryJson -Encoding utf8NoBOM
    }
    if ($results | Where-Object status -eq 'Failed') { 1 } else { 0 }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Pipeline -ConfigurationPath $ConfigurationPath -Force:$Force -DelayDays $DelayDays -SummaryPath $SummaryPath -Date $Date)
}
