#Requires -Version 7.4
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs Windows from a serviced ISO in a temporary Hyper-V VM without user interaction and verifies the installed system.

.DESCRIPTION
    Proves that an ISO produced by Update-WindowsISO installs and boots. The script detects the release, editions and versions on the ISO with Get-WindowsISOInfo, writes an Autounattend.xml for the selected edition, builds a second ISO that holds only that file with the Microsoft-signed OSCDIMG the module ships, and attaches both ISOs to a new, uniquely named VM. The VM starts from its disk first: the blank disk falls through to the Windows ISO, and after the first restart of Setup the installed disk starts, so the ISO can never start the installation again. The serviced ISO boots without "Press any key", so no key is pressed.
    Generation 2 VMs get Secure Boot with the MicrosoftWindows template and a virtual TPM with a local key protector. Windows 11 requires both, at least 4 GB of memory, two processors and a 64 GB disk, and the script refuses settings below that instead of bypassing the checks. Generation 1 (BIOS) is offered for releases that support it.
    The VM is monitored until Windows Setup records IMAGE_STATE_COMPLETE in %SystemRoot%\Setup\State\State.ini, which the script reads over PowerShell Direct with the supplied Administrator credential. Logging on with that credential also proves that the password from the answer file was applied. The VM turning off, more restarts than an installation needs, or the timeout end the run as failed. The installed system is then checked over PowerShell Direct: edition and installation type, version and UBR against the image on the ISO, architecture, the Package_for_RollupFix and servicing stack versions against the ISO's manifest (when one is next to the ISO), UI language, system and user locale, keyboard layout, time zone, computer name, the built-in Administrator account, and that the VM joined no domain. Releases without PowerShell Direct (before Windows 10 and Windows Server 2016) are checked through the Hyper-V data exchange (KVP) items the guest publishes; the checks that need a logon are then recorded as Skipped.
    Afterwards the VM is shut down and its disk is mounted read-only to copy the Panther, Setup event, CBS and DISM logs into the output folder, and to check State.ini and the setuperr.log of the specialize and oobeSystem passes. The answer file and the answer ISO hold the Administrator password in the Base64 form Windows Setup reads, which is not encryption. They are written to a folder only Administrators and SYSTEM can read, and are deleted on every exit path, also with -KeepVM. The password is never logged.
    The VM, its folder and its disk are removed at the end unless -KeepVM is given, or -KeepVMOnFailure and the test failed. Only the VM created by this run, found by its ID, and the folder created for it are removed. The serviced ISO is attached read-only and never changed. The script returns the result and exits with code 1 when any check fails.

.PARAMETER IsoPath
    Serviced Windows ISO to install, normally created by Update-WindowsISO.

.PARAMETER Edition
    EditionId of the image to install, for example ServerStandard or Professional. On Windows Server media, the Desktop Experience image is chosen unless -ServerCore is given.

.PARAMETER Index
    Image index to install, instead of -Edition.

.PARAMETER ServerCore
    With -Edition on Windows Server media, installs the Server Core image of that edition.

.PARAMETER AdministratorCredential
    Credential for the built-in Administrator account. The user name must be Administrator. The password must meet the default Windows complexity rules (at least 8 characters from three of: upper case, lower case, digits, symbols). Use a test password, never a production one.

.PARAMETER ManifestPath
    Manifest of the ISO, which supplies the expected cumulative update and servicing stack versions. Defaults to '<IsoPath>.json' when that file exists; without a manifest those checks are compared with the image version only, or Skipped.

.PARAMETER Language
    Windows Setup and system UI language. Must be one of the image's languages. Defaults to en-US.

.PARAMETER SystemLocale
    System locale (language for non-Unicode programs). Defaults to en-US.

.PARAMETER UserLocale
    User locale (formats). Defaults to en-US.

.PARAMETER KeyboardLayout
    Input locale, as a culture name. Defaults to da-DK.

.PARAMETER TimeZone
    Windows time zone ID. Defaults to Romance Standard Time.

.PARAMETER ComputerName
    Computer name of the installed system. Defaults to WIS- followed by eight random hexadecimal characters.

.PARAMETER ProductKey
    Product key for editions whose Setup requires one. Setup shows the key page only when the key is rejected.

.PARAMETER Generation
    Hyper-V VM generation: 2 (UEFI, default) or 1 (BIOS).

.PARAMETER MemoryGB
    Startup memory in GB, 2 to 64. Defaults to 4.

.PARAMETER DynamicMemory
    Enables dynamic memory, with the startup memory as minimum.

.PARAMETER ProcessorCount
    Number of virtual processors, 1 to 16. Defaults to 2.

.PARAMETER DiskSizeGB
    Size of the dynamically expanding VHDX, 32 to 1024 GB. Defaults to 64.

.PARAMETER SwitchName
    Hyper-V virtual switch for the VM's network adapter. Without it the VM has no network adapter and installs offline.

.PARAMETER TimeoutMinutes
    Time allowed from VM start until Windows Setup is complete, 20 to 480 minutes. Defaults to 90.

.PARAMETER OutputDirectory
    Folder for the result and the diagnostic logs. A subfolder named after the run is created. Defaults to %ProgramData%\WindowsIsoServicing\InstallationTests.

.PARAMETER WorkingDirectory
    Folder for the VM, its disk and the answer ISO. A subfolder named after the run is created. Needs 40 GB free. Defaults to %ProgramData%\WindowsIsoServicing\Workspace.

.PARAMETER KeepVM
    Keeps the VM and its disk after the test, turned off.

.PARAMETER KeepVMOnFailure
    Keeps the VM and its disk, turned off, only when the test failed.

.EXAMPLE
    .\tests\live\Test-WindowsIsoInstallation.ps1 -IsoPath 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso' -Edition 'ServerStandard' -AdministratorCredential (Get-Credential -UserName 'Administrator') -KeepVMOnFailure -Verbose

.EXAMPLE
    .\tests\live\Test-WindowsIsoInstallation.ps1 -IsoPath 'D:\ISO\Updated\Windows_11_24H2_x64_26100_2026-11.iso' -Edition 'Enterprise' -AdministratorCredential (Get-Credential -UserName 'Administrator') -Language 'en-US' -KeyboardLayout 'da-DK' -TimeZone 'Romance Standard Time' -MemoryGB 4 -ProcessorCount 2 -TimeoutMinutes 90

.OUTPUTS
    WindowsIsoServicing.InstallationTestResult

.NOTES
    Author:  Lars Krogh Paulsen
    Version: 1.0.0

.LINK
    https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/

.LINK
    https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct
#>

[CmdletBinding(DefaultParameterSetName = 'Edition')]
[OutputType('WindowsIsoServicing.InstallationTestResult')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$IsoPath,
    [Parameter(Mandatory, ParameterSetName = 'Edition')]
    [ValidatePattern('^[A-Za-z]+$')]
    [string]$Edition,
    [Parameter(Mandatory, ParameterSetName = 'Index')]
    [ValidateRange(1, 256)]
    [int]$Index,
    [Parameter(ParameterSetName = 'Edition')]
    [switch]$ServerCore,
    [Parameter(Mandatory)]
    [System.Management.Automation.Credential()]
    [pscredential]$AdministratorCredential,
    [string]$ManifestPath,
    [ValidateScript({ [cultureinfo]::GetCultureInfo($_) })]
    [string]$Language = 'en-US',
    [ValidateScript({ [cultureinfo]::GetCultureInfo($_) })]
    [string]$SystemLocale = 'en-US',
    [ValidateScript({ [cultureinfo]::GetCultureInfo($_) })]
    [string]$UserLocale = 'en-US',
    [ValidateScript({ [cultureinfo]::GetCultureInfo($_) })]
    [string]$KeyboardLayout = 'da-DK',
    [ValidateScript({ [System.TimeZoneInfo]::FindSystemTimeZoneById($_) })]
    [string]$TimeZone = 'Romance Standard Time',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
    [string]$ComputerName = "WIS-$([guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant())",
    [ValidatePattern('^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$')]
    [string]$ProductKey,
    [ValidateSet(1, 2)]
    [int]$Generation = 2,
    [ValidateRange(2, 64)]
    [int]$MemoryGB = 4,
    [switch]$DynamicMemory,
    [ValidateRange(1, 16)]
    [int]$ProcessorCount = 2,
    [ValidateRange(32, 1024)]
    [int]$DiskSizeGB = 64,
    [string]$SwitchName,
    [ValidateRange(20, 480)]
    [int]$TimeoutMinutes = 90,
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path $env:ProgramData 'WindowsIsoServicing\InstallationTests'),
    [ValidateNotNullOrEmpty()]
    [string]$WorkingDirectory = (Join-Path $env:ProgramData 'WindowsIsoServicing\Workspace'),
    [switch]$KeepVM,
    [switch]$KeepVMOnFailure
)

function New-InstallationAnswerFile {
    <#
    .SYNOPSIS
        Creates the Autounattend.xml text for an unattended installation that completes OOBE.

    .DESCRIPTION
        Returns an answer file for amd64 with the windowsPE, specialize and oobeSystem passes. windowsPE sets the Setup language and locales, wipes disk 0, creates a GPT layout (EFI 260 MB, MSR 16 MB, Windows) for UEFI or one active NTFS partition for BIOS, installs the image index and accepts the license terms. specialize sets the computer name and time zone. oobeSystem sets the locales of the installed system, hides the license and OEM pages, and sets the password of the built-in Administrator account, encoded the way Windows Setup expects (Base64 of the UTF-16 text password followed by AdministratorPassword), which is not encryption. Windows Server hides the Administrator password page (HideLocalAccountScreen, a Server-only setting). Client releases hide the online account, wireless and privacy pages, and enable the built-in Administrator account, which is disabled by default on client editions, with one automatic logon (AutoLogon with LogonCount 1, the method Microsoft documents for this; its password is encoded the same way with the suffix Password). No account is created, no domain is joined and Windows is not activated. Every value is XML-escaped.
        This is separate from the module's New-BootTestAnswerFile, which stops in the specialize pass and never completes OOBE.

    .PARAMETER Index
        Image index to install.

    .PARAMETER Firmware
        UEFI or BIOS.

    .PARAMETER Family
        Client or Server, from the release data. It selects the OOBE settings that apply to that family.

    .PARAMETER Language
        Setup and system UI language.

    .PARAMETER SystemLocale
        System locale.

    .PARAMETER UserLocale
        User locale.

    .PARAMETER KeyboardLayout
        Input locale as a culture name.

    .PARAMETER TimeZone
        Windows time zone ID.

    .PARAMETER ComputerName
        Computer name.

    .PARAMETER AdministratorPassword
        Password of the built-in Administrator account.

    .PARAMETER ProductKey
        Product key, or empty.

    .EXAMPLE
        New-InstallationAnswerFile -Index 2 -Firmware 'UEFI' -Family 'Server' -Language 'en-US' -SystemLocale 'en-US' -UserLocale 'en-US' -KeyboardLayout 'da-DK' -TimeZone 'Romance Standard Time' -ComputerName 'WIS-1A2B3C4D' -AdministratorPassword $AdministratorCredential.Password

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts-administratorpassword
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
        [ValidateSet('Client', 'Server')]
        [string]$Family,
        [Parameter(Mandatory)]
        [string]$Language,
        [Parameter(Mandatory)]
        [string]$SystemLocale,
        [Parameter(Mandatory)]
        [string]$UserLocale,
        [Parameter(Mandatory)]
        [string]$KeyboardLayout,
        [Parameter(Mandatory)]
        [string]$TimeZone,
        [Parameter(Mandatory)]
        [string]$ComputerName,
        [Parameter(Mandatory)]
        [securestring]$AdministratorPassword,
        [AllowEmptyString()]
        [string]$ProductKey
    )
    $plainPassword = [System.Net.NetworkCredential]::new('', $AdministratorPassword).Password
    $encodedPassword = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("${plainPassword}AdministratorPassword"))
    $encodedAutoLogonPassword = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("${plainPassword}Password"))
    $escaped = @{
        Language       = [System.Security.SecurityElement]::Escape($Language)
        SystemLocale   = [System.Security.SecurityElement]::Escape($SystemLocale)
        UserLocale     = [System.Security.SecurityElement]::Escape($UserLocale)
        KeyboardLayout = [System.Security.SecurityElement]::Escape($KeyboardLayout)
        TimeZone       = [System.Security.SecurityElement]::Escape($TimeZone)
        ComputerName   = [System.Security.SecurityElement]::Escape($ComputerName)
    }
    $component = '<component name="{0}" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    $disk = if ($Firmware -eq 'UEFI') {
        @'
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
'@
    }
    else {
        @'
        <CreatePartitions>
          <CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
        </CreatePartitions>
        <ModifyPartitions>
          <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Active>true</Active><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
        </ModifyPartitions>
'@
    }
    $partitionId = if ($Firmware -eq 'UEFI') { 3 } else { 1 }
    $productKeyXml = if ($ProductKey) { "<ProductKey><Key>$ProductKey</Key><WillShowUI>OnError</WillShowUI></ProductKey>" } else { '' }
    $familyOobe = if ($Family -eq 'Client') { '<HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC>' } else { '<HideLocalAccountScreen>true</HideLocalAccountScreen>' }
    $autoLogon = if ($Family -eq 'Client') { "<AutoLogon><Username>Administrator</Username><Enabled>true</Enabled><LogonCount>1</LogonCount><Password><Value>$encodedAutoLogonPassword</Value><PlainText>false</PlainText></Password></AutoLogon>" } else { '' }
    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    $($component -f 'Microsoft-Windows-International-Core-WinPE')
      <SetupUILanguage><UILanguage>$($escaped.Language)</UILanguage></SetupUILanguage>
      <InputLocale>$($escaped.KeyboardLayout)</InputLocale>
      <SystemLocale>$($escaped.SystemLocale)</SystemLocale>
      <UILanguage>$($escaped.Language)</UILanguage>
      <UserLocale>$($escaped.UserLocale)</UserLocale>
    </component>
    $($component -f 'Microsoft-Windows-Setup')
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
$disk
        </Disk>
      </DiskConfiguration>
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
    $($component -f 'Microsoft-Windows-Shell-Setup')
      <ComputerName>$($escaped.ComputerName)</ComputerName>
      <TimeZone>$($escaped.TimeZone)</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    $($component -f 'Microsoft-Windows-International-Core')
      <InputLocale>$($escaped.KeyboardLayout)</InputLocale>
      <SystemLocale>$($escaped.SystemLocale)</SystemLocale>
      <UILanguage>$($escaped.Language)</UILanguage>
      <UserLocale>$($escaped.UserLocale)</UserLocale>
    </component>
    $($component -f 'Microsoft-Windows-Shell-Setup')
      <OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>$familyOobe</OOBE>
      $autoLogon
      <UserAccounts><AdministratorPassword><Value>$encodedPassword</Value><PlainText>false</PlainText></AdministratorPassword></UserAccounts>
    </component>
  </settings>
</unattend>
"@
}

function Get-GuestKvpItem {
    <#
    .SYNOPSIS
        Reads the data exchange (KVP) items a running guest publishes to Hyper-V.

    .DESCRIPTION
        Returns a hashtable of the intrinsic items the guest's Hyper-V data exchange service publishes, such as OSName, OSVersion, OSBuildNumber, ProductType and FullyQualifiedDomainName. They are available only while the installed system is running with its integration services, so they show that the installed system booted, without logging on. Returns an empty hashtable when the guest publishes nothing yet.

    .PARAMETER VMId
        ID of the VM.

    .EXAMPLE
        Get-GuestKvpItem -VMId $vm.Id

    .OUTPUTS
        System.Collections.Hashtable

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/win32/hyperv_v2/msvm-kvpexchangecomponent
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [guid]$VMId
    )
    $items = @{}
    $computerSystem = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_ComputerSystem' -Filter "Name='$VMId'" -ErrorAction Stop
    $exchange = Get-CimAssociatedInstance -InputObject $computerSystem -ResultClassName 'Msvm_KvpExchangeComponent' -ErrorAction Stop
    foreach ($item in @(${exchange}?.GuestIntrinsicExchangeItems)) {
        if (-not $item) {
            continue
        }
        $properties = ([xml]$item).INSTANCE.PROPERTY
        $name = ($properties | Where-Object NAME -EQ 'Name').VALUE
        $items[$name] = ($properties | Where-Object NAME -EQ 'Data').VALUE
    }
    $items
}

function Get-GuestSetupState {
    <#
    .SYNOPSIS
        Reads the Windows Setup image state of a guest over PowerShell Direct.

    .DESCRIPTION
        Logs on to the VM over PowerShell Direct with the Administrator credential and returns the ImageState value of %SystemRoot%\Setup\State\State.ini, for example IMAGE_STATE_COMPLETE. Throws while the guest does not accept the logon, which is the case until OOBE has applied the Administrator password.

    .PARAMETER VMId
        ID of the VM.

    .PARAMETER Credential
        Administrator credential.

    .EXAMPLE
        Get-GuestSetupState -VMId $vm.Id -Credential $credential

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-states
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [guid]$VMId,
        [Parameter(Mandatory)]
        [pscredential]$Credential
    )
    Invoke-Command -VMId $VMId -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $stateFile = Join-Path $env:SystemRoot 'Setup\State\State.ini'
        if (Test-Path -LiteralPath $stateFile) {
            $match = Select-String -LiteralPath $stateFile -Pattern '^\s*ImageState\s*=\s*(\S+)' | Select-Object -First 1
            if ($match) { $match.Matches[0].Groups[1].Value }
        }
    }
}

function Get-GuestSystemInformation {
    <#
    .SYNOPSIS
        Reads the installed system's version, edition, packages, regional settings and accounts over PowerShell Direct.

    .DESCRIPTION
        Runs one read-only script block in the guest as Administrator. It returns the version and UBR, EditionID and InstallationType from the registry, the processor architecture, the highest installed Package_for_RollupFix and Package_for_ServicingStack versions from Get-WindowsPackage -Online, the installed UI language, system locale, the Administrator's user locale and first keyboard layout, the time zone, the computer name, whether the computer is in a domain, and the built-in Administrator account (SID ending in -500). The script block uses only Windows PowerShell 5.1 syntax, because it runs in the guest's Windows PowerShell. All values are returned as strings.

    .PARAMETER VMId
        ID of the VM.

    .PARAMETER Credential
        Administrator credential.

    .EXAMPLE
        Get-GuestSystemInformation -VMId $vm.Id -Credential $credential

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
        [guid]$VMId,
        [Parameter(Mandatory)]
        [pscredential]$Credential
    )
    Invoke-Command -VMId $VMId -Credential $Credential -ErrorAction Stop -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        $packages = @(Get-WindowsPackage -Online | Where-Object { $_.PackageState -eq 'Installed' -or $_.PackageState -eq 'InstallPending' })
        $rollup = $packages | Where-Object PackageName -Like 'Package_for_RollupFix~*' | ForEach-Object { [version]($_.PackageName -split '~')[-1] } | Sort-Object -Descending | Select-Object -First 1
        $servicingStack = $packages | Where-Object PackageName -Like 'Package_for_ServicingStack*' | ForEach-Object { [version]($_.PackageName -split '~')[-1] } | Sort-Object -Descending | Select-Object -First 1
        $administrator = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-21-*-500' } | Select-Object -First 1
        $preloadKey = 'HKCU:\Keyboard Layout\Preload'
        $keyboardLayout = if (Test-Path -LiteralPath $preloadKey) { (Get-ItemProperty -LiteralPath $preloadKey).'1' }
        $ubr = if ($currentVersion.PSObject.Properties['UBR']) { $currentVersion.UBR } else { 0 }
        [pscustomobject]@{
            Version              = "$($operatingSystem.Version).$ubr"
            EditionId            = [string]$currentVersion.EditionID
            InstallationType     = [string]$currentVersion.InstallationType
            Architecture         = [string]$env:PROCESSOR_ARCHITECTURE
            RollupVersion        = [string]$rollup
            ServicingStack       = [string]$servicingStack
            UiLanguage           = [System.Globalization.CultureInfo]::InstalledUICulture.Name
            SystemLocale         = (Get-WinSystemLocale).Name
            UserLocale           = (Get-Culture).Name
            KeyboardLayout       = [string]$keyboardLayout
            TimeZone             = (Get-TimeZone).Id
            ComputerName         = [string]$env:COMPUTERNAME
            PartOfDomain         = [string]$computerSystem.PartOfDomain
            AdministratorName    = [string]$administrator.Name
            AdministratorEnabled = [string]$administrator.Enabled
        }
    }
}

function Save-InstallationLog {
    <#
    .SYNOPSIS
        Copies the setup and servicing logs from the VM's disk while the VM is off.

    .DESCRIPTION
        Mounts the VHDX read-only, gives its largest partition (the Windows partition) a drive letter, and copies the Windows Setup logs (Panther, Panther\UnattendGC and, for failures in the windowsPE pass, $WINDOWS.~BT\Sources\Panther), State.ini, the Setup event log, CBS.log and dism.log into Destination. File names keep their path, with backslashes replaced by underscores. The copy of the answer file Setup keeps in Panther is never copied. Returns the files copied, the ImageState from State.ini and the lines of UnattendGC\setuperr.log. The VHDX is always dismounted again.

    .PARAMETER VhdPath
        Path of the VM's VHDX. The VM must be off.

    .PARAMETER Destination
        Folder for the logs. It is created when missing.

    .EXAMPLE
        Save-InstallationLog -VhdPath 'C:\ProgramData\WindowsIsoServicing\Workspace\wis-install-1a2b3c4d\disk.vhdx' -Destination 'C:\ProgramData\WindowsIsoServicing\InstallationTests\wis-install-1a2b3c4d\logs'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Files, ImageState and UnattendErrors.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/troubleshoot/windows-client/setup-upgrade-and-drivers/windows-setup-log-file-locations
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$VhdPath,
        [Parameter(Mandatory)]
        [string]$Destination
    )
    $logFiles = @(
        'Windows\Panther\setupact.log'
        'Windows\Panther\setuperr.log'
        'Windows\Panther\UnattendGC\setupact.log'
        'Windows\Panther\UnattendGC\setuperr.log'
        '$WINDOWS.~BT\Sources\Panther\setupact.log'
        '$WINDOWS.~BT\Sources\Panther\setuperr.log'
        'Windows\Setup\State\State.ini'
        'Windows\System32\winevt\Logs\Setup.evtx'
        'Windows\Logs\CBS\CBS.log'
        'Windows\Logs\DISM\dism.log'
    )
    $null = New-Item -Path $Destination -ItemType Directory -Force
    $disk = Mount-VHD -Path $VhdPath -ReadOnly -Passthru -ErrorAction Stop | Get-Disk
    try {
        $partition = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
        if (-not $partition) {
            return [pscustomobject]@{
                Files          = @()
                ImageState     = $null
                UnattendErrors = @('The disk has no partitions; Windows Setup did not partition it.')
            }
        }
        if (-not $partition.DriveLetter) {
            $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
            $partition = $partition | Get-Partition
        }
        $root = "$($partition.DriveLetter):\"
        $copied = foreach ($relativePath in $logFiles) {
            $source = Join-Path $root $relativePath
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $target = Join-Path $Destination ($relativePath -replace '[\\$~]', '_')
                Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
                $target
            }
        }
        $stateFile = Join-Path $root 'Windows\Setup\State\State.ini'
        $imageState = if (Test-Path -LiteralPath $stateFile -PathType Leaf) { (Select-String -LiteralPath $stateFile -Pattern '^\s*ImageState\s*=\s*(\S+)' | Select-Object -First 1)?.Matches[0].Groups[1].Value }
        $unattendErrorLog = Join-Path $root 'Windows\Panther\UnattendGC\setuperr.log'
        [pscustomobject]@{
            Files          = @($copied)
            ImageState     = $imageState
            UnattendErrors = @(if (Test-Path -LiteralPath $unattendErrorLog -PathType Leaf) { Get-Content -LiteralPath $unattendErrorLog | Where-Object { $_.Trim() } })
        }
    }
    finally {
        Dismount-VHD -Path $VhdPath -ErrorAction Stop
    }
}

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version 3.0

$module = Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force -PassThru

$startedAt = [DateTimeOffset]::Now
$runName = "wis-install-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$checks = [System.Collections.Generic.List[object]]::new()
$failureReason = $null
$installationStatus = 'NotStarted'
$vm = $null
$guest = $null
$logResult = $null
$kvp = @{}
$restartCount = 0
$keepMachine = $false

if ($AdministratorCredential.UserName -notmatch '^(\.\\)?Administrator$') {
    throw "The credential must be for the built-in account 'Administrator', not '$($AdministratorCredential.UserName)'. The test sets that account's password and logs on with it."
}
$plainPassword = $AdministratorCredential.GetNetworkCredential().Password
$categories = @('[A-Z]', '[a-z]', '[0-9]', '[^A-Za-z0-9]' | Where-Object { $plainPassword -cmatch $_ }).Count
if ($plainPassword.Length -lt 8 -or $categories -lt 3) {
    throw 'The Administrator password does not meet the default Windows complexity rules (at least 8 characters from three of: upper case, lower case, digits, symbols); Setup would stop at the password page.'
}
$plainPassword = $null
$guestCredential = [pscredential]::new('Administrator', $AdministratorCredential.Password)
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'The Hyper-V PowerShell module is not installed. Enable Hyper-V with its management tools: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All.'
}
Import-Module Hyper-V -ErrorAction Stop
$null = Get-VMHost -ErrorAction Stop
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'The installation test runs on x64 Hyper-V hosts only.'
}
if ($SwitchName -and -not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V virtual switch '$SwitchName' does not exist. List the switches with Get-VMSwitch, or omit -SwitchName to install without network."
}

$isoFile = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
if ((Get-DiskImage -ImagePath $isoFile).Attached) {
    throw "'$isoFile' is mounted on the host, so Hyper-V cannot attach it. Dismount it first: Dismount-DiskImage -ImagePath '$isoFile'."
}
Write-Information "Reading $isoFile" -InformationAction Continue
$isoInfo = Get-WindowsISOInfo -SourceISO $isoFile
$candidates = if ($PSCmdlet.ParameterSetName -eq 'Index') {
    @($isoInfo.Images | Where-Object Index -EQ $Index)
}
else {
    @($isoInfo.Images | Where-Object { $_.EditionId -eq $Edition -and ($_.InstallationType -ne 'Server Core') -ne $ServerCore.IsPresent })
}
if ($candidates.Count -ne 1) {
    $available = ($isoInfo.Images | ForEach-Object { "$($_.Index): $($_.EditionId) ($($_.InstallationType))" }) -join '; '
    throw "Exactly one image must match the selection, but $($candidates.Count) do. Images on the ISO: $available. Use -Index, or -ServerCore for a Server Core image."
}
$image = $candidates[0]
$release = $image.OperatingSystem
if ($image.Architecture -ne 'x64') {
    throw "Image $($image.Index) is $($image.Architecture); the Hyper-V installation test supports x64 images only."
}
if ($Language -notin $image.Languages) {
    throw "Language '$Language' is not in image $($image.Index) (languages: $($image.Languages -join ', ')). Pass one of them with -Language."
}
$isWindows11 = $release.Name -eq 'Windows 11'
if ($isWindows11 -and ($Generation -ne 2 -or $MemoryGB -lt 4 -or $ProcessorCount -lt 2 -or $DiskSizeGB -lt 64)) {
    throw 'Windows 11 requires a generation 2 VM with Secure Boot and TPM 2.0, at least 4 GB of memory, two processors and a 64 GB disk. The test does not bypass these requirements.'
}
$supportsPowerShellDirect = $image.Build -ge 10240
$firmware = if ($Generation -eq 2) { 'UEFI' } else { 'BIOS' }
if (-not $ManifestPath -and (Test-Path -LiteralPath "$isoFile.json" -PathType Leaf)) {
    $ManifestPath = "$isoFile.json"
}
$manifest = if ($ManifestPath) { Get-WindowsISOManifest -Path $ManifestPath }
$manifestImage = if ($manifest) { @($manifest.images.install) | Where-Object index -EQ $image.Index | Select-Object -First 1 }
$cumulative = if ($manifest) { @($manifest.updates) | Where-Object category -EQ 'CumulativeUpdate' | Select-Object -First 1 }

$freeMemoryGB = [math]::Round((Get-CimInstance -ClassName Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
if ($freeMemoryGB -lt $MemoryGB) {
    throw "The host has $freeMemoryGB GB of free memory; the VM needs $MemoryGB GB. Close other VMs or lower -MemoryGB."
}
$workRoot = (Resolve-Path -LiteralPath (New-Item -Path $WorkingDirectory -ItemType Directory -Force)).ProviderPath
& $module { Assert-FreeSpace -Path $args[0] -RequiredBytes 40GB } $workRoot
$vmDirectory = Join-Path $workRoot $runName
$answerDirectory = Join-Path $vmDirectory 'answer'
$answerIso = Join-Path $vmDirectory 'answer.iso'
$vhdPath = Join-Path $vmDirectory 'disk.vhdx'
$runDirectory = Join-Path (Resolve-Path -LiteralPath (New-Item -Path $OutputDirectory -ItemType Directory -Force)).ProviderPath $runName
$logDirectory = Join-Path $runDirectory 'logs'
if ((Test-Path -LiteralPath $vmDirectory) -or (Get-VM -Name $runName -ErrorAction SilentlyContinue)) {
    throw "A VM or folder named '$runName' already exists. Nothing was changed; run the test again."
}
$null = New-Item -Path $runDirectory -ItemType Directory
$vmConfiguration = [ordered]@{
    name           = $runName
    generation     = $Generation
    firmware       = $firmware
    processorCount = $ProcessorCount
    memoryGB       = $MemoryGB
    dynamicMemory  = $DynamicMemory.IsPresent
    diskSizeGB     = $DiskSizeGB
    switchName     = $SwitchName
    secureBoot     = $Generation -eq 2
    tpm            = $false
    computerName   = $ComputerName
}

try {
    $null = New-Item -Path $answerDirectory -ItemType Directory
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-32-544', 'S-1-5-18') {
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $answerDirectory -AclObject $acl
    $answerParameters = @{
        Index                 = $image.Index
        Firmware              = $firmware
        Family                = $release.Family
        Language              = $Language
        SystemLocale          = $SystemLocale
        UserLocale            = $UserLocale
        KeyboardLayout        = $KeyboardLayout
        TimeZone              = $TimeZone
        ComputerName          = $ComputerName
        AdministratorPassword = $AdministratorCredential.Password
        ProductKey            = $ProductKey
    }
    New-InstallationAnswerFile @answerParameters | Set-Content -LiteralPath (Join-Path $answerDirectory 'Autounattend.xml') -Encoding utf8NoBOM
    $oscdimg = (& $module { Find-Oscdimg }).Path
    $null = & $module { Invoke-ExternalTool -FilePath $args[0] -ArgumentList @('-u2', '-udfver102', '-lAUTOUNATTEND', $args[1], $args[2]) -Operation 'BuildAnswerIso' } $oscdimg $answerDirectory $answerIso
    Remove-Item -LiteralPath $answerDirectory -Recurse -Force
    Write-Information "Creating VM $runName (generation $Generation, $ProcessorCount vCPU, $MemoryGB GB, $DiskSizeGB GB disk)" -InformationAction Continue
    $null = New-VHD -Path $vhdPath -SizeBytes ([long]$DiskSizeGB * 1GB) -Dynamic -ErrorAction Stop
    $vm = New-VM -Name $runName -Generation $Generation -MemoryStartupBytes ([long]$MemoryGB * 1GB) -VHDPath $vhdPath -Path $vmDirectory -ErrorAction Stop
    Set-VM -VM $vm -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -ErrorAction Stop
    Set-VMProcessor -VM $vm -Count $ProcessorCount -ErrorAction Stop
    if ($DynamicMemory) {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes ([long]$MemoryGB * 1GB) -StartupBytes ([long]$MemoryGB * 1GB) -ErrorAction Stop
    }
    else {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -ErrorAction Stop
    }
    if ($SwitchName) {
        Get-VMNetworkAdapter -VM $vm | Connect-VMNetworkAdapter -SwitchName $SwitchName -ErrorAction Stop
    }
    else {
        Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter -ErrorAction Stop
    }
    if ($Generation -eq 2) {
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -ErrorAction Stop
        try {
            Set-VMKeyProtector -VM $vm -NewLocalKeyProtector -ErrorAction Stop
            Enable-VMTPM -VM $vm -ErrorAction Stop
            $vmConfiguration.tpm = $true
        }
        catch {
            if ($isWindows11) {
                throw "Windows 11 requires TPM 2.0, but the virtual TPM could not be enabled: $_"
            }
            Write-Warning "The virtual TPM could not be enabled; $($release.Name) installs without it: $_"
        }
        $hardDrive = Get-VMHardDiskDrive -VM $vm
        $windowsDvd = Add-VMDvdDrive -VM $vm -Path $isoFile -Passthru -ErrorAction Stop
        $answerDvd = Add-VMDvdDrive -VM $vm -Path $answerIso -Passthru -ErrorAction Stop
        $bootOrder = @($hardDrive, $windowsDvd, $answerDvd) + @(Get-VMNetworkAdapter -VM $vm)
        Set-VMFirmware -VM $vm -BootOrder $bootOrder -ErrorAction Stop
    }
    else {
        Set-VMDvdDrive -VMName $runName -ControllerNumber 1 -ControllerLocation 0 -Path $isoFile -ErrorAction Stop
        Add-VMDvdDrive -VM $vm -ControllerNumber 1 -ControllerLocation 1 -Path $answerIso -ErrorAction Stop
        Set-VMBios -VM $vm -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy') -ErrorAction Stop
    }

    Write-Information "Starting $runName; Windows Setup runs unattended (timeout $TimeoutMinutes minutes)" -InformationAction Continue
    $installationStatus = 'Running'
    Start-VM -VM $vm -ErrorAction Stop
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $maximumRestarts = 8
    $previousUptime = [timespan]::Zero
    $kvp = @{}
    $stablePolls = 0
    while ($installationStatus -eq 'Running') {
        Start-Sleep -Seconds 20
        $state = Get-VM -Id $vm.Id -ErrorAction Stop
        if ($state.State -eq 'Off') {
            $installationStatus = 'Failed'
            $failureReason = "The VM turned off after $restartCount restarts, before Windows Setup completed. Windows Setup or the installed system shut it down; see the Panther logs."
            break
        }
        if ($state.Uptime -lt $previousUptime) {
            $restartCount++
            $stablePolls = 0
            Write-Information "VM restarted ($restartCount); Windows Setup continues" -InformationAction Continue
        }
        $previousUptime = $state.Uptime
        if ($restartCount -gt $maximumRestarts) {
            $installationStatus = 'Failed'
            $failureReason = "The VM restarted $restartCount times. Windows Setup is probably starting again from the ISO, or failing and restarting."
            break
        }
        if ((Get-Date) -gt $deadline) {
            $installationStatus = 'Failed'
            $failureReason = "Windows Setup did not complete within $TimeoutMinutes minutes ($restartCount restarts, heartbeat $($state.Heartbeat)). Connect to the VM with -KeepVMOnFailure to see where it stopped."
            break
        }
        if ([string]$state.Heartbeat -notlike 'Ok*') {
            continue
        }
        if ($supportsPowerShellDirect) {
            try {
                $imageState = Get-GuestSetupState -VMId $vm.Id -Credential $guestCredential
                Write-Verbose "Windows Setup image state: $imageState"
                if ($imageState -eq 'IMAGE_STATE_COMPLETE') {
                    $installationStatus = 'Completed'
                }
            }
            catch {
                Write-Verbose "PowerShell Direct is not available yet: $_"
            }
        }
        else {
            $kvp = Get-GuestKvpItem -VMId $vm.Id
            $stablePolls = if ($kvp['OSBuildNumber']) { $stablePolls + 1 } else { 0 }
            if ($stablePolls -ge 15) {
                $installationStatus = 'Completed'
            }
        }
    }
    $elapsed = [math]::Round(((Get-Date) - $startedAt.LocalDateTime).TotalMinutes, 1)
    Write-Information "Installation $($installationStatus.ToLowerInvariant()) after $elapsed minutes and $restartCount restarts" -InformationAction Continue

    if ($installationStatus -eq 'Completed') {
        $kvp = Get-GuestKvpItem -VMId $vm.Id
        $checks.Add([pscustomobject]@{
                Name   = 'InstalledSystemBooted'
                Status = $kvp['OSBuildNumber'] ? 'Passed' : 'Failed'
                Detail = "Hyper-V data exchange: $($kvp['OSName']) $($kvp['OSVersion']) build $($kvp['OSBuildNumber']); $restartCount restarts"
            })
        if ($supportsPowerShellDirect) {
            $guest = Get-GuestSystemInformation -VMId $vm.Id -Credential $guestCredential
            $checks.Add([pscustomobject]@{
                    Name   = 'AdministratorPassword'
                    Status = 'Passed'
                    Detail = 'PowerShell Direct logged on as Administrator with the supplied password.'
                })
            $expectedInstallationType = $image.InstallationType
            $checks.Add([pscustomobject]@{
                    Name   = 'Edition'
                    Status = ($guest.EditionId -eq $image.EditionId -and $guest.InstallationType -eq $expectedInstallationType) ? 'Passed' : 'Failed'
                    Detail = "Installed $($guest.EditionId) ($($guest.InstallationType)); expected $($image.EditionId) ($expectedInstallationType)"
                })
            $checks.Add([pscustomobject]@{
                    Name   = 'Version'
                    Status = ($guest.Version -eq [string]$image.Version) ? 'Passed' : 'Failed'
                    Detail = "Installed $($guest.Version); image $($image.Version)"
                })
            $checks.Add([pscustomobject]@{
                    Name   = 'Architecture'
                    Status = ($guest.Architecture -eq 'AMD64') ? 'Passed' : 'Failed'
                    Detail = "PROCESSOR_ARCHITECTURE $($guest.Architecture); image $($image.Architecture)"
                })
            $expectedRollup = ${manifestImage}?.rollupAfter
            $rollupBuild = if ($guest.RollupVersion) { '{0}.{1}' -f ([version]$guest.RollupVersion).Major, ([version]$guest.RollupVersion).Minor }
            $rollupStatus = if ($expectedRollup) {
                ($guest.RollupVersion -eq $expectedRollup) ? 'Passed' : 'Failed'
            }
            elseif ($guest.RollupVersion) {
                ($rollupBuild -eq "$($image.Version.Build).$($image.Version.Revision)") ? 'Passed' : 'Failed'
            }
            else {
                'Failed'
            }
            $rollupExpectation = if ($expectedRollup) { "manifest $expectedRollup ($(${cumulative}?.kb))" } else { "image build $($image.Version.Build).$($image.Version.Revision) (no manifest)" }
            $checks.Add([pscustomobject]@{
                    Name   = 'CumulativeUpdate'
                    Status = $rollupStatus
                    Detail = "Package_for_RollupFix $($guest.RollupVersion); expected $rollupExpectation"
                })
            $expectedStack = if ($manifestImage) { @($manifestImage.packages) | Where-Object { $_.PackageName -like 'Package_for_ServicingStack*' } | ForEach-Object { [version]($_.PackageName -split '~')[-1] } | Sort-Object -Descending | Select-Object -First 1 }
            $stackStatus = if (-not $expectedStack) { 'Skipped' } elseif ($guest.ServicingStack -and [version]$guest.ServicingStack -ge $expectedStack) { 'Passed' } else { 'Failed' }
            $checks.Add([pscustomobject]@{
                    Name   = 'ServicingStack'
                    Status = $stackStatus
                    Detail = $expectedStack ? "Package_for_ServicingStack $($guest.ServicingStack); manifest $expectedStack" : "Package_for_ServicingStack $($guest.ServicingStack); the manifest lists no servicing stack package for index $($image.Index), so there is nothing independent to compare with."
                })
            $expectedKeyboard = '{0:X8}' -f [cultureinfo]::GetCultureInfo($KeyboardLayout).KeyboardLayoutId
            $regional = [ordered]@{
                UiLanguage     = @($guest.UiLanguage, $Language)
                SystemLocale   = @($guest.SystemLocale, $SystemLocale)
                UserLocale     = @($guest.UserLocale, $UserLocale)
                KeyboardLayout = @($guest.KeyboardLayout, $expectedKeyboard)
                TimeZone       = @($guest.TimeZone, $TimeZone)
                ComputerName   = @($guest.ComputerName, $ComputerName.ToUpperInvariant())
            }
            foreach ($name in $regional.Keys) {
                $checks.Add([pscustomobject]@{
                        Name   = $name
                        Status = ($regional[$name][0] -eq $regional[$name][1]) ? 'Passed' : 'Failed'
                        Detail = "Installed '$($regional[$name][0])'; expected '$($regional[$name][1])'"
                    })
            }
            $checks.Add([pscustomobject]@{
                    Name   = 'AdministratorAccount'
                    Status = ($guest.AdministratorEnabled -eq 'True') ? 'Passed' : 'Failed'
                    Detail = "Built-in account '$($guest.AdministratorName)' enabled: $($guest.AdministratorEnabled)"
                })
            $checks.Add([pscustomobject]@{
                    Name   = 'NoDomainJoin'
                    Status = ($guest.PartOfDomain -eq 'False') ? 'Passed' : 'Failed'
                    Detail = "Part of a domain: $($guest.PartOfDomain)"
                })
        }
        else {
            $expectedBuild = [string]$image.Build
            $checks.Add([pscustomobject]@{
                    Name   = 'Version'
                    Status = ($kvp['OSBuildNumber'] -eq $expectedBuild) ? 'Passed' : 'Failed'
                    Detail = "Hyper-V data exchange build $($kvp['OSBuildNumber']); image build $expectedBuild. The revision cannot be read without PowerShell Direct."
                })
            foreach ($name in 'AdministratorPassword', 'Edition', 'CumulativeUpdate', 'ServicingStack', 'RegionalSettings', 'AdministratorAccount') {
                $checks.Add([pscustomobject]@{
                        Name   = $name
                        Status = 'Skipped'
                        Detail = "$($release.Name) does not support PowerShell Direct (Windows 10 and Windows Server 2016 or later), so this check needs a logon the test cannot make."
                    })
            }
        }
    }
}
catch {
    $installationStatus = 'Failed'
    $failureReason = "$_"
}
finally {
    if ($vm) {
        $current = Get-VM -Id $vm.Id -ErrorAction SilentlyContinue
        if ($current -and $current.State -ne 'Off') {
            try {
                Stop-VM -VM $vm -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Graceful shutdown failed, turning the VM off: $_"
                Stop-VM -VM $vm -TurnOff -Force -ErrorAction Stop
            }
        }
        try {
            foreach ($drive in @(Get-VMDvdDrive -VM $vm | Where-Object Path -EQ $answerIso)) {
                Remove-VMDvdDrive -VMDvdDrive $drive -ErrorAction Stop
            }
        }
        catch {
            Write-Warning "The answer ISO could not be detached from '$runName': $_"
        }
    }
    foreach ($sensitive in $answerDirectory, $answerIso) {
        if (Test-Path -LiteralPath $sensitive) {
            try {
                Remove-Item -LiteralPath $sensitive -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "'$sensitive' holds the Administrator password and could not be deleted; delete it now: $_"
            }
        }
    }
    if ($vm) {
        try {
            $logResult = Save-InstallationLog -VhdPath $vhdPath -Destination $logDirectory
        }
        catch {
            Write-Warning "The logs could not be copied from '$vhdPath': $_"
        }
    }
}

if ($logResult) {
    if ($installationStatus -eq 'Completed') {
        $checks.Add([pscustomobject]@{
                Name   = 'SetupCompleted'
                Status = ($logResult.ImageState -eq 'IMAGE_STATE_COMPLETE') ? 'Passed' : 'Failed'
                Detail = "State.ini ImageState $($logResult.ImageState)"
            })
    }
    $checks.Add([pscustomobject]@{
            Name   = 'UnattendErrors'
            Status = ($logResult.UnattendErrors.Count -eq 0) ? 'Passed' : 'Failed'
            Detail = ($logResult.UnattendErrors.Count -eq 0) ? 'Panther\UnattendGC\setuperr.log is empty or absent.' : "$($logResult.UnattendErrors.Count) lines in Panther\UnattendGC\setuperr.log, first: $($logResult.UnattendErrors[0])"
        })
}
else {
    $checks.Add([pscustomobject]@{
            Name   = 'DiagnosticLogs'
            Status = 'Failed'
            Detail = 'No logs could be read from the VM disk.'
        })
}
if ($installationStatus -ne 'Completed') {
    $checks.Add([pscustomobject]@{
            Name   = 'Installation'
            Status = 'Failed'
            Detail = $failureReason
        })
}

$failedChecks = @($checks | Where-Object Status -EQ 'Failed')
$passed = $installationStatus -eq 'Completed' -and $failedChecks.Count -eq 0
if (-not $failureReason -and -not $passed) {
    $failureReason = "Failed checks: $(($failedChecks | ForEach-Object Name) -join ', ')"
}
$keepMachine = $KeepVM -or ($KeepVMOnFailure -and -not $passed)
if ($vm -and -not $keepMachine) {
    try {
        Remove-VM -VM $vm -Force -ErrorAction Stop
        Remove-Item -LiteralPath $vmDirectory -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Cleanup of VM '$runName' failed; remove it in Hyper-V Manager and delete '$vmDirectory': $_"
    }
}
elseif (-not $vm -and (Test-Path -LiteralPath $vmDirectory)) {
    Remove-Item -LiteralPath $vmDirectory -Recurse -Force -ErrorAction Stop
}

$endedAt = [DateTimeOffset]::Now
$result = [pscustomobject][ordered]@{
    PSTypeName         = 'WindowsIsoServicing.InstallationTestResult'
    testName           = 'HyperVUnattendedInstallation'
    runName            = $runName
    startTime          = $startedAt.ToString('o')
    endTime            = $endedAt.ToString('o')
    durationMinutes    = [math]::Round(($endedAt - $startedAt).TotalMinutes, 1)
    isoFile            = Split-Path $isoFile -Leaf
    isoPath            = $isoFile
    manifestPath       = $ManifestPath
    release            = $release.Name
    expected           = [ordered]@{
        index            = $image.Index
        editionId        = $image.EditionId
        installationType = $image.InstallationType
        version          = [string]$image.Version
        build            = $image.Build
        architecture     = $image.Architecture
        cumulativeUpdate = ${cumulative}?.kb
    }
    installed          = if ($guest) { $guest } else { [ordered]@{ osName = $kvp['OSName']; osVersion = $kvp['OSVersion']; build = $kvp['OSBuildNumber'] } }
    vmConfiguration    = $vmConfiguration
    vmKept             = [bool]($vm -and $keepMachine)
    restarts           = $restartCount
    installationStatus = $installationStatus
    passed             = $passed
    failureReason      = $failureReason
    checks             = @($checks)
    logDirectory       = $logDirectory
    logFiles           = @(${logResult}?.Files)
}
$resultPath = Join-Path $runDirectory 'result.json'
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding utf8NoBOM
Write-Information "Result: $(if ($passed) { 'Passed' } else { 'Failed' }). Details in $resultPath" -InformationAction Continue
$result
if (-not $passed) {
    exit 1
}
