@{
    RootModule           = 'WindowsIsoServicing.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '4f0b6a3e-2c51-4f0e-9d0b-8a6f3d2e7c19'
    Author               = 'Lars Krogh Paulsen'
    CompanyName          = 'larskrogh.dk'
    Copyright            = '(c) Lars Krogh Paulsen. All rights reserved.'
    Description          = 'Offline servicing of Microsoft Windows installation ISO media with DISM and OSCDIMG.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Get-WindowsISOInfo'
        'Get-WindowsISOUpdates'
        'Save-WindowsISOUpdate'
        'Update-WindowsISO'
        'Test-WindowsISO'
        'Get-WindowsISOManifest'
        'Publish-WindowsISO'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Windows', 'DISM', 'ISO', 'Servicing', 'DynamicUpdate', 'MicrosoftUpdateCatalog')
            ProjectUri = 'https://github.com/larskroghdk/windows-media-servicing'
        }
    }
}
