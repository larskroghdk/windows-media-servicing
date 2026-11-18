BeforeDiscovery {
    $configurationPath = $env:WIS_INTEGRATION_CONFIG
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $script:SkipReason = if (-not $configurationPath -or -not (Test-Path -LiteralPath $configurationPath)) {
        'WIS_INTEGRATION_CONFIG is not set or does not exist.'
    }
    elseif (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        'Integration tests require an elevated session.'
    }
    $script:Cases = if (-not $script:SkipReason) {
        @((Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json).cases | ForEach-Object { @{ Case = $_ } })
    }
    else {
        @(@{ Case = [pscustomobject]@{ name = 'not configured' } })
    }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
    if ($env:WIS_INTEGRATION_CONFIG -and (Test-Path -LiteralPath $env:WIS_INTEGRATION_CONFIG)) {
        $configuration = Get-Content -LiteralPath $env:WIS_INTEGRATION_CONFIG -Raw | ConvertFrom-Json
        $repositoryPath = $configuration.PSObject.Properties['updateSource']?.Value?.PSObject.Properties['repositoryPath']?.Value
        $script:sourceParameters = if ($repositoryPath) { @{ RepositoryPath = $repositoryPath } } else { @{} }
    }
}

Describe 'Servicing <Case.name>' -Tag 'Integration' -ForEach $Cases -Skip:([bool]$SkipReason) {
    BeforeAll {
        $output = Join-Path $configuration.outputPath $Case.name
        $null = New-Item -Path $output -ItemType Directory -Force
        $info = Get-WindowsISOInfo -SourceISO $Case.sourceIso -IncludePackages -WorkspacePath $configuration.workspacePath
        $script:sourceHashBefore = $info.Sha256
    }
    It 'identifies the release from the image' {
        $info.OperatingSystem.Key | Should -Be $Case.expectedReleaseKey
        $info.Images.Count | Should -BeGreaterThan 0
    }
    It 'discovers applicable updates including a cumulative update' {
        $plan = Get-WindowsISOInfo -SourceISO $Case.sourceIso -SkipChecksum | Get-WindowsISOUpdates @sourceParameters
        $plan.Updates.Category | Should -Contain 'CumulativeUpdate'
        if ($info.OperatingSystem.Servicing.CheckpointUpdates) {
            ($plan.Updates | Where-Object Category -eq 'CumulativeUpdate').Files.Role | Should -Contain 'Target'
        }
    }
    It 'services, rebuilds and validates the ISO' {
        $parameters = @{
            SourceISO     = $Case.sourceIso
            OutputPath    = $output
            WorkspacePath = $configuration.workspacePath
            CachePath     = $configuration.cachePath
            BootTest      = [bool]$Case.PSObject.Properties['bootTest']?.Value
            EsuEntitled   = [bool]$Case.PSObject.Properties['esuEntitled']?.Value
            Force         = $true
            Confirm       = $false
        }
        if ($Case.PSObject.Properties['index']) { $parameters.Index = @($Case.index) }
        $script:result = Update-WindowsISO @parameters @sourceParameters
        $result.Status | Should -Be 'Created'
        Test-Path -LiteralPath $result.IsoPath | Should -BeTrue
        @(Get-WindowsImage -Mounted | Where-Object Path -like "$($configuration.workspacePath)*") | Should -BeNullOrEmpty
    }
    It 'records an increased cumulative update revision for every serviced index' {
        $manifest = Get-WindowsISOManifest -Path $result.ManifestPath
        foreach ($image in $manifest.images.install | Where-Object serviced) {
            [version]$image.rollupAfter | Should -BeGreaterOrEqual ([version]$image.rollupBefore)
            [version]$image.versionAfter | Should -BeGreaterOrEqual ([version]$image.versionBefore)
        }
    }
    It 'passes deep structural validation of the generated ISO' {
        $validation = Test-WindowsISO -Path $result.IsoPath -Deep -WorkspacePath $configuration.workspacePath
        $failed = @($validation.Structural.checks | Where-Object status -eq 'Failed' | ForEach-Object { "$($_.name): $($_.detail)" })
        $failed | Should -BeNullOrEmpty
        $validation.Passed | Should -BeTrue
        $script:structuralChecks = $validation.Structural.checks
    }
    It 'builds boot entries that do not wait for "Press any key"' {
        $manifest = Get-WindowsISOManifest -Path $result.ManifestPath
        if ($manifest.output.bootModes.uefi) {
            ($structuralChecks | Where-Object name -eq 'UefiBootPrompt').status | Should -Be 'Passed'
        }
        if ($manifest.output.bootModes.bios) {
            ($structuralChecks | Where-Object name -eq 'BiosBootPrompt').status | Should -Be 'Passed'
        }
    }
    It 'leaves the source ISO unchanged' {
        (Get-FileHash -LiteralPath $Case.sourceIso -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $sourceHashBefore
    }
}
