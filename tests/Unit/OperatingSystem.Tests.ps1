BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
}

Describe 'Resolve-WindowsRelease' {
    It 'identifies <Expected> from build <Build> (<InstallationType>, <EditionId>)' -ForEach @(
        @{ Build = 9200; InstallationType = 'Server'; EditionId = 'ServerDatacenter'; Expected = 'WindowsServer2012' }
        @{ Build = 9600; InstallationType = 'Server'; EditionId = 'ServerDatacenter'; Expected = 'WindowsServer2012R2' }
        @{ Build = 14393; InstallationType = 'Server Core'; EditionId = 'ServerStandard'; Expected = 'WindowsServer2016' }
        @{ Build = 17763; InstallationType = 'Server'; EditionId = 'ServerDatacenter'; Expected = 'WindowsServer2019' }
        @{ Build = 20348; InstallationType = 'Server'; EditionId = 'ServerDatacenter'; Expected = 'WindowsServer2022' }
        @{ Build = 26100; InstallationType = 'Server Core'; EditionId = 'ServerDatacenter'; Expected = 'WindowsServer2025' }
        @{ Build = 14393; InstallationType = 'Client'; EditionId = 'EnterpriseS'; Expected = 'Windows10Version1607' }
        @{ Build = 17763; InstallationType = 'Client'; EditionId = 'EnterpriseS'; Expected = 'Windows10Version1809' }
        @{ Build = 19045; InstallationType = 'Client'; EditionId = 'Professional'; Expected = 'Windows10Version22H2' }
        @{ Build = 26100; InstallationType = 'Client'; EditionId = 'Enterprise'; Expected = 'Windows11Version24H2' }
        @{ Build = 26200; InstallationType = 'Client'; EditionId = 'Professional'; Expected = 'Windows11Version25H2' }
    ) {
        InModuleScope WindowsIsoServicing -Parameters $_ {
            (Resolve-WindowsRelease -Build $Build -InstallationType $InstallationType -EditionId $EditionId).Key | Should -Be $Expected
        }
    }
    It 'distinguishes Windows Server 2012 from Windows Server 2012 R2' {
        InModuleScope WindowsIsoServicing {
            (Resolve-WindowsRelease -Build 9200 -InstallationType Server -EditionId ServerStandard).Name | Should -Be 'Windows Server 2012'
            (Resolve-WindowsRelease -Build 9600 -InstallationType Server -EditionId ServerStandard).Name | Should -Be 'Windows Server 2012 R2'
        }
    }
    It 'reports lifecycle status <Expected> for <EditionId> build <Build> on <AsOf>' -ForEach @(
        @{ Build = 9600; InstallationType = 'Server'; EditionId = 'ServerStandard'; AsOf = '2025-06-01'; Expected = 'ExtendedSecurityUpdates' }
        @{ Build = 9600; InstallationType = 'Server'; EditionId = 'ServerStandard'; AsOf = '2026-11-18'; Expected = 'OutOfSupport' }
        @{ Build = 19045; InstallationType = 'Client'; EditionId = 'Enterprise'; AsOf = '2026-11-18'; Expected = 'ExtendedSecurityUpdates' }
        @{ Build = 19045; InstallationType = 'Client'; EditionId = 'Core'; AsOf = '2026-11-18'; Expected = 'OutOfSupport' }
        @{ Build = 26100; InstallationType = 'Client'; EditionId = 'Professional'; AsOf = '2026-10-13'; Expected = 'Supported' }
        @{ Build = 26100; InstallationType = 'Client'; EditionId = 'Professional'; AsOf = '2026-10-14'; Expected = 'OutOfSupport' }
        @{ Build = 26100; InstallationType = 'Client'; EditionId = 'Enterprise'; AsOf = '2026-11-18'; Expected = 'Supported' }
        @{ Build = 26100; InstallationType = 'Server'; EditionId = 'ServerDatacenter'; AsOf = '2026-11-18'; Expected = 'Supported' }
        @{ Build = 14393; InstallationType = 'Client'; EditionId = 'EnterpriseS'; AsOf = '2026-11-18'; Expected = 'OutOfSupport' }
    ) {
        InModuleScope WindowsIsoServicing -Parameters $_ {
            $os = Resolve-WindowsRelease -Build $Build -InstallationType $InstallationType -EditionId $EditionId -AsOf ([datetime]$AsOf)
            $os.LifecycleStatus | Should -Be $Expected
        }
    }
    It 'selects the LTSC channel and file name for EnterpriseS editions' {
        InModuleScope WindowsIsoServicing {
            $ltsc = Resolve-WindowsRelease -Build 26100 -InstallationType Client -EditionId EnterpriseS
            $ltsc.Channel | Should -Be 'Enterprise LTSC 2024'
            $ltsc.FileNameStem | Should -Be 'Windows_11_LTSC_2024'
            $iot = Resolve-WindowsRelease -Build 26100 -InstallationType Client -EditionId IoTEnterpriseS
            $iot.Channel | Should -Be 'IoT Enterprise LTSC 2024'
        }
    }
    It 'enables checkpoint servicing only for build 26100 and later' {
        InModuleScope WindowsIsoServicing {
            (Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter).Servicing.CheckpointUpdates | Should -BeTrue
            (Resolve-WindowsRelease -Build 20348 -InstallationType Server -EditionId ServerDatacenter).Servicing.CheckpointUpdates | Should -BeFalse
        }
    }
    It 'marks retired and unknown builds' {
        InModuleScope WindowsIsoServicing {
            $retired = Resolve-WindowsRelease -Build 22000 -InstallationType Client -EditionId Professional
            $retired.LifecycleStatus | Should -Be 'OutOfSupport'
            $retired.IsKnownRelease | Should -BeFalse
            (Resolve-WindowsRelease -Build 99999 -InstallationType Client -EditionId Professional).LifecycleStatus | Should -Be 'Unknown'
        }
    }
    It 'rejects Windows PE images' {
        InModuleScope WindowsIsoServicing {
            { Resolve-WindowsRelease -Build 26100 -InstallationType WindowsPE -EditionId WindowsPE } | Should -Throw '*Windows PE*'
        }
    }
}

Describe 'Assert-ServiceableRelease' {
    It 'requires -EsuEntitled for ESU media' {
        InModuleScope WindowsIsoServicing {
            $os = Resolve-WindowsRelease -Build 19045 -InstallationType Client -EditionId Enterprise -AsOf ([datetime]'2026-11-18')
            { Assert-ServiceableRelease -OperatingSystem $os } | Should -Throw -ErrorId 'EsuEntitlementRequired'
            { Assert-ServiceableRelease -OperatingSystem $os -EsuEntitled } | Should -Not -Throw
        }
    }
    It 'distinguishes out-of-support from unknown media' {
        InModuleScope WindowsIsoServicing {
            $retired = Resolve-WindowsRelease -Build 9600 -InstallationType Server -EditionId ServerStandard -AsOf ([datetime]'2026-11-18')
            { Assert-ServiceableRelease -OperatingSystem $retired -EsuEntitled } | Should -Throw -ErrorId 'OutOfSupportMedia'
            $unknown = Resolve-WindowsRelease -Build 99999 -InstallationType Server -EditionId ServerStandard
            { Assert-ServiceableRelease -OperatingSystem $unknown } | Should -Throw -ErrorId 'UnsupportedMedia'
        }
    }
}

Describe 'ConvertTo-ArchitectureName' {
    It 'maps DISM architecture <Value> to <Name>' -ForEach @(
        @{ Value = 0; Name = 'x86' }
        @{ Value = 9; Name = 'x64' }
        @{ Value = 12; Name = 'arm64' }
    ) {
        InModuleScope WindowsIsoServicing -Parameters $_ {
            ConvertTo-ArchitectureName -Architecture $Value | Should -Be $Name
        }
    }
    It 'rejects unknown values' {
        InModuleScope WindowsIsoServicing { { ConvertTo-ArchitectureName -Architecture 6 } | Should -Throw }
    }
}
