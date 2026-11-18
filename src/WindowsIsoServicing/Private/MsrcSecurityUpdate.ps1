$script:MsrcBaseUri = 'https://api.msrc.microsoft.com/cvrf/v3.0'
$script:MsrcArchitectureLabel = @{ x64 = 'x64-based'; arm64 = 'ARM64-based'; x86 = '32-bit' }
$script:MsrcDocumentCache = @{}

function Get-MsrcProductName {
    <#
    .SYNOPSIS
        Returns the MSRC product name of a release and architecture.

    .DESCRIPTION
        Formats the release's MsrcProductName from OperatingSystems.psd1 with the MSRC architecture label (x64-based,
        ARM64-based or 32-bit). Returns nothing for a release without an MSRC product name.

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .EXAMPLE
        Get-MsrcProductName -OperatingSystem $release -Architecture 'x64'

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
        [pscustomobject]$OperatingSystem,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture
    )
    if (-not $OperatingSystem.MsrcProductName) { return }
    $OperatingSystem.MsrcProductName -f $script:MsrcArchitectureLabel[$Architecture]
}

function Select-MsrcSecurityUpdate {
    <#
    .SYNOPSIS
        Selects the security update for a product from an MSRC CVRF document.

    .DESCRIPTION
        Looks up the product IDs of ProductName and returns the vendor-fix remediation (type 2) of subtype Security Update
        or Monthly Rollup with the highest fixed build. Remediations without a numeric KB or a valid fixed build are
        ignored. Returns nothing when the product is not in the document.

    .PARAMETER Document
        CVRF document from the MSRC Security Updates API, converted from JSON.

    .PARAMETER ProductName
        MSRC product name returned by Get-MsrcProductName.

    .EXAMPLE
        Select-MsrcSecurityUpdate -Document $cvrf -ProductName 'Windows Server 2025'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Kb, FixedBuild, Supersedes, SubType, ProductName and DocumentId.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Document,
        [Parameter(Mandatory)]
        [string]$ProductName
    )
    $productIds = @($Document.ProductTree.FullProductName | Where-Object Value -eq $ProductName | ForEach-Object ProductID)
    if ($productIds.Count -eq 0) { return }
    $candidates = foreach ($vulnerability in $Document.Vulnerability) {
        foreach ($remediation in @($vulnerability.PSObject.Properties['Remediations']?.Value)) {
            if ($null -eq $remediation -or $remediation.Type -ne 2) { continue }
            if ($remediation.PSObject.Properties['SubType']?.Value -notin 'Security Update', 'Monthly Rollup') { continue }
            if (-not @($remediation.ProductID | Where-Object { $_ -in $productIds })) { continue }
            $kb = [string]$remediation.Description.Value
            $build = $null
            if ($kb -notmatch '^\d+$' -or -not [version]::TryParse([string]$remediation.PSObject.Properties['FixedBuild']?.Value, [ref]$build)) { continue }
            [pscustomobject]@{
                Kb          = "KB$kb"
                FixedBuild  = $build
                Supersedes  = if ($remediation.PSObject.Properties['Supercedence']?.Value -match '^\d+$') { "KB$($remediation.Supercedence)" }
                SubType     = $remediation.SubType
                ProductName = $ProductName
                DocumentId  = $Document.DocumentTracking.Identification.ID.Value
            }
        }
    }
    $candidates | Sort-Object FixedBuild -Descending | Select-Object -First 1
}

function Get-MsrcSecurityUpdate {
    <#
    .SYNOPSIS
        Returns the latest security update MSRC lists for a product.

    .DESCRIPTION
        Reads the release list of the MSRC Security Updates API, picks the latest monthly release (yyyy-MMM) released on
        or before AsOf, and selects the product's security update from its CVRF document. The CVRF document is about
        30 MB, so it is cached for the session per document URL and revision date. The update is the security baseline
        the Catalog plan must reach.

    .PARAMETER ProductName
        MSRC product name returned by Get-MsrcProductName.

    .PARAMETER AsOf
        Date of the newest release to use. Defaults to now (UTC).

    .EXAMPLE
        Get-MsrcSecurityUpdate -ProductName 'Windows Server 2025'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://github.com/microsoft/MSRC-Microsoft-Security-Updates-API
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ProductName,
        [datetime]$AsOf = [datetime]::UtcNow
    )
    $headers = @{ Accept = 'application/json' }
    $index = Invoke-UpdateSourceRequest -Uri "$script:MsrcBaseUri/updates" -Headers $headers | ConvertFrom-Json -Depth 5
    $release = @($index.value) | Where-Object { $_.ID -match '^\d{4}-[A-Z][a-z]{2}$' -and [datetime]$_.InitialReleaseDate -le $AsOf } | Sort-Object { [datetime]$_.InitialReleaseDate } -Descending | Select-Object -First 1
    if (-not $release) { throw "The MSRC Security Updates API lists no monthly security release on or before $($AsOf.ToString('yyyy-MM-dd'))." }
    $cacheKey = "$($release.CvrfUrl)|$($release.CurrentReleaseDate)"
    if (-not $script:MsrcDocumentCache.ContainsKey($cacheKey)) {
        $script:MsrcDocumentCache[$cacheKey] = Invoke-UpdateSourceRequest -Uri $release.CvrfUrl -Headers $headers | ConvertFrom-Json -Depth 20
    }
    $document = $script:MsrcDocumentCache[$cacheKey]
    $update = Select-MsrcSecurityUpdate -Document $document -ProductName $ProductName
    $message = if ($update) { "$($update.Kb) (build $($update.FixedBuild))" } else { 'no security update' }
    Write-ServicingLog -Operation 'Discover' -Target 'MSRC' -Message "$($release.ID): $message for '$ProductName'"
    $update
}
