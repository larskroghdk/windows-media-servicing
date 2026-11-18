$script:HResultModuleNotFound = -2147024770
$script:HResultNotApplicable = -2146498530
$script:HResultPendingOperations = -2146498554

function Test-ErrorHResult {
    <#
    .SYNOPSIS
        Tests whether an error record carries a specific HRESULT.

    .DESCRIPTION
        Checks the HResult and the message of the exception and of every inner exception, and finally the error record
        text, for the HRESULT in 0x00000000 notation. DISM cmdlets report some failures only in the message, so the
        message check is needed to recognize the tolerated results listed in INVARIANTS.md (Servicing #2).

    .PARAMETER ErrorRecord
        Error record caught from a DISM cmdlet.

    .PARAMETER HResult
        HRESULT to look for, as a signed integer, for example -2146498530 for 0x800F081E.

    .EXAMPLE
        Test-ErrorHResult -ErrorRecord $_ -HResult $script:HResultNotApplicable

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
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory)]
        [int]$HResult
    )
    $hex = '0x{0:x8}' -f $HResult
    $exception = $ErrorRecord.Exception
    while ($exception) {
        if ($exception.HResult -eq $HResult -or $exception.Message -match $hex) { return $true }
        $exception = $exception.InnerException
    }
    $ErrorRecord.ToString() -match $hex
}

function Mount-ServicingImage {
    <#
    .SYNOPSIS
        Mounts one index of a WIM file for servicing.

    .DESCRIPTION
        Creates the mount folder, refuses a folder that is not empty, and mounts the index with Mount-WindowsImage using
        the run's scratch folder and a DISM log in the run's log folder (subject to -WhatIf and -Confirm).

    .PARAMETER ImagePath
        Path of the WIM file.

    .PARAMETER Index
        Image index to mount.

    .PARAMETER MountPath
        Empty folder to mount the image in.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext.

    .PARAMETER ReadOnly
        Mounts the image read-only.

    .EXAMPLE
        Mount-ServicingImage -ImagePath 'D:\IsoServicing\Workspace\20261118-080000-1a2b3c4d\work\install-source.wim' -Index 2 -MountPath 'D:\IsoServicing\Workspace\20261118-080000-1a2b3c4d\mount\install-2' -Context $context

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/dism/mount-windowsimage
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,
        [Parameter(Mandatory)]
        [int]$Index,
        [Parameter(Mandatory)]
        [string]$MountPath,
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [switch]$ReadOnly
    )
    if (-not $PSCmdlet.ShouldProcess("$ImagePath index $Index", "Mount at $MountPath")) { return }
    $null = New-Item -Path $MountPath -ItemType Directory -Force
    if (Get-ChildItem -LiteralPath $MountPath -Force | Select-Object -First 1) {
        throw "Mount directory '$MountPath' is not empty."
    }
    Write-ServicingLog -Operation 'MountImage' -Target "$ImagePath#$Index" -Message "Mounting at $MountPath"
    $null = Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $MountPath -ReadOnly:$ReadOnly -ScratchDirectory $Context.ScratchPath -LogPath (Join-Path $Context.LogPath 'dism-mount.log') -ErrorAction Stop
}

function Dismount-ServicingImage {
    <#
    .SYNOPSIS
        Dismounts a servicing image, saving or discarding the changes.

    .DESCRIPTION
        With Save, commits the changes and checks the image integrity; otherwise discards them. Afterwards the empty mount
        folder is deleted if possible. A folder that cannot be deleted is left without an error, because it is inside the
        run workspace, which Remove-ServicingWorkspace deletes.

    .PARAMETER MountPath
        Mount folder of the image.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext.

    .PARAMETER Save
        Commits the changes. Without it the changes are discarded.

    .EXAMPLE
        Dismount-ServicingImage -MountPath $mountPath -Context $context -Save

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/dism/dismount-windowsimage
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [switch]$Save
    )
    $action = if ($Save) { 'Commit and dismount' } else { 'Discard and dismount' }
    if (-not $PSCmdlet.ShouldProcess($MountPath, $action)) { return }
    Write-ServicingLog -Operation 'DismountImage' -Target $MountPath -Message $action
    $logPath = Join-Path $Context.LogPath 'dism-dismount.log'
    if ($Save) {
        $null = Dismount-WindowsImage -Path $MountPath -Save -CheckIntegrity -ScratchDirectory $Context.ScratchPath -LogPath $logPath -ErrorAction Stop
    }
    else {
        $null = Dismount-WindowsImage -Path $MountPath -Discard -ScratchDirectory $Context.ScratchPath -LogPath $logPath -ErrorAction Stop
    }
    Remove-Item -LiteralPath $MountPath -Force -ErrorAction SilentlyContinue
}

function Undo-ServicingMount {
    <#
    .SYNOPSIS
        Discards a mounted image after a servicing failure and rethrows the original error.

    .DESCRIPTION
        Called from the catch block of a servicing step. Discards the mounted image. If the discard fails too, that
        failure is only logged, because Clear-ServicingMount in the run's finally block retries the discard, and the
        servicing error is the one to report. Always ends by throwing Failure.

    .PARAMETER MountPath
        Mount folder of the image.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext.

    .PARAMETER Failure
        Error record of the servicing failure.

    .EXAMPLE
        try { Add-ServicingPackage -MountPath $mountPath -PackagePath $packagePath -Component 'WinRE' -Context $context } catch { Undo-ServicingMount -MountPath $mountPath -Context $context -Failure $_ }

    .OUTPUTS
        None. The function always throws.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$Failure
    )
    try {
        Dismount-ServicingImage -MountPath $MountPath -Context $Context
    }
    catch {
        Write-ServicingLog -Operation 'DismountImage' -Level Error -Target $MountPath -Message "Discarding the image after a servicing failure also failed: $_"
    }
    throw $Failure
}

function Clear-ServicingMount {
    <#
    .SYNOPSIS
        Discards every image still mounted under a folder.

    .DESCRIPTION
        Lists the mounted images and discards those whose mount path is under Root (subject to -WhatIf and -Confirm). An
        image that cannot be dismounted is logged with the next step (close the processes using the folder, then run
        dism /Cleanup-Mountpoints) and its path is returned, so the caller can keep the folder instead of deleting it.

    .PARAMETER Root
        Folder whose mounted images are discarded.

    .EXAMPLE
        Clear-ServicingMount -Root 'D:\IsoServicing\Workspace\20261118-080000-1a2b3c4d\mount'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )
    $rootPrefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($mounted in @(Get-WindowsImage -Mounted -ErrorAction Stop)) {
        if (-not ($mounted.Path + '\').StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $PSCmdlet.ShouldProcess($mounted.Path, 'Discard and dismount leftover image')) { continue }
        try {
            $null = Dismount-WindowsImage -Path $mounted.Path -Discard -ErrorAction Stop
            Write-ServicingLog -Operation 'Cleanup' -Level Warning -Target $mounted.Path -Message 'Discarded leftover mounted image'
        }
        catch {
            Write-ServicingLog -Operation 'Cleanup' -Level Error -Target $mounted.Path -Message "Unable to dismount: $_. Run 'dism /Cleanup-Mountpoints' after closing processes that use the mount folder."
            $mounted.Path
        }
    }
}

function Add-ServicingPackage {
    <#
    .SYNOPSIS
        Adds an update package to a mounted image and returns the result.

    .DESCRIPTION
        Adds the package with Add-WindowsPackage (subject to -WhatIf and -Confirm) and returns 'Installed'. Only the DISM
        results that INVARIANTS.md (Servicing #2) tolerates are accepted, and only when the caller allows them:
        0x800F081E (not applicable) returns 'NotApplicable' with AllowNotApplicable, and 0x8007007E returns
        'InstalledWithKnownIssue' with AllowCombinedUpdateKnownIssue. Microsoft documents 0x8007007E as a known issue when
        the combined cumulative update is added to WinPE or WinRE. Every other failure is logged and rethrown.

    .PARAMETER MountPath
        Mount folder of the image.

    .PARAMETER PackagePath
        Path of the MSU or CAB file, or of the target MSU in a checkpoint folder.

    .PARAMETER Component
        Name of the image being serviced, for example 'WinRE' or 'Install2'. Used in log entries and DISM log names.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext.

    .PARAMETER AllowNotApplicable
        Accepts 0x800F081E. Used for servicing stack and .NET packages, which do not apply to every image.

    .PARAMETER AllowCombinedUpdateKnownIssue
        Accepts 0x8007007E. Used when the combined cumulative update is added to WinPE or WinRE.

    .EXAMPLE
        Add-ServicingPackage -MountPath $mountPath -PackagePath 'E:\UpdateCache\packages\KB5127690\windows11.0-kb5127690-x64-ndp481.msu' -Component 'Install1' -Context $context -AllowNotApplicable

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [Parameter(Mandatory)]
        [string]$PackagePath,
        [Parameter(Mandatory)]
        [string]$Component,
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [switch]$AllowNotApplicable,
        [switch]$AllowCombinedUpdateKnownIssue
    )
    $packageName = Split-Path $PackagePath -Leaf
    if (-not $PSCmdlet.ShouldProcess($MountPath, "Add package $packageName")) { return }
    Write-ServicingLog -Operation 'AddPackage' -Target $Component -Message "Adding $packageName" -Data @{ package = $PackagePath }
    try {
        $null = Add-WindowsPackage -Path $MountPath -PackagePath $PackagePath -ScratchDirectory $Context.ScratchPath -LogPath (Join-Path $Context.LogPath "dism-$Component-$([System.IO.Path]::GetFileNameWithoutExtension($packageName)).log") -ErrorAction Stop
        'Installed'
    }
    catch {
        if ($AllowNotApplicable -and (Test-ErrorHResult -ErrorRecord $_ -HResult $script:HResultNotApplicable)) {
            Write-ServicingLog -Operation 'AddPackage' -Level Warning -Target $Component -Message "$packageName is not applicable to this image (0x800F081E)"
            return 'NotApplicable'
        }
        if ($AllowCombinedUpdateKnownIssue -and (Test-ErrorHResult -ErrorRecord $_ -HResult $script:HResultModuleNotFound)) {
            Write-ServicingLog -Operation 'AddPackage' -Level Warning -Target $Component -Message "$packageName reported the documented combined cumulative update issue 0x8007007E; continuing"
            return 'InstalledWithKnownIssue'
        }
        Write-ServicingLog -Operation 'AddPackage' -Level Error -Target $Component -Message "Failed to add ${packageName}: $_"
        throw
    }
}

function Get-RollupVersion {
    <#
    .SYNOPSIS
        Returns the version of the newest installed cumulative update package in an image.

    .DESCRIPTION
        Reads the installed or install-pending Package_for_RollupFix packages and returns the highest version from their
        names, for example 26100.7171.1.5, whose minor part is the OS build revision. Returns nothing when the image has no
        cumulative update.

    .PARAMETER MountPath
        Mount folder of the image, or the root of an installed Windows volume.

    .EXAMPLE
        Get-RollupVersion -MountPath 'D:\IsoServicing\Workspace\20261118-080000-1a2b3c4d\mount\install-1'

    .OUTPUTS
        System.Version

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath
    )
    $versions = foreach ($package in Get-WindowsPackage -Path $MountPath -ErrorAction Stop) {
        if ($package.PackageName -like 'Package_for_RollupFix~*' -and $package.PackageState -in 'Installed', 'InstallPending') {
            [version]($package.PackageName -split '~')[-1]
        }
    }
    $versions | Sort-Object -Descending | Select-Object -First 1
}

function Get-InstalledPackageList {
    <#
    .SYNOPSIS
        Lists the update packages installed in a mounted image.

    .DESCRIPTION
        Returns name, state, release type and install time of each package from Get-WindowsPackage. Feature, language,
        on-demand and foundation packages are left out, so the list shows the updates the manifest records.

    .PARAMETER MountPath
        Mount folder of the image.

    .EXAMPLE
        Get-InstalledPackageList -MountPath $mountPath

    .OUTPUTS
        System.Management.Automation.PSCustomObject with PackageName, State, ReleaseType and InstallTime.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath
    )
    Get-WindowsPackage -Path $MountPath -ErrorAction Stop | Where-Object { $_.ReleaseType -notin 'FeaturePack', 'LanguagePack', 'OnDemandPack', 'Foundation' } | ForEach-Object {
        [pscustomobject]@{
            PackageName = $_.PackageName
            State       = [string]$_.PackageState
            ReleaseType = [string]$_.ReleaseType
            InstallTime = $_.InstallTime
        }
    }
}

function Invoke-ComponentCleanup {
    <#
    .SYNOPSIS
        Runs DISM component cleanup on a mounted image.

    .DESCRIPTION
        Runs dism.exe /Cleanup-Image /StartComponentCleanup, which has no PowerShell cmdlet (subject to -WhatIf and
        -Confirm). /ResetBase is never used (INVARIANTS.md, Servicing #4). Exit code 0x800F0806 means the image has pending
        operations that complete at first boot; cleanup is then skipped with a warning, as INVARIANTS.md allows.

    .PARAMETER MountPath
        Mount folder of the image.

    .PARAMETER Component
        Name of the image being serviced, used in the log and the DISM log name.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext.

    .EXAMPLE
        Invoke-ComponentCleanup -MountPath $mountPath -Component 'Install1' -Context $context

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [Parameter(Mandatory)]
        [string]$Component,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $PSCmdlet.ShouldProcess($MountPath, 'Start component cleanup')) { return }
    $dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
    $arguments = @(
        "/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup', '/English',
        "/ScratchDir:$($Context.ScratchPath)", "/LogPath:$(Join-Path $Context.LogPath "dism-$Component-cleanup.log")"
    )
    $result = Invoke-ExternalTool -FilePath $dism -ArgumentList $arguments -Operation "ComponentCleanup $Component" -SuccessExitCodes 0, $script:HResultPendingOperations
    if ($result.ExitCode -eq $script:HResultPendingOperations) {
        Write-ServicingLog -Operation 'ComponentCleanup' -Level Warning -Target $Component -Message 'Skipped: the image has pending operations that complete on first boot (0x800F0806).'
    }
}

function New-CumulativeUpdateFolder {
    <#
    .SYNOPSIS
        Stages a cumulative update and its checkpoint updates in one folder.

    .DESCRIPTION
        Copies every file of the cumulative update into <WorkPath>\packages\<KB> (subject to -WhatIf and -Confirm) and
        returns the path of the target package. DISM installs the checkpoint MSUs it finds next to the target MSU, so the
        folder holds only the target and its checkpoints (INVARIANTS.md, Update discovery #4).

    .PARAMETER Update
        Cumulative update from the update plan, with downloaded files.

    .PARAMETER WorkPath
        Work folder of the run.

    .EXAMPLE
        New-CumulativeUpdateFolder -Update $cumulative -WorkPath $context.WorkPath

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Update,
        [Parameter(Mandatory)]
        [string]$WorkPath
    )
    $folder = Join-Path $WorkPath "packages\$($Update.Kb)"
    if (-not $PSCmdlet.ShouldProcess($folder, 'Stage cumulative update packages')) { return }
    $null = New-Item -Path $folder -ItemType Directory -Force
    foreach ($file in $Update.Files) {
        Copy-Item -LiteralPath $file.Path -Destination (Join-Path $folder $file.Name) -Force -ErrorAction Stop
    }
    $target = @($Update.Files | Where-Object Role -In 'Target', 'Package')
    if ($target.Count -ne 1) { throw "Cumulative update $($Update.Kb) must have exactly one target package." }
    Join-Path $folder $target[0].Name
}

function New-AppliedRecord {
    <#
    .SYNOPSIS
        Creates the manifest record of an update applied to an image.

    .DESCRIPTION
        Returns KB, category, title and result of the update, and name, role and SHA-256 of each package file, in the
        shape the manifest stores under images.

    .PARAMETER Update
        Update from the update plan.

    .PARAMETER Result
        Result of Add-ServicingPackage, for example 'Installed' or 'NotApplicable'.

    .EXAMPLE
        New-AppliedRecord -Update $safeOs -Result 'Installed'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with kb, category, title, result and packages.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Update,
        [Parameter(Mandatory)]
        [string]$Result
    )
    [pscustomobject][ordered]@{
        kb       = $Update.Kb
        category = $Update.Category
        title    = $Update.Title
        result   = $Result
        packages = @($Update.Files | ForEach-Object { [ordered]@{ name = $_.Name; role = $_.Role; sha256 = $_.Sha256 } })
    }
}

function Update-WinReImage {
    <#
    .SYNOPSIS
        Services a copy of the Windows Recovery Environment image.

    .DESCRIPTION
        Follows the WinRE step of Microsoft's Dynamic Update media sequence (INVARIANTS.md, Servicing #1): adds the
        standalone servicing stack updates, or on releases with a combined servicing stack the cumulative update for its
        servicing stack only, and then the Safe OS Dynamic Update. Runs component cleanup when the context requests it,
        commits the image and exports it to DestinationPath.
        Without a Safe OS Dynamic Update in the plan, WinRE is left unchanged and the result says why. On a failure the
        mount is discarded and the error rethrown.

    .PARAMETER WinRePath
        Writable copy of Winre.wim from the install image.

    .PARAMETER DestinationPath
        Path of the exported, serviced WinRE image.

    .PARAMETER Plan
        Update plan with downloaded files.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext. Its CumulativeUpdatePath must be set when the plan has a
        cumulative update.

    .EXAMPLE
        Update-WinReImage -WinRePath "$($context.WorkPath)\winre-0123456789ab-source.wim" -DestinationPath "$($context.WorkPath)\winre-0123456789ab.wim" -Plan $plan -Context $context

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Serviced, Reason, VersionBefore, VersionAfter and Applied.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$WinRePath,
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        [Parameter(Mandatory)]
        [pscustomobject]$Plan,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $safeOs = $Plan.Updates | Where-Object Category -EQ 'SafeOsDynamicUpdate' | Select-Object -First 1
    $versionBefore = (Get-WindowsImage -ImagePath $WinRePath -Index 1 -ErrorAction Stop).Version
    if (-not $safeOs) {
        return [pscustomobject]@{ Serviced = $false; Reason = 'No Safe OS Dynamic Update available'; VersionBefore = $versionBefore; VersionAfter = $versionBefore; Applied = @() }
    }
    if (-not $PSCmdlet.ShouldProcess($WinRePath, 'Service WinRE')) { return }
    $servicing = $Plan.OperatingSystem.Servicing
    $mountPath = Join-Path $Context.MountRoot 'winre'
    $applied = [System.Collections.Generic.List[object]]::new()
    Mount-ServicingImage -ImagePath $WinRePath -Index 1 -MountPath $mountPath -Context $Context
    try {
        foreach ($stack in $Plan.Updates | Where-Object Category -EQ 'ServicingStack') {
            $result = Add-ServicingPackage -MountPath $mountPath -PackagePath $stack.Files[0].Path -Component 'WinRE' -Context $Context -AllowNotApplicable
            $applied.Add((New-AppliedRecord -Update $stack -Result $result))
        }
        $cumulative = $Plan.Updates | Where-Object Category -EQ 'CumulativeUpdate' | Select-Object -First 1
        if ($servicing.ServicingStackCombined -and $cumulative) {
            $result = Add-ServicingPackage -MountPath $mountPath -PackagePath $Context.CumulativeUpdatePath -Component 'WinRE' -Context $Context -AllowCombinedUpdateKnownIssue
            $applied.Add((New-AppliedRecord -Update $cumulative -Result "ServicingStackOnly:$result"))
        }
        $result = Add-ServicingPackage -MountPath $mountPath -PackagePath $safeOs.Files[0].Path -Component 'WinRE' -Context $Context
        $applied.Add((New-AppliedRecord -Update $safeOs -Result $result))
        if ($Context.ComponentCleanup) { Invoke-ComponentCleanup -MountPath $mountPath -Component 'WinRE' -Context $Context }
        Dismount-ServicingImage -MountPath $mountPath -Context $Context -Save
    }
    catch {
        Undo-ServicingMount -MountPath $mountPath -Context $Context -Failure $_
    }
    $null = Export-WindowsImage -SourceImagePath $WinRePath -SourceIndex 1 -DestinationImagePath $DestinationPath -CheckIntegrity -ScratchDirectory $Context.ScratchPath -LogPath (Join-Path $Context.LogPath 'dism-export-winre.log') -ErrorAction Stop
    [pscustomobject]@{
        Serviced      = $true
        Reason        = $null
        VersionBefore = $versionBefore
        VersionAfter  = (Get-WindowsImage -ImagePath $DestinationPath -Index 1 -ErrorAction Stop).Version
        Applied       = @($applied)
    }
}

function Update-BootImage {
    <#
    .SYNOPSIS
        Services every index of boot.wim and saves the updated setup binaries.

    .DESCRIPTION
        For each index of boot.wim: adds the servicing stack updates and the cumulative update, runs component cleanup
        when the context requests it, and exports the index to a new boot.wim, which then replaces the original. From the
        index that contains Windows Setup, the serviced setup.exe, setuphost.exe and boot manager files are saved for
        Update-SetupMedia.
        On releases with a combined servicing stack, the cumulative update is added twice, as in Microsoft's sample
        (steps 17 and 23): the first add installs its servicing stack and may report the documented 0x8007007E issue,
        the second installs the update itself and must succeed.
        Releases serviced with monthly rollups, and plans without a cumulative update, leave boot.wim unchanged. On a
        failure the mount is discarded and the error rethrown.

    .PARAMETER BootImagePath
        Path of boot.wim in the media copy.

    .PARAMETER Plan
        Update plan with downloaded files.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext, with CumulativeUpdatePath set.

    .EXAMPLE
        Update-BootImage -BootImagePath "$($context.MediaPath)\sources\boot.wim" -Plan $plan -Context $context

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Serviced, Reason, Indexes and SetupFiles.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$BootImagePath,
        [Parameter(Mandatory)]
        [pscustomobject]$Plan,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    $cumulative = $Plan.Updates | Where-Object Category -EQ 'CumulativeUpdate' | Select-Object -First 1
    if ($Plan.OperatingSystem.Servicing.Model -ne 'Cumulative' -or -not $cumulative) {
        return [pscustomobject]@{ Serviced = $false; Reason = 'No applicable WinPE servicing'; Indexes = @(); SetupFiles = $null }
    }
    if (-not $PSCmdlet.ShouldProcess($BootImagePath, 'Service WinPE (boot.wim)')) { return }
    $exportPath = Join-Path $Context.WorkPath 'boot.wim'
    $setupFilesPath = Join-Path $Context.WorkPath 'setup-files'
    $null = New-Item -Path $setupFilesPath -ItemType Directory -Force
    $setupFiles = $null
    $indexes = [System.Collections.Generic.List[object]]::new()
    foreach ($image in @(Get-WindowsImage -ImagePath $BootImagePath -ErrorAction Stop)) {
        $index = $image.ImageIndex
        $detail = Get-WindowsImage -ImagePath $BootImagePath -Index $index -ErrorAction Stop
        $versionBefore = $detail.Version
        $mountPath = Join-Path $Context.MountRoot "boot-$index"
        $applied = [System.Collections.Generic.List[object]]::new()
        Mount-ServicingImage -ImagePath $BootImagePath -Index $index -MountPath $mountPath -Context $Context
        try {
            foreach ($stack in $Plan.Updates | Where-Object Category -EQ 'ServicingStack') {
                $result = Add-ServicingPackage -MountPath $mountPath -PackagePath $stack.Files[0].Path -Component "WinPE$index" -Context $Context -AllowNotApplicable
                $applied.Add((New-AppliedRecord -Update $stack -Result $result))
            }
            if ($Plan.OperatingSystem.Servicing.ServicingStackCombined) {
                $result = Add-ServicingPackage -MountPath $mountPath -PackagePath $Context.CumulativeUpdatePath -Component "WinPE$index" -Context $Context -AllowCombinedUpdateKnownIssue
                $applied.Add((New-AppliedRecord -Update $cumulative -Result "ServicingStackOnly:$result"))
            }
            $result = Add-ServicingPackage -MountPath $mountPath -PackagePath $Context.CumulativeUpdatePath -Component "WinPE$index" -Context $Context
            $applied.Add((New-AppliedRecord -Update $cumulative -Result $result))
            if ($Context.ComponentCleanup) { Invoke-ComponentCleanup -MountPath $mountPath -Component "WinPE$index" -Context $Context }
            if (Test-Path -LiteralPath (Join-Path $mountPath 'sources\setup.exe') -PathType Leaf) {
                $setupFiles = Save-SetupBinary -MountPath $mountPath -Destination $setupFilesPath -Build $detail.Build
            }
            Dismount-ServicingImage -MountPath $mountPath -Context $Context -Save
        }
        catch {
            Undo-ServicingMount -MountPath $mountPath -Context $Context -Failure $_
        }
        $null = Export-WindowsImage -SourceImagePath $BootImagePath -SourceIndex $index -DestinationImagePath $exportPath -CheckIntegrity -ScratchDirectory $Context.ScratchPath -LogPath (Join-Path $Context.LogPath 'dism-export-boot.log') -ErrorAction Stop
        $indexes.Add([pscustomobject][ordered]@{
                index         = $index
                name          = $image.ImageName
                versionBefore = $versionBefore
                versionAfter  = (Get-WindowsImage -ImagePath $exportPath -Index $index -ErrorAction Stop).Version
                applied       = @($applied)
            })
    }
    Move-Item -LiteralPath $exportPath -Destination $BootImagePath -Force
    [pscustomobject]@{ Serviced = $true; Reason = $null; Indexes = @($indexes); SetupFiles = $setupFiles }
}

function Save-SetupBinary {
    <#
    .SYNOPSIS
        Copies the setup and boot manager binaries out of the serviced Windows Setup image.

    .DESCRIPTION
        Copies sources\setup.exe and the EFI boot manager files (bootmgfw.efi, bootmgr.efi, boot.stl) from the mounted
        WinPE index, plus sources\setuphost.exe on build 26100 and later, which Microsoft documents for those releases.
        setup.exe and setuphost.exe are required; the boot manager files are copied when present.

    .PARAMETER MountPath
        Mount folder of the serviced boot.wim index.

    .PARAMETER Destination
        Folder that receives the files.

    .PARAMETER Build
        Build number of the boot image.

    .EXAMPLE
        Save-SetupBinary -MountPath $mountPath -Destination "$($context.WorkPath)\setup-files" -Build 26100

    .OUTPUTS
        System.Management.Automation.PSCustomObject with one property per saved file.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$MountPath,
        [Parameter(Mandatory)]
        [string]$Destination,
        [Parameter(Mandatory)]
        [int]$Build
    )
    $saved = [ordered]@{}
    $files = [ordered]@{
        'setup.exe'    = 'sources\setup.exe'
        'bootmgfw.efi' = 'Windows\Boot\EFI\bootmgfw.efi'
        'bootmgr.efi'  = 'Windows\Boot\EFI\bootmgr.efi'
        'boot.stl'     = 'Windows\Boot\EFI\boot.stl'
    }
    if ($Build -ge 26100) { $files['setuphost.exe'] = 'sources\setuphost.exe' }
    foreach ($name in $files.Keys) {
        $source = Join-Path $MountPath $files[$name]
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $target = Join-Path $Destination $name
            Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
            $saved[$name] = $target
        }
        elseif ($name -in 'setup.exe', 'setuphost.exe') {
            throw "Expected '$($files[$name])' in the Windows Setup image but it was not found."
        }
    }
    [pscustomobject]$saved
}

function Copy-FileOverProtected {
    <#
    .SYNOPSIS
        Replaces a file that may be read-only, hidden or system, keeping its attributes.

    .DESCRIPTION
        Clears the attributes of an existing destination file, copies Source over it and restores the original
        attributes. Media and image files such as Winre.wim and the boot managers carry these attributes.

    .PARAMETER Source
        File to copy.

    .PARAMETER Destination
        File to replace or create.

    .EXAMPLE
        Copy-FileOverProtected -Source "$($context.WorkPath)\setup-files\setup.exe" -Destination "$($context.MediaPath)\sources\setup.exe"

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Destination
    )
    $attributes = $null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existing = Get-Item -LiteralPath $Destination -Force
        $attributes = $existing.Attributes
        $existing.Attributes = [System.IO.FileAttributes]::Normal
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
    if ($null -ne $attributes) { (Get-Item -LiteralPath $Destination -Force).Attributes = $attributes }
}

function Update-InstallImage {
    <#
    .SYNOPSIS
        Services the selected indexes of install.wim and exports every index.

    .DESCRIPTION
        For each selected index, in Microsoft's Dynamic Update media order: services WinRE (each distinct Winre.wim only
        once, identified by its SHA-256) and puts it back into the image, adds the servicing stack updates, the cumulative
        update, optional component cleanup and the .NET cumulative updates. Every MSU of a .NET rollup is added, and those
        for frameworks the image lacks report 0x800F081E. The cumulative update must change the image
        (Assert-CumulativeUpdateResult).
        Afterwards every index, serviced or not, is exported to DestinationPath with maximum compression, and the version
        after export is recorded. On a failure the mount is discarded and the error rethrown.

    .PARAMETER InstallImagePath
        Writable working copy of install.wim.

    .PARAMETER DestinationPath
        Path of the exported install.wim in the media copy.

    .PARAMETER Inventory
        Image inventory returned by Get-InstallImageInventory.

    .PARAMETER SelectedIndex
        Indexes to service. The others are exported unchanged.

    .PARAMETER Plan
        Update plan with downloaded files.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext, with CumulativeUpdatePath set.

    .EXAMPLE
        Update-InstallImage -InstallImagePath "$($context.WorkPath)\install-source.wim" -DestinationPath "$($context.MediaPath)\sources\install.wim" -Inventory $inventory -SelectedIndex 2, 4 -Plan $plan -Context $context

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$InstallImagePath,
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        [Parameter(Mandatory)]
        [pscustomobject[]]$Inventory,
        [Parameter(Mandatory)]
        [int[]]$SelectedIndex,
        [Parameter(Mandatory)]
        [pscustomobject]$Plan,
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )
    if (-not $PSCmdlet.ShouldProcess($InstallImagePath, "Service indexes $($SelectedIndex -join ', ')")) { return }
    $cumulative = $Plan.Updates | Where-Object Category -EQ 'CumulativeUpdate' | Select-Object -First 1
    $stacks = $Plan.Updates | Where-Object Category -EQ 'ServicingStack'
    $dotNet = $Plan.Updates | Where-Object Category -EQ 'DotNetCumulativeUpdate'
    $serviceWinRe = $Plan.OperatingSystem.Servicing.Model -eq 'Cumulative'
    $winReCache = @{}
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($image in $Inventory) {
        $index = $image.Index
        if ($index -notin $SelectedIndex) {
            $results.Add([pscustomobject][ordered]@{
                    index = $index; name = $image.Name; editionId = $image.EditionId; serviced = $false
                    versionBefore = $image.Version.ToString(); versionAfter = $image.Version.ToString()
                    rollupBefore = $null; rollupAfter = $null; winRe = $null; applied = @(); packages = @()
                })
            continue
        }
        $mountPath = Join-Path $Context.MountRoot "install-$index"
        $applied = [System.Collections.Generic.List[object]]::new()
        $winReRecord = $null
        Mount-ServicingImage -ImagePath $InstallImagePath -Index $index -MountPath $mountPath -Context $Context
        try {
            $rollupBefore = Get-RollupVersion -MountPath $mountPath
            $winRePath = Join-Path $mountPath 'Windows\System32\Recovery\Winre.wim'
            if (-not $serviceWinRe) {
                $winReRecord = [ordered]@{ present = (Test-Path -LiteralPath $winRePath); serviced = $false; reason = 'Release is not serviced with Safe OS Dynamic Updates' }
            }
            elseif (-not (Test-Path -LiteralPath $winRePath -PathType Leaf)) {
                $winReRecord = [ordered]@{ present = $false; serviced = $false; reason = 'Image contains no Windows\System32\Recovery\Winre.wim' }
                Write-ServicingLog -Operation 'WinRE' -Level Warning -Target "install.wim#$index" -Message 'No WinRE image present; skipped'
            }
            else {
                $originalHash = Get-FileSha256 -Path $winRePath
                if (-not $winReCache.ContainsKey($originalHash)) {
                    $workingCopy = Join-Path $Context.WorkPath "winre-$($originalHash.Substring(0, 12))-source.wim"
                    $servicedCopy = Join-Path $Context.WorkPath "winre-$($originalHash.Substring(0, 12)).wim"
                    Copy-Item -LiteralPath $winRePath -Destination $workingCopy -Force -ErrorAction Stop
                    (Get-Item -LiteralPath $workingCopy -Force).Attributes = [System.IO.FileAttributes]::Normal
                    $serviced = Update-WinReImage -WinRePath $workingCopy -DestinationPath $servicedCopy -Plan $Plan -Context $Context
                    $winReCache[$originalHash] = [pscustomobject]@{ Result = $serviced; Path = if ($serviced.Serviced) { $servicedCopy } }
                }
                $cached = $winReCache[$originalHash]
                if ($cached.Path) {
                    Copy-FileOverProtected -Source $cached.Path -Destination $winRePath
                }
                $winReRecord = [ordered]@{
                    present       = $true
                    serviced      = $cached.Result.Serviced
                    reason        = $cached.Result.Reason
                    sourceSha256  = $originalHash
                    versionBefore = [string]$cached.Result.VersionBefore
                    versionAfter  = [string]$cached.Result.VersionAfter
                    applied       = $cached.Result.Applied
                }
            }
            foreach ($stack in $stacks) {
                $result = Add-ServicingPackage -MountPath $mountPath -PackagePath $stack.Files[0].Path -Component "Install$index" -Context $Context -AllowNotApplicable
                $applied.Add((New-AppliedRecord -Update $stack -Result $result))
            }
            if ($cumulative) {
                $result = Add-ServicingPackage -MountPath $mountPath -PackagePath $Context.CumulativeUpdatePath -Component "Install$index" -Context $Context
                $applied.Add((New-AppliedRecord -Update $cumulative -Result $result))
            }
            if ($Context.ComponentCleanup) { Invoke-ComponentCleanup -MountPath $mountPath -Component "Install$index" -Context $Context }
            foreach ($package in $dotNet) {
                $result = @(foreach ($file in $package.Files) {
                        Add-ServicingPackage -MountPath $mountPath -PackagePath $file.Path -Component "Install$index" -Context $Context -AllowNotApplicable
                    }) -join ','
                $applied.Add((New-AppliedRecord -Update $package -Result $result))
            }
            $rollupAfter = Get-RollupVersion -MountPath $mountPath
            if ($cumulative) {
                Assert-CumulativeUpdateResult -Before $rollupBefore -After $rollupAfter -Update $cumulative -Target "install.wim#$index"
            }
            $packages = @(Get-InstalledPackageList -MountPath $mountPath)
            Dismount-ServicingImage -MountPath $mountPath -Context $Context -Save
        }
        catch {
            Undo-ServicingMount -MountPath $mountPath -Context $Context -Failure $_
        }
        $results.Add([pscustomobject][ordered]@{
                index         = $index
                name          = $image.Name
                editionId     = $image.EditionId
                serviced      = $true
                versionBefore = $image.Version.ToString()
                versionAfter  = $null
                rollupBefore  = [string]$rollupBefore
                rollupAfter   = [string]$rollupAfter
                winRe         = $winReRecord
                applied       = @($applied)
                packages      = $packages
            })
    }
    foreach ($image in $Inventory) {
        Write-ServicingLog -Operation 'ExportImage' -Target "install.wim#$($image.Index)" -Message "Exporting to $DestinationPath"
        $null = Export-WindowsImage -SourceImagePath $InstallImagePath -SourceIndex $image.Index -DestinationImagePath $DestinationPath -CompressionType max -CheckIntegrity -ScratchDirectory $Context.ScratchPath -LogPath (Join-Path $Context.LogPath 'dism-export-install.log') -ErrorAction Stop
    }
    foreach ($record in $results) {
        $record.versionAfter = (Get-WindowsImage -ImagePath $DestinationPath -Index $record.index -ErrorAction Stop).Version
    }
    $results.ToArray()
}

function Assert-CumulativeUpdateResult {
    <#
    .SYNOPSIS
        Throws unless adding a cumulative update changed the image.

    .DESCRIPTION
        Compares the Package_for_RollupFix version before and after the update (INVARIANTS.md, Servicing #3). The version
        must increase, unless the image was already at the OS build revision in the update title. When the title carries
        an OS build, the revision after the update must be at least that revision.

    .PARAMETER Before
        Rollup version before the update, or $null for an image without a cumulative update.

    .PARAMETER After
        Rollup version after the update.

    .PARAMETER Update
        Cumulative update from the update plan.

    .PARAMETER Target
        Name of the image in error messages, for example 'install.wim#2'.

    .EXAMPLE
        Assert-CumulativeUpdateResult -Before ([version]'26100.33650.1.7') -After ([version]'26100.33822.1.8') -Update $cumulative -Target 'install.wim#1'

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [version]$Before,
        [AllowNull()]
        [version]$After,
        [Parameter(Mandatory)]
        [pscustomobject]$Update,
        [Parameter(Mandatory)]
        [string]$Target
    )
    if (-not $After) {
        throw "$Target reports no installed cumulative update package after adding $($Update.Kb)."
    }
    $expectedRevision = if ($Update.OsBuild) { [int]($Update.OsBuild -split '\.')[1] }
    if ($Before -and $After -le $Before) {
        if ($expectedRevision -and $Before.Minor -ge $expectedRevision) {
            Write-ServicingLog -Operation 'VerifyUpdate' -Target $Target -Message "Image already contained $($Update.Kb) (revision $($Before.Minor))."
            return
        }
        throw "$Target cumulative update revision did not change after adding $($Update.Kb) (before $Before, after $After)."
    }
    if ($expectedRevision) {
        if ($After.Minor -lt $expectedRevision) {
            throw "$Target is at revision $($After.Minor) after adding $($Update.Kb); expected at least $expectedRevision."
        }
    }
    Write-ServicingLog -Operation 'VerifyUpdate' -Target $Target -Message "Cumulative update package version $Before -> $After"
}

function Update-SetupMedia {
    <#
    .SYNOPSIS
        Applies the Setup Dynamic Update and the serviced setup binaries to the media.

    .DESCRIPTION
        Expands each Setup Dynamic Update into the media sources folder with expand.exe, then replaces sources\setup.exe,
        sources\setuphost.exe, the EFI boot managers (bootmgfw.efi and the boot*.efi loaders, bootmgr.efi) and boot.stl
        with the copies saved from the serviced boot image, as Microsoft's media sequence describes.

    .PARAMETER MediaPath
        Root of the media copy.

    .PARAMETER Plan
        Update plan with downloaded files.

    .PARAMETER SetupFiles
        Files returned by Save-SetupBinary, or $null when boot.wim was not serviced.

    .EXAMPLE
        Update-SetupMedia -MediaPath $context.MediaPath -Plan $plan -SetupFiles $bootResult.SetupFiles

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Applied and ReplacedFiles.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$MediaPath,
        [Parameter(Mandatory)]
        [pscustomobject]$Plan,
        [AllowNull()]
        [pscustomobject]$SetupFiles
    )
    if (-not $PSCmdlet.ShouldProcess($MediaPath, 'Update setup media files')) { return }
    $applied = [System.Collections.Generic.List[object]]::new()
    $sources = Join-Path $MediaPath 'sources'
    $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
    foreach ($setupUpdate in $Plan.Updates | Where-Object Category -EQ 'SetupDynamicUpdate') {
        foreach ($file in $setupUpdate.Files) {
            $null = Invoke-ExternalTool -FilePath $expand -ArgumentList @($file.Path, '-F:*', $sources) -Operation "ExpandSetupDynamicUpdate $($setupUpdate.Kb)"
        }
        $applied.Add((New-AppliedRecord -Update $setupUpdate -Result 'Installed'))
        Write-ServicingLog -Operation 'SetupDynamicUpdate' -Target $sources -Message "Expanded $($setupUpdate.Kb)"
    }
    $replaced = [System.Collections.Generic.List[string]]::new()
    if ($SetupFiles) {
        foreach ($name in 'setup.exe', 'setuphost.exe') {
            $saved = $SetupFiles.PSObject.Properties[$name]?.Value
            if ($saved) {
                Copy-FileOverProtected -Source $saved -Destination (Join-Path $sources $name)
                $replaced.Add("sources\$name")
            }
        }
        $bootManager = $SetupFiles.PSObject.Properties['bootmgfw.efi']?.Value
        $bootManagerEfi = $SetupFiles.PSObject.Properties['bootmgr.efi']?.Value
        foreach ($file in Get-ChildItem -LiteralPath $MediaPath -Recurse -Force -File -Filter 'b*.efi') {
            $relative = $file.FullName.Substring($MediaPath.TrimEnd('\').Length + 1)
            if ($bootManager -and $file.Name -in 'bootmgfw.efi', 'bootx64.efi', 'bootia32.efi', 'bootaa64.efi') {
                Copy-FileOverProtected -Source $bootManager -Destination $file.FullName
                $replaced.Add($relative)
            }
            elseif ($bootManagerEfi -and $file.Name -eq 'bootmgr.efi') {
                Copy-FileOverProtected -Source $bootManagerEfi -Destination $file.FullName
                $replaced.Add($relative)
            }
        }
        $bootStl = $SetupFiles.PSObject.Properties['boot.stl']?.Value
        if ($bootStl) {
            $destination = Join-Path $MediaPath 'efi\microsoft\boot\boot.stl'
            $null = New-Item -Path (Split-Path $destination) -ItemType Directory -Force
            Copy-FileOverProtected -Source $bootStl -Destination $destination
            $replaced.Add('efi\microsoft\boot\boot.stl')
        }
    }
    [pscustomobject]@{ Applied = @($applied); ReplacedFiles = @($replaced) }
}
