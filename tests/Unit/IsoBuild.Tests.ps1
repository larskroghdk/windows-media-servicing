BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
}

Describe 'Get-IsoFileName' {
    It 'builds <Expected>' -ForEach @(
        @{ Stem = 'Windows_Server_2025'; Arch = 'x64'; Build = 26100; Month = '2026-11'; Expected = 'Windows_Server_2025_x64_26100_2026-11.iso' }
        @{ Stem = 'Windows_Server_2022'; Arch = 'x64'; Build = 20348; Month = '2026-11'; Expected = 'Windows_Server_2022_x64_20348_2026-11.iso' }
        @{ Stem = 'Windows_11_24H2'; Arch = 'x64'; Build = 26100; Month = '2026-11'; Expected = 'Windows_11_24H2_x64_26100_2026-11.iso' }
        @{ Stem = 'Windows_11_LTSC_2024'; Arch = 'arm64'; Build = 26100; Month = '2026-10'; Expected = 'Windows_11_LTSC_2024_arm64_26100_2026-10.iso' }
    ) {
        InModuleScope WindowsIsoServicing -Parameters $_ {
            Get-IsoFileName -FileNameStem $Stem -Architecture $Arch -Build $Build -ServicingMonth $Month | Should -Be $Expected
        }
    }
    It 'replaces characters that are unsafe in file names' {
        InModuleScope WindowsIsoServicing {
            Get-IsoFileName -FileNameStem 'Windows Server, 2025' -Architecture x64 -Build 26100 -ServicingMonth '2026-11' | Should -Be 'Windows_Server__2025_x64_26100_2026-11.iso'
        }
    }
    It 'rejects malformed servicing months' {
        InModuleScope WindowsIsoServicing {
            { Get-IsoFileName -FileNameStem 'Windows_11_24H2' -Architecture x64 -Build 26100 -ServicingMonth '2026-1' } | Should -Throw
        }
    }
}

Describe 'New-IsoImage' {
    BeforeEach {
        $media = Join-Path $TestDrive 'media'
        $null = New-Item -Path $media -ItemType Directory -Force
    }
    It 'creates dual BIOS and UEFI boot entries without boot prompt when both are present' {
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media; Target = (Join-Path $TestDrive 'out.iso') } {
            Mock Invoke-ExternalTool { [pscustomobject]@{ ExitCode = 0 } }
            $boot = [pscustomobject]@{ Bios = $true; Uefi = $true; UefiNoPromptAvailable = $true }
            New-IsoImage -MediaPath $Media -DestinationPath $Target -OscdimgPath 'C:\oscdimg.exe' -BootConfiguration $boot -VolumeLabel 'SSS_X64FREE_EN-US_DV9' -Confirm:$false
            Should -Invoke Invoke-ExternalTool -Times 1 -ParameterFilter {
                $ArgumentList -contains "-bootdata:2#p0,e,b$Media\boot\etfsboot.com#pEF,e,b$Media\efi\microsoft\boot\efisys_noprompt.bin" -and $ArgumentList -contains '-lSSS_X64FREE_EN_US_DV9' -and $ArgumentList -contains '-udfver102' -and $ArgumentList[-1] -eq $Target
            }
        }
    }
    It 'creates a UEFI-only entry without boot prompt for media without BIOS boot files' {
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media; Target = (Join-Path $TestDrive 'out.iso') } {
            Mock Invoke-ExternalTool { [pscustomobject]@{ ExitCode = 0 } }
            $boot = [pscustomobject]@{ Bios = $false; Uefi = $true; UefiNoPromptAvailable = $true }
            New-IsoImage -MediaPath $Media -DestinationPath $Target -OscdimgPath 'C:\oscdimg.exe' -BootConfiguration $boot -VolumeLabel 'ARM64' -Confirm:$false
            Should -Invoke Invoke-ExternalTool -Times 1 -ParameterFilter {
                $ArgumentList -contains "-bootdata:1#pEF,e,b$Media\efi\microsoft\boot\efisys_noprompt.bin"
            }
        }
    }
    It 'refuses UEFI media without efisys_noprompt.bin instead of building a prompting entry' {
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media } {
            Mock Invoke-ExternalTool { [pscustomobject]@{ ExitCode = 0 } }
            $boot = [pscustomobject]@{ Bios = $true; Uefi = $true; UefiNoPromptAvailable = $false }
            { New-IsoImage -MediaPath $Media -DestinationPath 'C:\x.iso' -OscdimgPath 'C:\oscdimg.exe' -BootConfiguration $boot -VolumeLabel 'X' -Confirm:$false } | Should -Throw '*efisys_noprompt.bin*'
            Should -Invoke Invoke-ExternalTool -Times 0
        }
    }
    It 'refuses BIOS media that still contains boot\bootfix.bin' {
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media } {
            Mock Invoke-ExternalTool { [pscustomobject]@{ ExitCode = 0 } }
            $null = New-Item -Path (Join-Path $Media 'boot\bootfix.bin') -ItemType File -Force
            $boot = [pscustomobject]@{ Bios = $true; Uefi = $false; UefiNoPromptAvailable = $false }
            { New-IsoImage -MediaPath $Media -DestinationPath 'C:\x.iso' -OscdimgPath 'C:\oscdimg.exe' -BootConfiguration $boot -VolumeLabel 'X' -Confirm:$false } | Should -Throw '*bootfix.bin*'
            Should -Invoke Invoke-ExternalTool -Times 0
        }
    }
    It 'refuses media paths with whitespace and media without boot files' {
        InModuleScope WindowsIsoServicing {
            $boot = [pscustomobject]@{ Bios = $true; Uefi = $true; UefiNoPromptAvailable = $true }
            { New-IsoImage -MediaPath 'C:\with space\media' -DestinationPath 'C:\x.iso' -OscdimgPath 'C:\o.exe' -BootConfiguration $boot -VolumeLabel 'X' -Confirm:$false } | Should -Throw '*whitespace*'
            $none = [pscustomobject]@{ Bios = $false; Uefi = $false; UefiNoPromptAvailable = $false }
            { New-IsoImage -MediaPath 'C:\media' -DestinationPath 'C:\x.iso' -OscdimgPath 'C:\o.exe' -BootConfiguration $none -VolumeLabel 'X' -Confirm:$false } | Should -Throw '*neither BIOS*'
        }
    }
}

Describe 'Copy-MediaContent' {
    It 'copies the media without the install image and boot\bootfix.bin' {
        $source = Join-Path $TestDrive 'copy-source'
        $target = Join-Path $TestDrive 'copy-target'
        foreach ($file in 'setup.exe', 'boot\etfsboot.com', 'boot\bootfix.bin', 'efi\microsoft\boot\efisys_noprompt.bin', 'sources\boot.wim', 'sources\install.wim') {
            $path = Join-Path $source $file
            $null = New-Item -Path (Split-Path $path) -ItemType Directory -Force
            Set-Content -LiteralPath $path -Value $file
        }
        InModuleScope WindowsIsoServicing -Parameters @{ Source = $source; Target = $target } {
            Mock Write-ServicingLog { }
            Copy-MediaContent -MediaRoot $Source -Destination $Target -Confirm:$false
        }
        Join-Path $target 'boot\bootfix.bin' | Should -Not -Exist
        Join-Path $target 'sources\install.wim' | Should -Not -Exist
        Join-Path $target 'boot\etfsboot.com' | Should -Exist
        Join-Path $target 'efi\microsoft\boot\efisys_noprompt.bin' | Should -Exist
        Join-Path $target 'sources\boot.wim' | Should -Exist
        Join-Path $source 'boot\bootfix.bin' | Should -Exist -Because 'the source media is never changed'
    }
}

Describe 'Get-IsoBootEntry and Get-IsoBootImageSha256' {
    BeforeAll {
        $iso = Join-Path $TestDrive 'catalog.iso'
        $bytes = [byte[]]::new(2048 * 40)
        $primary = 16 * 2048
        $bytes[$primary] = 1
        [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, $primary + 1)
        $bootRecord = 17 * 2048
        [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, $bootRecord + 1)
        [System.Text.Encoding]::ASCII.GetBytes('EL TORITO SPECIFICATION').CopyTo($bytes, $bootRecord + 7)
        [System.BitConverter]::GetBytes([uint32]20).CopyTo($bytes, $bootRecord + 0x47)
        $terminator = 18 * 2048
        $bytes[$terminator] = 255
        [System.Text.Encoding]::ASCII.GetBytes('CD001').CopyTo($bytes, $terminator + 1)
        $catalog = 20 * 2048
        $bytes[$catalog] = 1
        $bytes[$catalog + 30] = 0x55
        $bytes[$catalog + 31] = 0xAA
        $bytes[$catalog + 32] = 0x88
        [System.BitConverter]::GetBytes([uint16]4).CopyTo($bytes, $catalog + 38)
        [System.BitConverter]::GetBytes([uint32]30).CopyTo($bytes, $catalog + 40)
        $bytes[$catalog + 64] = 0x91
        $bytes[$catalog + 65] = 0xEF
        [System.BitConverter]::GetBytes([uint16]1).CopyTo($bytes, $catalog + 66)
        $bytes[$catalog + 96] = 0x88
        [System.BitConverter]::GetBytes([uint32]32).CopyTo($bytes, $catalog + 104)
        $bootImage = [byte[]](1..200 | ForEach-Object { [byte]$_ })
        $bootImage.CopyTo($bytes, 32 * 2048)
        [System.IO.File]::WriteAllBytes($iso, $bytes)
        $bootImageFile = Join-Path $TestDrive 'efisys_noprompt.bin'
        [System.IO.File]::WriteAllBytes($bootImageFile, $bootImage)
    }
    It 'returns the BIOS and UEFI entries with their boot image sectors' {
        InModuleScope WindowsIsoServicing -Parameters @{ Iso = $iso } {
            $entries = @(Get-IsoBootEntry -Path $Iso)
            $entries.Count | Should -Be 2
            $entries[0].Platform | Should -Be 'BIOS'
            $entries[0].LoadRba | Should -Be 30
            $entries[1].Platform | Should -Be 'UEFI'
            $entries[1].LoadRba | Should -Be 32
        }
    }
    It 'hashes the boot image stored at the UEFI entry like the file it was built from' {
        InModuleScope WindowsIsoServicing -Parameters @{ Iso = $iso; File = $bootImageFile } {
            $length = (Get-Item -LiteralPath $File).Length
            Get-IsoBootImageSha256 -Path $Iso -LoadRba 32 -Length $length | Should -Be (Get-FileSha256 -Path $File)
            Get-IsoBootImageSha256 -Path $Iso -LoadRba 30 -Length $length | Should -Not -Be (Get-FileSha256 -Path $File)
        }
    }
    It 'returns nothing for an image without an El Torito boot record' {
        $plain = Join-Path $TestDrive 'plain.iso'
        [System.IO.File]::WriteAllBytes($plain, [byte[]]::new(2048 * 20))
        InModuleScope WindowsIsoServicing -Parameters @{ Plain = $plain } {
            @(Get-IsoBootEntry -Path $Plain).Count | Should -Be 0
        }
    }
    It 'throws when the boot record points to an invalid boot catalog' {
        $broken = Join-Path $TestDrive 'broken.iso'
        $bytes = [System.IO.File]::ReadAllBytes($iso)
        $bytes[20 * 2048 + 31] = 0
        [System.IO.File]::WriteAllBytes($broken, $bytes)
        InModuleScope WindowsIsoServicing -Parameters @{ Broken = $broken } {
            { Get-IsoBootEntry -Path $Broken } | Should -Throw '*no valid boot catalog*'
        }
    }
}

Describe 'Get-MediaBootConfiguration' {
    It 'detects BIOS and UEFI boot files' {
        $media = Join-Path $TestDrive 'bootmedia'
        foreach ($file in 'bootmgr', 'boot\etfsboot.com', 'efi\boot\bootx64.efi', 'efi\microsoft\boot\efisys.bin') {
            $path = Join-Path $media $file
            $null = New-Item -Path (Split-Path $path) -ItemType Directory -Force
            Set-Content -LiteralPath $path -Value 'x'
        }
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media } {
            $result = Get-MediaBootConfiguration -MediaRoot $Media
            $result.Bios | Should -BeTrue
            $result.Uefi | Should -BeTrue
            $result.UefiLoader | Should -Be 'efi\boot\bootx64.efi'
            $result.UefiNoPromptAvailable | Should -BeFalse
        }
    }
}

Describe 'Find-Oscdimg' {
    BeforeAll {
        $script:AdkRelative = 'Assessment and Deployment Kit\Deployment Tools'
        $script:AdkPrimary = Join-Path $TestDrive 'Kits1'
        $script:AdkSecondary = Join-Path $TestDrive 'Kits2'
        foreach ($folder in 'amd64', 'arm64', 'x86') {
            foreach ($root in $script:AdkPrimary, $script:AdkSecondary) {
                $target = Join-Path $root "$script:AdkRelative\$folder\Oscdimg"
                $null = New-Item -Path $target -ItemType Directory -Force
                Set-Content -LiteralPath (Join-Path $target 'oscdimg.exe') -Value $folder
            }
        }
        $script:Installations = @([pscustomobject]@{ Root = $script:AdkPrimary; Source = 'Registry (test)'; Version = '10.1.28000.3481' }, [pscustomobject]@{ Root = $script:AdkSecondary; Source = 'Default folder'; Version = '10.1.28000.3481' })
    }
    It 'uses the first ADK installation and the folder for the host architecture' {
        InModuleScope WindowsIsoServicing -Parameters @{ Installations = $script:Installations; Expected = (Join-Path $script:AdkPrimary "$script:AdkRelative\amd64\Oscdimg\oscdimg.exe") } {
            Mock Test-MicrosoftSignature { $true }
            Mock Get-WindowsAdkInstallation { $Installations }
            $result = Find-Oscdimg -HostArchitecture X64
            $result.Path | Should -Be $Expected
            $result.Source | Should -Be 'Registry (test)'
            $result.AdkVersion | Should -Be '10.1.28000.3481'
        }
    }
    It 'prefers arm64 on an Arm64 host' {
        InModuleScope WindowsIsoServicing -Parameters @{ Installations = $script:Installations; Expected = (Join-Path $script:AdkPrimary "$script:AdkRelative\arm64\Oscdimg\oscdimg.exe") } {
            Mock Test-MicrosoftSignature { $true }
            Mock Get-WindowsAdkInstallation { $Installations }
            (Find-Oscdimg -HostArchitecture Arm64).Path | Should -Be $Expected
        }
    }
    It 'uses the next installation when the first one holds only unsigned files' {
        InModuleScope WindowsIsoServicing -Parameters @{ Installations = $script:Installations; Primary = $script:AdkPrimary; Expected = (Join-Path $script:AdkSecondary "$script:AdkRelative\amd64\Oscdimg\oscdimg.exe") } {
            Mock Test-MicrosoftSignature { -not $Path.StartsWith($Primary) }
            Mock Get-WindowsAdkInstallation { $Installations }
            (Find-Oscdimg -HostArchitecture X64).Path | Should -Be $Expected
        }
    }
    It 'throws OscdimgNotFound with ADK installation instructions when no ADK is installed, and looks nowhere else' {
        InModuleScope WindowsIsoServicing {
            Mock Get-WindowsAdkInstallation { }
            Mock Test-MicrosoftSignature { throw 'no candidate must be checked' }
            $failure = { Find-Oscdimg } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -BeLike 'OscdimgNotFound*'
            $failure.Exception.Message | Should -BeLike '*none is installed*adksetup.exe /quiet /norestart /features OptionId.DeploymentTools*-OscdimgPath*'
            $failure.Exception.Message | Should -Not -BeLike '*Resources*'
            Should -Invoke Test-MicrosoftSignature -Times 0
        }
    }
    It 'names refused files in the error' {
        InModuleScope WindowsIsoServicing -Parameters @{ Installations = $script:Installations } {
            Mock Test-MicrosoftSignature { $false }
            Mock Get-WindowsAdkInstallation { $Installations }
            { Find-Oscdimg } | Should -Throw '*Refused:*does not carry a valid Microsoft Authenticode signature*'
        }
    }
    It 'refuses a file that cannot be read' {
        InModuleScope WindowsIsoServicing -Parameters @{ Installations = $script:Installations } {
            Mock Test-MicrosoftSignature { throw 'Access is denied' }
            Mock Get-WindowsAdkInstallation { $Installations }
            { Find-Oscdimg } | Should -Throw '*cannot be read: Access is denied*'
        }
    }
    It 'uses a file given with -Path' {
        $file = Join-Path $script:AdkPrimary "$script:AdkRelative\x86\Oscdimg\oscdimg.exe"
        InModuleScope WindowsIsoServicing -Parameters @{ File = $file } {
            Mock Test-MicrosoftSignature { $true }
            Mock Get-WindowsAdkInstallation { throw 'not searched' }
            $result = Find-Oscdimg -Path $File
            $result.Path | Should -Be $File
            $result.Source | Should -Be '-OscdimgPath'
        }
    }
    It 'searches an ADK folder given with -Path' {
        InModuleScope WindowsIsoServicing -Parameters @{ Root = $script:AdkSecondary; Expected = (Join-Path $script:AdkSecondary "$script:AdkRelative\amd64\Oscdimg\oscdimg.exe") } {
            Mock Test-MicrosoftSignature { $true }
            (Find-Oscdimg -Path $Root -HostArchitecture X64).Path | Should -Be $Expected
        }
    }
    It 'does not replace an unsigned -Path file with another copy' {
        $fake = Join-Path $TestDrive 'oscdimg.exe'
        Set-Content -LiteralPath $fake -Value 'not signed'
        InModuleScope WindowsIsoServicing -Parameters @{ Fake = $fake } {
            Mock Test-MicrosoftSignature { $Path -ne $Fake }
            { Find-Oscdimg -Path $Fake } | Should -Throw '*does not carry a valid Microsoft Authenticode signature*'
        }
    }
    It 'reports a missing -Path file with the option to pass -OscdimgPath' {
        InModuleScope WindowsIsoServicing {
            $failure = { Find-Oscdimg -Path 'C:\does-not-exist\oscdimg.exe' } | Should -Throw -PassThru
            $failure.FullyQualifiedErrorId | Should -BeLike 'OscdimgNotFound*'
            $failure.Exception.Message | Should -BeLike "*'C:\does-not-exist\oscdimg.exe'*-OscdimgPath*"
        }
    }
}

Describe 'Get-WindowsAdkInstallation' {
    It 'returns the registry folder before the default folder and each folder once' {
        $custom = Join-Path $TestDrive 'CustomKits'
        $null = New-Item -Path $custom -ItemType Directory -Force
        InModuleScope WindowsIsoServicing -Parameters @{ Custom = $custom } {
            Mock Get-ItemProperty { [pscustomobject]@{ KitsRoot10 = "$Custom\" } } -ParameterFilter { $Name -eq 'KitsRoot10' }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Windows Deployment Tools'; DisplayVersion = '10.1.28000.3481' } } -ParameterFilter { -not $Name }
            Mock Test-Path { $LiteralPath -eq "$Custom\" } -ParameterFilter { $PathType -eq 'Container' }
            $result = @(Get-WindowsAdkInstallation)
            $result.Count | Should -Be 1
            $result[0].Root | Should -Be $Custom
            $result[0].Source | Should -BeLike 'Registry*'
            $result[0].Version | Should -Be '10.1.28000.3481'
        }
    }
    It 'returns nothing when no ADK folder exists' {
        InModuleScope WindowsIsoServicing {
            Mock Get-ItemProperty { }
            Mock Test-Path { $false } -ParameterFilter { $PathType -eq 'Container' }
            @(Get-WindowsAdkInstallation).Count | Should -Be 0
        }
    }
}
