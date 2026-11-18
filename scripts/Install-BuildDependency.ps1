#Requires -Version 7.4

<#
.SYNOPSIS
    Saves the pinned build and test modules into a folder for CI and packaging.

.DESCRIPTION
    Saves each module at its pinned, tested version from the PowerShell Gallery with Save-PSResource, which ships with PowerShell 7.4 and later, so the legacy PowerShellGet commands (Set-PSRepository, Install-Module) are not used. The pinned versions are PSResourceGet 1.2.0, the first version tested with Publish-PSResource -NupkgPath, Pester 5.6.1 and PSScriptAnalyzer 1.22.0. Put the folder first in PSModulePath: Import-Module by name then loads the pinned versions, also when the runner has newer ones in its own module folders. After saving, the folder must hold exactly the pinned version of each module with a manifest of that version; otherwise the script throws and names the module, so a failed or partial installation stops the job instead of falling back to another version. Returns one object per module.

.PARAMETER Path
    Folder to save the modules into. It is created when missing.

.PARAMETER Name
    Modules to save. Defaults to all of them: Microsoft.PowerShell.PSResourceGet, Pester and PSScriptAnalyzer.

.EXAMPLE
    .\scripts\Install-BuildDependency.ps1 -Path "$env:RUNNER_TEMP\modules"

.EXAMPLE
    .\scripts\Install-BuildDependency.ps1 -Path "$env:RUNNER_TEMP\modules" -Name 'Microsoft.PowerShell.PSResourceGet'

.OUTPUTS
    System.Management.Automation.PSCustomObject with Name, Version and Path.

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
    [ValidateNotNullOrEmpty()]
    [string]$Path,
    [ValidateSet(
        'Microsoft.PowerShell.PSResourceGet',
        'Pester',
        'PSScriptAnalyzer'
    )]
    [string[]]$Name = @('Microsoft.PowerShell.PSResourceGet', 'Pester', 'PSScriptAnalyzer')
)

$script:PinnedModuleVersion = @{
    'Microsoft.PowerShell.PSResourceGet' = '1.2.0'
    'Pester'                             = '5.6.1'
    'PSScriptAnalyzer'                   = '1.22.0'
}

function Save-PinnedModule {
    <#
    .SYNOPSIS
        Saves one module at an exact version and checks the result.

    .DESCRIPTION
        Calls Save-PSResource for the exact version from the PSGallery repository and then checks the module folder: it must contain only the requested version, and that version folder must hold a manifest whose ModuleVersion is the requested one. A leftover version from an earlier run on a self-hosted runner is reported too, because Import-Module would otherwise pick the highest version in the folder. Throws with the module, the version and the cause when saving or the check fails.

    .PARAMETER Name
        Module name.

    .PARAMETER Version
        Exact module version.

    .PARAMETER Path
        Folder to save into.

    .EXAMPLE
        Save-PinnedModule -Name 'Pester' -Version '5.6.1' -Path 'C:\actions\_temp\modules'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Name, Version and Path.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Version,
        [Parameter(Mandatory)]
        [string]$Path
    )
    try {
        Save-PSResource -Name $Name -Version $Version -Repository 'PSGallery' -Path $Path -TrustRepository -ErrorAction Stop
    }
    catch {
        throw "Could not save $Name $Version from the PowerShell Gallery: $($_.Exception.Message) Check network access to www.powershellgallery.com and that version $Version still exists."
    }
    $moduleFolder = Join-Path $Path $Name
    $versions = @(Get-ChildItem -LiteralPath $moduleFolder -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
    if ($versions.Count -ne 1 -or $versions[0] -ne $Version) {
        throw "Expected only $Name $Version in '$moduleFolder', found: $(if ($versions) { $versions -join ', ' } else { 'nothing' }). Empty the folder and run again."
    }
    $manifestPath = Join-Path $moduleFolder "$Version\$Name.psd1"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Saving $Name $Version did not produce the manifest '$manifestPath'."
    }
    $manifestVersion = [string](Import-PowerShellDataFile -LiteralPath $manifestPath)['ModuleVersion']
    if ($manifestVersion -ne $Version) {
        throw "The manifest '$manifestPath' has ModuleVersion '$manifestVersion', not the pinned $Version."
    }
    [pscustomobject]@{
        Name    = $Name
        Version = $Version
        Path    = Split-Path $manifestPath -Parent
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 3.0
    $folder = (New-Item -Path $Path -ItemType Directory -Force).FullName
    foreach ($module in $Name) {
        Save-PinnedModule -Name $module -Version $script:PinnedModuleVersion[$module] -Path $folder
    }
}
