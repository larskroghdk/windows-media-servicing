BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
}

Describe 'New-BootTestAnswerFile' {
    It 'writes well-formed XML with the three amd64 setup components for <Firmware>' -ForEach @(
        @{ Firmware = 'UEFI'; Index = 3; PartitionId = '3' }
        @{ Firmware = 'BIOS'; Index = 1; PartitionId = '1' }
    ) {
        $text = InModuleScope WindowsIsoServicing -Parameters @{ Firmware = $Firmware; Index = $Index } {
            New-BootTestAnswerFile -Index $Index -Firmware $Firmware -Language 'da-DK' -ProductKey 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
        }

        $xml = [xml]$text
        $ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')

        $components = @($xml.SelectNodes('//u:component', $ns))
        $components.name | Should -Be @('Microsoft-Windows-International-Core-WinPE', 'Microsoft-Windows-Setup', 'Microsoft-Windows-Deployment')
        $components.processorArchitecture | Sort-Object -Unique | Should -Be 'amd64'
        $components.publicKeyToken | Sort-Object -Unique | Should -Be '31bf3856ad364e35'

        $xml.SelectSingleNode('//u:InstallFrom/u:MetaData/u:Value', $ns).InnerText | Should -Be "$Index"
        $xml.SelectSingleNode('//u:InstallTo/u:PartitionID', $ns).InnerText | Should -Be $PartitionId
        $xml.SelectSingleNode('//u:SetupUILanguage/u:UILanguage', $ns).InnerText | Should -Be 'da-DK'
        $xml.SelectSingleNode('//u:ProductKey/u:Key', $ns).InnerText | Should -Be 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE'
    }

    It 'omits the product key element when no key is given' {
        $text = InModuleScope WindowsIsoServicing {
            New-BootTestAnswerFile -Index 1 -Firmware 'UEFI' -Language 'en-US'
        }
        $text | Should -Not -Match '<ProductKey>'
        { [xml]$text } | Should -Not -Throw
    }
}

Describe 'Test-IsoStructure boot prompt checks' {
    BeforeAll {
        $media = Join-Path $TestDrive 'structure-media'
        foreach ($file in 'bootmgr', 'boot\etfsboot.com', 'boot\bcd', 'efi\boot\bootx64.efi', 'efi\microsoft\boot\bcd', 'efi\microsoft\boot\efisys.bin', 'efi\microsoft\boot\efisys_noprompt.bin', 'setup.exe', 'sources\setup.exe', 'sources\boot.wim', 'sources\install.wim') {
            $path = Join-Path $media $file
            $null = New-Item -Path (Split-Path $path) -ItemType Directory -Force
            Set-Content -LiteralPath $path -Value $file
        }
    }
    BeforeEach {
        Remove-Item -LiteralPath (Join-Path $media 'boot\bootfix.bin') -Force -ErrorAction SilentlyContinue
        $manifest = [pscustomobject]@{
            output = [pscustomobject]@{
                sha256    = $null
                bootModes = [pscustomobject]@{ bios = $true; uefi = $true; uefiNoPrompt = $true; biosNoPrompt = $true }
            }
            images = [pscustomobject]@{ install = @() }
        }
        $legacyManifest = [pscustomobject]@{
            output = [pscustomobject]@{
                sha256    = $null
                bootModes = [pscustomobject]@{ bios = $true; uefi = $true }
            }
            images = [pscustomobject]@{ install = @() }
        }
    }
    It 'passes when the UEFI entry starts efisys_noprompt.bin and bootfix.bin is absent' {
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media; Manifest = $manifest } {
            Mock Mount-IsoImage { $Media }
            Mock Dismount-IsoImage { }
            Mock Get-WindowsImage { [pscustomobject]@{ ImageIndex = 1 } }
            Mock Get-IsoBootEntry { [pscustomobject]@{ Platform = 'BIOS'; LoadRba = 30; SectorCount = 4 }, [pscustomobject]@{ Platform = 'UEFI'; LoadRba = 32; SectorCount = 1 } }
            Mock Get-IsoBootImageSha256 { 'noprompt' }
            Mock Get-FileSha256 { if ($Path -like '*efisys_noprompt.bin') { 'noprompt' } else { 'iso' } }
            $result = Test-IsoStructure -IsoPath 'C:\out.iso' -Manifest $Manifest
            $result.passed | Should -BeTrue
            ($result.checks | Where-Object name -EQ 'BootCatalog').status | Should -Be 'Passed'
            ($result.checks | Where-Object name -EQ 'UefiBootPrompt').status | Should -Be 'Passed'
            ($result.checks | Where-Object name -EQ 'BiosBootPrompt').status | Should -Be 'Passed'
            Should -Invoke Get-IsoBootImageSha256 -ParameterFilter { $LoadRba -eq 32 }
        }
    }
    It 'fails when the manifest records no-prompt boot but the ISO would prompt' {
        $null = New-Item -Path (Join-Path $media 'boot\bootfix.bin') -ItemType File -Force
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media; Manifest = $manifest } {
            Mock Mount-IsoImage { $Media }
            Mock Dismount-IsoImage { }
            Mock Get-WindowsImage { [pscustomobject]@{ ImageIndex = 1 } }
            Mock Get-IsoBootEntry { [pscustomobject]@{ Platform = 'BIOS'; LoadRba = 30; SectorCount = 4 }, [pscustomobject]@{ Platform = 'UEFI'; LoadRba = 32; SectorCount = 1 } }
            Mock Get-IsoBootImageSha256 { 'prompting' }
            Mock Get-FileSha256 { if ($Path -like '*efisys_noprompt.bin') { 'noprompt' } else { 'iso' } }
            $result = Test-IsoStructure -IsoPath 'C:\out.iso' -Manifest $Manifest
            $result.passed | Should -BeFalse
            ($result.checks | Where-Object name -EQ 'UefiBootPrompt').status | Should -Be 'Failed'
            ($result.checks | Where-Object name -EQ 'BiosBootPrompt').status | Should -Be 'Failed'
        }
    }
    It 'records a prompting ISO as Skipped for a manifest written before no-prompt boot' {
        $null = New-Item -Path (Join-Path $media 'boot\bootfix.bin') -ItemType File -Force
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media; Manifest = $legacyManifest } {
            Mock Mount-IsoImage { $Media }
            Mock Dismount-IsoImage { }
            Mock Get-WindowsImage { [pscustomobject]@{ ImageIndex = 1 } }
            Mock Get-IsoBootEntry { [pscustomobject]@{ Platform = 'BIOS'; LoadRba = 30; SectorCount = 4 }, [pscustomobject]@{ Platform = 'UEFI'; LoadRba = 32; SectorCount = 1 } }
            Mock Get-IsoBootImageSha256 { 'prompting' }
            Mock Get-FileSha256 { if ($Path -like '*efisys_noprompt.bin') { 'noprompt' } else { 'iso' } }
            $result = Test-IsoStructure -IsoPath 'C:\out.iso' -Manifest $Manifest
            $result.passed | Should -BeTrue
            ($result.checks | Where-Object name -EQ 'UefiBootPrompt').status | Should -Be 'Skipped'
            ($result.checks | Where-Object name -EQ 'BiosBootPrompt').status | Should -Be 'Skipped'
        }
    }
    It 'fails the boot catalog check when an expected boot mode has no entry' {
        InModuleScope WindowsIsoServicing -Parameters @{ Media = $media; Manifest = $manifest } {
            Mock Mount-IsoImage { $Media }
            Mock Dismount-IsoImage { }
            Mock Get-WindowsImage { [pscustomobject]@{ ImageIndex = 1 } }
            Mock Get-IsoBootEntry { [pscustomobject]@{ Platform = 'BIOS'; LoadRba = 30; SectorCount = 4 } }
            Mock Get-IsoBootImageSha256 { 'noprompt' }
            Mock Get-FileSha256 { 'iso' }
            $result = Test-IsoStructure -IsoPath 'C:\out.iso' -Manifest $Manifest
            $result.passed | Should -BeFalse
            ($result.checks | Where-Object name -EQ 'BootCatalog').detail | Should -BeLike '*missing: UEFI*'
            ($result.checks | Where-Object name -EQ 'UefiBootPrompt').status | Should -Be 'Failed'
            Should -Invoke Get-IsoBootImageSha256 -Times 0
        }
    }
}
