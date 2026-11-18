BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'Update-WindowsISO orchestration' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = @{
            Root      = $root
            Source    = Join-Path $root 'source\Windows_Server_2025.iso'
            Output    = Join-Path $root 'output'
            Workspace = Join-Path $root 'workspace'
            Cache     = Join-Path $root 'cache'
            Media     = Join-Path $root 'mounted'
        }
        $null = New-Item -Path (Split-Path $paths.Source), $paths.Output, "$($paths.Media)\sources" -ItemType Directory -Force
        Set-Content -LiteralPath $paths.Source -Value 'source-iso' -NoNewline
        Set-Content -LiteralPath "$($paths.Media)\sources\install.wim" -Value 'wim' -NoNewline
        $previous = Join-Path $paths.Output 'Windows_Server_2025_x64_26100_2026-10.iso'
        Set-Content -LiteralPath $previous -Value 'known-good' -NoNewline
        $paths.Previous = $previous
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Assert-Administrator { }
            Mock Protect-ServicingDirectory { }
            Mock Find-Oscdimg { [pscustomobject]@{ Path = 'C:\oscdimg.exe'; FileVersion = '2.56.0.1010'; AdkVersion = '10.1.28000.3481'; Source = 'Registry (HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots)' } }
            Mock Mount-IsoImage { $Paths.Media }
            Mock Dismount-IsoImage { }
            Mock Get-IsoVolumeLabel { 'SSS_X64FREE_EN-US_DV9' }
            Mock Get-MediaBootConfiguration { [pscustomobject]@{ Bios = $true; Uefi = $true; UefiLoader = 'efi\boot\bootx64.efi'; UefiNoPromptAvailable = $true } }
            Mock Get-InstallImageInventory {
                foreach ($index in 1..2) {
                    [pscustomobject]@{
                        Index = $index; Name = "Edition $index"; EditionId = 'ServerDatacenter'; InstallationType = 'Server'; Architecture = 'x64'
                        Version = [version]'10.0.26100.1742'; Build = 26100; Revision = 1742; Languages = @('en-US'); DefaultLanguage = 'en-US'; SizeBytes = 1MB
                        OperatingSystem = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
                    }
                }
            }
            Mock Get-UpdatePlan {
                $os = Resolve-WindowsRelease -Build 26100 -InstallationType Server -EditionId ServerDatacenter
                [pscustomobject]@{
                    OperatingSystem = $os; Architecture = 'x64'; Source = 'Repository:test'; Notes = @(); GeneratedAt = [DateTimeOffset]::Now
                    Updates = @([pscustomobject]@{
                            Category = 'CumulativeUpdate'; Kb = 'KB5070000'; Title = 'LCU'; ReleaseMonth = '2026-11'; OsBuild = '26100.7171'; UpdateId = $null; IsPreview = $false; Source = 'Repository'
                            Files = @([pscustomobject]@{ Name = 'windows11.0-kb5070000-x64.msu'; Path = 'C:\cache\x.msu'; Size = 1; Role = 'Target'; Sha256 = ('c' * 64); HashSource = 'SHA256' })
                        })
                }
            }
            Mock Assert-FreeSpace { }
            Mock Save-UpdatePackage { $Update }
            Mock New-CumulativeUpdateFolder { 'C:\work\packages\KB5070000\windows11.0-kb5070000-x64.msu' }
            Mock Copy-MediaContent { $null = New-Item -Path (Join-Path $Destination 'sources') -ItemType Directory -Force }
            Mock Update-InstallImage {
                foreach ($index in 1..2) {
                    [pscustomobject][ordered]@{ index = $index; name = "Edition $index"; editionId = 'ServerDatacenter'; serviced = $true; versionBefore = '10.0.26100.1742'; versionAfter = '10.0.26100.7171'; rollupBefore = '26100.1742.1.10'; rollupAfter = '26100.7171.1.10'; winRe = $null; applied = @(); packages = @() }
                }
            }
            Mock Update-BootImage { [pscustomobject]@{ Serviced = $true; Reason = $null; Indexes = @(); SetupFiles = $null } }
            Mock Update-SetupMedia { [pscustomobject]@{ Applied = @(); ReplacedFiles = @() } }
            Mock New-IsoImage { Set-Content -LiteralPath $DestinationPath -Value 'serviced-iso' -NoNewline; $DestinationPath }
            Mock Clear-ServicingMount { }
        }
    }
    It 'publishes nothing to OutputPath when validation fails and keeps the known-good ISO' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Test-IsoStructure { [pscustomobject]@{ type = 'Structural'; passed = $false; sha256 = 'x'; checks = @([pscustomobject]@{ name = 'UefiBootFiles'; status = 'Failed'; detail = 'missing' }) } }
            { Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Confirm:$false } | Should -Throw '*Validation of the serviced ISO failed*UefiBootFiles*'
            Test-Path (Join-Path $Paths.Output 'Windows_Server_2025_x64_26100_2026-11.iso') | Should -BeFalse
            Get-Content -LiteralPath $Paths.Previous -Raw | Should -Be 'known-good'
            Get-Content -LiteralPath $Paths.Source -Raw | Should -Be 'source-iso'
            @(Get-ChildItem -LiteralPath $Paths.Workspace -Directory) | Should -BeNullOrEmpty -Because 'the run workspace is removed'
            @(Get-ChildItem -LiteralPath (Join-Path $Paths.Output 'logs') -Recurse -Filter '*.failed.json') | Should -HaveCount 1
            @(Get-ChildItem -LiteralPath (Join-Path $Paths.Output 'logs') -Recurse -Filter '*.log.jsonl') | Should -HaveCount 1
        }
    }
    It 'cleans up the workspace and keeps the known-good ISO when servicing fails' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Update-InstallImage { throw 'DISM failure 0x800f0922' }

            { Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Confirm:$false } | Should -Throw '*0x800f0922*'
            Should -Invoke Clear-ServicingMount -Times 1
            @(Get-ChildItem -LiteralPath $Paths.Workspace -Directory) | Should -BeNullOrEmpty
            Get-Content -LiteralPath $Paths.Previous -Raw | Should -Be 'known-good'
            Test-Path (Join-Path $Paths.Workspace '.windows-iso-servicing.lock') | Should -BeFalse -Because 'locks are released'
        }
    }
    It 'creates the ISO, manifest and checksum after validation passes' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Test-IsoStructure { [pscustomobject]@{ type = 'Structural'; passed = $true; sha256 = 'x'; checks = @() } }
            $result = Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Confirm:$false
            $result.Status | Should -Be 'Created'
            $result.IsoPath | Should -Be (Join-Path $Paths.Output 'Windows_Server_2025_x64_26100_2026-11.iso')
            Get-Content -LiteralPath $result.IsoPath -Raw | Should -Be 'serviced-iso'
            $manifest = Get-WindowsISOManifest -Path $result.IsoPath
            $manifest.validation.passed | Should -BeTrue
            $manifest.updates.kb | Should -Be 'KB5070000'
            $manifest.output.sha256 | Should -Be (Get-FileHash $result.IsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
            (Get-Content "$($result.IsoPath).sha256") | Should -BeLike "$($manifest.output.sha256) *Windows_Server_2025_x64_26100_2026-11.iso"
            Get-Content -LiteralPath $Paths.Previous -Raw | Should -Be 'known-good'
            $manifest.output.bootModes.uefiNoPrompt | Should -BeTrue
            $manifest.output.bootModes.biosNoPrompt | Should -BeTrue
        }
    }
    It 'refuses UEFI media without efisys_noprompt.bin before servicing' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Get-MediaBootConfiguration { [pscustomobject]@{ Bios = $true; Uefi = $true; UefiLoader = 'efi\boot\bootx64.efi'; UefiNoPromptAvailable = $false } }
            { Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Confirm:$false } | Should -Throw '*efisys_noprompt.bin*'
            Should -Invoke Save-UpdatePackage -Times 0
            Should -Invoke Update-InstallImage -Times 0
            Should -Invoke New-IsoImage -Times 0
        }
    }
    It 'accepts the obsolete -NoBootPrompt with a warning and builds the same ISO' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Test-IsoStructure { [pscustomobject]@{ type = 'Structural'; passed = $true; sha256 = 'x'; checks = @() } }
            Mock Write-ServicingLog { }
            $result = Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -NoBootPrompt -Confirm:$false
            $result.Status | Should -Be 'Created'
            Should -Invoke Write-ServicingLog -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*-NoBootPrompt is obsolete*' }
            Should -Invoke New-IsoImage -Times 1 -ParameterFilter { -not $PSBoundParameters.ContainsKey('NoBootPrompt') }
        }
    }
    It 'returns Unchanged when the baseline manifest has the same source and update set' {
        $baseline = New-TestManifest
        $baseline.source.sha256 = (Get-FileHash $paths.Source -Algorithm SHA256).Hash.ToLowerInvariant()
        $baseline.images.install = @(
            [pscustomobject]@{ index = 1; editionId = 'ServerDatacenter'; serviced = $true; versionAfter = '10.0.26100.7171' }
            [pscustomobject]@{ index = 2; editionId = 'ServerDatacenter'; serviced = $true; versionAfter = '10.0.26100.7171' }
        )
        $baselinePath = Join-Path $paths.Root 'latest.json'
        $baseline | ConvertTo-Json -Depth 10 | Set-Content $baselinePath
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths; Baseline = $baselinePath } {
            $result = Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -BaselineManifestPath $Baseline -Confirm:$false
            $result.Status | Should -Be 'Unchanged'
            Should -Invoke Update-InstallImage -Times 0
        }
    }
    It 'returns NoApplicableUpdates without building' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Get-UpdatePlan { [pscustomobject]@{ OperatingSystem = $null; Architecture = 'x64'; Source = 'Repository:test'; Notes = @('No applicable cumulative update was found.'); Updates = @() } }
            $result = Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Confirm:$false
            $result.Status | Should -Be 'NoApplicableUpdates'
            Should -Invoke New-IsoImage -Times 0
        }
    }
    It 'does not modify anything under -WhatIf' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -WhatIf
            Should -Invoke Save-UpdatePackage -Times 0
            Should -Invoke Update-InstallImage -Times 0
            Test-Path $Paths.Workspace | Should -BeFalse
        }
    }
    It 'refuses to service an explicitly selected out-of-support index' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Get-InstallImageInventory {
                [pscustomobject]@{
                    Index = 1; Name = 'Pro'; EditionId = 'Professional'; InstallationType = 'Client'; Architecture = 'x64'; Version = [version]'10.0.26100.1742'
                    Build = 26100; Revision = 1742; Languages = @('en-US'); DefaultLanguage = 'en-US'; SizeBytes = 1MB
                    OperatingSystem = Resolve-WindowsRelease -Build 26100 -InstallationType Client -EditionId Professional -AsOf ([datetime]'2026-11-18')
                }
            }
            { Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -RepositoryPath $Paths.Root -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Index 1 -Confirm:$false } | Should -Throw -ErrorId 'OutOfSupportMedia*'
        }
    }
}

Describe 'Update-WindowsISO workspace and cache safety' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $paths = @{ Source = Join-Path $root 'Windows_Server_2025.iso'; Output = Join-Path $root 'output'; Workspace = Join-Path $root 'workspace'; Cache = Join-Path $root 'cache' }
        $null = New-Item -Path $root -ItemType Directory -Force
        Set-Content -LiteralPath $paths.Source -Value 'source-iso' -NoNewline
    }
    It 'protects the workspace and the whole cache before the ISO is mounted, and stops when protection refuses' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Assert-Administrator { }
            Mock Find-Oscdimg { [pscustomobject]@{ Path = 'C:\oscdimg.exe'; FileVersion = '2.56.0.1010'; AdkVersion = '10.1.28000.3481'; Source = 'Registry (HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots)' } }
            Mock Protect-ServicingDirectory { } -ParameterFilter { $Path -eq $Paths.Workspace }
            Mock Protect-ServicingDirectory { throw "Refusing to use '$Path'" } -ParameterFilter { $Path -eq $Paths.Cache }
            Mock Mount-IsoImage { throw 'must not be reached' }
            { Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Confirm:$false } | Should -Throw "Refusing to use '$($Paths.Cache)'"
            Should -Invoke Protect-ServicingDirectory -Times 1 -Exactly -ParameterFilter { $Path -eq $Paths.Workspace -and $Check -ne 'All' }
            Should -Invoke Protect-ServicingDirectory -Times 1 -Exactly -ParameterFilter { $Path -eq $Paths.Cache -and $Check -eq 'All' }
            Should -Invoke Mount-IsoImage -Times 0
        }
    }
    It 'refuses to share the cache with a run that holds it' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Assert-Administrator { }
            Mock Protect-ServicingDirectory { }
            Mock Find-Oscdimg { [pscustomobject]@{ Path = 'C:\oscdimg.exe'; FileVersion = '2.56.0.1010'; AdkVersion = '10.1.28000.3481'; Source = 'Registry (HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots)' } }
            Mock Clear-ServicingMount { }
            Mock Mount-IsoImage { throw 'must not be reached' }
            $null = New-Item -Path $Paths.Cache -ItemType Directory -Force
            $held = Lock-Directory -Directory $Paths.Cache
            try {
                { Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Confirm:$false } | Should -Throw "*'$($Paths.Cache)' is locked by another*"
            }
            finally {
                Unlock-Directory -Lock $held
            }
            Should -Invoke Mount-IsoImage -Times 0
            Test-Path -LiteralPath (Join-Path $Paths.Workspace '.windows-iso-servicing.lock') | Should -BeFalse -Because 'the workspace lock is released'
        }
    }
    It 'discards images left mounted by a crashed run, and stops when one cannot be discarded' {
        InModuleScope WindowsIsoServicing -Parameters @{ Paths = $paths } {
            Mock Assert-Administrator { }
            Mock Protect-ServicingDirectory { }
            Mock Find-Oscdimg { [pscustomobject]@{ Path = 'C:\oscdimg.exe'; FileVersion = '2.56.0.1010'; AdkVersion = '10.1.28000.3481'; Source = 'Registry (HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots)' } }
            Mock Clear-ServicingMount { "$Root\20261117-080000-1a2b3c4d\mount\install-1" }
            Mock Mount-IsoImage { throw 'must not be reached' }
            { Update-WindowsISO -SourceISO $Paths.Source -OutputPath $Paths.Output -WorkspacePath $Paths.Workspace -CachePath $Paths.Cache -Confirm:$false } | Should -Throw '*still mounted under the workspace*dism /Cleanup-Mountpoints*'
            Should -Invoke Clear-ServicingMount -Times 1 -Exactly -ParameterFilter { $Root -eq $Paths.Workspace }
            Should -Invoke Mount-IsoImage -Times 0
        }
    }
}

Describe 'Protect-ServicingDirectory' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path "$folder\packages\KB5070000" -ItemType Directory -Force
        Set-Content -LiteralPath "$folder\packages\KB5070000\windows11.0-kb5070000-x64.msu" -Value 'msu'
    }
    It 'restricts a folder the current user owns to SYSTEM and Administrators, with Administrators as owner' {
        InModuleScope WindowsIsoServicing -Parameters @{ Folder = $folder } {
            Mock Set-Acl { }
            Protect-ServicingDirectory -Path $Folder -Check All -Confirm:$false
            Should -Invoke Set-Acl -Times 1 -Exactly -ParameterFilter {
                $sddl = $AclObject.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]'Owner, Access')
                $LiteralPath -eq $Folder -and $AclObject.AreAccessRulesProtected -and $sddl -match '^O:BA' -and $sddl -match '\(A;OICI;FA;;;SY\)' -and $sddl -match '\(A;OICI;FA;;;BA\)' -and @($AclObject.Access).Count -eq 2
            }
        }
    }
    It 'refuses a cached file owned by another user, and changes nothing' {
        InModuleScope WindowsIsoServicing -Parameters @{ Folder = $folder } {
            Mock Set-Acl { }
            Mock Get-Acl { [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($type) [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333-1001') } -PassThru } -ParameterFilter { $LiteralPath -like '*.msu' }
            { Protect-ServicingDirectory -Path $Folder -Check All -Confirm:$false } | Should -Throw '*windows11.0-kb5070000-x64.msu (owner S-1-5-21-1111111111-2222222222-3333333333-1001)*'
            Should -Invoke Set-Acl -Times 0
        }
    }
    It 'checks only the direct children of a workspace' {
        InModuleScope WindowsIsoServicing -Parameters @{ Folder = $folder } {
            Mock Set-Acl { }
            Mock Get-Acl { [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($type) [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333-1001') } -PassThru } -ParameterFilter { $LiteralPath -like '*.msu' }
            Protect-ServicingDirectory -Path $Folder -Confirm:$false
            Should -Invoke Set-Acl -Times 1 -Exactly
        }
    }
    It 'refuses a link inside the folder' {
        $target = New-Item -Path "$folder-target" -ItemType Directory -Force
        $null = New-Item -Path "$folder\redirect" -ItemType Junction -Value $target.FullName
        InModuleScope WindowsIsoServicing -Parameters @{ Folder = $folder } {
            Mock Set-Acl { }
            { Protect-ServicingDirectory -Path $Folder -Confirm:$false } | Should -Throw '*redirect (link)*'
            Should -Invoke Set-Acl -Times 0
        }
    }
    It 'refuses a folder whose parent another user owns' {
        InModuleScope WindowsIsoServicing -Parameters @{ Folder = $folder } {
            Mock Set-Acl { }
            Mock Get-Acl { [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($type) [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1111111111-2222222222-3333333333-1001') } -PassThru } -ParameterFilter { $LiteralPath -eq (Split-Path -Parent $Folder) }
            { Protect-ServicingDirectory -Path $Folder -Confirm:$false } | Should -Throw "*$((Split-Path -Parent $Folder).Replace('\', '?')) (owner S-1-5-21-*"
            Should -Invoke Set-Acl -Times 0
        }
    }
    It 'does not rewrite an access list that is already restricted' {
        InModuleScope WindowsIsoServicing -Parameters @{ Folder = $folder } {
            Mock Set-Acl { }
            Mock Get-Acl { $stored = [System.Security.AccessControl.DirectorySecurity]::new(); $stored.SetSecurityDescriptorSddlForm('O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'); $stored } -ParameterFilter { $LiteralPath -eq $Folder }
            Protect-ServicingDirectory -Path $Folder -Confirm:$false
            Should -Invoke Set-Acl -Times 0
        }
    }
    It 'changes nothing under -WhatIf and leaves network shares to their share permissions' {
        InModuleScope WindowsIsoServicing -Parameters @{ Folder = $folder } {
            Mock Set-Acl { }
            Protect-ServicingDirectory -Path $Folder -WhatIf
            Protect-ServicingDirectory -Path '\\fs01\cache' -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue
            "$warnings" | Should -BeLike '*network share*only administrators can write*'
            Should -Invoke Set-Acl -Times 0
        }
    }
}

Describe 'Lock-Directory' {
    It 'prevents a second lock on the same directory until released' {
        InModuleScope WindowsIsoServicing -Parameters @{ Directory = $TestDrive } {
            $lock = Lock-Directory -Directory $Directory
            try {
                { Lock-Directory -Directory $Directory } | Should -Throw '*locked by another*'
            }
            finally {
                Unlock-Directory -Lock $lock
            }
            $again = Lock-Directory -Directory $Directory
            Unlock-Directory -Lock $again
        }
    }
}

Describe 'Invoke-ExternalTool' {
    It 'returns output for successful exit codes and throws for others' {
        InModuleScope WindowsIsoServicing {
            $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
            (Invoke-ExternalTool -FilePath $cmd -ArgumentList '/c', 'echo hello' -Operation 'Test').StandardOutput | Should -Match 'hello'
            (Invoke-ExternalTool -FilePath $cmd -ArgumentList '/c', 'exit 3' -Operation 'Test' -SuccessExitCodes 0, 3).ExitCode | Should -Be 3
            { Invoke-ExternalTool -FilePath $cmd -ArgumentList '/c', 'exit 5' -Operation 'Test' } | Should -Throw '*Test failed with exit code 5*'
        }
    }
}

Describe 'Resolve-TrustedFilePath' {
    It 'rejects device paths, wildcards, directories and wrong extensions' {
        InModuleScope WindowsIsoServicing -Parameters @{ Directory = $TestDrive } {
            $file = Join-Path $Directory 'media.iso'
            Set-Content -LiteralPath $file -Value 'x'
            Resolve-TrustedFilePath -Path $file -AllowedExtension '.iso' | Should -Be $file
            { Resolve-TrustedFilePath -Path '\\?\C:\media.iso' } | Should -Throw '*Device paths*'
            { Resolve-TrustedFilePath -Path (Join-Path $Directory '*.iso') } | Should -Throw '*Wildcard*'
            { Resolve-TrustedFilePath -Path $Directory } | Should -Throw '*directory*'
            { Resolve-TrustedFilePath -Path $file -AllowedExtension '.wim' } | Should -Throw '*extensions*'
        }
    }
    It 'resolves a relative path against the PowerShell location, not the process directory' {
        $folder = Join-Path $TestDrive 'relative'
        $null = New-Item -Path $folder -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $folder 'media.iso') -Value 'x'
        InModuleScope WindowsIsoServicing -Parameters @{ Folder = $folder } {
            Push-Location -LiteralPath $Folder
            try {
                [System.IO.Directory]::GetCurrentDirectory() | Should -Not -Be $Folder
                Resolve-TrustedFilePath -Path '.\media.iso' -AllowedExtension '.iso' | Should -Be (Join-Path $Folder 'media.iso')
            }
            finally {
                Pop-Location
            }
        }
    }
    It 'rejects paths of other PowerShell providers' {
        InModuleScope WindowsIsoServicing {
            { Resolve-TrustedFilePath -Path 'HKLM:\SOFTWARE\Microsoft' } | Should -Throw '*Registry provider path*'
        }
    }
}

Describe 'Resolve-DirectoryPath' {
    It 'resolves and creates a relative directory under the PowerShell location' {
        InModuleScope WindowsIsoServicing -Parameters @{ Root = $TestDrive } {
            Push-Location -LiteralPath $Root
            try {
                Resolve-DirectoryPath -Path '.\created\output' -Create -Confirm:$false | Should -Be (Join-Path $Root 'created\output')
                Test-Path -LiteralPath (Join-Path $Root 'created\output') -PathType Container | Should -BeTrue
                { Resolve-DirectoryPath -Path '.\missing' } | Should -Throw "*Directory '$(Join-Path $Root 'missing')' does not exist*"
            }
            finally {
                Pop-Location
            }
        }
    }
    It 'rejects paths of other PowerShell providers' {
        InModuleScope WindowsIsoServicing {
            { Resolve-DirectoryPath -Path 'Env:\' } | Should -Throw '*Environment provider path*'
        }
    }
}

Describe 'Undo-ServicingMount' {
    It 'rethrows the servicing error after discarding the image' {
        InModuleScope WindowsIsoServicing {
            Mock Dismount-ServicingImage { }
            Mock Write-ServicingLog { }
            $failure = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('Add-WindowsPackage failed'), 'PackageFailed', 'InvalidOperation', $null)
            { Undo-ServicingMount -MountPath 'C:\mount\winre' -Context ([pscustomobject]@{}) -Failure $failure } | Should -Throw -ErrorId 'PackageFailed'
            Should -Invoke Dismount-ServicingImage -Times 1 -ParameterFilter { $MountPath -eq 'C:\mount\winre' -and -not $Save }
            Should -Invoke Write-ServicingLog -Times 0
        }
    }
    It 'keeps the servicing error and logs the discard failure when the discard also fails' {
        InModuleScope WindowsIsoServicing {
            Mock Dismount-ServicingImage { throw 'The mount point is in use.' }
            Mock Write-ServicingLog { }
            $failure = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('Add-WindowsPackage failed'), 'PackageFailed', 'InvalidOperation', $null)
            { Undo-ServicingMount -MountPath 'C:\mount\winre' -Context ([pscustomobject]@{}) -Failure $failure } | Should -Throw -ErrorId 'PackageFailed'
            Should -Invoke Write-ServicingLog -Times 1 -ParameterFilter { $Level -eq 'Error' -and $Message -like '*mount point is in use*' }
        }
    }
}

Describe 'Assert-FreeSpace' {
    It 'throws when the drive has less free space than required' {
        InModuleScope WindowsIsoServicing -Parameters @{ Directory = $TestDrive } {
            { Assert-FreeSpace -Path $Directory -RequiredBytes ([long]::MaxValue) } | Should -Throw '*Insufficient free space*'
            { Assert-FreeSpace -Path $Directory -RequiredBytes 1 } | Should -Not -Throw
        }
    }
    It 'checks a UNC path against the free space of its share' {
        InModuleScope WindowsIsoServicing {
            Mock Get-AvailableFreeSpace { 5GB }
            { Assert-FreeSpace -Path '\\fs01\iso\Updated' -RequiredBytes 10GB } | Should -Throw '*Insufficient free space on \\fs01\iso: 5?0 GB available*'
            { Assert-FreeSpace -Path '\\fs01\iso\Updated' -RequiredBytes 1GB } | Should -Not -Throw
            Should -Invoke Get-AvailableFreeSpace -Times 2 -ParameterFilter { $Root -eq '\\fs01\iso' }
        }
    }}

Describe 'Update-BootImage' {
    It 'takes the build for the setup files from the per-index image information' {
        $mountRoot = Join-Path $TestDrive 'mount'
        $null = New-Item -Path (Join-Path $mountRoot 'boot-2\sources') -ItemType Directory -Force
        $null = New-Item -Path (Join-Path $mountRoot 'boot-2\sources\setup.exe') -ItemType File
        $context = [pscustomobject]@{ WorkPath = (Join-Path $TestDrive 'work'); MountRoot = $mountRoot; ScratchPath = $TestDrive; LogPath = $TestDrive; CumulativeUpdatePath = 'C:\lcu'; ComponentCleanup = $false }
        InModuleScope WindowsIsoServicing -Parameters @{ Context = $context } {
            Mock Get-WindowsImage { if ($Index) { [pscustomobject]@{ ImageIndex = $Index; Version = '10.0.26100.1'; Build = 26100 } } else { [pscustomobject]@{ ImageIndex = 1; ImageName = 'Microsoft Windows PE' }, [pscustomobject]@{ ImageIndex = 2; ImageName = 'Microsoft Windows Setup' } } }
            Mock Mount-ServicingImage { }
            Mock Dismount-ServicingImage { }
            Mock Add-ServicingPackage { 'Installed' }
            Mock New-AppliedRecord { [pscustomobject]@{ result = $Result } }
            Mock Save-SetupBinary { [pscustomobject]@{ Build = $Build } }
            Mock Export-WindowsImage { }
            Mock Move-Item { }
            $cumulative = [pscustomobject]@{ Category = 'CumulativeUpdate'; Kb = 'KB5070000'; Files = @() }
            $plan = [pscustomobject]@{ OperatingSystem = [pscustomobject]@{ Servicing = [pscustomobject]@{ Model = 'Cumulative'; ServicingStackCombined = $true } }; Updates = @($cumulative) }
            $result = Update-BootImage -BootImagePath 'C:\media\sources\boot.wim' -Plan $plan -Context $Context
            $result.Serviced | Should -BeTrue
            $result.SetupFiles.Build | Should -Be 26100
            $result.Indexes.name | Should -Be @('Microsoft Windows PE', 'Microsoft Windows Setup')
            Should -Invoke Save-SetupBinary -Times 1 -ParameterFilter { $Build -eq 26100 -and $MountPath -like '*boot-2' }
            Should -Invoke Add-ServicingPackage -Times 4
        }
    }
}

Describe 'Test-ErrorHResult' {
    It 'recognizes the documented combined cumulative update error in nested exceptions' {
        InModuleScope WindowsIsoServicing {
            $inner = [System.Runtime.InteropServices.COMException]::new('The specified module could not be found.', -2147024770)
            $record = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new('Add-WindowsPackage failed', $inner), 'x', 'NotSpecified', $null)
            Test-ErrorHResult -ErrorRecord $record -HResult $script:HResultModuleNotFound | Should -BeTrue
            Test-ErrorHResult -ErrorRecord $record -HResult $script:HResultNotApplicable | Should -BeFalse
        }
    }
}

Describe 'Assert-CumulativeUpdateResult' {
    It 'accepts an increased revision and rejects an unchanged one' {
        InModuleScope WindowsIsoServicing {
            $update = [pscustomobject]@{ Kb = 'KB5070000'; OsBuild = '26100.7171' }
            { Assert-CumulativeUpdateResult -Before ([version]'26100.1742.1.10') -After ([version]'26100.7171.1.10') -Update $update -Target 't' } | Should -Not -Throw
            { Assert-CumulativeUpdateResult -Before ([version]'26100.1742.1.10') -After ([version]'26100.1742.1.10') -Update $update -Target 't' } | Should -Throw '*did not change*'
            { Assert-CumulativeUpdateResult -Before ([version]'26100.1742.1.10') -After ([version]'26100.5000.1.10') -Update $update -Target 't' } | Should -Throw '*expected at least 7171*'
            { Assert-CumulativeUpdateResult -Before ([version]'26100.7171.1.10') -After ([version]'26100.7171.1.10') -Update $update -Target 't' } | Should -Not -Throw
            { Assert-CumulativeUpdateResult -Before $null -After $null -Update $update -Target 't' } | Should -Throw '*no installed cumulative update*'
        }
    }
}
