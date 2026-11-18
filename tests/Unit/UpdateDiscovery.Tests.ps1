BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'Get-UpdateClassification' {
    It 'classifies "<Title>" as <Category>' -ForEach @(
        @{ Product = 'Windows 11 Version 24H2'; Arch = 'x64'; Title = '2026-11 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5070000) (26100.7171)'; Category = 'CumulativeUpdate'; Kb = 'KB5070000'; Month = '2026-11'; Build = '26100.7171' }
        @{ Product = 'Microsoft server operating system version 24H2'; Arch = 'x64'; Title = '2026-11 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5070001)'; Category = 'CumulativeUpdate'; Kb = 'KB5070001'; Month = '2026-11'; Build = $null }
        @{ Product = 'Microsoft server operating system, version 21H2'; Arch = 'x64'; Title = '2026-11 Cumulative Update for Microsoft server operating system, version 21H2 for x64-based Systems (KB5070002)'; Category = 'CumulativeUpdate'; Kb = 'KB5070002'; Month = '2026-11'; Build = $null }
        @{ Product = 'Windows Server 2016'; Arch = 'x64'; Title = '2026-11 Cumulative Update for Windows Server 2016 for x64-based Systems (KB5070003)'; Category = 'CumulativeUpdate'; Kb = 'KB5070003'; Month = '2026-11'; Build = $null }
        @{ Product = 'Windows Server 2016'; Arch = 'x64'; Title = '2026-11 Servicing Stack Update for Windows Server 2016 for x64-based Systems (KB5070004)'; Category = 'ServicingStack'; Kb = 'KB5070004'; Month = '2026-11'; Build = $null }
        @{ Product = 'Windows Server 2016'; Arch = 'x64'; Title = 'Servicing Stack Update for Windows Server 2016 for x64-based Systems (KB4498947)'; Category = 'ServicingStack'; Kb = 'KB4498947'; Month = $null; Build = $null }
        @{ Product = 'Windows 11 Version 24H2'; Arch = 'x64'; Title = '2026-11 Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for x64 (KB5070005)'; Category = 'DotNetCumulativeUpdate'; Kb = 'KB5070005'; Month = '2026-11'; Build = $null }
        @{ Product = 'Windows Server 2019'; Arch = 'x64'; Title = '2026-11 Cumulative Update for .NET Framework 3.5, 4.7.2 and 4.8 for Windows Server 2019 for x64 (KB5070006)'; Category = 'DotNetCumulativeUpdate'; Kb = 'KB5070006'; Month = '2026-11'; Build = $null }
        @{ Product = 'Windows 11 Version 24H2'; Arch = 'arm64'; Title = '2026-11 Safe OS Dynamic Update for Windows 11 Version 24H2 for ARM64-based Systems (KB5070007)'; Category = 'SafeOsDynamicUpdate'; Kb = 'KB5070007'; Month = '2026-11'; Build = $null }
        @{ Product = 'Microsoft server operating system version 24H2'; Arch = 'x64'; Title = '2026-11 Setup Dynamic Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5070008)'; Category = 'SetupDynamicUpdate'; Kb = 'KB5070008'; Month = '2026-11'; Build = $null }
        @{ Product = 'Windows Server 2012 R2'; Arch = 'x64'; Title = '2023-10 Security Monthly Quality Rollup for Windows Server 2012 R2 for x64-based Systems (KB5031419)'; Category = 'CumulativeUpdate'; Kb = 'KB5031419'; Month = '2023-10'; Build = $null }
    ) {
        InModuleScope WindowsIsoServicing -Parameters $_ {
            $result = Get-UpdateClassification -Title $Title -ProductText $Product -Architecture $Arch
            $result.Category | Should -Be $Category
            $result.Kb | Should -Be $Kb
            $result.ReleaseMonth | Should -Be $Month
            $result.OsBuild | Should -Be $Build
            $result.IsPreview | Should -BeFalse
        }
    }
    It 'flags preview cumulative updates' {
        InModuleScope WindowsIsoServicing {
            $result = Get-UpdateClassification -Title '2026-10 Cumulative Update Preview for Windows 11 Version 24H2 for x64-based Systems (KB5069999)' -ProductText 'Windows 11 Version 24H2' -Architecture x64
            $result.IsPreview | Should -BeTrue
        }
    }
    It 'uses product and description to classify combined Dynamic Update titles' {
        InModuleScope WindowsIsoServicing {
            $title = '2026-11 Dynamic Update for Windows 10 Version 22H2 for x64-based Systems (KB5070010)'
            (Get-UpdateClassification -Title $title -ProductText 'Windows 10 Version 22H2' -Architecture x64 -ProductTitles 'Windows Safe OS Dynamic Update').Category | Should -Be 'SafeOsDynamicUpdate'
            (Get-UpdateClassification -Title $title -ProductText 'Windows 10 Version 22H2' -Architecture x64 -ProductTitles 'Windows 10 and later Dynamic Update' -Description 'SetupUpdate').Category | Should -Be 'SetupDynamicUpdate'
            Get-UpdateClassification -Title $title -ProductText 'Windows 10 Version 22H2' -Architecture x64 | Should -BeNullOrEmpty
        }
    }
    It 'ignores other architectures and other products' {
        InModuleScope WindowsIsoServicing {
            Get-UpdateClassification -Title '2026-11 Cumulative Update for Windows 11 Version 24H2 for ARM64-based Systems (KB5070000)' -ProductText 'Windows 11 Version 24H2' -Architecture x64 | Should -BeNullOrEmpty
            Get-UpdateClassification -Title '2023-10 Security Monthly Quality Rollup for Windows Server 2012 R2 for x64-based Systems (KB5031419)' -ProductText 'Windows Server 2012' -Architecture x64 | Should -BeNullOrEmpty
            Get-UpdateClassification -Title '2026-11 Cumulative Update for Windows 11 Version 25H2 for x64-based Systems (KB5070011)' -ProductText 'Windows 11 Version 24H2' -Architecture x64 | Should -BeNullOrEmpty
        }
    }
}

Describe 'Select-ApplicableUpdate' {
    It 'selects the newest non-superseded, non-preview update per category' {
        $candidates = @(
            New-TestUpdate CumulativeUpdate KB1 '2026-09' -Superseded
            New-TestUpdate CumulativeUpdate KB2 '2026-10'
            New-TestUpdate CumulativeUpdate KB3 '2026-11'
            New-TestUpdate CumulativeUpdate KB4 '2026-11' -Preview
            New-TestUpdate SafeOsDynamicUpdate KB5 '2026-10'
            New-TestUpdate SetupDynamicUpdate KB6 '2026-11'
        )
        InModuleScope WindowsIsoServicing -Parameters @{ Candidates = $candidates } {
            $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
            $selected = @(Select-ApplicableUpdate -Candidate $Candidates -OperatingSystem $os)
            $selected.Kb | Should -Be @('KB3', 'KB5', 'KB6')
        }
    }
    It 'includes preview updates only when requested' {
        $candidates = @(
            New-TestUpdate CumulativeUpdate KB3 '2026-10'
            New-TestUpdate CumulativeUpdate KB4 '2026-11' -Preview
        )
        InModuleScope WindowsIsoServicing -Parameters @{ Candidates = $candidates } {
            $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
            (Select-ApplicableUpdate -Candidate $Candidates -OperatingSystem $os -IncludePreview).Kb | Should -Be 'KB4'
        }
    }
    It 'only takes a standalone servicing stack from the cumulative update month on combined releases' {
        $candidates = @(
            New-TestUpdate CumulativeUpdate KB10 '2026-11'
            New-TestUpdate ServicingStack KB11 '2026-05'
        )
        InModuleScope WindowsIsoServicing -Parameters @{ Candidates = $candidates } {
            $combined = Resolve-WindowsRelease -Build 20348 -InstallationType Server -EditionId ServerDatacenter
            @(Select-ApplicableUpdate -Candidate $Candidates -OperatingSystem $combined).Kb | Should -Be @('KB10')
            $separate = Resolve-WindowsRelease -Build 14393 -InstallationType Server -EditionId ServerDatacenter
            @(Select-ApplicableUpdate -Candidate $Candidates -OperatingSystem $separate).Kb | Should -Be @('KB11', 'KB10')
        }
    }
    It 'keeps every .NET cumulative update of the newest month' {
        $candidates = @(
            New-TestUpdate DotNetCumulativeUpdate KB21 '2026-11'
            New-TestUpdate DotNetCumulativeUpdate KB20 '2026-11'
            New-TestUpdate DotNetCumulativeUpdate KB19 '2026-10'
        )
        InModuleScope WindowsIsoServicing -Parameters @{ Candidates = $candidates } {
            $os = Resolve-WindowsRelease -Build 20348 -InstallationType Server -EditionId ServerDatacenter
            @(Select-ApplicableUpdate -Candidate $Candidates -OperatingSystem $os).Kb | Should -Be @('KB20', 'KB21')
        }
    }
    It 'omits Dynamic Updates for rollup-serviced releases' {
        $candidates = @(
            New-TestUpdate CumulativeUpdate KB30 '2023-10'
            New-TestUpdate SafeOsDynamicUpdate KB31 '2023-10'
        )
        InModuleScope WindowsIsoServicing -Parameters @{ Candidates = $candidates } {
            $os = Resolve-WindowsRelease -Build 9600 -InstallationType Server -EditionId ServerStandard
            @(Select-ApplicableUpdate -Candidate $Candidates -OperatingSystem $os).Kb | Should -Be @('KB30')
        }
    }
}

Describe 'Select-UpdatePackageFile' {
    It 'assigns target and checkpoint roles for checkpoint cumulative updates' {
        $update = [pscustomobject]@{
            Category = 'CumulativeUpdate'; Kb = 'KB5048667'; Title = 'LCU'
            Files = @(
                New-TestFile 'windows11.0-kb5043080-x64_953449672073f8fb99badb4cc6d5d7849b9c83e8.msu'
                New-TestFile 'windows11.0-kb5048667-x64_d4ad0ca69de9a02bc356757581e0e0d6960c9f93.msu'
                New-TestFile 'windows11.0-kb5048667-x64.psf'
            )
        }
        InModuleScope WindowsIsoServicing -Parameters @{ Update = $update } {
            $files = @(Select-UpdatePackageFile -Update $Update -CheckpointUpdates)
            $files.Count | Should -Be 2
            ($files | Where-Object Role -eq 'Target').Name | Should -BeLike '*kb5048667*.msu'
            ($files | Where-Object Role -eq 'Checkpoint').Name | Should -BeLike '*kb5043080*.msu'
            $Update.Files[0].Role | Should -BeNullOrEmpty -Because 'the input objects are not modified'
        }
    }
    It 'requires MSU files for checkpoint cumulative updates' {
        $update = [pscustomobject]@{ Category = 'CumulativeUpdate'; Kb = 'KB5048667'; Title = 'LCU'; Files = @(New-TestFile 'windows11.0-kb5048667-x64.cab') }
        InModuleScope WindowsIsoServicing -Parameters @{ Update = $update } {
            { Select-UpdatePackageFile -Update $Update -CheckpointUpdates } | Should -Throw '*provides no MSU*'
        }
    }
    It 'rejects unexpected MSU files in a checkpoint cumulative update' {
        $update = [pscustomobject]@{
            Category = 'CumulativeUpdate'; Kb = 'KB5048667'; Title = 'LCU'
            Files = @(New-TestFile 'windows11.0-kb5048667-x64.msu'; New-TestFile 'other.msu')
        }
        InModuleScope WindowsIsoServicing -Parameters @{ Update = $update } {
            { Select-UpdatePackageFile -Update $Update -CheckpointUpdates } | Should -Throw '*Unexpected file*'
        }
    }
    It 'chooses the full CAB over express files when no MSU exists' {
        $update = [pscustomobject]@{
            Category = 'CumulativeUpdate'; Kb = 'KB5070003'; Title = 'LCU'
            Files = @(New-TestFile 'windows10.0-kb5070003-x64.cab'; New-TestFile 'windows10.0-kb5070003-x64-express.cab'; New-TestFile 'windows10.0-kb5070003-x64.psf')
        }
        InModuleScope WindowsIsoServicing -Parameters @{ Update = $update } {
            $file = Select-UpdatePackageFile -Update $Update
            $file.Name | Should -Be 'windows10.0-kb5070003-x64.cab'
            $file.Role | Should -Be 'Package'
        }
    }
}

Describe 'Find-RepositoryUpdate' {
    It 'reads matching entries and resolves file paths inside the repository' {
        $repository = Join-Path $TestDrive 'repo'
        $null = New-Item -Path $repository -ItemType Directory
        @{
            schemaVersion = 1
            updates       = @(
                @{ category = 'CumulativeUpdate'; kb = 'kb5070001'; title = 'LCU'; releaseKey = 'WindowsServer2025'; architecture = 'x64'; releaseMonth = '2026-11'
                    files = @(@{ name = 'windows11.0-kb5070001-x64.msu'; path = 'packages\KB5070001\windows11.0-kb5070001-x64.msu'; role = 'Target' })
                }
                @{ category = 'CumulativeUpdate'; kb = 'KB5070002'; title = 'Other'; releaseKey = 'WindowsServer2022'; architecture = 'x64'; releaseMonth = '2026-11'; files = @() }
            )
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $repository 'updates.json')
        InModuleScope WindowsIsoServicing -Parameters @{ Repository = $repository } {
            $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
            $updates = @(Find-RepositoryUpdate -OperatingSystem $os -Architecture x64 -RepositoryPath $Repository)
            $updates.Count | Should -Be 1
            $updates[0].Kb | Should -Be 'KB5070001'
            $updates[0].Source | Should -Be 'Repository'
            $updates[0].Files[0].Path | Should -Be (Join-Path $Repository 'packages\KB5070001\windows11.0-kb5070001-x64.msu')
        }
    }
    It 'rejects file paths outside the repository' {
        $repository = Join-Path $TestDrive 'repo-traversal'
        $null = New-Item -Path $repository -ItemType Directory
        @{
            schemaVersion = 1
            updates       = @(@{ category = 'CumulativeUpdate'; kb = 'KB1'; title = 'x'; releaseKey = 'WindowsServer2025'; architecture = 'x64'; releaseMonth = '2026-11'
                    files = @(@{ name = 'evil.msu'; path = '..\..\evil.msu' })
                })
        } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $repository 'updates.json')
        InModuleScope WindowsIsoServicing -Parameters @{ Repository = $repository } {
            $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
            { Find-RepositoryUpdate -OperatingSystem $os -Architecture x64 -RepositoryPath $Repository } | Should -Throw '*outside the repository*'
        }
    }
}


Describe 'Get-UpdateClassification for combined Dynamic Update titles' {
    It 'lets the description decide when a Safe OS update lists both Dynamic Update products' {
        InModuleScope WindowsIsoServicing {
            $title = '2026-11 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5131094)'
            $both = 'Windows 10 and later Dynamic Update', 'Windows Safe OS Dynamic Update'
            (Get-UpdateClassification -Title $title -ProductText 'Windows 10 Version 1809' -Architecture x64 -ProductTitles $both -Description 'ComponentUpdate:').Category | Should -Be 'SafeOsDynamicUpdate'
            (Get-UpdateClassification -Title $title -ProductText 'Windows 10 Version 1809' -Architecture x64 -ProductTitles $both -Description 'SetupUpdate:').Category | Should -Be 'SetupDynamicUpdate'
        }
    }
}

Describe 'Get-CatalogUpdateClassification' {
    It 'accepts Windows 10 1809 Dynamic Updates for Windows Server 2019, but not Windows 10 cumulative updates' {
        InModuleScope WindowsIsoServicing {
            $os = Resolve-WindowsRelease -Build 17763 -InstallationType Server -EditionId ServerStandard
            $du = Get-CatalogUpdateClassification -Title '2026-11 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5131094)' -OperatingSystem $os -Architecture x64 -Description 'ComponentUpdate:'
            $du.Category | Should -Be 'SafeOsDynamicUpdate'
            Get-CatalogUpdateClassification -Title '2026-11 Cumulative Update for Windows 10 Version 1809 for x64-based Systems (KB5131085)' -OperatingSystem $os -Architecture x64 | Should -BeNullOrEmpty
            (Get-CatalogUpdateClassification -Title '2026-11 Cumulative Update for Windows Server 2019 for x64-based Systems (KB5131085)' -OperatingSystem $os -Architecture x64).Category | Should -Be 'CumulativeUpdate'
        }
    }
}

Describe 'Get-CatalogSearchQuery' {
    It 'searches each category Windows Server 2019 needs, with Dynamic Updates under Windows 10 1809' {
        InModuleScope WindowsIsoServicing {
            $os = Resolve-WindowsRelease -Build 17763 -InstallationType Server -EditionId ServerStandard
            @(Get-CatalogSearchQuery -OperatingSystem $os -Architecture x64) | Should -Be @(
                'Cumulative Update for Windows Server 2019 for x64-based Systems'
                'Servicing Stack Update for Windows Server 2019 for x64-based Systems'
                'Cumulative Update for .NET Framework for Windows Server 2019 for x64'
                'Dynamic Update for Windows 10 Version 1809 for x64-based Systems'
            )
        }
    }
    It 'searches rollups and servicing stacks only for rollup-serviced releases' {
        InModuleScope WindowsIsoServicing {
            $os = Resolve-WindowsRelease -Build 9600 -InstallationType Server -EditionId ServerStandard
            @(Get-CatalogSearchQuery -OperatingSystem $os -Architecture x64) | Should -Be @(
                'Security Monthly Quality Rollup for Windows Server 2012 R2 for x64-based Systems'
                'Servicing Stack Update for Windows Server 2012 R2 for x64-based Systems'
            )
        }
    }
}

Describe '.NET Framework rollups' {
    It 'keeps every per-framework MSU of a rollup' {
        $update = [pscustomobject]@{
            Category = 'DotNetCumulativeUpdate'; Kb = 'KB5128923'; Title = '.NET rollup'
            Files = @(
                New-TestFile 'windows10.0-kb5127666-x64_9a0ee3619df932ec86f14a1e6889bc4af4fe29e1.msu'
                New-TestFile 'windows10.0-kb5127685-x64-ndp48_bf787eddacc3f63fa93c0b2ab51c4a422b3bd316.msu'
            )
        }
        $files = @(InModuleScope WindowsIsoServicing -Parameters @{ Update = $update } { Select-UpdatePackageFile -Update $Update })
        $files.Count | Should -Be 2
        @($files.Role | Sort-Object -Unique) | Should -Be @('Package')
    }
    It 'refuses a rollup file without a KB number' {
        $update = [pscustomobject]@{
            Category = 'DotNetCumulativeUpdate'; Kb = 'KB5128923'; Title = '.NET rollup'
            Files = @((New-TestFile 'windows10.0-kb5127666-x64.msu'), (New-TestFile 'ndp48-x64.msu'))
        }
        { InModuleScope WindowsIsoServicing -Parameters @{ Update = $update } { Select-UpdatePackageFile -Update $Update } } | Should -Throw "*Unexpected file 'ndp48-x64.msu'*"
    }
    It 'installs each MSU once when a rollup and its per-framework updates are both selected' {
        $a = New-TestFile 'windows10.0-kb5127666-x64.msu'
        $b = New-TestFile 'windows10.0-kb5127685-x64-ndp48.msu'
        $updates = @(
            [pscustomobject]@{ Category = 'CumulativeUpdate'; Kb = 'KB5131085'; Files = @(New-TestFile 'windows10.0-kb5131085-x64.msu') }
            [pscustomobject]@{ Category = 'DotNetCumulativeUpdate'; Kb = 'KB5127666'; Files = @($a) }
            [pscustomobject]@{ Category = 'DotNetCumulativeUpdate'; Kb = 'KB5127685'; Files = @($b) }
            [pscustomobject]@{ Category = 'DotNetCumulativeUpdate'; Kb = 'KB5128923'; Files = @($a, $b) }
        )
        $kept = @(InModuleScope WindowsIsoServicing -Parameters @{ Updates = $updates } { Select-DistinctPackageUpdate -Update $Updates })
        $kept.Kb | Should -Be @('KB5131085', 'KB5128923')
    }
}

Describe 'Find-CatalogUpdate' {
    BeforeAll {
        $script:catalogRows = @(
            New-TestCatalogRow -Id 1 -Title '2026-11 Cumulative Update for Windows Server 2019 for x64-based Systems (KB5136490)' -Classification 'Updates' -Date '2026-11-13' -Products 'Windows Server 2019'
            New-TestCatalogRow -Id 2 -Title '2026-11 Cumulative Update for Windows Server 2019 for x64-based Systems (KB5131085)' -Classification 'Security Updates' -Date '2026-11-10' -Products 'Windows Server 2019'
            New-TestCatalogRow -Id 3 -Title '2026-11 Cumulative Update for Windows Server 2019 for ARM64-based Systems (KB5131086)' -Classification 'Security Updates' -Date '2026-11-10' -Products 'Windows Server 2019'
            New-TestCatalogRow -Id 4 -Title '2026-11 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5131094)' -Classification 'Critical Updates' -Date '2026-11-10' -Products 'Windows 10 and later Dynamic Update', 'Windows Safe OS Dynamic Update'
            New-TestCatalogRow -Id 5 -Title '2025-11 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5068795)' -Classification 'Critical Updates' -Date '2025-11-11' -Products 'Windows 10 and later Dynamic Update'
            New-TestCatalogRow -Id 6 -Title '2024-06 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5039000)' -Classification 'Critical Updates' -Date '2024-06-11' -Products 'Windows 10 and later Dynamic Update'
        )
        Mock -ModuleName WindowsIsoServicing Write-ServicingLog {}
        Mock -ModuleName WindowsIsoServicing Search-CatalogUpdate {
            if ($Query -like 'Cumulative Update for Windows Server*') { $catalogRows[0..2] }
            elseif ($Query -like 'Dynamic Update*') { $catalogRows[3..5] }
        }
        Mock -ModuleName WindowsIsoServicing Get-CatalogUpdateDetail {
            $description = if ($UpdateId -eq $catalogRows[3].UpdateId) { 'ComponentUpdate:' } else { 'SetupUpdate:' }
            [pscustomobject]@{ Title = ''; Description = $description; Products = @('Windows 10 and later Dynamic Update'); Classification = 'Critical Updates'; SupersededBy = @() }
        }
        $script:found = @(InModuleScope WindowsIsoServicing {
                $os = Resolve-WindowsRelease -Build 17763 -InstallationType Server -EditionId ServerStandard
                Find-CatalogUpdate -OperatingSystem $os -Architecture x64 -AsOf ([datetime]'2026-11-18')
            })
    }
    It 'keeps only updates for the release and architecture that are within the age limit' {
        $found.Kb | Should -Be @('KB5136490', 'KB5131085', 'KB5131094', 'KB5068795')
        @($found.Source | Sort-Object -Unique) | Should -Be @('MicrosoftUpdateCatalog')
    }
    It 'treats a cumulative update the Catalog does not classify as a security update as a preview' {
        ($found | Where-Object Kb -eq 'KB5136490').IsPreview | Should -BeTrue
        ($found | Where-Object Kb -eq 'KB5131085').IsPreview | Should -BeFalse
    }
    It 'classifies combined Dynamic Update titles from the description on their details page' {
        ($found | Where-Object Kb -eq 'KB5131094').Category | Should -Be 'SafeOsDynamicUpdate'
        ($found | Where-Object Kb -eq 'KB5068795').Category | Should -Be 'SetupDynamicUpdate'
        Should -Invoke -ModuleName WindowsIsoServicing Get-CatalogUpdateDetail -Times 2 -Exactly -Scope Describe
    }
}

Describe 'Assert-CatalogUpdatePlan' {
    BeforeAll {
        $script:security = [pscustomobject]@{ Category = 'CumulativeUpdate'; Kb = 'KB5131080'; UpdateId = '00000000-0000-0000-0000-00000000000a'; IsPreview = $false; CreationDate = [datetime]'2026-11-10'; CatalogClassification = 'Security Updates' }
        $script:optional = [pscustomobject]@{ Category = 'CumulativeUpdate'; Kb = 'KB5136489'; UpdateId = '00000000-0000-0000-0000-00000000000b'; IsPreview = $true; CreationDate = [datetime]'2026-11-13'; CatalogClassification = 'Updates' }
        $script:older = [pscustomobject]@{ Category = 'CumulativeUpdate'; Kb = 'KB5126646'; UpdateId = '00000000-0000-0000-0000-00000000000c'; IsPreview = $false; CreationDate = [datetime]'2026-10-13'; CatalogClassification = 'Security Updates' }
        $script:supersededBy = @()
        Mock -ModuleName WindowsIsoServicing Write-ServicingLog {}
        Mock -ModuleName WindowsIsoServicing Get-MsrcSecurityUpdate { [pscustomobject]@{ Kb = 'KB5131080'; FixedBuild = [version]'10.0.26100.33822'; DocumentId = '2026-Nov' } }
        Mock -ModuleName WindowsIsoServicing Get-CatalogUpdateDetail { [pscustomobject]@{ SupersededBy = @($supersededBy) } }
    }
    BeforeEach {
        $script:supersededBy = @()
    }
    It 'reports a newer non-security cumulative update instead of dropping it silently' {
        $script:supersededBy = @([pscustomobject]@{ UpdateId = $optional.UpdateId; Title = '2026-11 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5136489) (26100.33828)' })
        $notes = @(InModuleScope WindowsIsoServicing -Parameters @{ Selected = @($security); Candidate = @($security, $optional) } {
                $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
                Assert-CatalogUpdatePlan -Selected $Selected -Candidate $Candidate -OperatingSystem $os -Architecture x64
            })
        $notes.Count | Should -Be 1
        $notes[0] | Should -BeLike 'KB5136489 (2026-11-13*pass -IncludePreview*'
    }
    It 'stops when the MSRC security update is missing from the Catalog results' {
        { InModuleScope WindowsIsoServicing -Parameters @{ Selected = @($older); Candidate = @($older) } {
                $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
                Assert-CatalogUpdatePlan -Selected $Selected -Candidate $Candidate -OperatingSystem $os -Architecture x64
            } } | Should -Throw '*lists KB5131080*returned no such x64 cumulative update*'
    }
    It 'stops when the selected cumulative update is older than the MSRC security update' {
        { InModuleScope WindowsIsoServicing -Parameters @{ Selected = @($older); Candidate = @($older, $security) } {
                $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
                Assert-CatalogUpdatePlan -Selected $Selected -Candidate $Candidate -OperatingSystem $os -Architecture x64
            } } | Should -Throw '*KB5126646 is older than KB5131080*'
    }
    It 'stops when a selected update is superseded by an update the search did not return' {
        $script:supersededBy = @([pscustomobject]@{ UpdateId = '00000000-0000-0000-0000-0000000000ff'; Title = '2026-12 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5199999)' })
        { InModuleScope WindowsIsoServicing -Parameters @{ Selected = @($security); Candidate = @($security) } {
                $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
                Assert-CatalogUpdatePlan -Selected $Selected -Candidate $Candidate -OperatingSystem $os -Architecture x64
            } } | Should -Throw '*KB5199999*did not return it*'
    }
    It 'notes, and does not stop, when MSRC does not list the release' {
        $notes = @(InModuleScope WindowsIsoServicing -Parameters @{ Selected = @($security); Candidate = @($security) } {
                $os = Resolve-WindowsRelease -Build 25398 -InstallationType Server -EditionId ServerStandard
                Assert-CatalogUpdatePlan -Selected $Selected -Candidate $Candidate -OperatingSystem $os -Architecture x64
            })
        $notes | Should -BeLike '*MSRC Security Updates API does not list*'
        Should -Invoke -ModuleName WindowsIsoServicing Get-MsrcSecurityUpdate -Times 0 -Exactly
    }
}

Describe 'Get-UpdatePlan' {
    BeforeAll {
        Mock -ModuleName WindowsIsoServicing Write-ServicingLog {}
        Mock -ModuleName WindowsIsoServicing Assert-CatalogUpdatePlan { 'note from the MSRC check' }
        Mock -ModuleName WindowsIsoServicing Find-RepositoryUpdate {}
        Mock -ModuleName WindowsIsoServicing Find-CatalogUpdate {
            [pscustomobject]@{
                Category = 'CumulativeUpdate'; Kb = 'KB5048667'; Title = 'LCU'; ReleaseMonth = '2026-11'; IsPreview = $false; IsSuperseded = $false
                CreationDate = [datetime]'2026-11-10'; UpdateId = '00000000-0000-0000-0000-000000000001'; Source = 'MicrosoftUpdateCatalog'; Files = @()
            }
        }
        Mock -ModuleName WindowsIsoServicing Get-CatalogUpdateFile {
            New-TestFile 'windows11.0-kb5043080-x64.msu'
            New-TestFile 'windows11.0-kb5048667-x64.msu'
        }
    }
    It 'resolves Catalog files with checkpoint roles and reports missing components' {
        $plan = InModuleScope WindowsIsoServicing {
            $os = Resolve-WindowsRelease -Build 26100 -InstallationType Client -EditionId Enterprise
            Get-UpdatePlan -OperatingSystem $os -Architecture x64
        }
        $plan.Source | Should -Be 'MicrosoftUpdateCatalog'
        $plan.Updates.Count | Should -Be 1
        @($plan.Updates[0].Files.Role) | Should -Be @('Checkpoint', 'Target')
        $plan.Notes | Should -Contain 'note from the MSRC check'
        $plan.Notes | Should -Contain 'No Safe OS Dynamic Update was found; WinRE will not be serviced.'
        Should -Invoke -ModuleName WindowsIsoServicing Get-CatalogUpdateFile -Times 1 -Exactly -ParameterFilter { $UpdateId -eq '00000000-0000-0000-0000-000000000001' }
    }
    It 'uses only the repository when a repository path is given' {
        $plan = InModuleScope WindowsIsoServicing {
            $os = Resolve-WindowsRelease -Build 26100 -InstallationType Client -EditionId Enterprise
            Get-UpdatePlan -OperatingSystem $os -Architecture x64 -RepositoryPath 'E:\Repository'
        }
        $plan.Source | Should -Be 'Repository:E:\Repository'
        $plan.Notes | Should -Contain 'No applicable cumulative update was found.'
        Should -Invoke -ModuleName WindowsIsoServicing Find-CatalogUpdate -Times 0 -Exactly -Scope It
        Should -Invoke -ModuleName WindowsIsoServicing Assert-CatalogUpdatePlan -Times 0 -Exactly -Scope It
    }
}
