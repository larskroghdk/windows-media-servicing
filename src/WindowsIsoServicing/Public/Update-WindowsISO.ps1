function Update-WindowsISO {

    <#
    .SYNOPSIS
        Creates a serviced, validated and bootable copy of a Windows installation ISO.

    .DESCRIPTION
        Integrates the applicable Microsoft updates offline, following the sequence documented in
        "Update Windows installation media with Dynamic Update":
          1. WinRE (inside install.wim): servicing stack (standalone, or through the combined cumulative update),
             then the Safe OS Dynamic Update.
          2. install.wim, per selected index: servicing stack, latest cumulative update (with checkpoint cumulative
             updates on releases that use them), optional component cleanup, .NET cumulative updates, export.
          3. boot.wim, every index: servicing stack, latest cumulative update, export. setup.exe, setuphost.exe and the
             boot manager files are taken from the serviced Windows Setup index.
          4. Media: Setup Dynamic Update expanded into \sources, then the WinPE setup and boot manager binaries.
        The ISO is rebuilt with OSCDIMG, preserving the BIOS and UEFI boot paths of the source media, and always boots
        into Windows Setup without "Press any key to boot from CD or DVD": UEFI from the efisys_noprompt.bin on the media,
        BIOS from media without boot\bootfix.bin. UEFI media without efisys_noprompt.bin is refused before servicing
        starts. Because nothing waits for a key, a machine whose firmware still starts from the DVD after the first
        restart of Setup starts Setup again: on UEFI, Setup puts Windows Boot Manager first in the boot order; on BIOS,
        the disk must come before the DVD. The ISO is validated
        structurally (and optionally by a Hyper-V installation test), and only then moved to OutputPath together with a
        JSON manifest and a .sha256 file. The source ISO and existing files in OutputPath are never modified; on failure
        nothing is written to OutputPath except logs.
        Indexes whose edition is out of support are left unchanged unless no serviceable index exists, in which case
        the command stops with an 'UnsupportedMedia' or 'OutOfSupportMedia' error. Media that only receives updates
        through Extended Security Updates requires -EsuEntitled.

    .PARAMETER SourceISO
        Path to the original Microsoft Windows installation ISO.

    .PARAMETER OutputPath
        Folder that receives the serviced ISO, its manifest and checksum file.

    .PARAMETER Index
        Image indexes to service. Defaults to every index whose edition is in support.

    .PARAMETER RepositoryPath
        Local package repository (updates.json) used instead of the Microsoft Update Catalog. When omitted, updates are
        discovered in and downloaded from the Microsoft Update Catalog, cross-checked with the MSRC Security Updates API.

    .PARAMETER CachePath
        Update cache. Downloaded packages are kept and reused.

    .PARAMETER WorkspacePath
        Working folder for media, mounts and scratch space. Must be on a local NTFS volume and contain no whitespace.

    .PARAMETER LogPath
        Folder for the structured run log and DISM logs. Defaults to <OutputPath>\logs.

    .PARAMETER BaselineManifestPath
        Manifest of the last published ISO. When the source ISO, the update set and the serviced indexes are unchanged,
        no ISO is built and the result status is 'Unchanged'.

    .PARAMETER IncludePreview
        Includes cumulative updates that are not security releases: optional preview releases and non-security
        out-of-band releases. The Microsoft Update Catalog metadata does not distinguish the two.

    .PARAMETER EsuEntitled
        Confirms that the organization holds a valid Extended Security Updates entitlement for every device installed
        from media that is past end of support. The tool does not activate or bypass ESU licensing.

    .PARAMETER ComponentCleanup
        Runs DISM /Cleanup-Image /StartComponentCleanup (without /ResetBase) on every serviced image.

    .PARAMETER SplitInstallImage
        Splits install.wim into install.swm parts below 4 GB for FAT32 USB media.

    .PARAMETER NoBootPrompt
        Obsolete and without effect: every serviced ISO now boots without the prompt. Kept so existing scripts keep
        working; a warning is logged when it is used.

    .PARAMETER BootTest
        Installs the first serviced index in a temporary Hyper-V VM and requires the installation to reach the
        specialize pass before the ISO is accepted.

    .PARAMETER BootTestProductKey
        Product key used by the boot test answer file, for media that requires one during Setup.

    .PARAMETER OscdimgPath
        Path to oscdimg.exe, or to a folder that contains it or the Windows ADK (for example 'D:\Windows Kits\10').
        Defaults to the copy in the module's Resources folder, then to the installed Windows ADK Deployment Tools. The
        file must carry a valid Microsoft Authenticode signature.

    .PARAMETER KeepWorkspace
        Keeps the run workspace after completion for diagnostics.

    .PARAMETER Force
        Replaces an existing output ISO with the same name.

    .EXAMPLE
        Update-WindowsISO -SourceISO 'D:\ISO\Windows_Server_2025.iso' -OutputPath 'D:\ISO\Updated'

    .EXAMPLE
        Update-WindowsISO -SourceISO 'D:\ISO\Windows_11_24H2.iso' -OutputPath 'D:\ISO\Updated' -RepositoryPath 'E:\UpdateCache' -Index 3 -BootTest

    .EXAMPLE
        Update-WindowsISO -SourceISO 'D:\ISO\Windows_Server_2022.iso' -OutputPath 'D:\ISO\Updated' -BaselineManifestPath '\\fs01\iso\WindowsServer2022_x64_en-us\latest.json' -WhatIf

    .OUTPUTS
        WindowsIsoServicing.ServicingResult

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        Get-WindowsISOInfo

    .LINK
        Get-WindowsISOUpdates

    .LINK
        Test-WindowsISO

    .LINK
        Publish-WindowsISO

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('WindowsIsoServicing.ServicingResult')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceISO,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,
        [ValidateRange(1, 256)]
        [int[]]$Index,
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath,
        [ValidateNotNullOrEmpty()]
        [string]$CachePath = (Get-DefaultServicingPath -Kind Cache),
        [ValidateNotNullOrEmpty()]
        [string]$WorkspacePath = (Get-DefaultServicingPath -Kind Workspace),
        [string]$LogPath,
        [string]$BaselineManifestPath,
        [switch]$IncludePreview,
        [switch]$EsuEntitled,
        [switch]$ComponentCleanup,
        [switch]$SplitInstallImage,
        [switch]$NoBootPrompt,
        [switch]$BootTest,
        [ValidatePattern('^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$')]
        [string]$BootTestProductKey,
        [string]$OscdimgPath,
        [switch]$KeepWorkspace,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'

    $startedAt = [DateTimeOffset]::Now
    $runId = '{0:yyyyMMdd-HHmmss}-{1}' -f $startedAt, [guid]::NewGuid().ToString('N').Substring(0, 8)
    Assert-Administrator
    $isoPath = Resolve-TrustedFilePath -Path $SourceISO -AllowedExtension '.iso'
    $output = Resolve-DirectoryPath -Path $OutputPath -Create
    $workspace = Resolve-DirectoryPath -Path $WorkspacePath -Create
    $cache = Resolve-DirectoryPath -Path $CachePath -Create
    $logDirectory = if ($LogPath) { Resolve-DirectoryPath -Path $LogPath -Create } else { Join-Path $output "logs\$runId" }
    $oscdimg = Find-Oscdimg -Path $OscdimgPath
    $repository = if ($RepositoryPath) { Resolve-DirectoryPath -Path $RepositoryPath }
    $null = Start-ServicingLog -Directory $logDirectory -RunId $runId
    Write-ServicingLog -Operation 'Start' -Target $isoPath -Message "windows-iso-servicing $script:ToolVersion run $runId"
    Write-ServicingLog -Operation 'Start' -Target $oscdimg.Path -Message "Using oscdimg.exe $($oscdimg.FileVersion) from $($oscdimg.Source)$(if ($oscdimg.AdkVersion) { ", Windows ADK Deployment Tools $($oscdimg.AdkVersion)" })"
    $workspaceLock = $null
    $outputLock = $null
    $context = $null
    $mediaRoot = $null

    try {
        if ($NoBootPrompt) {
            Write-ServicingLog -Operation 'Start' -Level Warning -Message '-NoBootPrompt is obsolete and has no effect: every serviced ISO boots without "Press any key".'
        }
        if (-not $WhatIfPreference) {
            $workspaceLock = Lock-Directory -Directory $workspace
            $outputLock = Lock-Directory -Directory $output
        }
        $sourceSha256 = Get-FileSha256 -Path $isoPath
        $sourceSize = (Get-Item -LiteralPath $isoPath).Length
        Write-ServicingLog -Operation 'Inspect' -Target $isoPath -Message "SHA-256 $sourceSha256"
        $mediaRoot = Mount-IsoImage -Path $isoPath -WhatIf:$false -Confirm:$false
        $volumeLabel = Get-IsoVolumeLabel -MediaRoot $mediaRoot
        $sourceInstallImage = Get-InstallImagePath -MediaRoot $mediaRoot
        $sourceFormat = [System.IO.Path]::GetExtension($sourceInstallImage).TrimStart('.').ToLowerInvariant()
        $bootConfiguration = Get-MediaBootConfiguration -MediaRoot $mediaRoot
        if ($bootConfiguration.Uefi -and -not $bootConfiguration.UefiNoPromptAvailable) {
            throw "The source media has UEFI boot files but no efi\microsoft\boot\efisys_noprompt.bin, so the serviced ISO could not boot without ""Press any key""; nothing was serviced."
        }
        $inventory = @(Get-InstallImageInventory -ImagePath $sourceInstallImage)
        if (@($inventory.Build | Select-Object -Unique).Count -ne 1 -or @($inventory.Architecture | Select-Object -Unique).Count -ne 1) {
            throw 'The installation image mixes builds or architectures; such media is not supported.'
        }
        $architecture = $inventory[0].Architecture
        $build = $inventory[0].Build
        if ($Index) {
            $unknown = @($Index | Where-Object { $_ -notin $inventory.Index })
            if ($unknown) { throw "Index $($unknown -join ', ') does not exist. Available: $($inventory.Index -join ', ')." }
            $selected = @($inventory | Where-Object Index -in $Index)
            Assert-ServiceableRelease -OperatingSystem $selected.OperatingSystem -EsuEntitled:$EsuEntitled
        }
        else {
            $serviceable = @('Supported') + $(if ($EsuEntitled) { 'ExtendedSecurityUpdates' })
            $selected = @($inventory | Where-Object { $_.OperatingSystem.LifecycleStatus -in $serviceable })
            if ($selected.Count -eq 0) {
                Assert-ServiceableRelease -OperatingSystem $inventory.OperatingSystem -EsuEntitled:$EsuEntitled
            }
            foreach ($skipped in $inventory | Where-Object { $_ -notin $selected }) {
                Write-ServicingLog -Operation 'Inspect' -Level Warning -Target "install#$($skipped.Index)" -Message "$($skipped.Name) ($($skipped.OperatingSystem.Channel)) is $($skipped.OperatingSystem.LifecycleStatus); left unchanged"
            }
        }
        $selectedIndex = @($selected.Index)
        $operatingSystem = $selected[0].OperatingSystem
        Write-ServicingLog -Operation 'Inspect' -Target $isoPath -Message "$($operatingSystem.Name) $($operatingSystem.Version) build $build $architecture; servicing indexes $($selectedIndex -join ', ')"
        $planParameters = @{ OperatingSystem = $operatingSystem; Architecture = $architecture; IncludePreview = $IncludePreview }
        if ($repository) { $planParameters.RepositoryPath = $repository }
        $plan = Get-UpdatePlan @planParameters
        foreach ($note in $plan.Notes) { Write-ServicingLog -Operation 'Plan' -Level Warning -Message $note }
        if ($plan.Updates.Count -eq 0) {
            Write-ServicingLog -Operation 'Plan' -Level Warning -Message 'No applicable updates are available; no ISO was created.'
            return [pscustomobject]@{ PSTypeName = 'WindowsIsoServicing.ServicingResult'; Status = 'NoApplicableUpdates'; IsoPath = $null; ManifestPath = $null; Plan = $plan; LogPath = $logDirectory }
        }
        foreach ($update in $plan.Updates) {
            Write-ServicingLog -Operation 'Plan' -Target $update.Kb -Message "$($update.Category): $($update.Title)"
        }
        if ($BaselineManifestPath) {
            $baseline = Read-ServicingManifest -Path (Resolve-TrustedFilePath -Path $BaselineManifestPath -AllowedExtension '.json')
            $baselineSignature = Get-ManifestUpdateSignature -SourceSha256 $baseline.source.sha256 -Kb @($baseline.updates.kb) -Index @($baseline.images.install | Where-Object serviced | ForEach-Object index)
            $currentSignature = Get-ManifestUpdateSignature -SourceSha256 $sourceSha256 -Kb @($plan.Updates.Kb) -Index $selectedIndex
            if ($baseline.validation.passed -and $baselineSignature -eq $currentSignature) {
                Write-ServicingLog -Operation 'Plan' -Message "Baseline $($baseline.output.fileName) already contains this update set; nothing to build."
                return [pscustomobject]@{ PSTypeName = 'WindowsIsoServicing.ServicingResult'; Status = 'Unchanged'; IsoPath = $null; ManifestPath = $BaselineManifestPath; Plan = $plan; LogPath = $logDirectory }
            }
        }
        $cumulative = $plan.Updates | Where-Object Category -eq 'CumulativeUpdate' | Select-Object -First 1
        $servicingMonth = if ($cumulative) { $cumulative.ReleaseMonth } else { ($plan.Updates | Sort-Object { [string]$_.ReleaseMonth } -Descending | Select-Object -First 1).ReleaseMonth }
        if (-not $servicingMonth) { $servicingMonth = $startedAt.ToString('yyyy-MM') }
        $stems = @($selected.OperatingSystem.FileNameStem | Select-Object -Unique)
        $stem = if ($stems.Count -eq 1) { $stems[0] } else { ($script:OperatingSystemData.Releases | Where-Object Key -eq $operatingSystem.Key).FileNameStem }
        $isoName = Get-IsoFileName -FileNameStem $stem -Architecture $architecture -Build $build -ServicingMonth $servicingMonth
        $destinationIso = Join-Path $output $isoName
        if ($destinationIso -eq $isoPath) { throw 'The output ISO path equals the source ISO path; the source ISO is never overwritten.' }
        if ((Test-Path -LiteralPath $destinationIso) -and -not $Force) {
            throw "'$destinationIso' already exists. Use -Force to replace it, or a different -OutputPath."
        }
        $installSize = ($inventory | Measure-Object SizeBytes -Maximum).Maximum
        $updateSize = ($plan.Updates.Files | Measure-Object Size -Sum).Sum
        Assert-FreeSpace -Path $workspace -RequiredBytes ([long](2 * $sourceSize + 2 * $updateSize + $installSize + 20GB))
        Assert-FreeSpace -Path $output -RequiredBytes ([long](1.5 * $sourceSize))
        if (-not $PSCmdlet.ShouldProcess($destinationIso, "Service $($operatingSystem.Name) indexes $($selectedIndex -join ', ') with $($plan.Updates.Kb -join ', ')")) {
            return
        }
        $context = New-ServicingContext -WorkspacePath $workspace -RunId $runId -LogPath $logDirectory -ComponentCleanup:$ComponentCleanup -Confirm:$false
        $plan.Updates = @(Save-UpdatePackage -Update $plan.Updates -OperatingSystem $operatingSystem -Architecture $architecture -CachePath $cache -Confirm:$false)
        if ($cumulative) {
            $cumulative = $plan.Updates | Where-Object Category -eq 'CumulativeUpdate' | Select-Object -First 1
            $context.CumulativeUpdatePath = New-CumulativeUpdateFolder -Update $cumulative -WorkPath $context.WorkPath -Confirm:$false
        }
        Copy-MediaContent -MediaRoot $mediaRoot -Destination $context.MediaPath -Confirm:$false
        $workingInstallImage = Join-Path $context.WorkPath 'install-source.wim'
        if ($sourceFormat -eq 'esd') {
            foreach ($image in $inventory) {
                Write-ServicingLog -Operation 'ConvertEsd' -Target "install.esd#$($image.Index)" -Message 'Exporting to WIM'
                $null = Export-WindowsImage -SourceImagePath $sourceInstallImage -SourceIndex $image.Index -DestinationImagePath $workingInstallImage -CompressionType max -CheckIntegrity -ScratchDirectory $context.ScratchPath -LogPath (Join-Path $logDirectory 'dism-export-esd.log')
            }
        }
        else {
            Copy-Item -LiteralPath $sourceInstallImage -Destination $workingInstallImage
            (Get-Item -LiteralPath $workingInstallImage).IsReadOnly = $false
        }
        Dismount-IsoImage -Path $isoPath -Confirm:$false
        $mediaRoot = $null
        $installResults = @(Update-InstallImage -InstallImagePath $workingInstallImage -DestinationPath (Join-Path $context.MediaPath 'sources\install.wim') -Inventory $inventory -SelectedIndex $selectedIndex -Plan $plan -Context $context -Confirm:$false)
        Remove-Item -LiteralPath $workingInstallImage -Force
        $bootResult = Update-BootImage -BootImagePath (Join-Path $context.MediaPath 'sources\boot.wim') -Plan $plan -Context $context -Confirm:$false
        $setupResult = Update-SetupMedia -MediaPath $context.MediaPath -Plan $plan -SetupFiles $bootResult.SetupFiles -Confirm:$false
        $split = $false
        if ($SplitInstallImage) { $split = Split-InstallImage -MediaPath $context.MediaPath -Context $context -Confirm:$false }
        $stagedIso = Join-Path $context.OutputStagingPath $isoName
        $isoParameters = @{
            MediaPath         = $context.MediaPath
            DestinationPath   = $stagedIso
            OscdimgPath       = $oscdimg.Path
            BootConfiguration = $bootConfiguration
            VolumeLabel       = $volumeLabel
        }
        $null = New-IsoImage @isoParameters -Confirm:$false
        $isoSha256 = Get-FileSha256 -Path $stagedIso
        $manifest = [ordered]@{
            schemaVersion   = $script:ManifestSchemaVersion
            toolName        = 'windows-iso-servicing'
            toolVersion     = $script:ToolVersion
            runId           = $runId
            createdAt       = [DateTimeOffset]::Now.ToString('o')
            host            = $env:COMPUTERNAME
            source          = [ordered]@{
                fileName           = Split-Path $isoPath -Leaf
                path               = $isoPath
                sha256             = $sourceSha256
                sizeBytes          = $sourceSize
                volumeLabel        = $volumeLabel
                installImageFormat = $sourceFormat
            }
            operatingSystem = [ordered]@{
                key          = $operatingSystem.Key
                name         = $operatingSystem.Name
                version      = $operatingSystem.Version
                family       = $operatingSystem.Family
                build        = $build
                architecture = $architecture
                language     = $selected[0].DefaultLanguage
                servicing    = $operatingSystem.Servicing
            }
            output          = [ordered]@{
                fileName           = $isoName
                sha256             = $isoSha256
                sizeBytes          = (Get-Item -LiteralPath $stagedIso).Length
                servicingMonth     = $servicingMonth
                installImageFormat = if ($split) { 'swm' } else { 'wim' }
                bootModes          = [ordered]@{ bios = $bootConfiguration.Bios; uefi = $bootConfiguration.Uefi; uefiNoPrompt = [bool]$bootConfiguration.Uefi; biosNoPrompt = [bool]$bootConfiguration.Bios }
            }
            updateSource    = $plan.Source
            updates         = @($plan.Updates | ForEach-Object {
                    [ordered]@{
                        kb = $_.Kb; category = $_.Category; title = $_.Title; releaseMonth = $_.ReleaseMonth; osBuild = $_.OsBuild; updateId = $_.UpdateId
                        files = @($_.Files | ForEach-Object { [ordered]@{ name = $_.Name; role = $_.Role; sha256 = $_.Sha256; hashSource = $_.HashSource } })
                    }
                })
            images          = [ordered]@{
                install    = @($installResults | ForEach-Object {
                        $record = $_
                        $os = ($inventory | Where-Object Index -eq $record.index).OperatingSystem
                        $record | Add-Member -NotePropertyName channel -NotePropertyValue $os.Channel -PassThru | Add-Member -NotePropertyName lifecycleStatus -NotePropertyValue $os.LifecycleStatus -PassThru
                    })
                boot       = @($bootResult.Indexes)
                bootReason = $bootResult.Reason
                setupMedia = $setupResult
            }
            notes           = @($plan.Notes)
            servicing       = [ordered]@{
                startedAt        = $startedAt.ToString('o')
                completedAt      = $null
                componentCleanup = [bool]$ComponentCleanup
            }
            validation      = [ordered]@{ passed = $false; structural = $null; bootTest = [ordered]@{ performed = $false } }
        }
        $structural = Test-IsoStructure -IsoPath $stagedIso -Manifest ([pscustomobject]$manifest | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20) -MountRoot $context.MountRoot
        $manifest.validation.structural = $structural
        $passed = $structural.passed
        if ($passed -and $BootTest) {
            $manifest.validation.bootTest = Invoke-HyperVBootTest -IsoPath $stagedIso -Index $selectedIndex[0] -Language $selected[0].DefaultLanguage -WorkPath $context.WorkPath -OscdimgPath $oscdimg.Path-ProductKey $BootTestProductKey -Confirm:$false
            $passed = $manifest.validation.bootTest.result -eq 'Passed'
        }
        $manifest.validation.passed = [bool]$passed
        $manifest.servicing.completedAt = [DateTimeOffset]::Now.ToString('o')
        if (-not $passed) {
            $failedManifest = Join-Path $logDirectory "$isoName.failed.json"
            $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $failedManifest -Encoding utf8NoBOM
            $failures = @($structural.checks | Where-Object status -eq 'Failed' | ForEach-Object { "$($_.name): $($_.detail)" })
            if ($manifest.validation.bootTest.performed) { $failures += "BootTest: $($manifest.validation.bootTest.detail)" }
            throw "Validation of the serviced ISO failed; nothing was published. $($failures -join '; '). Details: $failedManifest"
        }
        $temporaryIso = "$destinationIso.partial"
        try {
            Move-Item -LiteralPath $stagedIso -Destination $temporaryIso -Force -ErrorAction Stop
            if ((Get-FileSha256 -Path $temporaryIso) -ne $isoSha256) {
                throw "Checksum mismatch after moving the ISO to '$output'."
            }
            Move-Item -LiteralPath $temporaryIso -Destination $destinationIso -Force -ErrorAction Stop
        }
        catch {
            if (Test-Path -LiteralPath $temporaryIso) { Remove-Item -LiteralPath $temporaryIso -Force }
            throw
        }
        $manifestPath = "$destinationIso.json"
        Write-ServicingManifest -Manifest $manifest -Path $manifestPath -Confirm:$false
        Set-Content -LiteralPath "$destinationIso.sha256" -Value "$isoSha256 *$isoName" -Encoding ascii
        Write-ServicingLog -Operation 'Complete' -Target $destinationIso -Message "Created and validated; SHA-256 $isoSha256"
        [pscustomobject]@{
            PSTypeName   = 'WindowsIsoServicing.ServicingResult'
            Status       = 'Created'
            IsoPath      = $destinationIso
            ManifestPath = $manifestPath
            Plan         = $plan
            LogPath      = $logDirectory
        }
    }
    catch {
        Write-ServicingLog -Operation 'Failed' -Level Error -Target $isoPath -Message "$_" -Data @{ stack = $_.ScriptStackTrace }
        throw
    }
    finally {
        if ($mediaRoot) { Dismount-IsoImage -Path $isoPath -WhatIf:$false -Confirm:$false }
        if ($context) {
            if ($KeepWorkspace) {
                $null = Clear-ServicingMount -Root $context.MountRoot -Confirm:$false
                Write-ServicingLog -Operation 'Cleanup' -Message "Workspace kept at $($context.RunPath)"
            }
            else {
                Remove-ServicingWorkspace -Context $context -Confirm:$false
            }
        }
        Unlock-Directory -Lock $outputLock
        Unlock-Directory -Lock $workspaceLock
        Stop-ServicingLog
    }
}
