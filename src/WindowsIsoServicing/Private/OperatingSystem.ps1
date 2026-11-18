function ConvertTo-ArchitectureName {
    <#
    .SYNOPSIS
        Converts the numeric image architecture from DISM to its name.

    .DESCRIPTION
        Maps the Architecture value of Get-WindowsImage (0, 9, 12) to x86, x64 or arm64. Other values, including 5
        (32-bit ARM, which none of the supported releases ships as installation media), throw, so an unsupported
        architecture is refused before any servicing starts.

    .PARAMETER Architecture
        Architecture value reported by Get-WindowsImage.

    .EXAMPLE
        ConvertTo-ArchitectureName -Architecture 9

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
        [int]$Architecture
    )
    switch ($Architecture) {
        0 { 'x86' }
        9 { 'x64' }
        12 { 'arm64' }
        default { throw "Unsupported image architecture value $Architecture." }
    }
}

function Resolve-WindowsRelease {
    <#
    .SYNOPSIS
        Identifies the Windows release of an image and its lifecycle status on a date.

    .DESCRIPTION
        Looks up the release by family (Server or Client, from the installation type) and build in
        Data\OperatingSystems.psd1. The first lifecycle rule whose EditionPattern matches the edition decides the channel,
        end of support and ESU end, and with them the status Supported, ExtendedSecurityUpdates or OutOfSupport.
        Builds listed as retired releases are returned as OutOfSupport. Other unknown builds are returned with the status
        Unknown and IsKnownRelease = $false rather than an error, so that callers can refuse them with a distinct error ID.
        Windows PE images throw.

    .PARAMETER Build
        Major build number of the image, for example 26100.

    .PARAMETER InstallationType
        InstallationType reported by Get-WindowsImage, for example 'Server', 'Server Core' or 'Client'.

    .PARAMETER EditionId
        EditionId reported by Get-WindowsImage, for example 'ServerDatacenter' or 'EnterpriseS'.

    .PARAMETER AsOf
        Date the lifecycle status is evaluated for. Defaults to today.

    .EXAMPLE
        Resolve-WindowsRelease -Build 26100 -InstallationType 'Server' -EditionId 'ServerDatacenter' -AsOf '2026-11-18'

    .OUTPUTS
        WindowsIsoServicing.OperatingSystem

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/lifecycle/
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [int]$Build,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$InstallationType,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$EditionId,
        [datetime]$AsOf = [datetime]::Today
    )
    if ($InstallationType -eq 'WindowsPE') {
        throw 'The image is a Windows PE image, not a Windows installation image.'
    }
    $family = if ($InstallationType -like 'Server*') { 'Server' } else { 'Client' }
    $release = $script:OperatingSystemData.Releases | Where-Object { $_.Family -eq $family -and $_.Build -eq $Build } | Select-Object -First 1
    if (-not $release) {
        $retired = $script:OperatingSystemData.RetiredReleases | Where-Object { $_.Family -eq $family -and $_.Build -eq $Build } | Select-Object -First 1
        return [pscustomobject]@{
            PSTypeName               = 'WindowsIsoServicing.OperatingSystem'
            Key                      = $null
            Name                     = if ($retired) { $retired.Name } else { "Unknown $family build $Build" }
            Version                  = $null
            Family                   = $family
            Build                    = $Build
            EditionId                = $EditionId
            Channel                  = $null
            LifecycleStatus          = if ($retired) { 'OutOfSupport' } else { 'Unknown' }
            EndOfSupport             = $null
            EsuEnd                   = $null
            FileNameStem             = $null
            UpdateProductText        = $null
            DynamicUpdateProductText = $null
            MsrcProductName          = $null
            Servicing                = $null
            IsKnownRelease           = $false
        }
    }
    $rule = $release.Lifecycle | Where-Object { $EditionId -match $_.EditionPattern } | Select-Object -First 1
    $endOfSupport = [datetime]::ParseExact($rule.EndOfSupport, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
    $esuEnd = if ($rule.EsuEnd) { [datetime]::ParseExact($rule.EsuEnd, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture) }
    $status = if ($AsOf.Date -le $endOfSupport) {
        'Supported'
    }
    elseif ($esuEnd -and $AsOf.Date -le $esuEnd) {
        'ExtendedSecurityUpdates'
    }
    else {
        'OutOfSupport'
    }
    [pscustomobject]@{
        PSTypeName               = 'WindowsIsoServicing.OperatingSystem'
        Key                      = $release.Key
        Name                     = $release.Name
        Version                  = $release.Version
        Family                   = $family
        Build                    = $Build
        EditionId                = $EditionId
        Channel                  = $rule.Channel
        LifecycleStatus          = $status
        EndOfSupport             = $endOfSupport
        EsuEnd                   = $esuEnd
        FileNameStem             = if ($rule.ContainsKey('FileNameStem')) { $rule.FileNameStem } else { $release.FileNameStem }
        UpdateProductText        = $release.UpdateProductText
        DynamicUpdateProductText = if ($release.ContainsKey('DynamicUpdateProductText')) { $release.DynamicUpdateProductText } else { $release.UpdateProductText }
        MsrcProductName          = $release.MsrcProductName
        Servicing                = [pscustomobject]$release.Servicing
        IsKnownRelease           = $true
    }
}

function Assert-ServiceableRelease {
    <#
    .SYNOPSIS
        Refuses media that is unknown, out of support, or ESU-only without a stated entitlement.

    .DESCRIPTION
        Throws a terminating error with a distinct error ID for the first operating system that cannot be serviced:
        UnsupportedMedia for unknown releases, OutOfSupportMedia for releases past end of support and ESU, and
        EsuEntitlementRequired for ESU-only releases when EsuEntitled is not set. The distinct IDs keep these cases from
        being reported as servicing failures (INVARIANTS.md, Lifecycle #1 and #2).

    .PARAMETER OperatingSystem
        Operating systems returned by Resolve-WindowsRelease, one per selected image index.

    .PARAMETER EsuEntitled
        States that the organization holds a valid Extended Security Updates entitlement. The tool does not check or
        activate ESU licenses.

    .EXAMPLE
        Assert-ServiceableRelease -OperatingSystem (Resolve-WindowsRelease -Build 19045 -InstallationType 'Client' -EditionId 'Enterprise') -EsuEntitled

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject[]]$OperatingSystem,
        [switch]$EsuEntitled
    )
    foreach ($os in $OperatingSystem) {
        switch ($os.LifecycleStatus) {
            'Unknown' {
                $exception = [System.NotSupportedException]::new("Unsupported media: $($os.Name) (edition $($os.EditionId)) is not a release known to this tool.")
                throw [System.Management.Automation.ErrorRecord]::new($exception, 'UnsupportedMedia', 'NotImplemented', $os)
            }
            'OutOfSupport' {
                $exception = [System.NotSupportedException]::new("Unsupported media: $($os.Name) $($os.Channel) (edition $($os.EditionId)) is out of support; Microsoft publishes no further updates for it.")
                throw [System.Management.Automation.ErrorRecord]::new($exception, 'OutOfSupportMedia', 'NotImplemented', $os)
            }
            'ExtendedSecurityUpdates' {
                if (-not $EsuEntitled) {
                    $exception = [System.UnauthorizedAccessException]::new("$($os.Name) $($os.Version) (edition $($os.EditionId)) is past end of support and only receives updates through the Extended Security Updates program. Specify -EsuEntitled to confirm the organization holds a valid ESU entitlement for every device installed from this media.")
                    throw [System.Management.Automation.ErrorRecord]::new($exception, 'EsuEntitlementRequired', 'PermissionDenied', $os)
                }
            }
        }
    }
}
