function New-ValidationCheck {
    <#
    .SYNOPSIS
        Creates one validation check record.

    .DESCRIPTION
        Returns the name, status and detail of a check in the shape the manifest stores under validation.structural.

    .PARAMETER Name
        Name of the check, for example 'Checksum' or 'InstallIndex2'.

    .PARAMETER Status
        Passed, Failed or Skipped.

    .PARAMETER Detail
        What was checked or why it failed.

    .EXAMPLE
        New-ValidationCheck -Name 'BootImage' -Status 'Passed' -Detail '2 indexes'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with name, status and detail.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [ValidateSet('Passed', 'Failed', 'Skipped')]
        [string]$Status,

        [string]$Detail
    )
    [pscustomobject][ordered]@{ name = $Name; status = $Status; detail = $Detail }
}

function Test-IsoStructure {
    <#
    .SYNOPSIS
        Runs the structural validation of a serviced ISO.

    .DESCRIPTION
        Checks the SHA-256 against the manifest, mounts the ISO read-only, and checks the BIOS and UEFI boot files the
        manifest records, the setup files and BCD stores, and that boot.wim and the installation image can be read.
        The El Torito boot catalog must have an entry for each of those boot modes. UefiBootPrompt compares the boot image
        the UEFI entry points to, byte for byte, with efi\microsoft\boot\efisys_noprompt.bin; BiosBootPrompt checks that
        boot\bootfix.bin, which makes etfsboot.com wait for a key, is absent. Both fail when the manifest records the
        boot mode as uefiNoPrompt or biosNoPrompt, and are otherwise Skipped with what was found. With
        a manifest, each install index must have the recorded edition and version. With Deep, each serviced index of
        install.wim is mounted read-only and its cumulative update package version is compared with the manifest.
        Finally, no image may still be mounted under MountRoot.
        A check that cannot run is recorded as Failed with the error, so the result covers every check. Structural
        validation does not show that the image installs; that is recorded separately by the boot test (INVARIANTS.md,
        Media #3).

    .PARAMETER IsoPath
        Path of the ISO.

    .PARAMETER Manifest
        Manifest of the ISO, or $null to check the ISO without reference values.

    .PARAMETER Deep
        Also inspects the installed packages of each serviced index. Requires a manifest and install.wim.

    .PARAMETER MountRoot
        Folder for the Deep inspection mounts, which is also checked for leftover mounts.

    .EXAMPLE
        Test-IsoStructure -IsoPath "$($context.OutputStagingPath)\Windows_Server_2025_x64_26100_2026-11.iso" -Manifest $manifest -Deep -MountRoot $context.MountPath

    .OUTPUTS
        System.Management.Automation.PSCustomObject with type, passed, sha256 and checks.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$IsoPath,
        [AllowNull()]
        [object]$Manifest,
        [switch]$Deep,
        [string]$MountRoot
    )
    $checks = [System.Collections.Generic.List[object]]::new()
    $sha256 = Get-FileSha256 -Path $IsoPath
    if ($Manifest -and $Manifest.output.sha256) {
        $status = if ($Manifest.output.sha256 -eq $sha256) { 'Passed' } else { 'Failed' }
        $checks.Add((New-ValidationCheck -Name 'Checksum' -Status $status -Detail "SHA-256 $sha256"))
    }
    else {
        $checks.Add((New-ValidationCheck -Name 'Checksum' -Status 'Passed' -Detail "SHA-256 $sha256 (no reference value)"))
    }
    $mediaRoot = $null
    try {
        $mediaRoot = Mount-IsoImage -Path $IsoPath -Confirm:$false
        $checks.Add((New-ValidationCheck -Name 'Mount' -Status 'Passed' -Detail $mediaRoot))
        $boot = Get-MediaBootConfiguration -MediaRoot $mediaRoot
        $expectedBios = if ($Manifest) { [bool]$Manifest.output.bootModes.bios } else { $boot.Bios }
        $expectedUefi = if ($Manifest) { [bool]$Manifest.output.bootModes.uefi } else { $boot.Uefi }
        if (-not ($expectedBios -or $expectedUefi)) {
            $checks.Add((New-ValidationCheck -Name 'BootFiles' -Status 'Failed' -Detail 'No BIOS or UEFI boot files found.'))
        }
        if ($expectedBios) {
            $status = if ($boot.Bios) { 'Passed' } else { 'Failed' }
            $checks.Add((New-ValidationCheck -Name 'BiosBootFiles' -Status $status -Detail 'boot\etfsboot.com, bootmgr'))
        }
        if ($expectedUefi) {
            $status = if ($boot.Uefi) { 'Passed' } else { 'Failed' }
            $checks.Add((New-ValidationCheck -Name 'UefiBootFiles' -Status $status -Detail "efi\microsoft\boot\efisys.bin, $($boot.UefiLoader)"))
        }
        $bootModes = if ($Manifest) { $Manifest.output.bootModes }
        $requireUefiNoPrompt = [bool]${bootModes}?.PSObject.Properties['uefiNoPrompt']?.Value
        $requireBiosNoPrompt = [bool]${bootModes}?.PSObject.Properties['biosNoPrompt']?.Value
        try {
            $bootEntries = @(Get-IsoBootEntry -Path $IsoPath)
            $platforms = @($bootEntries | ForEach-Object Platform)
            $missingPlatforms = @(@('BIOS' | Where-Object { $expectedBios }) + @('UEFI' | Where-Object { $expectedUefi }) | Where-Object { $_ -notin $platforms })
            $status = if ($bootEntries.Count -gt 0 -and $missingPlatforms.Count -eq 0) { 'Passed' } else { 'Failed' }
            $detail = if ($missingPlatforms) { "Boot catalog entries: $($platforms -join ', '); missing: $($missingPlatforms -join ', ')" } else { "Boot catalog entries: $($platforms -join ', ')" }
            $checks.Add((New-ValidationCheck -Name 'BootCatalog' -Status $status -Detail $detail))
            if ($expectedUefi) {
                $uefiEntry = $bootEntries | Where-Object Platform -eq 'UEFI' | Select-Object -First 1
                $noPromptImage = Join-Path $mediaRoot 'efi\microsoft\boot\efisys_noprompt.bin'
                $observed = if (-not $uefiEntry) {
                    'the boot catalog has no UEFI entry'
                }
                elseif (-not (Test-Path -LiteralPath $noPromptImage -PathType Leaf)) {
                    'the media has no efi\microsoft\boot\efisys_noprompt.bin to compare with'
                }
                elseif ((Get-IsoBootImageSha256 -Path $IsoPath -LoadRba $uefiEntry.LoadRba -Length (Get-Item -LiteralPath $noPromptImage).Length) -eq (Get-FileSha256 -Path $noPromptImage)) {
                    $null
                }
                else {
                    "the UEFI boot image at sector $($uefiEntry.LoadRba) is not efisys_noprompt.bin"
                }
                $status = if (-not $observed) { 'Passed' } elseif ($requireUefiNoPrompt) { 'Failed' } else { 'Skipped' }
                $detail = if (-not $observed) { "The UEFI boot entry starts efisys_noprompt.bin (sector $($uefiEntry.LoadRba)), which boots without ""Press any key""." } else { "Not without boot prompt: $observed." }
                $checks.Add((New-ValidationCheck -Name 'UefiBootPrompt' -Status $status -Detail $detail))
            }
            if ($expectedBios) {
                $bootFixPresent = Test-Path -LiteralPath (Join-Path $mediaRoot 'boot\bootfix.bin')
                $status = if (-not $bootFixPresent) { 'Passed' } elseif ($requireBiosNoPrompt) { 'Failed' } else { 'Skipped' }
                $detail = if ($bootFixPresent) { 'boot\bootfix.bin is present, so etfsboot.com shows "Press any key".' } else { 'boot\bootfix.bin is absent, so etfsboot.com does not wait for a key.' }
                $checks.Add((New-ValidationCheck -Name 'BiosBootPrompt' -Status $status -Detail $detail))
            }
        }
        catch {
            $checks.Add((New-ValidationCheck -Name 'BootCatalog' -Status 'Failed' -Detail "$_"))
        }
        $requiredFiles = 'setup.exe', 'sources\setup.exe', 'sources\boot.wim', 'boot\bcd'
        $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $mediaRoot $_)) })
        if ($expectedUefi) {
            $missing += @('efi\microsoft\boot\bcd' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $mediaRoot $_)) })
        }
        $status = if ($missing.Count -eq 0) { 'Passed' } else { 'Failed' }
        $checks.Add((New-ValidationCheck -Name 'SetupFiles' -Status $status -Detail $(if ($missing) { "Missing: $($missing -join ', ')" } else { $requiredFiles -join ', ' })))
        try {
            $bootImages = @(Get-WindowsImage -ImagePath (Join-Path $mediaRoot 'sources\boot.wim') -ErrorAction Stop)
            $checks.Add((New-ValidationCheck -Name 'BootImage' -Status 'Passed' -Detail "$($bootImages.Count) indexes"))
        }
        catch {
            $checks.Add((New-ValidationCheck -Name 'BootImage' -Status 'Failed' -Detail "$_"))
        }
        $installImage = @('install.wim', 'install.swm', 'install.esd' | ForEach-Object { Join-Path $mediaRoot "sources\$_" } | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
        if (-not $installImage) {
            $checks.Add((New-ValidationCheck -Name 'InstallImage' -Status 'Failed' -Detail 'No installation image found.'))
        }
        else {
            try {
                $images = @(Get-WindowsImage -ImagePath $installImage -ErrorAction Stop)
                $checks.Add((New-ValidationCheck -Name 'InstallImage' -Status 'Passed' -Detail "$(Split-Path $installImage -Leaf), $($images.Count) indexes"))
                if ($Manifest) {
                    foreach ($expected in @($Manifest.images.install)) {
                        $actual = $images | Where-Object ImageIndex -eq $expected.index
                        if (-not $actual) {
                            $checks.Add((New-ValidationCheck -Name "InstallIndex$($expected.index)" -Status 'Failed' -Detail 'Index missing'))
                            continue
                        }
                        $detail = Get-WindowsImage -ImagePath $installImage -Index $expected.index -ErrorAction Stop
                        $ok = $detail.EditionId -eq $expected.editionId -and [string]$detail.Version -eq [string]$expected.versionAfter
                        $status = if ($ok) { 'Passed' } else { 'Failed' }
                        $checks.Add((New-ValidationCheck -Name "InstallIndex$($expected.index)" -Status $status -Detail "$($detail.EditionId) $($detail.Version) (expected $($expected.editionId) $($expected.versionAfter))"))
                    }
                }
            }
            catch {
                $checks.Add((New-ValidationCheck -Name 'InstallImage' -Status 'Failed' -Detail "$_"))
            }
        }
        if ($Deep) {
            if (-not $Manifest) {
                $checks.Add((New-ValidationCheck -Name 'DeepInspection' -Status 'Skipped' -Detail 'Requires a manifest.'))
            }
            elseif ($installImage -notlike '*.wim') {
                $checks.Add((New-ValidationCheck -Name 'DeepInspection' -Status 'Skipped' -Detail 'Deep inspection supports install.wim only.'))
            }
            else {
                foreach ($expected in @($Manifest.images.install | Where-Object serviced)) {
                    $mountPath = Join-Path $MountRoot "validate-$($expected.index)"
                    $null = New-Item -Path $mountPath -ItemType Directory -Force
                    try {
                        $null = Mount-WindowsImage -ImagePath $installImage -Index $expected.index -Path $mountPath -ReadOnly -CheckIntegrity -ErrorAction Stop
                        try {
                            $rollup = Get-RollupVersion -MountPath $mountPath
                            $ok = [string]$rollup -eq [string]$expected.rollupAfter
                            $status = if ($ok) { 'Passed' } else { 'Failed' }
                            $checks.Add((New-ValidationCheck -Name "InstallIndex$($expected.index)Packages" -Status $status -Detail "Cumulative update package $rollup (expected $($expected.rollupAfter))"))
                        }
                        finally {
                            $null = Dismount-WindowsImage -Path $mountPath -Discard -ErrorAction Stop
                        }
                    }
                    catch {
                        $checks.Add((New-ValidationCheck -Name "InstallIndex$($expected.index)Packages" -Status 'Failed' -Detail "$_"))
                    }
                    finally {
                        Remove-Item -LiteralPath $mountPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
    catch {
        $checks.Add((New-ValidationCheck -Name 'Mount' -Status 'Failed' -Detail "$_"))
    }
    finally {
        if ($mediaRoot) { Dismount-IsoImage -Path $IsoPath -Confirm:$false }
    }
    $mountedLeftovers = @(if ($MountRoot) { Get-WindowsImage -Mounted | Where-Object { $_.Path -like "$MountRoot*" } })
    $status = if ($mountedLeftovers.Count -eq 0) { 'Passed' } else { 'Failed' }
    $checks.Add((New-ValidationCheck -Name 'NoMountedImages' -Status $status -Detail "$($mountedLeftovers.Count) leftover mounts"))
    [pscustomobject][ordered]@{
        type   = 'Structural'
        passed = -not ($checks | Where-Object status -eq 'Failed')
        sha256 = $sha256
        checks = @($checks)
    }
}

function New-BootTestAnswerFile {
    <#
    .SYNOPSIS
        Creates the unattended answer file for the Hyper-V boot test.

    .DESCRIPTION
        Returns autounattend.xml text for amd64 that wipes disk 0, creates a UEFI (EFI, MSR, Windows) or BIOS (one active
        partition) layout, installs the given image index, and in the specialize pass writes a marker file to
        %SystemRoot%\Temp and shuts the VM down. The marker proves that Windows Setup completed and the installed system
        booted. A product key is included only when one is given; the boot test never activates Windows.

    .PARAMETER Index
        Image index to install.

    .PARAMETER Firmware
        UEFI or BIOS.

    .PARAMETER Language
        Setup and system language, for example 'en-US'.

    .PARAMETER ProductKey
        Product key in the form XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, for editions whose setup requires one.

    .EXAMPLE
        New-BootTestAnswerFile -Index 2 -Firmware 'UEFI' -Language 'en-US'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns XML text only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [int]$Index,
        [Parameter(Mandatory)]
        [ValidateSet('UEFI', 'BIOS')]
        [string]$Firmware,
        [Parameter(Mandatory)]
        [string]$Language,
        [ValidatePattern('^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$')]
        [string]$ProductKey
    )
    $architecture = 'amd64'
    $language = [System.Security.SecurityElement]::Escape($Language)
    $componentStart = '<component name="{0}" processorArchitecture="{1}" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">'
    $disk = if ($Firmware -eq 'UEFI') {
        @'
        <DiskConfiguration>
          <Disk wcm:action="add">
            <DiskID>0</DiskID>
            <WillWipeDisk>true</WillWipeDisk>
            <CreatePartitions>
              <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
              <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
              <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
            </CreatePartitions>
            <ModifyPartitions>
              <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
              <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>
              <ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
            </ModifyPartitions>
          </Disk>
        </DiskConfiguration>
'@
    }
    else {
        @'
        <DiskConfiguration>
          <Disk wcm:action="add">
            <DiskID>0</DiskID>
            <WillWipeDisk>true</WillWipeDisk>
            <CreatePartitions>
              <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
            </CreatePartitions>
            <ModifyPartitions>
              <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Active>true</Active><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
            </ModifyPartitions>
          </Disk>
        </DiskConfiguration>
'@
    }
    $partitionId = if ($Firmware -eq 'UEFI') { 3 } else { 1 }
    $productKeyXml = if ($ProductKey) { "<ProductKey><Key>$ProductKey</Key><WillShowUI>OnError</WillShowUI></ProductKey>" } else { '' }
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    $($componentStart -f 'Microsoft-Windows-International-Core-WinPE', $architecture)
      <SetupUILanguage><UILanguage>$language</UILanguage></SetupUILanguage>
      <InputLocale>$language</InputLocale>
      <SystemLocale>$language</SystemLocale>
      <UILanguage>$language</UILanguage>
      <UserLocale>$language</UserLocale>
    </component>
    $($componentStart -f 'Microsoft-Windows-Setup', $architecture)
$disk
      <ImageInstall>
        <OSImage>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>$Index</Value></MetaData></InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>$partitionId</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData><AcceptEula>true</AcceptEula>$productKeyXml</UserData>
    </component>
  </settings>
  <settings pass="specialize">
    $($componentStart -f 'Microsoft-Windows-Deployment', $architecture)
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd.exe /c echo specialize&gt;%SystemRoot%\Temp\WindowsIsoServicing-BootTest.txt</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>shutdown.exe /s /t 0 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
"@
}

function Invoke-HyperVBootTest {
    <#
    .SYNOPSIS
        Installs an image from the ISO in a temporary Hyper-V VM and reports whether it worked.

    .DESCRIPTION
        Builds an answer ISO, creates a VM with an 80 GB dynamic disk, 4 GB memory and two processors, and starts it from
        the ISO (subject to -WhatIf and -Confirm). UEFI VMs are generation 2 with Secure Boot and a virtual TPM, which
        Windows 11 setup requires; the TPM needs a local key protector. No key is pressed unless -SendBootKeys is given,
        so an ISO built by Update-WindowsISO must reach Setup on its own; the result records keyboardInput. Generation 1
        VMs start from the disk before the DVD, as Setup needs when the DVD does not wait for a key: the blank disk
        falls through to the DVD, and after the first restart the installed disk starts.
        The test passes only when the VM shuts down within the timeout and the specialize marker file exists on the
        installed disk; the result starts as Failed and stays so otherwise (INVARIANTS.md, Media #3). The installed
        cumulative update version is read from the disk when possible. The VM, disk and test folder are always removed; a
        cleanup step that fails is logged as a warning with the manual step, and does not change the result.
        Runs on x64 hosts with x64 media only.

    .PARAMETER IsoPath
        Path of the ISO to test.

    .PARAMETER Index
        Image index to install.

    .PARAMETER Language
        Language of the image, for example 'en-US'.

    .PARAMETER WorkPath
        Folder for the VM, its disk and the answer ISO.

    .PARAMETER OscdimgPath
        Path of oscdimg.exe returned by Find-Oscdimg.

    .PARAMETER Firmware
        UEFI (generation 2 VM) or BIOS (generation 1 VM). Defaults to UEFI.

    .PARAMETER TimeoutMinutes
        Time allowed for the installation, 10 to 240 minutes. Defaults to 90.

    .PARAMETER ProductKey
        Product key for editions whose setup requires one.

    .PARAMETER SendBootKeys
        Sends Enter through the Hyper-V keyboard of a generation 2 VM for 20 seconds after it starts, for media whose
        UEFI boot entry still shows "Press any key to boot from CD or DVD".

    .EXAMPLE
        Invoke-HyperVBootTest -IsoPath "$($context.OutputStagingPath)\Windows_Server_2025_x64_26100_2026-11.iso" -Index 2 -Language 'en-US' -WorkPath $context.WorkPath -OscdimgPath (Find-Oscdimg).Path

    .OUTPUTS
        System.Management.Automation.PSCustomObject with performed, type, firmware, index, keyboardInput, result, detail,
        durationMinutes and deployedRollupVersion.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-server/virtualization/hyper-v/get-started/create-a-virtual-machine-in-hyper-v
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$IsoPath,
        [Parameter(Mandatory)]
        [int]$Index,
        [Parameter(Mandatory)]
        [string]$Language,
        [Parameter(Mandatory)]
        [string]$WorkPath,
        [Parameter(Mandatory)]
        [string]$OscdimgPath,
        [ValidateSet('UEFI', 'BIOS')]
        [string]$Firmware = 'UEFI',
        [ValidateRange(10, 240)]
        [int]$TimeoutMinutes = 90,
        [string]$ProductKey,
        [switch]$SendBootKeys
    )
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'The Hyper-V PowerShell module is not available. Enable Hyper-V and its management tools to run a boot test.'
    }
    Import-Module Hyper-V -ErrorAction Stop
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Hyper-V boot tests are implemented for x64 hosts and x64 media only.' }
    $name = "wis-boottest-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $testPath = Join-Path $WorkPath $name
    $vhdPath = Join-Path $testPath 'disk.vhdx'
    $answerMedia = Join-Path $testPath 'answer'
    $answerIso = Join-Path $testPath 'answer.iso'
    $started = Get-Date
    $result = [ordered]@{
        performed = $true; type = 'HyperVInstall'; firmware = $Firmware; index = $Index; keyboardInput = $SendBootKeys.IsPresent -and $Firmware -eq 'UEFI'
        result = 'Failed'; detail = $null; durationMinutes = $null; deployedRollupVersion = $null
    }
    if (-not $PSCmdlet.ShouldProcess($name, 'Create temporary Hyper-V VM and install Windows')) { return }
    $vm = $null
    $vhdMounted = $false
    try {
        $null = New-Item -Path $answerMedia -ItemType Directory -Force
        New-BootTestAnswerFile -Index $Index -Firmware $Firmware -Language $Language -ProductKey $ProductKey | Set-Content -LiteralPath (Join-Path $answerMedia 'autounattend.xml') -Encoding utf8NoBOM
        $null = Invoke-ExternalTool -FilePath $OscdimgPath -ArgumentList @('-u2', '-udfver102', '-lANSWER', $answerMedia, $answerIso) -Operation 'BuildAnswerIso'
        $null = New-VHD -Path $vhdPath -SizeBytes 80GB -Dynamic -ErrorAction Stop
        $generation = if ($Firmware -eq 'UEFI') { 2 } else { 1 }
        $vm = New-VM -Name $name -Generation $generation -MemoryStartupBytes 4GB -VHDPath $vhdPath -Path $testPath -ErrorAction Stop
        Set-VMProcessor -VM $vm -Count 2 -ErrorAction Stop
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -ErrorAction Stop
        if ($generation -eq 2) {
            Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
            Set-VMKeyProtector -VM $vm -NewLocalKeyProtector -ErrorAction Stop
            Enable-VMTPM -VM $vm -ErrorAction Stop
            $dvd = Add-VMDvdDrive -VM $vm -Path $IsoPath -Passthru -ErrorAction Stop
            Add-VMDvdDrive -VM $vm -Path $answerIso -ErrorAction Stop
            Set-VMFirmware -VM $vm -FirstBootDevice $dvd -ErrorAction Stop
        }
        else {
            Set-VMDvdDrive -VMName $name -ControllerNumber 1 -ControllerLocation 0 -Path $IsoPath -ErrorAction Stop
            Add-VMDvdDrive -VM $vm -ControllerNumber 1 -ControllerLocation 1 -Path $answerIso -ErrorAction Stop
            Set-VMBios -VM $vm -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy') -ErrorAction Stop
        }
        Start-VM -VM $vm -ErrorAction Stop
        if ($generation -eq 2 -and $SendBootKeys) {
            $computerSystem = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_ComputerSystem' -Filter "Name='$($vm.Id)'"
            $keyboard = Get-CimAssociatedInstance -InputObject $computerSystem -ResultClassName 'Msvm_Keyboard'
            foreach ($second in 1..20) {
                $null = Invoke-CimMethod -InputObject $keyboard -MethodName 'TypeKey' -Arguments @{ keyCode = [uint32]0x0D }
                Start-Sleep -Seconds 1
            }
        }
        $deadline = $started.AddMinutes($TimeoutMinutes)
        while ((Get-VM -Id $vm.Id).State -ne 'Off' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 30
        }
        if ((Get-VM -Id $vm.Id).State -ne 'Off') {
            $result.detail = "VM did not shut down within $TimeoutMinutes minutes; Windows Setup did not reach the specialize pass."
        }
        else {
            $disk = Mount-VHD -Path $vhdPath -ReadOnly -Passthru -ErrorAction Stop | Get-Disk
            $vhdMounted = $true
            $windowsPartition = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
            if (-not $windowsPartition.DriveLetter) {
                $windowsPartition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
                $windowsPartition = $windowsPartition | Get-Partition
            }
            $windowsRoot = "$($windowsPartition.DriveLetter):\"
            if (-not (Test-Path -LiteralPath (Join-Path $windowsRoot 'Windows\Temp\WindowsIsoServicing-BootTest.txt'))) {
                $result.detail = 'The VM shut down but the specialize marker file is missing; installation did not complete.'
            }
            else {
                $result.result = 'Passed'
                $result.detail = 'Windows Setup installed the image, the VM booted from the installed disk and ran the specialize pass.'
                try {
                    $result.deployedRollupVersion = [string](Get-RollupVersion -MountPath $windowsRoot)
                }
                catch {
                    $result.detail += " Installed package inventory could not be read: $_"
                }
            }
        }
    }
    catch {
        $result.detail = "$_"
    }
    finally {
        $result.durationMinutes = [math]::Round(((Get-Date) - $started).TotalMinutes, 1)
        if ($vhdMounted) {
            try { Dismount-VHD -Path $vhdPath -ErrorAction Stop }
            catch { Write-ServicingLog -Operation 'BootTest' -Level Warning -Target $vhdPath -Message "Unable to dismount the test disk; dismount it manually: $_" }
        }
        if ($vm) {
            try {
                if ((Get-VM -Id $vm.Id -ErrorAction Stop).State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop }
                Remove-VM -VM $vm -Force -ErrorAction Stop
            }
            catch { Write-ServicingLog -Operation 'BootTest' -Level Warning -Target $name -Message "Unable to remove the test VM; remove it in Hyper-V Manager: $_" }
        }
        if (Test-Path -LiteralPath $testPath) {
            try { Remove-Item -LiteralPath $testPath -Recurse -Force -ErrorAction Stop }
            catch { Write-ServicingLog -Operation 'BootTest' -Level Warning -Target $testPath -Message "Unable to remove the boot test folder; delete it manually: $_" }
        }
        Write-ServicingLog -Operation 'BootTest' -Target $IsoPath -Message "Result: $($result.result). $($result.detail)"
    }
    [pscustomobject]$result
}
