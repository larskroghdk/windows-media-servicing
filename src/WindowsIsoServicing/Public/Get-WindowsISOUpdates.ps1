function Get-WindowsISOUpdates {

    <#
    .SYNOPSIS
        Determines which Microsoft updates apply to the media in a Windows installation ISO.

    .DESCRIPTION
        Identifies the Windows release of the ISO and finds the latest cumulative update, servicing stack update (where
        Microsoft publishes one separately), .NET Framework cumulative updates, Safe OS Dynamic Update and Setup Dynamic
        Update. Superseded updates and cumulative updates that are not security releases are excluded unless
        -IncludePreview is used; excluded newer releases are listed in the plan notes. For releases with checkpoint
        cumulative updates, the checkpoint MSU files published with the target update are included.
        Update sources:
          (default)        Microsoft Update Catalog, cross-checked with the MSRC Security Updates API. The Catalog has
                           no documented API; see docs\update-discovery.md for what is read and how failures surface.
          -RepositoryPath  A local package repository index (updates.json), such as a copied update cache.
        The host's own Windows Update or WSUS configuration is never read or used.

    .PARAMETER SourceISO
        Path to the Windows installation ISO.

    .PARAMETER InputObject
        Output of Get-WindowsISOInfo, to avoid inspecting the ISO again.

    .PARAMETER RepositoryPath
        Package repository folder that contains updates.json. When omitted, the Microsoft Update Catalog is used.

    .PARAMETER IncludePreview
        Includes cumulative updates that are not security releases: optional preview releases and non-security
        out-of-band releases. The Catalog metadata does not distinguish the two.

    .PARAMETER MaximumAgeDays
        Ignores Catalog updates last modified more than this number of days ago.

    .EXAMPLE
        Get-WindowsISOUpdates -SourceISO 'D:\ISO\Windows_Server_2025.iso'

    .EXAMPLE
        Get-WindowsISOInfo -SourceISO 'D:\ISO\Windows_11_24H2.iso' | Get-WindowsISOUpdates -RepositoryPath 'E:\UpdateCache'

    .OUTPUTS
        WindowsIsoServicing.UpdatePlan

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        Save-WindowsISOUpdate

    .LINK
        Update-WindowsISO

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Public command name is part of the documented module interface.')]
    [CmdletBinding(DefaultParameterSetName = 'IsoCatalog')]
    [OutputType('WindowsIsoServicing.UpdatePlan')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'IsoCatalog')]
        [Parameter(Mandatory, ParameterSetName = 'IsoRepository')]
        [ValidateNotNullOrEmpty()]
        [string]$SourceISO,
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InfoCatalog')]
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'InfoRepository')]
        [PSTypeName('WindowsIsoServicing.IsoInfo')]
        [pscustomobject]$InputObject,
        [Parameter(Mandatory, ParameterSetName = 'IsoRepository')]
        [Parameter(Mandatory, ParameterSetName = 'InfoRepository')]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath,
        [Parameter(ParameterSetName = 'IsoCatalog')]
        [Parameter(ParameterSetName = 'InfoCatalog')]
        [ValidateRange(30, 3650)]
        [int]$MaximumAgeDays = 400,
        [switch]$IncludePreview
    )

    process {
        $info = if ($InputObject) { $InputObject } else { Get-WindowsISOInfo -SourceISO $SourceISO -SkipChecksum }
        if (@($info.Build).Count -ne 1 -or @($info.Architecture).Count -ne 1) {
            throw 'The installation image mixes builds or architectures; such media is not supported.'
        }
        $os = $info.OperatingSystem
        if (-not $os.IsKnownRelease) {
            Write-Warning "$($os.Name) is not supported by this tool (lifecycle status: $($os.LifecycleStatus))."
            return
        }
        $planParameters = @{
            OperatingSystem = $os
            Architecture    = $info.Architecture
            IncludePreview  = $IncludePreview
        }
        if ($RepositoryPath) {
            $planParameters.RepositoryPath = Resolve-DirectoryPath -Path $RepositoryPath
        }
        else {
            $planParameters.MaximumAgeDays = $MaximumAgeDays
        }
        Get-UpdatePlan @planParameters
    }
}
