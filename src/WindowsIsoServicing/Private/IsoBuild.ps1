function Get-WindowsAdkInstallation {
    <#
    .SYNOPSIS
        Returns the Windows ADK installation folders on this host, in the order they are searched.

    .DESCRIPTION
        The ADK installer records its folder as KitsRoot10 under HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots, in the 32-bit registry view on 64-bit Windows, which also holds a custom installation folder. That folder comes first, then the default folder %ProgramFiles(x86)%\Windows Kits\10, so a leftover default folder never wins over the installation the registry names. Only folders that exist are returned, each once. The version is the DisplayVersion of the 'Windows Deployment Tools' entry under Uninstall, when there is one.

    .EXAMPLE
        Get-WindowsAdkInstallation

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Root, Source and Version.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-hardware/get-started/adk-install
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $registryKeys = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots'
    $roots = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $registryKeys) {
        $kitsRoot = (Get-ItemProperty -LiteralPath $key -Name 'KitsRoot10' -ErrorAction SilentlyContinue)?.KitsRoot10
        if ($kitsRoot) { $roots.Add([pscustomobject]@{ Root = $kitsRoot; Source = "Registry ($key)" }) }
    }
    if (${env:ProgramFiles(x86)}) { $roots.Add([pscustomobject]@{ Root = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'; Source = 'Default folder' }) }
    $uninstallKeys = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $deploymentTools = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName']?.Value -eq 'Windows Deployment Tools' } | Select-Object -First 1
    $version = if ($deploymentTools) { $deploymentTools.PSObject.Properties['DisplayVersion']?.Value }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $roots) {
        if (-not (Test-Path -LiteralPath $entry.Root -PathType Container)) { continue }
        $fullRoot = [System.IO.Path]::GetFullPath($entry.Root).TrimEnd('\')
        if (-not $seen.Add($fullRoot)) { continue }
        [pscustomobject]@{ Root = $fullRoot; Source = $entry.Source; Version = $version }
    }
}

function Find-Oscdimg {
    <#
    .SYNOPSIS
        Locates and validates the oscdimg.exe used to build ISO images.

    .DESCRIPTION
        oscdimg.exe is part of the Windows ADK Deployment Tools and is not shipped with the module, so the ADK must be installed on the servicing host. With Path, that file is used, or, for a folder, its oscdimg.exe or the one under Assessment and Deployment Kit\Deployment Tools\<architecture>\Oscdimg. Otherwise the installed Windows ADK Deployment Tools are searched, in the order of Get-WindowsAdkInstallation. Only operations that build an ISO call this. Within an installation the folder for the host architecture is preferred (amd64 on x64, arm64 on Arm64), then the ones Windows can run under emulation, so the choice is the same on every run. The system PATH is not used. A candidate must be a file with a valid Microsoft Authenticode signature; a file that cannot be read or is not signed by Microsoft is refused, and with Path that stops the search, because an explicit choice must not be replaced silently. Throws with installation instructions when nothing usable is found. Whether the file runs is shown by its first use, whose exit code Invoke-ExternalTool checks.

    .PARAMETER Path
        oscdimg.exe, or a folder that contains it or the ADK (for example 'D:\Windows Kits\10').

    .PARAMETER HostArchitecture
        Processor architecture of the host. Defaults to the operating system's architecture.

    .EXAMPLE
        Find-Oscdimg -Path 'D:\Windows Kits\10'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Path, FileVersion, AdkVersion and Source.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-hardware/manufacture/desktop/oscdimg-command-line-options
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path,
        [ValidateSet('X64', 'Arm64', 'X86')]
        [string]$HostArchitecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    )
    $architectureFolders = switch ($HostArchitecture) {
        'X64' { 'amd64', 'x86' }
        'Arm64' { 'arm64', 'amd64', 'x86' }
        'X86' { 'x86' }
    }
    $candidates = [System.Collections.Generic.List[object]]::new()
    if ($Path) {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $candidates.Add([pscustomobject]@{ Path = Join-Path $Path 'oscdimg.exe'; Source = "-OscdimgPath $Path"; AdkVersion = $null })
            foreach ($folder in $architectureFolders) {
                $candidates.Add([pscustomobject]@{ Path = Join-Path $Path "Assessment and Deployment Kit\Deployment Tools\$folder\Oscdimg\oscdimg.exe"; Source = "-OscdimgPath $Path"; AdkVersion = $null })
            }
        }
        else {
            $candidates.Add([pscustomobject]@{ Path = $Path; Source = '-OscdimgPath'; AdkVersion = $null })
        }
    }
    else {
        foreach ($installation in Get-WindowsAdkInstallation) {
            foreach ($folder in $architectureFolders) {
                $candidates.Add([pscustomobject]@{ Path = Join-Path $installation.Root "Assessment and Deployment Kit\Deployment Tools\$folder\Oscdimg\oscdimg.exe"; Source = $installation.Source; AdkVersion = $installation.Version })
            }
        }
    }
    $refused = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate.Path -PathType Leaf)) { continue }
        try {
            $signed = Test-MicrosoftSignature -Path $candidate.Path
        }
        catch {
            $refused.Add("'$($candidate.Path)' cannot be read: $($_.Exception.Message)")
            if ($Path) { break }
            continue
        }
        if (-not $signed) {
            $refused.Add("'$($candidate.Path)' does not carry a valid Microsoft Authenticode signature")
            if ($Path) { break }
            continue
        }
        $fullPath = (Resolve-Path -LiteralPath $candidate.Path).ProviderPath
        return [pscustomobject]@{
            Path        = $fullPath
            FileVersion = [string](Get-Item -LiteralPath $fullPath).VersionInfo.FileVersionRaw
            AdkVersion  = $candidate.AdkVersion
            Source      = $candidate.Source
        }
    }
    $searched = if ($Path) { "'$Path'" } else { $(if ($candidates.Count) { "a Windows ADK installation (searched: $(@($candidates.Path | Split-Path -Parent | Select-Object -Unique) -join ', '))" } else { 'a Windows ADK installation: none is installed' }) }
    $reason = if ($refused.Count) { " Refused: $($refused -join '; ')." } else { '' }
    $exception = [System.IO.FileNotFoundException]::new("No usable oscdimg.exe was found in $searched.$reason oscdimg.exe is needed to build ISO images and comes from the Windows ADK. Install the Windows ADK with the Deployment Tools feature from https://learn.microsoft.com/windows-hardware/get-started/adk-install (unattended: adksetup.exe /quiet /norestart /features OptionId.DeploymentTools; the Windows PE add-on is not needed), or pass -OscdimgPath with the path of oscdimg.exe or of the ADK folder.")
    throw [System.Management.Automation.ErrorRecord]::new($exception, 'OscdimgNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Path)
}

function Get-IsoFileName {
    <#
    .SYNOPSIS
        Builds the file name of a serviced ISO.

    .DESCRIPTION
        Returns <stem>_<architecture>_<build>_<servicing month>.iso. Characters other than letters, digits, '_', '.' and
        '-' in the stem are replaced with '_'.

    .PARAMETER FileNameStem
        File name stem of the release, for example 'Windows_Server_2025'.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .PARAMETER Build
        Build number of the image.

    .PARAMETER ServicingMonth
        Release month of the cumulative update, in yyyy-MM format.

    .EXAMPLE
        Get-IsoFileName -FileNameStem 'Windows_Server_2025' -Architecture 'x64' -Build 26100 -ServicingMonth '2026-11'

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
        [string]$FileNameStem,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture,
        [Parameter(Mandatory)]
        [int]$Build,
        [Parameter(Mandatory)]
        [ValidatePattern('^\d{4}-\d{2}$')]
        [string]$ServicingMonth
    )
    $stem = $FileNameStem -replace '[^A-Za-z0-9_.-]', '_'
    '{0}_{1}_{2}_{3}.iso' -f $stem, $Architecture, $Build, $ServicingMonth
}

function Split-InstallImage {
    <#
    .SYNOPSIS
        Splits install.wim into install.swm parts when it is too large for FAT32.

    .DESCRIPTION
        When install.wim is larger than 4 GB minus one byte, the FAT32 file size limit, splits it into install.swm parts
        with Split-WindowsImage and deletes install.wim (subject to -WhatIf and -Confirm). Smaller images are left as they
        are.

    .PARAMETER MediaPath
        Root of the media copy.

    .PARAMETER Context
        Servicing context returned by New-ServicingContext.

    .PARAMETER FileSizeMB
        Maximum part size in MB, 512 to 4095. Defaults to 3800.

    .EXAMPLE
        Split-InstallImage -MediaPath $context.MediaPath -Context $context

    .OUTPUTS
        System.Boolean

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/dism/split-windowsimage
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$MediaPath,
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [ValidateRange(512, 4095)]
        [int]$FileSizeMB = 3800
    )
    $wim = Join-Path $MediaPath 'sources\install.wim'
    if ((Get-Item -LiteralPath $wim).Length -le [uint32]::MaxValue) { return $false }
    if (-not $PSCmdlet.ShouldProcess($wim, "Split into $FileSizeMB MB parts")) { return $false }
    $null = Split-WindowsImage -ImagePath $wim -SplitImagePath (Join-Path $MediaPath 'sources\install.swm') -FileSize $FileSizeMB -CheckIntegrity -ScratchDirectory $Context.ScratchPath -LogPath (Join-Path $Context.LogPath 'dism-split.log') -ErrorAction Stop
    Remove-Item -LiteralPath $wim -Force
    Write-ServicingLog -Operation 'SplitImage' -Target $wim -Message "Split into install.swm parts of $FileSizeMB MB"
    $true
}

function New-IsoImage {
    <#
    .SYNOPSIS
        Builds a bootable ISO from a media folder with OSCDIMG.

    .DESCRIPTION
        Recreates the boot entries the source media had: BIOS and UEFI (two-entry boot catalog), UEFI only or BIOS only.
        Every ISO boots into Windows Setup without "Press any key to boot from CD or DVD": the UEFI entry uses the
        efisys_noprompt.bin that Microsoft ships on the media, and the BIOS entry uses etfsboot.com from a media folder
        without boot\bootfix.bin, which Copy-MediaContent leaves out. There is no fallback to the prompting boot images:
        UEFI media without efisys_noprompt.bin and a media folder that still contains boot\bootfix.bin are refused. The ISO
        uses UDF 1.02 with optimized storage and a volume label of at most 32 letters, digits and underscores.
        The media path must not contain whitespace, because OSCDIMG boot sector arguments cannot be quoted. An existing
        file at DestinationPath is replaced (subject to -WhatIf and -Confirm).

    .PARAMETER MediaPath
        Root of the media folder.

    .PARAMETER DestinationPath
        Path of the ISO to create.

    .PARAMETER OscdimgPath
        Path of oscdimg.exe returned by Find-Oscdimg.

    .PARAMETER BootConfiguration
        Boot configuration returned by Get-MediaBootConfiguration for the source media.

    .PARAMETER VolumeLabel
        Volume label of the source ISO. 'WINDOWS' is used when it is empty.

    .EXAMPLE
        New-IsoImage -MediaPath $context.MediaPath -DestinationPath "$($context.OutputStagingPath)\Windows_Server_2025_x64_26100_2026-11.iso" -OscdimgPath (Find-Oscdimg) -BootConfiguration $bootConfiguration -VolumeLabel 'SSS_X64FREE_EN-US_DV9'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-hardware/manufacture/desktop/oscdimg-command-line-options
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$MediaPath,
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        [Parameter(Mandatory)]
        [string]$OscdimgPath,
        [Parameter(Mandatory)]
        [pscustomobject]$BootConfiguration,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$VolumeLabel
    )
    if ($MediaPath -match '\s') {
        throw "The media path '$MediaPath' contains whitespace, which OSCDIMG boot sector arguments cannot represent. Use a workspace path without spaces."
    }
    $biosBootSector = Join-Path $MediaPath 'boot\etfsboot.com'
    $uefiBootImage = Join-Path $MediaPath 'efi\microsoft\boot\efisys_noprompt.bin'
    if ($BootConfiguration.Uefi -and -not $BootConfiguration.UefiNoPromptAvailable) {
        throw 'The media does not contain efi\microsoft\boot\efisys_noprompt.bin, so no UEFI boot entry without "Press any key" can be built. The ISO is not created with the prompting efisys.bin instead.'
    }
    if ($BootConfiguration.Bios -and (Test-Path -LiteralPath (Join-Path $MediaPath 'boot\bootfix.bin'))) {
        throw "'$MediaPath' contains boot\bootfix.bin, which makes the BIOS entry show ""Press any key"". Copy the media with Copy-MediaContent, which leaves it out."
    }
    $bootData = if ($BootConfiguration.Bios -and $BootConfiguration.Uefi) {
        "-bootdata:2#p0,e,b$biosBootSector#pEF,e,b$uefiBootImage"
    }
    elseif ($BootConfiguration.Uefi) {
        "-bootdata:1#pEF,e,b$uefiBootImage"
    }
    elseif ($BootConfiguration.Bios) {
        "-bootdata:1#p0,e,b$biosBootSector"
    }
    else {
        throw 'The media contains neither BIOS (boot\etfsboot.com) nor UEFI (efi\microsoft\boot\efisys.bin) boot files.'
    }
    $label = ($VolumeLabel -replace '[^A-Za-z0-9_]', '_')
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
    if (-not $label) { $label = 'WINDOWS' }
    if (-not $PSCmdlet.ShouldProcess($DestinationPath, 'Create ISO')) { return }
    if (Test-Path -LiteralPath $DestinationPath) { Remove-Item -LiteralPath $DestinationPath -Force }
    $arguments = @('-m', '-o', '-h', '-u2', '-udfver102', "-l$label", $bootData, $MediaPath, $DestinationPath)
    $null = Invoke-ExternalTool -FilePath $OscdimgPath -ArgumentList $arguments -Operation 'BuildIso'
    Write-ServicingLog -Operation 'BuildIso' -Target $DestinationPath -Message "Created ISO without boot prompt (BIOS: $($BootConfiguration.Bios), UEFI: $($BootConfiguration.Uefi) with efisys_noprompt.bin)"
    $DestinationPath
}
