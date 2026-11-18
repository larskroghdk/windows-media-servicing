BeforeDiscovery {
    $manifestPath = Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1'
    $script:publicCommands = @((Import-PowerShellDataFile -LiteralPath $manifestPath).FunctionsToExport | ForEach-Object { @{ Name = $_ } })
    $script:sourceFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing') -Recurse -Include '*.ps1', '*.psm1' -File
    $script:moduleFunctions = @(foreach ($file in $sourceFiles) { $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null); $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { @{ Name = $_.Name; File = $file.Name } } })
}

BeforeAll {
    $manifestPath = Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1'
    $script:module = Import-Module $manifestPath -Force -PassThru
    $script:approvedVerbs = @(Get-Verb | ForEach-Object Verb)
}

Describe 'WindowsIsoServicing module' {
    It 'imports from its manifest with the manifest version' {
        $module.Name | Should -Be 'WindowsIsoServicing'
        $module.Version | Should -Be (Import-PowerShellDataFile -LiteralPath $manifestPath).ModuleVersion
    }
    It 'exports exactly the functions listed in FunctionsToExport' {
        $expected = @((Import-PowerShellDataFile -LiteralPath $manifestPath).FunctionsToExport | Sort-Object)
        @($module.ExportedFunctions.Keys | Sort-Object) | Should -Be $expected
        $module.ExportedAliases.Count | Should -Be 0
        $module.ExportedVariables.Count | Should -Be 0
    }
    It '<Name> in <File> uses an approved verb' -ForEach $moduleFunctions {
        ($Name -split '-', 2)[0] | Should -BeIn $approvedVerbs
    }
}

Describe 'Help for <Name>' -ForEach $publicCommands {
    BeforeAll {
        $script:help = Get-Help -Name $Name -Full
        $script:command = Get-Command -Name $Name -Module WindowsIsoServicing
        $script:commonParameters = [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
    }
    It 'has a synopsis and a description' {
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match "^\s*$Name\s"
        ($help.Description | ForEach-Object Text) -join '' | Should -Not -BeNullOrEmpty
    }
    It 'describes every parameter' {
        foreach ($parameter in $command.Parameters.Keys | Where-Object { $_ -notin $commonParameters }) {
            $described = $help.Parameters.Parameter | Where-Object Name -eq $parameter
            ($described.Description | ForEach-Object Text) -join '' | Should -Not -BeNullOrEmpty -Because "-$parameter must be documented"
        }
    }
    It 'has at least one single-line example that calls the command' {
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
        foreach ($example in $help.Examples.Example) {
            $example.Code.Trim() | Should -Not -Match '\r?\n'
            $example.Code | Should -Match ([regex]::Escape($Name))
        }
    }
    It 'documents outputs and authorship' {
        $help.ReturnValues | Should -Not -BeNullOrEmpty
        ($help.AlertSet | Out-String) | Should -Match 'Author:\s+Lars Krogh Paulsen'
        ($help.AlertSet | Out-String) | Should -Match 'Version:\s+\d+\.\d+\.\d+'
    }
}
