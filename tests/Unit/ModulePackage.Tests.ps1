BeforeAll {
    $script:buildScript = Join-Path $PSScriptRoot '..\..\scripts\Build-ModulePackage.ps1'
    $script:publishScript = Join-Path $PSScriptRoot '..\..\scripts\Publish-ModulePackage.ps1'
    $script:manifestPath = Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1'
    $script:testApiKey = [securestring]::new()
    foreach ($character in 'not-a-real-key'.ToCharArray()) { $script:testApiKey.AppendChar($character) }
    . $script:buildScript
    . $script:publishScript -PackagePath 'unused.nupkg' -ApiKey $script:testApiKey
}

Describe 'Get-ModulePackageVersion' {
    It 'returns <Expected> for ModuleVersion <ModuleVersion> and prerelease <Prerelease>' -ForEach @(
        @{ ModuleVersion = '1.2.3'; Prerelease = $null; Tag = ''; Expected = '1.2.3' }
        @{ ModuleVersion = '1.2.3'; Prerelease = 'beta1'; Tag = ''; Expected = '1.2.3-beta1' }
        @{ ModuleVersion = '1.2.3'; Prerelease = $null; Tag = 'v1.2.3'; Expected = '1.2.3' }
        @{ ModuleVersion = '1.2.3'; Prerelease = 'BETA1'; Tag = 'v1.2.3-beta1'; Expected = '1.2.3-BETA1' }
    ) {
        $manifest = @{ ModuleVersion = $ModuleVersion; PrivateData = @{ PSData = @{ Prerelease = $Prerelease } } }
        (Get-ModulePackageVersion -Manifest $manifest -ReleaseTag $Tag).Version | Should -Be $Expected
    }
    It 'reads a manifest without PrivateData' {
        (Get-ModulePackageVersion -Manifest @{ ModuleVersion = '2.0.0' }).Version | Should -Be '2.0.0'
    }
    It 'refuses ModuleVersion <ModuleVersion>, which is not a three-part version' -ForEach @(
        @{ ModuleVersion = '1.2.3.4' }
        @{ ModuleVersion = '1.2' }
    ) {
        { Get-ModulePackageVersion -Manifest @{ ModuleVersion = $ModuleVersion } } | Should -Throw '*not a three-part semantic version*'
    }
    It 'refuses prerelease label <Prerelease>, which the PowerShell Gallery rejects' -ForEach @(
        @{ Prerelease = 'beta.1' }
        @{ Prerelease = 'beta-1' }
        @{ Prerelease = 'beta+build' }
    ) {
        { Get-ModulePackageVersion -Manifest @{ ModuleVersion = '1.0.0'; PrivateData = @{ PSData = @{ Prerelease = $Prerelease } } } } | Should -Throw '*not accepted by the PowerShell Gallery*'
    }
    It 'refuses release tag <Tag> for version <Version> and names the expected tag' -ForEach @(
        @{ Tag = 'v1.0.1'; Prerelease = $null; Version = '1.0.0' }
        @{ Tag = 'v1.0.0'; Prerelease = 'beta1'; Version = '1.0.0-beta1' }
        @{ Tag = 'v1.0.0-beta1'; Prerelease = $null; Version = '1.0.0' }
    ) {
        $manifest = @{ ModuleVersion = '1.0.0'; PrivateData = @{ PSData = @{ Prerelease = $Prerelease } } }
        { Get-ModulePackageVersion -Manifest $manifest -ReleaseTag $Tag } | Should -Throw "*Tag the release 'v$Version'*"
    }
    It 'refuses <Tag>, which is not a release tag' -ForEach @(
        @{ Tag = '1.0.0' }
        @{ Tag = 'V1.0.0' }
        @{ Tag = 'v1.0' }
        @{ Tag = 'v1.0.0.0' }
        @{ Tag = 'v1.0.0+build5' }
        @{ Tag = 'v1.0.0-beta.1' }
        @{ Tag = 'release-1.0.0' }
    ) {
        { Get-ModulePackageVersion -Manifest @{ ModuleVersion = '1.0.0' } -ReleaseTag $Tag } | Should -Throw "*is not a release tag*'v1.0.0'*"
    }
    It 'accepts a GitHub release whose prerelease flag matches the manifest' -ForEach @(
        @{ Prerelease = $null; Tag = 'v1.0.0'; IsPrerelease = $false }
        @{ Prerelease = 'beta1'; Tag = 'v1.0.0-beta1'; IsPrerelease = $true }
    ) {
        $manifest = @{ ModuleVersion = '1.0.0'; PrivateData = @{ PSData = @{ Prerelease = $Prerelease } } }
        { Get-ModulePackageVersion -Manifest $manifest -ReleaseTag $Tag -ReleaseIsPrerelease $IsPrerelease } | Should -Not -Throw
    }
    It 'refuses a GitHub release marked <Kind> for manifest prerelease <Prerelease>' -ForEach @(
        @{ Prerelease = $null; Tag = 'v1.0.0'; IsPrerelease = $true; Kind = 'a prerelease' }
        @{ Prerelease = 'beta1'; Tag = 'v1.0.0-beta1'; IsPrerelease = $false; Kind = 'a stable release' }
    ) {
        $manifest = @{ ModuleVersion = '1.0.0'; PrivateData = @{ PSData = @{ Prerelease = $Prerelease } } }
        { Get-ModulePackageVersion -Manifest $manifest -ReleaseTag $Tag -ReleaseIsPrerelease $IsPrerelease } | Should -Throw "*marked as $Kind*Set as a pre-release*"
    }
}

Describe 'Get-ManifestProblem' {
    BeforeAll {
        $script:modulePath = Join-Path $TestDrive 'Module'
        $null = New-Item -Path (Join-Path $script:modulePath 'Public') -ItemType Directory -Force
        Set-Content -LiteralPath (Join-Path $script:modulePath 'Public\Get-Thing.ps1') -Value ''
        $script:validManifest = @{
            Author            = 'Author'
            Description       = 'Description'
            FunctionsToExport = @('Get-Thing')
            CmdletsToExport   = @()
            VariablesToExport = @()
            AliasesToExport   = @()
            PrivateData       = @{ PSData = @{ ProjectUri = 'https://github.com/example/project' } }
        }
    }
    It 'accepts the module manifest of this repository' {
        $manifest = Import-PowerShellDataFile -LiteralPath $script:manifestPath
        Get-ManifestProblem -Manifest $manifest -ModulePath (Split-Path $script:manifestPath -Parent) | Should -BeNullOrEmpty
    }
    It 'accepts a complete manifest' {
        Get-ManifestProblem -Manifest $script:validManifest -ModulePath $script:modulePath | Should -BeNullOrEmpty
    }
    It 'reports <Case>' -ForEach @(
        @{ Case = 'a missing description'; Key = 'Description'; Value = ''; Expected = '*no Description*' }
        @{ Case = 'a missing author'; Key = 'Author'; Value = $null; Expected = '*no Author*' }
        @{ Case = 'a wildcard export'; Key = 'FunctionsToExport'; Value = @('*'); Expected = '*wildcard*' }
        @{ Case = 'an export without a Public file'; Key = 'FunctionsToExport'; Value = @('Get-Thing', 'Set-Thing'); Expected = "*'Set-Thing' has no file*" }
        @{ Case = 'no exported functions'; Key = 'FunctionsToExport'; Value = @(); Expected = '*FunctionsToExport is empty*' }
        @{ Case = 'exported cmdlets'; Key = 'CmdletsToExport'; Value = @('*'); Expected = '*CmdletsToExport must be empty*' }
        @{ Case = 'an http project address'; Key = 'PrivateData'; Value = @{ PSData = @{ ProjectUri = 'http://example.com' } }; Expected = '*not an absolute https address*' }
        @{ Case = 'a missing project address'; Key = 'PrivateData'; Value = @{}; Expected = '*not an absolute https address*' }
    ) {
        $manifest = $script:validManifest.Clone()
        $manifest[$Key] = $Value
        @(Get-ManifestProblem -Manifest $manifest -ModulePath $script:modulePath) | Should -BeLike $Expected
    }
}

Describe 'Copy-ModulePackageContent' {
    BeforeAll {
        $script:source = Join-Path $TestDrive 'source\Sample'
        $files = @(
            'Sample.psd1', 'Sample.psm1', 'Public\Get-Sample.ps1', 'Private\Helper.ps1', 'Data\Data.psd1'
            'Public\Get-Sample.ps1.bak', 'Private\Nested\Deep.ps1', 'Resources\oscdimg.exe', 'tests\Sample.Tests.ps1', 'debug.log', '.vscode\settings.json', 'secrets.json'
        )
        foreach ($file in $files) {
            $path = Join-Path $script:source $file
            $null = New-Item -Path (Split-Path $path -Parent) -ItemType Directory -Force
            Set-Content -LiteralPath $path -Value $file
        }
        $script:destination = Join-Path $TestDrive 'stage\Sample'
        $script:copied = @(Copy-ModulePackageContent -SourcePath $script:source -DestinationPath $script:destination -ModuleName 'Sample' -WarningVariable script:packageWarnings -WarningAction SilentlyContinue)
    }
    It 'copies only the runtime files and returns their package paths' {
        $script:copied | Sort-Object | Should -Be @('Data/Data.psd1', 'Private/Helper.ps1', 'Public/Get-Sample.ps1', 'Sample.psd1', 'Sample.psm1')
        @(Get-ChildItem -LiteralPath $script:destination -Recurse -File).Count | Should -Be 5
    }
    It 'warns about every file it leaves out' {
        $script:packageWarnings.Count | Should -Be 7
        ($script:packageWarnings -join "`n") | Should -BeLike "*'secrets.json'*"
        ($script:packageWarnings -join "`n") | Should -BeLike "*'tests/Sample.Tests.ps1'*"
    }
}

Describe 'Assert-VersionPublishable' {
    It 'accepts <Version> when the repository holds <Published>' -ForEach @(
        @{ Version = '1.0.0'; Published = @() }
        @{ Version = '1.0.1'; Published = @('1.0.0') }
        @{ Version = '1.1.0-beta1'; Published = @('1.0.0', '1.0.1') }
        @{ Version = '1.1.0'; Published = @('1.1.0-beta1') }
        @{ Version = '1.1.0-beta2'; Published = @('1.1.0-beta1') }
    ) {
        { Assert-VersionPublishable -Version $Version -PublishedVersion $Published } | Should -Not -Throw
    }
    It 'refuses <Version>, which is already published, with VersionAlreadyPublished' -ForEach @(
        @{ Version = '1.0.0'; Published = @('1.0.0') }
        @{ Version = '1.1.0-BETA1'; Published = @('1.0.0', '1.1.0-beta1') }
    ) {
        { Assert-VersionPublishable -Version $Version -PublishedVersion $Published } | Should -Throw -ErrorId 'VersionAlreadyPublished'
    }
    It 'refuses <Version> below the latest published <Published> with VersionNotGreater' -ForEach @(
        @{ Version = '1.0.0'; Published = @('1.0.1') }
        @{ Version = '1.1.0-beta1'; Published = @('1.1.0') }
        @{ Version = '1.1.0-alpha1'; Published = @('1.1.0-beta1') }
    ) {
        { Assert-VersionPublishable -Version $Version -PublishedVersion $Published } | Should -Throw -ErrorId 'VersionNotGreater'
    }
}

Describe 'Get-PublishedVersion' {
    It 'returns release and prerelease versions as strings' {
        Mock Find-PSResource { [pscustomobject]@{ Version = [version]'1.0.0'; Prerelease = $null }; [pscustomobject]@{ Version = [version]'1.1.0'; Prerelease = 'beta1' } }
        Get-PublishedVersion -Name 'Sample' -Repository 'PSGallery' | Should -Be @('1.0.0', '1.1.0-beta1')
    }
    It 'returns nothing for a module that is not published' {
        Mock Find-PSResource { }
        Get-PublishedVersion -Name 'Sample' -Repository 'PSGallery' | Should -BeNullOrEmpty
    }
    It 'throws instead of returning an empty list when the lookup fails' {
        Mock Find-PSResource { Write-Error -Message 'Response status code does not indicate success: 503' -ErrorId 'HttpRequestCallFailure' }
        { Get-PublishedVersion -Name 'Sample' -Repository 'PSGallery' } | Should -Throw '*unknown whether this version already exists*'
    }
}

Describe 'Package build and publish with a local repository' {
    BeforeAll {
        $script:outputPath = Join-Path $TestDrive 'package'
        $script:build = & $script:buildScript -OutputPath $script:outputPath -InformationAction SilentlyContinue
        $script:repositoryPath = Join-Path $TestDrive 'repository'
        $null = New-Item -Path $script:repositoryPath -ItemType Directory
        $script:repositoryName = "PublishTest-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        Register-PSResourceRepository -Name $script:repositoryName -Uri $script:repositoryPath -Trusted
        $script:manifest = Import-PowerShellDataFile -LiteralPath $script:manifestPath
    }
    AfterAll {
        Unregister-PSResourceRepository -Name $script:repositoryName
    }
    It 'writes the package and a passing build report with its SHA-256' {
        $script:build.validation.passed | Should -BeTrue
        $script:build.version | Should -Be $script:manifest.ModuleVersion
        $script:build.packageFile | Should -Be "WindowsIsoServicing.$($script:manifest.ModuleVersion).nupkg"
        (Get-FileHash -LiteralPath $script:build.packagePath -Algorithm SHA256).Hash | Should -Be $script:build.sha256
        (Get-Content -LiteralPath "$($script:build.packagePath).json" -Raw | ConvertFrom-Json).sha256 | Should -Be $script:build.sha256
    }
    It 'packages the module files and metadata and nothing else' {
        $content = Get-PackageContent -Path $script:build.packagePath
        $content.Id | Should -Be 'WindowsIsoServicing'
        $content.Version | Should -Be $script:manifest.ModuleVersion
        $content.Dependencies | Should -BeNullOrEmpty
        $content.Files | Should -Contain 'WindowsIsoServicing.psd1'
        $content.Files | Where-Object { $_ -like '*.exe' } | Should -BeNullOrEmpty -Because 'oscdimg.exe comes from the Windows ADK, not from the package'
        $content.Files | Where-Object { $_ -notmatch '^(WindowsIsoServicing\.ps[dm]1|(Public|Private)/[^/]+\.ps1|Data/[^/]+\.psd1)$' } | Should -BeNullOrEmpty
        $expectedPublic = @($script:manifest.FunctionsToExport | ForEach-Object { "Public/$_.ps1" })
        @($content.Files | Where-Object { $_ -like 'Public/*' }) | Sort-Object | Should -Be ($expectedPublic | Sort-Object)
    }
    It 'records the clean-process installation and import checks' {
        $passedChecks = @($script:build.validation.checks | Where-Object Passed | ForEach-Object Name)
        $passedChecks | Should -Contain 'InstalledVersion'
        $passedChecks | Should -Contain 'InstalledLocation'
        $passedChecks | Should -Contain 'ExportedFunctions'
        $passedChecks | Should -Contain 'UnchangedDuringValidation'
    }
    It 'records the PowerShell and PSResourceGet versions that built the package' {
        $script:build.builtWith.powerShell | Should -Be ([string]$PSVersionTable.PSVersion)
        $script:build.builtWith.psResourceGet | Should -Be ([string](Get-Command Compress-PSResource).Version)
    }
    It 'refuses a release prerelease flag without a release tag' {
        { & $script:buildScript -OutputPath (Join-Path $TestDrive 'flag-only') -ReleaseIsPrerelease $false -InformationAction SilentlyContinue } | Should -Throw '*needs ReleaseTag*'
    }
    It 'leaves no temporary validation repository registered' {
        Get-PSResourceRepository | Where-Object Name -Like 'PackageValidation-*' | Should -BeNullOrEmpty
    }
    It 'refuses a release tag that differs from the manifest version and writes nothing' {
        $mismatchPath = Join-Path $TestDrive 'mismatch'
        { & $script:buildScript -OutputPath $mismatchPath -ReleaseTag 'v0.0.1' -InformationAction SilentlyContinue } | Should -Throw '*does not match the manifest version*'
        Test-Path -LiteralPath $mismatchPath | Should -BeFalse
    }
    It 'publishes nothing with -WhatIf' {
        $result = & $script:publishScript -PackagePath $script:build.packagePath -ApiKey $script:testApiKey -Repository $script:repositoryName -WhatIf -InformationAction SilentlyContinue
        $result.status | Should -Be 'Validated'
        Get-ChildItem -LiteralPath $script:repositoryPath | Should -BeNullOrEmpty
    }
    It 'publishes the validated file once and refuses the same version again' {
        $result = & $script:publishScript -PackagePath $script:build.packagePath -ApiKey $script:testApiKey -ExpectedSha256 $script:build.sha256 -Repository $script:repositoryName -Confirm:$false -InformationAction SilentlyContinue
        $result.status | Should -Be 'Published'
        $result.listed | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $script:repositoryPath $script:build.packageFile) -Algorithm SHA256).Hash | Should -Be $script:build.sha256
        { & $script:publishScript -PackagePath $script:build.packagePath -ApiKey $script:testApiKey -Repository $script:repositoryName -Confirm:$false -InformationAction SilentlyContinue } | Should -Throw -ErrorId 'VersionAlreadyPublished'
    }
    It 'refuses a package that changed after validation' {
        $folder = Join-Path $TestDrive 'tampered'
        $null = New-Item -Path $folder -ItemType Directory
        Copy-Item -LiteralPath $script:build.packagePath, "$($script:build.packagePath).json" -Destination $folder
        $tampered = Join-Path $folder $script:build.packageFile
        [System.IO.File]::AppendAllText($tampered, ' ')
        { & $script:publishScript -PackagePath $tampered -ApiKey $script:testApiKey -Repository $script:repositoryName -Confirm:$false } | Should -Throw '*changed after validation*'
    }
    It 'refuses a package whose SHA-256 differs from the one the build recorded' {
        { & $script:publishScript -PackagePath $script:build.packagePath -ApiKey $script:testApiKey -ExpectedSha256 ('0' * 64) -Repository $script:repositoryName -Confirm:$false } | Should -Throw '*not the validated build artifact*'
    }
    It 'refuses a package without a build report' {
        $folder = Join-Path $TestDrive 'unreported'
        $null = New-Item -Path $folder -ItemType Directory
        Copy-Item -LiteralPath $script:build.packagePath -Destination $folder
        { & $script:publishScript -PackagePath (Join-Path $folder $script:build.packageFile) -ApiKey $script:testApiKey -Repository $script:repositoryName -Confirm:$false } | Should -Throw '*build report*is missing*'
    }
    It 'refuses a build report that does not record a passed validation' {
        $folder = Join-Path $TestDrive 'failed'
        $null = New-Item -Path $folder -ItemType Directory
        Copy-Item -LiteralPath $script:build.packagePath -Destination $folder
        $report = Get-Content -LiteralPath "$($script:build.packagePath).json" -Raw | ConvertFrom-Json
        $report.validation.passed = $false
        $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $folder "$($script:build.packageFile).json")
        { & $script:publishScript -PackagePath (Join-Path $folder $script:build.packageFile) -ApiKey $script:testApiKey -Repository $script:repositoryName -Confirm:$false } | Should -Throw '*does not record a passed validation*'
    }
    It 'refuses a package folder that holds files other than the package and its report' {
        $folder = Join-Path $TestDrive 'extra'
        $null = New-Item -Path $folder -ItemType Directory
        Copy-Item -LiteralPath $script:build.packagePath, "$($script:build.packagePath).json" -Destination $folder
        Set-Content -LiteralPath (Join-Path $folder 'other.nupkg') -Value 'x'
        { & $script:publishScript -PackagePath (Join-Path $folder $script:build.packageFile) -ApiKey $script:testApiKey -Repository $script:repositoryName -Confirm:$false } | Should -Throw '*not part of the validated build: other.nupkg*'
    }
    It 'refuses a package whose file name does not match its build report' {
        $folder = Join-Path $TestDrive 'renamed'
        $null = New-Item -Path $folder -ItemType Directory
        Copy-Item -LiteralPath $script:build.packagePath -Destination (Join-Path $folder 'WindowsIsoServicing.9.9.9.nupkg')
        Copy-Item -LiteralPath "$($script:build.packagePath).json" -Destination (Join-Path $folder 'WindowsIsoServicing.9.9.9.nupkg.json')
        { & $script:publishScript -PackagePath (Join-Path $folder 'WindowsIsoServicing.9.9.9.nupkg') -ApiKey $script:testApiKey -Repository $script:repositoryName -Confirm:$false } | Should -Throw "*named 'WindowsIsoServicing.9.9.9.nupkg'*"
    }
    It 'refuses an empty API key before reading the package' {
        { & $script:publishScript -PackagePath 'missing.nupkg' -ApiKey ([securestring]::new()) -Repository $script:repositoryName -Confirm:$false } | Should -Throw '*PSGALLERY_API_KEY*'
    }
}
