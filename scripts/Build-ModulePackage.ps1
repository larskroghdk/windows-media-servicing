#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Microsoft.PowerShell.PSResourceGet'; ModuleVersion = '1.1.0' }

<#
.SYNOPSIS
    Builds the module into a validated NuGet package (.nupkg) for the PowerShell Gallery.

.DESCRIPTION
    Finds the module under src (the folder that holds a manifest of the same name), validates the manifest with Test-ModuleManifest and the PowerShell Gallery rules, and takes the version from ModuleVersion and PrivateData.PSData.Prerelease. The version is never changed: with -ReleaseTag, the tag must be 'v<version>', and with -ReleaseIsPrerelease the release's prerelease flag must match the manifest, otherwise the build stops. Only runtime files are staged: the manifest, the root module, Public and Private scripts and Data files. No executables are packaged: oscdimg.exe comes from the Windows ADK on the servicing host. Anything else in the module folder is left out with a warning. Compress-PSResource builds the package in a temporary folder. The package is then checked: the nuspec id, version and dependencies must match the manifest, and the package must hold exactly the staged files. It is installed with Save-PSResource from a temporary local repository, which is registered for the check and unregistered afterwards, and imported in a separate PowerShell process whose PSModulePath holds only the installation folder and the system module folders, so user modules and the source tree cannot satisfy the import. The imported version and exported functions must match the manifest. The package is packed once; its SHA-256 is taken right after packing and must be unchanged after validation and in the copy written to OutputPath, so the reported hash belongs to the file that was validated. Only when every check passes are the package and its build report (<package>.json with name, version, SHA-256, files, tool versions and checks) written to OutputPath, replacing an earlier local build of the same version. Publish-ModulePackage.ps1 publishes only packages with a passing report. No network access is needed.

.PARAMETER OutputPath
    Folder for the package and its build report. Defaults to output\package in the repository, which Git ignores.

.PARAMETER ReleaseTag
    Git tag of the release, for example v1.1.0 or v1.1.0-beta1. The build stops when it does not equal 'v' followed by the manifest version.

.PARAMETER ReleaseIsPrerelease
    Prerelease flag of the GitHub release. The build stops when it does not match whether the manifest has a Prerelease label. Requires ReleaseTag.

.EXAMPLE
    .\scripts\Build-ModulePackage.ps1

.EXAMPLE
    .\scripts\Build-ModulePackage.ps1 -OutputPath 'D:\Packages' -ReleaseTag 'v1.1.0-beta1' -ReleaseIsPrerelease $true

.OUTPUTS
    System.Management.Automation.PSCustomObject with name, version, packagePath, sha256, files, exportedFunctions and validation.

.NOTES
    Author:  Lars Krogh Paulsen
    Version: 1.0.0

.LINK
    https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/compress-psresource

.LINK
    https://learn.microsoft.com/powershell/gallery/concepts/module-prerelease-support
#>

[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'output\package'),
    [ValidateNotNullOrEmpty()]
    [string]$ReleaseTag,
    [Nullable[bool]]$ReleaseIsPrerelease
)

function Get-ModulePackageVersion {
    <#
    .SYNOPSIS
        Returns the package version from a module manifest and checks it against a release tag.

    .DESCRIPTION
        The PowerShell Gallery accepts a prerelease label only on a three-part ModuleVersion, and the label may contain only ASCII letters and digits, without dots or plus signs. The version is ModuleVersion, followed by a hyphen and PrivateData.PSData.Prerelease when there is one. With ReleaseTag, the tag must have the form v<Major>.<Minor>.<Patch> or v<Major>.<Minor>.<Patch>-<label> and name that version; the comparison ignores case, as the Gallery does. With ReleaseIsPrerelease, the prerelease flag of the GitHub release must agree with the manifest: a release marked prerelease needs a Prerelease label, and a stable release must not have one. Throws with the expected tag or setting instead of adjusting either side, because the version must never change silently.

    .PARAMETER Manifest
        Manifest data from Import-PowerShellDataFile.

    .PARAMETER ReleaseTag
        Release tag to compare with, or empty.

    .PARAMETER ReleaseIsPrerelease
        Prerelease flag of the GitHub release, when there is one.

    .EXAMPLE
        Get-ModulePackageVersion -Manifest (Import-PowerShellDataFile -LiteralPath '.\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -ReleaseTag 'v1.0.0' -ReleaseIsPrerelease $false

    .OUTPUTS
        System.Management.Automation.PSCustomObject with ModuleVersion, Prerelease and Version.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Manifest,
        [AllowEmptyString()]
        [string]$ReleaseTag,
        [Nullable[bool]]$ReleaseIsPrerelease
    )
    $moduleVersion = [string]$Manifest['ModuleVersion']
    if ($moduleVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "ModuleVersion '$moduleVersion' is not a three-part semantic version (Major.Minor.Patch). Set ModuleVersion in the manifest; the PowerShell Gallery accepts a prerelease label only on a three-part version."
    }
    $prerelease = [string]$Manifest['PrivateData']?['PSData']?['Prerelease']
    if ($prerelease -and $prerelease -notmatch '^[0-9A-Za-z]+$') {
        throw "Prerelease label '$prerelease' in PrivateData.PSData.Prerelease is not accepted by the PowerShell Gallery. Use ASCII letters and digits only, for example beta1, without dots, hyphens or plus signs."
    }
    $version = if ($prerelease) { "$moduleVersion-$prerelease" } else { $moduleVersion }
    if ($ReleaseTag -and $ReleaseTag -cnotmatch '^v\d+\.\d+\.\d+(-[0-9A-Za-z]+)?$') {
        throw "Release tag '$ReleaseTag' is not a release tag. Use 'v' followed by the manifest version, for example 'v$version'."
    }
    if ($ReleaseTag -and $ReleaseTag.Substring(1) -ne $version) {
        throw "Release tag '$ReleaseTag' does not match the manifest version '$version'. Tag the release 'v$version', or change ModuleVersion and PrivateData.PSData.Prerelease in the manifest and create a new release; the build never changes the version."
    }
    if ($null -ne $ReleaseIsPrerelease -and $ReleaseIsPrerelease -ne [bool]$prerelease) {
        $releaseKind = if ($ReleaseIsPrerelease) { 'a prerelease' } else { 'a stable release' }
        $manifestKind = if ($prerelease) { "the prerelease $version" } else { "the stable version $version" }
        throw "The GitHub release is marked as $releaseKind, but the manifest defines $manifestKind. Make the release's 'Set as a pre-release' setting and PrivateData.PSData.Prerelease agree."
    }
    [pscustomobject]@{
        ModuleVersion = $moduleVersion
        Prerelease    = $prerelease
        Version       = $version
    }
}

function Get-ManifestProblem {
    <#
    .SYNOPSIS
        Reports module manifest settings that the PowerShell Gallery or this package build cannot accept.

    .DESCRIPTION
        Test-ModuleManifest checks that the manifest loads; this adds what the Gallery listing and the package need. Author and Description are required by the Gallery, ProjectUri must be an absolute https address, FunctionsToExport must list names without wildcards, and every exported function must have its own Public\<name>.ps1 file. CmdletsToExport, VariablesToExport and AliasesToExport must be empty, so nothing is exported that the manifest does not name.

    .PARAMETER Manifest
        Manifest data from Import-PowerShellDataFile.

    .PARAMETER ModulePath
        Folder of the module.

    .EXAMPLE
        Get-ManifestProblem -Manifest (Import-PowerShellDataFile -LiteralPath '.\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -ModulePath '.\src\WindowsIsoServicing'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/gallery/concepts/publishing-guidelines
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Manifest,
        [Parameter(Mandatory)]
        [string]$ModulePath
    )
    foreach ($key in 'Author', 'Description') {
        if ([string]::IsNullOrWhiteSpace([string]$Manifest[$key])) {
            "The manifest has no $key; the PowerShell Gallery requires one."
        }
    }
    $projectUri = [string]$Manifest['PrivateData']?['PSData']?['ProjectUri']
    $parsedUri = $null
    if (-not [uri]::TryCreate($projectUri, [System.UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -ne 'https') {
        "PrivateData.PSData.ProjectUri '$projectUri' is not an absolute https address."
    }
    $functions = @($Manifest['FunctionsToExport'])
    if ($functions.Count -eq 0) {
        'FunctionsToExport is empty; the package would export no commands.'
    }
    foreach ($function in $functions) {
        if ([string]$function -match '[*?\[]') {
            "FunctionsToExport entry '$function' is a wildcard; list each function by name."
        }
        elseif (-not (Test-Path -LiteralPath (Join-Path $ModulePath "Public\$function.ps1") -PathType Leaf)) {
            "Exported function '$function' has no file Public\$function.ps1."
        }
    }
    foreach ($key in 'CmdletsToExport', 'VariablesToExport', 'AliasesToExport') {
        if (@($Manifest[$key] | Where-Object { $_ }).Count -gt 0) {
            "$key must be empty; the module exports only the functions it lists."
        }
    }
}

function Copy-ModulePackageContent {
    <#
    .SYNOPSIS
        Copies the runtime files of the module into a staging folder.

    .DESCRIPTION
        The package must contain what the module loads at run time and nothing else, so files are selected by an allow list rather than by excluding known development files: <ModuleName>.psd1 and <ModuleName>.psm1 at the root, *.ps1 directly in Public and Private, and *.psd1 directly in Data. Hidden files are included in the scan so they are reported too. Every other file is left out with a warning that names it. Returns the relative paths of the copied files with forward slashes, as they appear in the package.

    .PARAMETER SourcePath
        Module folder in the repository.

    .PARAMETER DestinationPath
        Staging folder named after the module. It is created when missing.

    .PARAMETER ModuleName
        Name of the module, which is also the file name of its manifest and root module.

    .EXAMPLE
        Copy-ModulePackageContent -SourcePath '.\src\WindowsIsoServicing' -DestinationPath 'C:\Temp\stage\WindowsIsoServicing' -ModuleName 'WindowsIsoServicing'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        [Parameter(Mandatory)]
        [string]$ModuleName
    )
    $runtimeFile = '^({0}\.psd1|{0}\.psm1|Public/[^/]+\.ps1|Private/[^/]+\.ps1|Data/[^/]+\.psd1)$' -f [regex]::Escape($ModuleName)
    $sourceRoot = (Resolve-Path -LiteralPath $SourcePath -ErrorAction Stop).ProviderPath
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
        $relativePath = [System.IO.Path]::GetRelativePath($sourceRoot, $file.FullName) -replace '\\', '/'
        if ($relativePath -notmatch $runtimeFile) {
            Write-Warning "Not packaged: '$relativePath' is not a runtime file of $ModuleName. Remove it from the module folder if it is a leftover."
            continue
        }
        $target = Join-Path $DestinationPath $relativePath
        $null = New-Item -Path (Split-Path $target -Parent) -ItemType Directory -Force
        Copy-Item -LiteralPath $file.FullName -Destination $target -ErrorAction Stop
        $relativePath
    }
}

function Get-PackageContent {
    <#
    .SYNOPSIS
        Reads the nuspec metadata and the payload file list of a .nupkg.

    .DESCRIPTION
        Opens the package as a ZIP archive and returns the id, version and dependency ids from the nuspec at its root, and the paths of all other files except the Open Packaging Conventions parts that NuGet adds ([Content_Types].xml, _rels and package\services). The nuspec is read by local element names, so the result does not depend on the nuspec schema namespace. Throws when the package has no nuspec or more than one at its root.

    .PARAMETER Path
        Path of the .nupkg file.

    .EXAMPLE
        Get-PackageContent -Path '.\output\package\WindowsIsoServicing.1.0.0.nupkg'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Id, Version, Dependencies and Files.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/nuget/reference/nuspec
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $nuspecEntries = @($archive.Entries | Where-Object { $_.FullName -notmatch '/' -and $_.FullName -like '*.nuspec' })
        if ($nuspecEntries.Count -ne 1) {
            throw "Package '$Path' has $($nuspecEntries.Count) nuspec files at its root; a valid package has exactly one."
        }
        $reader = [System.IO.StreamReader]::new($nuspecEntries[0].Open())
        try {
            $nuspec = [xml]$reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        $metadata = $nuspec.DocumentElement.SelectSingleNode("*[local-name()='metadata']")
        $packagingPart = '^(\[Content_Types\]\.xml|_rels/.*|package/.*)$'
        [pscustomobject]@{
            Id           = $metadata.SelectSingleNode("*[local-name()='id']")?.InnerText
            Version      = $metadata.SelectSingleNode("*[local-name()='version']")?.InnerText
            Dependencies = @($metadata.SelectNodes(".//*[local-name()='dependency']") | ForEach-Object { $_.GetAttribute('id') })
            Files        = @($archive.Entries | Where-Object { $_.FullName -notmatch $packagingPart -and $_.FullName -ne $nuspecEntries[0].FullName -and -not $_.FullName.EndsWith('/') } | ForEach-Object { [uri]::UnescapeDataString($_.FullName) })
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Test-ModulePackageInstallation {
    <#
    .SYNOPSIS
        Installs a package from a temporary local repository and imports it in a clean PowerShell process.

    .DESCRIPTION
        Registers the folder that holds the package as a trusted PSResourceGet repository with a unique name, saves the package into InstallPath with Save-PSResource, and always unregisters the repository again, so the user's repository list is left as it was. Dependencies are not resolved from the temporary repository, which holds only this package; the import shows whether they are available. The import runs in a background job, which is a separate pwsh process without profiles, with PSModulePath set to InstallPath and the PowerShell and Windows system module folders only. Returns the version, prerelease label, module folder and exported commands that the clean process sees.

    .PARAMETER PackagePath
        Path of the .nupkg file. Its folder must contain no other packages.

    .PARAMETER ModuleName
        Name of the module.

    .PARAMETER Version
        Package version, including a prerelease label.

    .PARAMETER InstallPath
        Empty folder to install into.

    .EXAMPLE
        Test-ModulePackageInstallation -PackagePath 'C:\Temp\pack\WindowsIsoServicing.1.0.0.nupkg' -ModuleName 'WindowsIsoServicing' -Version '1.0.0' -InstallPath 'C:\Temp\install'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Version, Prerelease, ModuleBase, ExportedFunctions and ExportedCmdlets.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/save-psresource
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,
        [Parameter(Mandatory)]
        [string]$ModuleName,
        [Parameter(Mandatory)]
        [string]$Version,
        [Parameter(Mandatory)]
        [string]$InstallPath
    )
    $repositoryName = "PackageValidation-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Register-PSResourceRepository -Name $repositoryName -Uri (Split-Path $PackagePath -Parent) -Trusted -ErrorAction Stop
    try {
        Save-PSResource -Name $ModuleName -Version $Version -Prerelease -Repository $repositoryName -Path $InstallPath -TrustRepository -SkipDependencyCheck -ErrorAction Stop
    }
    finally {
        Unregister-PSResourceRepository -Name $repositoryName -ErrorAction Stop
    }
    $isolatedModulePath = @($InstallPath, (Join-Path $PSHOME 'Modules'), (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')) -join [System.IO.Path]::PathSeparator
    $job = Start-Job -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $env:PSModulePath = $using:isolatedModulePath
        $module = Import-Module -Name $using:ModuleName -PassThru
        [pscustomobject]@{
            Version           = [string]$module.Version
            Prerelease        = [string]$module.PrivateData['PSData']['Prerelease']
            ModuleBase        = $module.ModuleBase
            ExportedFunctions = @($module.ExportedFunctions.Keys)
            ExportedCmdlets   = @($module.ExportedCmdlets.Keys)
        }
    }
    $job | Receive-Job -Wait -AutoRemoveJob -ErrorAction Stop
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 3.0
    $repositoryRoot = Split-Path $PSScriptRoot -Parent
    $moduleFolders = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$($_.Name).psd1") -PathType Leaf })
    if ($moduleFolders.Count -ne 1) {
        throw "Expected one module folder under src with a manifest of the same name, found $($moduleFolders.Count)."
    }
    $moduleName = $moduleFolders[0].Name
    $modulePath = $moduleFolders[0].FullName
    $manifestPath = Join-Path $modulePath "$moduleName.psd1"
    $null = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $manifestProblems = @(Get-ManifestProblem -Manifest $manifest -ModulePath $modulePath)
    if ($manifestProblems.Count -gt 0) {
        throw "The manifest '$manifestPath' cannot be packaged: $($manifestProblems -join ' ')"
    }
    if ($null -ne $ReleaseIsPrerelease -and -not $ReleaseTag) {
        throw 'ReleaseIsPrerelease describes a GitHub release and needs ReleaseTag.'
    }
    $version = (Get-ModulePackageVersion -Manifest $manifest -ReleaseTag $ReleaseTag -ReleaseIsPrerelease $ReleaseIsPrerelease).Version
    $dependencies = @($manifest['RequiredModules'] | Where-Object { $_ } | ForEach-Object { if ($_ -is [hashtable]) { $_['ModuleName'] } else { [string]$_ } })
    $exportedFunctions = @($manifest['FunctionsToExport'])
    $module = Import-Module -Name $manifestPath -Force -PassThru
    Write-Information "Packaging $moduleName $version from $modulePath" -InformationAction Continue

    $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) "module-package-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $stagingPath = Join-Path $workRoot "stage\$moduleName"
    $packageFolder = Join-Path $workRoot 'package'
    $installPath = Join-Path $workRoot 'install'
    $checks = [System.Collections.Generic.List[object]]::new()
    try {
        $null = New-Item -Path $stagingPath, $packageFolder, $installPath -ItemType Directory -Force
        $files = @(Copy-ModulePackageContent -SourcePath $modulePath -DestinationPath $stagingPath -ModuleName $moduleName)
        $built = Compress-PSResource -Path $stagingPath -DestinationPath $packageFolder -PassThru -ErrorAction Stop
        $sha256 = & $module { Get-FileSha256 -Path $args[0] } $built.FullName
        $content = Get-PackageContent -Path $built.FullName
        $checks.Add([pscustomobject]@{ Name = 'PackageId'; Passed = $content.Id -eq $moduleName; Detail = "nuspec id '$($content.Id)'; manifest '$moduleName'" })
        $checks.Add([pscustomobject]@{ Name = 'PackageVersion'; Passed = $content.Version -eq $version; Detail = "nuspec version '$($content.Version)'; manifest '$version'" })
        $dependencyDifference = @(Compare-Object -ReferenceObject $dependencies -DifferenceObject $content.Dependencies)
        $checks.Add([pscustomobject]@{ Name = 'Dependencies'; Passed = $dependencyDifference.Count -eq 0; Detail = "nuspec '$($content.Dependencies -join ', ')'; manifest RequiredModules '$($dependencies -join ', ')'" })
        $fileDifference = @(Compare-Object -ReferenceObject $files -DifferenceObject $content.Files)
        $checks.Add([pscustomobject]@{ Name = 'PackageFiles'; Passed = $fileDifference.Count -eq 0; Detail = ($fileDifference.Count -eq 0) ? "$($files.Count) runtime files, nothing else." : "Differs from the staged files: $(($fileDifference | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join '; ')" })
        $installed = Test-ModulePackageInstallation -PackagePath $built.FullName -ModuleName $moduleName -Version $version -InstallPath $installPath
        $installedVersion = if ($installed.Prerelease) { "$($installed.Version)-$($installed.Prerelease)" } else { $installed.Version }
        $checks.Add([pscustomobject]@{ Name = 'InstalledVersion'; Passed = $installedVersion -eq $version; Detail = "Imported $installedVersion from $($installed.ModuleBase)" })
        $checks.Add([pscustomobject]@{ Name = 'InstalledLocation'; Passed = $installed.ModuleBase.StartsWith($installPath, [System.StringComparison]::OrdinalIgnoreCase); Detail = "Module loaded from $($installed.ModuleBase); expected under $installPath" })
        $exportDifference = @(Compare-Object -ReferenceObject $exportedFunctions -DifferenceObject @($installed.ExportedFunctions))
        $checks.Add([pscustomobject]@{ Name = 'ExportedFunctions'; Passed = $exportDifference.Count -eq 0 -and $installed.ExportedCmdlets.Count -eq 0; Detail = "Imported module exports $($installed.ExportedFunctions.Count) functions and $($installed.ExportedCmdlets.Count) cmdlets; the manifest lists $($exportedFunctions.Count) functions." })
        $validatedSha256 = & $module { Get-FileSha256 -Path $args[0] } $built.FullName
        $checks.Add([pscustomobject]@{ Name = 'UnchangedDuringValidation'; Passed = $validatedSha256 -eq $sha256; Detail = "SHA-256 after packing $sha256; after validation $validatedSha256" })
        $failed = @($checks | Where-Object { -not $_.Passed })
        if ($failed.Count -gt 0) {
            throw "Package validation failed, nothing was written to '$OutputPath': $(($failed | ForEach-Object { "$($_.Name): $($_.Detail)" }) -join ' | ')"
        }
        $outputFolder = (New-Item -Path $OutputPath -ItemType Directory -Force).FullName
        $packagePath = Join-Path $outputFolder $built.Name
        Copy-Item -LiteralPath $built.FullName -Destination $packagePath -Force -ErrorAction Stop
        $copiedSha256 = & $module { Get-FileSha256 -Path $args[0] } $packagePath
        if ($copiedSha256 -ne $sha256) {
            Remove-Item -LiteralPath $packagePath -Force
            throw "The copy of the package in '$outputFolder' has SHA-256 $copiedSha256, not the validated $sha256. Nothing was written; check the output folder and build again."
        }
        $result = [pscustomobject][ordered]@{
            name              = $moduleName
            version           = $version
            moduleVersion     = [string]$manifest['ModuleVersion']
            prerelease        = [string]$manifest['PrivateData']?['PSData']?['Prerelease']
            releaseTag        = $ReleaseTag
            packageFile       = $built.Name
            packagePath       = $packagePath
            sha256            = $sha256
            sizeBytes         = (Get-Item -LiteralPath $packagePath).Length
            builtAt           = [DateTimeOffset]::Now.ToString('o')
            builtWith         = [ordered]@{
                powerShell    = [string]$PSVersionTable.PSVersion
                psResourceGet = [string](Get-Command Compress-PSResource).Version
            }
            files             = $files
            dependencies      = $dependencies
            exportedFunctions = $exportedFunctions
            validation        = [ordered]@{
                passed = $true
                checks = @($checks)
            }
        }
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$packagePath.json" -Encoding utf8NoBOM
        Write-Information "Package validated: $packagePath (SHA-256 $sha256, $($files.Count) files)" -InformationAction Continue
        $result
    }
    finally {
        try {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "The temporary build folder '$workRoot' could not be removed; delete it by hand: $_"
        }
    }
}
