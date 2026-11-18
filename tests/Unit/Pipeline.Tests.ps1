BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\Invoke-IsoServicingPipeline.ps1') -ConfigurationPath 'unused.json'
}

Describe 'Get-PatchTuesday' {
    It 'returns <Expected> for <Year>-<Month>' -ForEach @(
        @{ Year = 2026; Month = 11; Expected = '2026-11-10' }
        @{ Year = 2026; Month = 12; Expected = '2026-12-08' }
        @{ Year = 2027; Month = 1; Expected = '2027-01-12' }
        @{ Year = 2026; Month = 9; Expected = '2026-09-08' }
        @{ Year = 2024; Month = 10; Expected = '2024-10-08' }
    ) {
        (Get-PatchTuesday -Year $Year -Month $Month).ToString('yyyy-MM-dd') | Should -Be $Expected
    }
}

Describe 'Test-ServicingWindowOpen' {
    It 'opens <DelayDays> days after Patch Tuesday' -ForEach @(
        @{ Date = '2026-11-11'; DelayDays = 2; Expected = $false }
        @{ Date = '2026-11-12'; DelayDays = 2; Expected = $true }
        @{ Date = '2026-11-10'; DelayDays = 0; Expected = $true }
        @{ Date = '2026-11-03'; DelayDays = 0; Expected = $false }
    ) {
        Test-ServicingWindowOpen -Date ([datetime]$Date) -DelayDays $DelayDays | Should -Be $Expected
    }
}

Describe 'Read-PipelineConfiguration' {
    It 'accepts the example configuration' {
        $configuration = Read-PipelineConfiguration -Path (Join-Path $PSScriptRoot '..\..\config\servicing.example.json')
        $configuration.media.Count | Should -BeGreaterThan 0
    }
    It 'accepts a configuration without an update source, which uses the Microsoft Update Catalog' {
        $path = Join-Path $TestDrive 'catalog.json'
        @{ outputPath = 'D:\o'; storePath = 'D:\s'; media = @(@{ name = 'a'; sourceIso = 'D:\a.iso' }) } | ConvertTo-Json -Depth 4 | Set-Content $path
        (Read-PipelineConfiguration -Path $path).PSObject.Properties['updateSource'] | Should -BeNullOrEmpty
    }
    It 'rejects a WSUS update source' {
        $path = Join-Path $TestDrive 'wsus.json'
        @{ outputPath = 'D:\o'; storePath = 'D:\s'; updateSource = @{ wsusServer = 'wsus01' }; media = @() } | ConvertTo-Json | Set-Content $path
        { Read-PipelineConfiguration -Path $path } | Should -Throw '*found: wsusServer*WSUS is not supported*'
    }
}

Describe 'Invoke-Pipeline' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
    }
    It 'reports a media entry as failed and exits with 1 when publishing a created ISO fails' {
        $sourceIso = Join-Path $TestDrive 'source.iso'
        $null = New-Item -Path $sourceIso -ItemType File -Force
        $outputPath = Join-Path $TestDrive 'output'
        $null = New-Item -Path $outputPath -ItemType Directory -Force
        $path = Join-Path $TestDrive 'pipeline.json'
        @{ outputPath = $outputPath; storePath = (Join-Path $TestDrive 'store'); media = @(@{ name = 'server-2025'; sourceIso = $sourceIso }) } | ConvertTo-Json -Depth 4 | Set-Content $path
        Mock Import-Module { }
        Mock Update-WindowsISO { [pscustomobject]@{ Status = 'Created'; IsoPath = 'D:\o\a.iso'; ManifestPath = 'D:\o\a.iso.json'; Plan = [pscustomobject]@{ Updates = @() } } }
        Mock Get-WindowsISOManifest { [pscustomobject]@{ validation = [pscustomobject]@{ bootTest = [pscustomobject]@{ performed = $false } } } }
        Mock Publish-WindowsISO { throw 'The store share is not reachable.' }
        $exitCode = Invoke-Pipeline -ConfigurationPath $path -Force -Date ([datetime]'2026-11-12') 2>$null 6>$null
        $exitCode | Should -Be 1
        $summary = Get-Content -LiteralPath (Join-Path $outputPath 'servicing-summary.json') -Raw | ConvertFrom-Json
        $summary[0].status | Should -Be 'Failed'
        $summary[0].error | Should -BeLike '*store share is not reachable*'
    }
}

Describe 'Find-BaselineManifest' {
    It 'returns the newest published manifest for the same source and index selection' {
        $store = Join-Path $TestDrive 'store'
        foreach ($item in @(
                @{ Key = 'A'; Sha = ('a' * 64); Created = '2026-10-12T00:00:00Z'; Index = @(1) }
                @{ Key = 'B'; Sha = ('a' * 64); Created = '2026-11-12T00:00:00Z'; Index = @(1) }
                @{ Key = 'C'; Sha = ('a' * 64); Created = '2026-12-12T00:00:00Z'; Index = @(2) }
                @{ Key = 'D'; Sha = ('d' * 64); Created = '2026-12-12T00:00:00Z'; Index = @(1) }
            )) {
            $null = New-Item -Path (Join-Path $store $item.Key) -ItemType Directory -Force
            @{
                createdAt = $item.Created; source = @{ sha256 = $item.Sha }
                images = @{ install = @($item.Index | ForEach-Object { @{ index = $_; serviced = $true } }) }
            } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $store "$($item.Key)\latest.json")
        }
        Find-BaselineManifest -StorePath $store -SourceSha256 ('a' * 64) -Index 1 | Should -Be (Join-Path $store 'B\latest.json')
        Find-BaselineManifest -StorePath $store -SourceSha256 ('f' * 64) | Should -BeNullOrEmpty
    }
}
