Set-StrictMode -Version 3.0

Import-Module -Name Dism -ErrorAction Stop

$script:ToolVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'WindowsIsoServicing.psd1')).ModuleVersion
$script:OperatingSystemData = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'Data\OperatingSystems.psd1')
$script:LogFilePath = $null

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -File) {
        . $file.FullName
    }
}
