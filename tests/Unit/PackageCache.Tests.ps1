BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
}

Describe 'Assert-PackageFileIntegrity' {
    BeforeAll {
        $package = Join-Path $TestDrive 'windows10.0-kb5070000-x64.cab'
        Set-Content -LiteralPath $package -Value 'not a signed package' -NoNewline
        $script:sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    }
    It 'rejects a hash mismatch' {
        InModuleScope WindowsIsoServicing -Parameters @{ Package = $package } {
            { Assert-PackageFileIntegrity -Path $Package -Sha256 ('0' * 64) } | Should -Throw '*SHA-256 mismatch*'
        }
    }
    It 'rejects a file without a Microsoft Authenticode signature even when the hash matches' {
        InModuleScope WindowsIsoServicing -Parameters @{ Package = $package; Sha256 = $sha256 } {
            { Assert-PackageFileIntegrity -Path $Package -Sha256 $Sha256 } | Should -Throw '*Microsoft Authenticode signature*'
        }
    }
}

Describe 'Save-PackageFile' {
    It 'refuses unexpected file names' {
        InModuleScope WindowsIsoServicing -Parameters @{ Cache = $TestDrive } {
            $file = [pscustomobject]@{ Name = '..\evil.exe'; Uri = 'https://example.invalid/x'; Path = $null; Sha1 = $null; Sha256 = $null; Size = 1; Role = 'Package' }
            { Save-PackageFile -File $file -Kb 'KB1' -CachePath $Cache -Confirm:$false } | Should -Throw '*Refusing package file name*'
        }
    }
}
