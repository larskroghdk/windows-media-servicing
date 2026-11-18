BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'Test-ManifestSchema' {
    It 'accepts a complete manifest' {
        $manifest = New-TestManifest
        InModuleScope WindowsIsoServicing -Parameters @{ Manifest = $manifest } {
            @(Test-ManifestSchema -Manifest $Manifest) | Should -BeNullOrEmpty
        }
    }
    It 'reports <Problem>' -ForEach @(
        @{ Mutation = { param($m) $m.schemaVersion = 2 }; Problem = 'schemaVersion must be 1.' }
        @{ Mutation = { param($m) $m.source.sha256 = 'ABC' }; Problem = 'source.sha256 must be a lowercase SHA-256 hex string.' }
        @{ Mutation = { param($m) $m.output.PSObject.Properties.Remove('fileName') }; Problem = 'output.fileName is required.' }
        @{ Mutation = { param($m) $m.updates[0].kb = '5070000' }; Problem = "updates entry has an invalid kb '5070000'." }
        @{ Mutation = { param($m) $m.images.install = @() }; Problem = 'images.install must list at least one image index.' }
        @{ Mutation = { param($m) $m.validation.passed = 'yes' }; Problem = 'validation.passed must be a boolean.' }
    ) {
        $manifest = New-TestManifest
        & $Mutation $manifest
        InModuleScope WindowsIsoServicing -Parameters @{ Manifest = $manifest; Problem = $Problem } {
            Test-ManifestSchema -Manifest $Manifest | Should -Contain $Problem
        }
    }
}

Describe 'Read-ServicingManifest and Write-ServicingManifest' {
    It 'round-trips a manifest and validates it on read' {
        $path = Join-Path $TestDrive 'manifest.json'
        InModuleScope WindowsIsoServicing -Parameters @{ Manifest = (New-TestManifest); Path = $path } {
            Write-ServicingManifest -Manifest $Manifest -Path $Path -Confirm:$false
            (Read-ServicingManifest -Path $Path).output.fileName | Should -Be $Manifest.output.fileName
        }
    }
    It 'refuses to write an invalid manifest' {
        $manifest = New-TestManifest
        $manifest.output.sha256 = 'not-a-hash'
        $path = Join-Path $TestDrive 'invalid.json'
        InModuleScope WindowsIsoServicing -Parameters @{ Manifest = $manifest; Path = $path } {
            { Write-ServicingManifest -Manifest $Manifest -Path $Path -Confirm:$false } | Should -Throw '*invalid manifest*'
            Test-Path $Path | Should -BeFalse
        }
    }
    It 'fails to read a manifest with a structural problem' {
        $manifest = New-TestManifest
        $manifest.updates = $null
        $path = Join-Path $TestDrive 'broken.json'
        $manifest | ConvertTo-Json -Depth 10 | Set-Content $path
        { Get-WindowsISOManifest -Path $path } | Should -Throw '*updates is required*'
    }
}

Describe 'Get-ManifestUpdateSignature' {
    It 'is independent of KB and index order and KB casing' {
        InModuleScope WindowsIsoServicing {
            $a = Get-ManifestUpdateSignature -SourceSha256 ('A' * 64) -Kb 'KB2', 'kb1' -Index 4, 2
            $b = Get-ManifestUpdateSignature -SourceSha256 ('a' * 64) -Kb 'KB1', 'KB2' -Index 2, 4
            $a | Should -Be $b
        }
    }
    It 'changes when the update set changes' {
        InModuleScope WindowsIsoServicing {
            $a = Get-ManifestUpdateSignature -SourceSha256 ('a' * 64) -Kb 'KB1' -Index 1
            $b = Get-ManifestUpdateSignature -SourceSha256 ('a' * 64) -Kb 'KB2' -Index 1
            $a | Should -Not -Be $b
        }
    }
}
