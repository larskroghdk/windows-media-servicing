#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Microsoft.PowerShell.PSResourceGet'; ModuleVersion = '1.1.0' }

<#
.SYNOPSIS
    Publishes a package built by Build-ModulePackage.ps1 to the PowerShell Gallery, unchanged.

.DESCRIPTION
    Publishes exactly the validated file, never a rebuild. The package must have the build report <package>.json next to it with validation.passed set to true, and the folder must hold nothing else, so an unexpected file in a downloaded artifact is refused. The file name must be <name>.<version>.nupkg from the report, and its SHA-256 must equal the report's. With -ExpectedSha256, which the workflow takes from the build job's outputs rather than from the artifact, it must equal that too, so a package that changed after validation is refused. Before publishing, every version of the module in the repository is read with Find-PSResource, prereleases included. The run stops when the version already exists, because the Gallery never allows a version to be replaced, or when a higher version exists, because the Gallery accepts only versions above the latest. A failed lookup stops the run as well, so a network error is never taken for an empty repository. The package is published with Publish-PSResource -NupkgPath (PSResourceGet 1.1.0 and later), which for a NuGet v2 repository such as the PowerShell Gallery pushes the given file unchanged through NuGet's push API; it does not repack it and, unlike publishing from a module folder, does not check that dependencies exist in the repository. The API key is passed as a SecureString, converted only for that call, and never written to output or logs. Afterwards the script polls Find-PSResource for up to ten minutes, because the Gallery lists a new version only after its own validation; lookup errors while polling are retried and logged as verbose messages. A version that is not listed by then is reported with a warning, not as a failure, because the push was already accepted. -WhatIf runs every check and skips only the publish.

.PARAMETER PackagePath
    Path of the .nupkg file created by Build-ModulePackage.ps1.

.PARAMETER ApiKey
    PowerShell Gallery API key with permission to push the module, as a SecureString.

.PARAMETER ExpectedSha256
    SHA-256 of the package as recorded by the build, to prove that the published file is the validated one.

.PARAMETER Repository
    Name of the registered PSResourceGet repository to publish to. Defaults to PSGallery.

.EXAMPLE
    .\scripts\Publish-ModulePackage.ps1 -PackagePath '.\output\package\WindowsIsoServicing.1.0.0.nupkg' -ApiKey (Read-Host -AsSecureString -Prompt 'PowerShell Gallery API key') -WhatIf

.EXAMPLE
    .\scripts\Publish-ModulePackage.ps1 -PackagePath '.\output\package\WindowsIsoServicing.1.0.0.nupkg' -ApiKey (Read-Host -AsSecureString -Prompt 'PowerShell Gallery API key') -ExpectedSha256 '04e646672113621ff3b4d50bb22e42dd1507e5296cd56b424c15543427f98eb0'

.OUTPUTS
    System.Management.Automation.PSCustomObject with name, version, repository, sha256, status, listed and galleryUri.

.NOTES
    Author:  Lars Krogh Paulsen
    Version: 1.0.0

.LINK
    https://learn.microsoft.com/powershell/module/microsoft.powershell.psresourceget/publish-psresource
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PackagePath,
    [Parameter(Mandatory)]
    [securestring]$ApiKey,
    [ValidatePattern('^[0-9A-Fa-f]{64}$')]
    [string]$ExpectedSha256,
    [ValidateNotNullOrEmpty()]
    [string]$Repository = 'PSGallery'
)

function Get-PublishedVersion {
    <#
    .SYNOPSIS
        Returns every version of a module in a PSResourceGet repository, prereleases included.

    .DESCRIPTION
        Uses Find-PSResource with the version range * and -Prerelease. A module that is not in the repository returns nothing without an error, so any error means that the lookup itself failed (for example HttpRequestCallFailure), and the function throws instead of returning an empty list that would look like a first release. Unlisted Gallery versions are not returned; the Gallery still rejects them on push.

    .PARAMETER Name
        Module name.

    .PARAMETER Repository
        Registered repository name.

    .EXAMPLE
        Get-PublishedVersion -Name 'WindowsIsoServicing' -Repository 'PSGallery'

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
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Repository
    )
    $lookupErrors = $null
    $found = @(Find-PSResource -Name $Name -Version '*' -Prerelease -Repository $Repository -ErrorAction SilentlyContinue -ErrorVariable lookupErrors)
    if ($lookupErrors) {
        throw "Could not read the published versions of $Name from repository '$Repository', so it is unknown whether this version already exists: $($lookupErrors[0]). Check the network connection and the repository, then run again."
    }
    foreach ($resource in $found) {
        $release = '{0}.{1}.{2}' -f $resource.Version.Major, $resource.Version.Minor, [math]::Max($resource.Version.Build, 0)
        if ($resource.Prerelease) { "$release-$($resource.Prerelease)" } else { $release }
    }
}

function Assert-VersionPublishable {
    <#
    .SYNOPSIS
        Throws unless a version can be published next to the versions already in the repository.

    .DESCRIPTION
        The PowerShell Gallery never lets a version be replaced and accepts only a version above the latest one it holds, where a release sorts above its own prereleases (2.5.0 is above 2.5.0-beta). Versions are compared as semantic versions; prerelease labels are compared without regard to case, as the Gallery compares them. The error IDs VersionAlreadyPublished and VersionNotGreater tell the two cases apart.

    .PARAMETER Version
        Version to publish, including a prerelease label.

    .PARAMETER PublishedVersion
        Versions already in the repository.

    .EXAMPLE
        Assert-VersionPublishable -Version '1.1.0-beta1' -PublishedVersion '1.0.0', '1.0.1'

    .OUTPUTS
        None.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/gallery/concepts/module-prerelease-support
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Version,
        [AllowEmptyCollection()]
        [string[]]$PublishedVersion = @()
    )
    $candidate = [semver]$Version.ToLowerInvariant()
    $existing = @($PublishedVersion | ForEach-Object { [semver]$_.ToLowerInvariant() })
    if ($existing -contains $candidate) {
        $exception = [System.InvalidOperationException]::new("Version $Version is already published. Published versions can never be replaced; raise ModuleVersion (or the prerelease label) in the manifest and create a new release.")
        throw [System.Management.Automation.ErrorRecord]::new($exception, 'VersionAlreadyPublished', [System.Management.Automation.ErrorCategory]::ResourceExists, $Version)
    }
    $latest = $existing | Sort-Object -Descending | Select-Object -First 1
    if ($latest -and $latest -gt $candidate) {
        $exception = [System.InvalidOperationException]::new("Version $Version is lower than the published version $latest. The PowerShell Gallery accepts only a version above the latest; raise ModuleVersion in the manifest and create a new release.")
        throw [System.Management.Automation.ErrorRecord]::new($exception, 'VersionNotGreater', [System.Management.Automation.ErrorCategory]::InvalidData, $Version)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 3.0
    if ($ApiKey.Length -eq 0) {
        throw 'The API key is empty. In GitHub Actions, set the secret PSGALLERY_API_KEY; locally, pass the key from the PowerShell Gallery account page.'
    }
    $package = Get-Item -LiteralPath $PackagePath -ErrorAction Stop
    if ($package.Extension -ne '.nupkg') {
        throw "'$($package.FullName)' is not a .nupkg file. Pass the package created by Build-ModulePackage.ps1."
    }
    $reportPath = "$($package.FullName).json"
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw "The build report '$reportPath' is missing, so the package is not known to be validated. Build it with Build-ModulePackage.ps1, which writes the report next to the package."
    }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $name = [string]$report.PSObject.Properties['name']?.Value
    $version = [string]$report.PSObject.Properties['version']?.Value
    $reportedSha256 = [string]$report.PSObject.Properties['sha256']?.Value
    $validationPassed = $report.PSObject.Properties['validation']?.Value?.PSObject.Properties['passed']?.Value -eq $true
    if (-not $name -or -not $version -or -not $reportedSha256 -or -not $validationPassed) {
        throw "The build report '$reportPath' does not record a passed validation with name, version and SHA-256. Build the package again with Build-ModulePackage.ps1."
    }
    if ($package.Name -ne "$name.$version.nupkg") {
        throw "The package file is named '$($package.Name)', but its build report describes $name $version, whose package is '$name.$version.nupkg'. Publish the package together with its own report."
    }
    $unexpectedFiles = @(Get-ChildItem -LiteralPath $package.DirectoryName -Force | Where-Object { $_.Name -notin $package.Name, "$($package.Name).json" } | ForEach-Object Name)
    if ($unexpectedFiles.Count -gt 0) {
        throw "The package folder '$($package.DirectoryName)' holds files that are not part of the validated build: $($unexpectedFiles -join ', '). Publish from a folder that holds only the package and its build report."
    }
    $sha256 = (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sha256 -ne $reportedSha256.ToLowerInvariant()) {
        throw "The SHA-256 of '$($package.FullName)' is $sha256, but the build report records $reportedSha256. The package changed after validation; build it again."
    }
    if ($ExpectedSha256 -and $sha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "The SHA-256 of '$($package.FullName)' is $sha256, but the build recorded $($ExpectedSha256.ToLowerInvariant()). This is not the validated build artifact; nothing was published."
    }
    $null = Get-PSResourceRepository -Name $Repository -ErrorAction Stop
    $publishedVersions = @(Get-PublishedVersion -Name $name -Repository $Repository)
    Assert-VersionPublishable -Version $version -PublishedVersion $publishedVersions
    Write-Information "$name $version is not in '$Repository' yet ($($publishedVersions.Count) other versions); package SHA-256 $sha256" -InformationAction Continue
    $galleryUri = if ($Repository -eq 'PSGallery') { "https://www.powershellgallery.com/packages/$name/$version" } else { $null }
    $status = 'Validated'
    $listed = $false
    if ($PSCmdlet.ShouldProcess("$Repository", "Publish $name $version")) {
        $plainApiKey = [System.Net.NetworkCredential]::new('', $ApiKey).Password
        try {
            Publish-PSResource -NupkgPath $package.FullName -Repository $Repository -ApiKey $plainApiKey -ErrorAction Stop
        }
        catch {
            throw "Publishing $name $version to '$Repository' failed: $($_.Exception.Message) Check that the API key is valid, has not expired and may push $name, and that the version is not already in the repository (unlisted versions count)."
        }
        finally {
            $plainApiKey = $null
        }
        $status = 'Published'
        Write-Information "Pushed $name $version to '$Repository'; waiting until it is listed" -InformationAction Continue
        $deadline = (Get-Date).AddMinutes(10)
        while (-not $listed -and (Get-Date) -lt $deadline) {
            $lookupErrors = $null
            $listed = @(Find-PSResource -Name $name -Version $version -Prerelease -Repository $Repository -ErrorAction SilentlyContinue -ErrorVariable lookupErrors).Count -gt 0
            if ($lookupErrors) {
                Write-Verbose "Lookup of $name $version failed, retrying: $($lookupErrors[0])"
            }
            if (-not $listed) {
                Start-Sleep -Seconds 30
            }
        }
        if (-not $listed) {
            Write-Warning "$name $version was accepted by '$Repository' but is not listed after 10 minutes. The Gallery lists a version after its own validation; check $galleryUri later."
        }
    }
    [pscustomobject][ordered]@{
        name       = $name
        version    = $version
        repository = $Repository
        sha256     = $sha256
        status     = $status
        listed     = $listed
        galleryUri = $galleryUri
    }
}
