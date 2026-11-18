BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'Publish-WindowsISO' {
    BeforeEach {
        $store = Join-Path $TestDrive "store-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -Path $store -ItemType Directory
        $script:build = Join-Path $TestDrive "build-$([guid]::NewGuid().ToString('N'))"
    }
    It 'refuses media whose validation did not pass and leaves the latest known-good media in place' {
        $good = New-BuiltIso -Directory $build -Month '2026-10' -Content 'good'
        $null = Publish-WindowsISO -ManifestPath $good -StorePath $store -Confirm:$false
        $bad = New-BuiltIso -Directory $build -Month '2026-11' -Content 'bad' -Passed $false
        { Publish-WindowsISO -ManifestPath $bad -StorePath $store -Confirm:$false } | Should -Throw '*does not record a passed validation*'
        (Get-WindowsISOManifest -StorePath $store -MediaKey 'WindowsServer2025_x64_en-us').output.fileName | Should -Be 'Windows_Server_2025_x64_26100_2026-10.iso'
    }
    It 'refuses an ISO whose checksum does not match its manifest' {
        $manifest = New-BuiltIso -Directory $build -Month '2026-11' -Content 'original'
        Set-Content -LiteralPath ($manifest -replace '\.json$') -Value 'tampered' -NoNewline
        { Publish-WindowsISO -ManifestPath $manifest -StorePath $store -Confirm:$false } | Should -Throw '*does not match its manifest*'
        Test-Path (Join-Path $store 'WindowsServer2025_x64_en-us\latest.json') | Should -BeFalse
    }
    It 'removes the partial copy and leaves latest unchanged when copying to the store fails' {
        $good = New-BuiltIso -Directory $build -Month '2026-10' -Content 'good'
        $null = Publish-WindowsISO -ManifestPath $good -StorePath $store -Confirm:$false
        $next = New-BuiltIso -Directory $build -Month '2026-11' -Content 'next'
        Mock Copy-Item -ModuleName WindowsIsoServicing -ParameterFilter { $Destination -like '*.partial' } { Set-Content -LiteralPath $Destination -Value 'half'; throw 'There is not enough space on the disk.' }
        { Publish-WindowsISO -ManifestPath $next -StorePath $store -Confirm:$false } | Should -Throw '*not enough space*'
        Get-ChildItem $store -Recurse -Filter '*.partial' | Should -BeNullOrEmpty
        (Get-WindowsISOManifest -StorePath $store -MediaKey 'WindowsServer2025_x64_en-us').output.fileName | Should -Be 'Windows_Server_2025_x64_26100_2026-10.iso'
    }
    It 'publishes, replaces latest, rolls back and applies retention' {
        $october = New-BuiltIso -Directory $build -Month '2026-10' -Content 'oct'
        $november = New-BuiltIso -Directory $build -Month '2026-11' -Content 'nov'
        $december = New-BuiltIso -Directory $build -Month '2026-12' -Content 'dec'
        $first = Publish-WindowsISO -ManifestPath $october -StorePath $store -RetainCount 2 -Confirm:$false
        $first.IsRollback | Should -BeFalse
        $null = Publish-WindowsISO -ManifestPath $november -StorePath $store -RetainCount 2 -Confirm:$false
        (Get-WindowsISOManifest -StorePath $store -MediaKey $first.MediaKey).output.fileName | Should -BeLike '*2026-11.iso'
        $rollback = Publish-WindowsISO -ManifestPath "$($first.IsoPath).json" -StorePath $store -RetainCount 2 -Confirm:$false
        $rollback.IsRollback | Should -BeTrue
        (Get-WindowsISOManifest -StorePath $store -MediaKey $first.MediaKey).output.fileName | Should -BeLike '*2026-10.iso'
        $third = Publish-WindowsISO -ManifestPath $december -StorePath $store -RetainCount 2 -Confirm:$false
        $third.Removed | Should -HaveCount 1
        $third.Removed[0] | Should -BeLike '*2026-10'
        (Get-ChildItem (Join-Path $store $first.MediaKey) -Directory).Name | Should -Be @('Windows_Server_2025_x64_26100_2026-11', 'Windows_Server_2025_x64_26100_2026-12')
        (Get-Content (Join-Path $store "$($first.MediaKey)\history.json") -Raw | ConvertFrom-Json).Count | Should -Be 4
    }
    It 'does not publish under -WhatIf' {
        $manifest = New-BuiltIso -Directory $build -Month '2026-11' -Content 'x'
        Publish-WindowsISO -ManifestPath $manifest -StorePath $store -WhatIf
        Get-ChildItem $store | Should -BeNullOrEmpty
    }
}
