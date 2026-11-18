BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\scripts\Install-BuildDependency.ps1') -Path 'unused'
}

Describe 'Install-BuildDependency' {
    It 'pins every module it installs to an exact version' {
        $script:PinnedModuleVersion.Keys | Sort-Object | Should -Be @('Microsoft.PowerShell.PSResourceGet', 'Pester', 'PSScriptAnalyzer')
        $script:PinnedModuleVersion.Values | ForEach-Object { $_ | Should -Match '^\d+\.\d+\.\d+$' }
        $script:PinnedModuleVersion['Microsoft.PowerShell.PSResourceGet'] | Should -Be '1.2.0'
    }
}

Describe 'Save-PinnedModule' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $script:folder -ItemType Directory
    }
    It 'saves the exact version from the PowerShell Gallery and returns its folder' {
        Mock Save-PSResource { $target = Join-Path $Path "$Name\$Version"; $null = New-Item -Path $target -ItemType Directory -Force; Set-Content -LiteralPath (Join-Path $target "$Name.psd1") -Value "@{ ModuleVersion = '$Version' }" }
        $result = Save-PinnedModule -Name 'Pester' -Version '5.6.1' -Path $script:folder
        $result.Version | Should -Be '5.6.1'
        $result.Path | Should -Be (Join-Path $script:folder 'Pester\5.6.1')
        Should -Invoke Save-PSResource -Times 1 -ParameterFilter { $Name -eq 'Pester' -and $Version -eq '5.6.1' -and $Repository -eq 'PSGallery' -and $TrustRepository }
    }
    It 'fails with the module and version when the Gallery cannot be reached' {
        Mock Save-PSResource { throw 'Response status code does not indicate success: 503.' }
        { Save-PinnedModule -Name 'Pester' -Version '5.6.1' -Path $script:folder } | Should -Throw '*Could not save Pester 5.6.1*503*'
    }
    It 'refuses a folder that also holds another version of the module' {
        Mock Save-PSResource { foreach ($folderVersion in $Version, '5.7.1') { $target = Join-Path $Path "$Name\$folderVersion"; $null = New-Item -Path $target -ItemType Directory -Force; Set-Content -LiteralPath (Join-Path $target "$Name.psd1") -Value "@{ ModuleVersion = '$folderVersion' }" } }
        { Save-PinnedModule -Name 'Pester' -Version '5.6.1' -Path $script:folder } | Should -Throw '*Expected only Pester 5.6.1*5.6.1, 5.7.1*'
    }
    It 'refuses a saved manifest with another ModuleVersion' {
        Mock Save-PSResource { $target = Join-Path $Path "$Name\$Version"; $null = New-Item -Path $target -ItemType Directory -Force; Set-Content -LiteralPath (Join-Path $target "$Name.psd1") -Value "@{ ModuleVersion = '9.9.9' }" }
        { Save-PinnedModule -Name 'Pester' -Version '5.6.1' -Path $script:folder } | Should -Throw "*ModuleVersion '9.9.9', not the pinned 5.6.1*"
    }
}
