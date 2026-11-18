function Get-DefaultServicingPath {
    <#
    .SYNOPSIS
        Returns the default workspace or update cache folder.

    .DESCRIPTION
        Returns %ProgramData%\WindowsIsoServicing\Workspace or %ProgramData%\WindowsIsoServicing\Cache. Used as the
        default value of the WorkspacePath and CachePath parameters.

    .PARAMETER Kind
        Workspace or Cache.

    .EXAMPLE
        Get-DefaultServicingPath -Kind Cache

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
        [ValidateSet('Workspace', 'Cache')]
        [string]$Kind
    )
    Join-Path $env:ProgramData "WindowsIsoServicing\$Kind"
}

function New-ServicingContext {
    <#
    .SYNOPSIS
        Creates the per-run workspace layout and returns its paths.

    .DESCRIPTION
        Creates the media, work, mount, scratch and output staging folders under <WorkspacePath>\<RunId>, and the log
        folder (subject to -WhatIf and -Confirm). The returned context is passed to every servicing step. The workspace
        path must not contain whitespace, because OSCDIMG boot sector arguments cannot be quoted.

    .PARAMETER WorkspacePath
        Workspace root folder.

    .PARAMETER RunId
        Run identifier; the run folder is named after it.

    .PARAMETER LogPath
        Folder for the run log and the DISM logs.

    .PARAMETER ComponentCleanup
        Records that component cleanup is to run on every serviced image.

    .EXAMPLE
        New-ServicingContext -WorkspacePath 'D:\IsoServicing\Workspace' -RunId '20261118-080000-1a2b3c4d' -LogPath 'D:\ISO\Updated\logs\20261118-080000-1a2b3c4d'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with RunId, RunPath, MediaPath, WorkPath, MountRoot, ScratchPath,
        OutputStagingPath, LogPath, ComponentCleanup and CumulativeUpdatePath.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,
        [Parameter(Mandatory)]
        [string]$RunId,
        [Parameter(Mandatory)]
        [string]$LogPath,
        [switch]$ComponentCleanup
    )
    if ($WorkspacePath -match '\s') {
        throw "Workspace path '$WorkspacePath' must not contain whitespace."
    }
    $runPath = Join-Path $WorkspacePath $RunId
    $context = [pscustomobject]@{
        RunId                = $RunId
        RunPath              = $runPath
        MediaPath            = Join-Path $runPath 'media'
        WorkPath             = Join-Path $runPath 'work'
        MountRoot            = Join-Path $runPath 'mount'
        ScratchPath          = Join-Path $runPath 'scratch'
        OutputStagingPath    = Join-Path $runPath 'output'
        LogPath              = $LogPath
        ComponentCleanup     = [bool]$ComponentCleanup
        CumulativeUpdatePath = $null
    }
    if ($PSCmdlet.ShouldProcess($runPath, 'Create workspace')) {
        foreach ($path in $context.MediaPath, $context.WorkPath, $context.MountRoot, $context.ScratchPath, $context.OutputStagingPath, $context.LogPath) {
            $null = New-Item -Path $path -ItemType Directory -Force
        }
    }
    $context
}

function Remove-ServicingWorkspace {
    <#
    .SYNOPSIS
        Discards leftover mounts and deletes the run workspace.

    .DESCRIPTION
        Discards every image still mounted under the run's mount folder. When an image cannot be dismounted, the workspace
        is kept and a warning names the mounts, because deleting a folder that holds a mounted image corrupts the mount.
        Otherwise the run folder is deleted (subject to -WhatIf and -Confirm).

    .PARAMETER Context
        Servicing context returned by New-ServicingContext.

    .EXAMPLE
        Remove-ServicingWorkspace -Context $context

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $leftovers = @(Clear-ServicingMount -Root $Context.MountRoot -Confirm:$false)
    if ($leftovers.Count -gt 0) {
        Write-ServicingLog -Operation 'Cleanup' -Level Warning -Target $Context.RunPath -Message "Workspace kept because images are still mounted: $($leftovers -join ', ')"
        return
    }
    if ((Test-Path -LiteralPath $Context.RunPath) -and $PSCmdlet.ShouldProcess($Context.RunPath, 'Remove workspace')) {
        Remove-Item -LiteralPath $Context.RunPath -Recurse -Force -ErrorAction Stop
    }
}
