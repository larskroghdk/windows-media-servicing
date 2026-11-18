#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the repository quality gate: Lint, Typecheck, Test, or All.

.DESCRIPTION
    Lint       PSScriptAnalyzer and the forbidden-pattern checks listed in INVARIANTS.md on src, scripts and tests\live, no nested
               functions, complete comment-based help, no comments other than #Requires and help, no command that
               continues on the next line (src, scripts and tests), and the agent skill definitions (.agents/skills
               and their .claude/skills adapters).
    Typecheck  Parses every PowerShell file without errors and validates the module manifest.
    Test       Pester unit tests (tests\Unit).
    Requires PowerShell 7.4 or later, PSScriptAnalyzer for Lint, and Pester 5.5 or later (5.x) for Test. The unit
    tests mock DISM, Hyper-V and network access, so the gate runs without elevation or network. The script changes
    nothing in the repository; only Test with -TestResultPath writes a file.

.PARAMETER Task
    Stage to run: Lint, Typecheck, Test or All. Defaults to All, which runs the stages in that order.

.PARAMETER TestResultPath
    Path of a JUnit XML file for the Test stage results, for CI test reporting.

.EXAMPLE
    .\scripts\Invoke-QualityGate.ps1 -Task All

.EXAMPLE
    .\scripts\Invoke-QualityGate.ps1 -Task Test -TestResultPath '.\TestResults.xml'

.OUTPUTS
    None. Findings and results go to the information stream and the Pester output. A failing stage throws, so
    pwsh -File exits with code 1.

.NOTES
    Author:  Lars Krogh Paulsen
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [ValidateSet('Lint', 'Typecheck', 'Test', 'All')]
    [string]$Task = 'All',
    [string]$TestResultPath
)

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$sourceFolders = @((Join-Path $root 'src'), (Join-Path $root 'scripts'))
$analyzedFolders = $sourceFolders + (Join-Path $root 'tests\live')

function Invoke-Lint {
    <#
    .SYNOPSIS
        Runs the Lint stage of the quality gate.

    .DESCRIPTION
        Runs PSScriptAnalyzer on src, scripts and tests\live with PSScriptAnalyzerSettings.psd1, the forbidden-pattern checks of
        INVARIANTS.md, and the nested-function, comment-based help, formatting and skill definition checks. Writes every
        finding to the information stream and throws with the counts when there is any.

    .EXAMPLE
        Invoke-Lint

    .OUTPUTS
        None. Results go to the information stream.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/overview
    #>
    [CmdletBinding()]
    param()
    $failures = @($analyzedFolders | ForEach-Object {
            Invoke-ScriptAnalyzer -Path $_ -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1')
        })
    $failures | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String | Write-Information -InformationAction Continue
    $forbidden = @(
        @{ Pattern = '[''"]/ResetBase'; Reason = 'component cleanup must not use /ResetBase' }
        @{ Pattern = 'catalog\.update\.microsoft\.com|DownloadDialog\.aspx|ScopedViewInline\.aspx'; Reason = 'Microsoft Update Catalog access belongs in Private\MicrosoftUpdateCatalog.ps1 only'; AllowedIn = 'src\WindowsIsoServicing\Private\MicrosoftUpdateCatalog.ps1' }
        @{ Pattern = 'UpdateServices|IUpdateSearcher|Microsoft\.Update\.(Session|ServiceManager)|wuapi|wsusscn2'; Reason = 'updates come from the Microsoft Update Catalog, never from WSUS or the host''s Windows Update Agent' }
        @{ Pattern = '\bTODO\b|\bFIXME\b'; Reason = 'no TODOs in production code' }
        @{ Pattern = 'SuppressMessageAttribute\((?![^)]*Justification\s*=\s*''[^'']+'')'; Reason = 'analyzer suppressions require a justification' }
    )
    $scanned = Get-ChildItem -Path $analyzedFolders -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File | Where-Object FullName -NE $PSCommandPath
    $violations = foreach ($file in $scanned) {
        foreach ($rule in $forbidden) {
            if ($rule.AllowedIn -and $file.FullName -eq (Join-Path $root $rule.AllowedIn)) { continue }
            foreach ($match in Select-String -LiteralPath $file.FullName -Pattern $rule.Pattern) {
                "$($file.FullName):$($match.LineNumber): $($rule.Reason)"
            }
        }
    }
    $violations | Write-Information -InformationAction Continue
    $nested = @(Get-NestedFunctionProblem)
    $nested | Write-Information -InformationAction Continue
    $helpProblems = @(Get-HelpProblem)
    $helpProblems | Write-Information -InformationAction Continue
    $formattingProblems = @(Get-FormattingProblem)
    $formattingProblems | Write-Information -InformationAction Continue
    $skillProblems = @(Get-SkillDefinitionProblem)
    $skillProblems | Write-Information -InformationAction Continue
    if ($failures.Count -gt 0 -or @($violations).Count -gt 0 -or $nested.Count -gt 0 -or $helpProblems.Count -gt 0 -or $formattingProblems.Count -gt 0 -or $skillProblems.Count -gt 0) {
        throw "Lint failed: $($failures.Count) analyzer findings, $(@($violations).Count) invariant violations, $($nested.Count) nested functions, $($helpProblems.Count) help problems, $($formattingProblems.Count) formatting problems, $($skillProblems.Count) skill definition problems."
    }
    Write-Information 'Lint passed.' -InformationAction Continue
}

function Get-FormattingProblem {
    <#
    .SYNOPSIS
        Reports comments and commands that span lines in src, scripts and tests.

    .DESCRIPTION
        Tokenizes every .ps1, .psm1 and .psd1 file. Comments are reported, except #Requires statements and
        comment-based help blocks (those containing .SYNOPSIS). A line continuation (backtick), or a pipe or binary
        operator at the end of a line, is reported as a command continued on the next line. Multi-line hashtables,
        script block bodies and here-strings are allowed. In comment-based help, sections are separated by exactly one
        blank line and there are no blank lines inside a section, so descriptions read as one paragraph.

    .EXAMPLE
        Get-FormattingProblem

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $binaryOperator = [System.Management.Automation.Language.TokenFlags]::BinaryOperator
    foreach ($file in Get-ChildItem -Path ($sourceFolders + (Join-Path $root 'tests')) -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File) {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        for ($position = 0; $position -lt $tokens.Count; $position++) {
            $token = $tokens[$position]
            $location = "$($file.FullName):$($token.Extent.StartLineNumber)"
            if ($token.Kind -eq 'Comment' -and $token.Text -notmatch '^#Requires\b' -and $token.Text -notmatch '(?m)^\s*\.SYNOPSIS\b') {
                "${location}: comments are not allowed; only #Requires and comment-based help."
            }
            if ($token.Kind -eq 'Comment' -and $token.Text -match '(?m)^\s*\.SYNOPSIS\b') {
                $helpLines = $token.Text -split '\r?\n'
                for ($index = 1; $index -lt $helpLines.Count; $index++) {
                    $isKeyword = $helpLines[$index] -match '^\s*\.[A-Z]+\b'
                    $isBlank = -not $helpLines[$index].Trim()
                    $previousBlank = -not $helpLines[$index - 1].Trim()
                    $helpLocation = "$($file.FullName):$($token.Extent.StartLineNumber + $index)"
                    if ($isKeyword -and $helpLines[$index] -notmatch '^\s*\.SYNOPSIS\b' -and -not $previousBlank) {
                        "${helpLocation}: separate help sections with one blank line."
                    }
                    if ($isBlank -and ($index + 1 -ge $helpLines.Count -or $helpLines[$index + 1] -notmatch '^\s*\.[A-Z]+\b')) {
                        "${helpLocation}: blank lines are allowed only between help sections."
                    }
                }
            }
            $isOperator = $token.Kind -ne 'Generic' -and ($token.Kind -eq 'Pipe' -or ($token.TokenFlags -band $binaryOperator))
            if ($token.Kind -eq 'LineContinuation' -or ($isOperator -and $tokens[$position + 1].Kind -eq 'NewLine')) {
                "${location}: a command continues on the next line; keep each command on one line."
            }
        }
    }
}

function Get-HelpProblem {
    <#
    .SYNOPSIS
        Reports missing or incomplete comment-based help in src, scripts and tests.

    .DESCRIPTION
        Checks the help of every function in .ps1 and .psm1 files, and the script-level help of the scripts directly in tests\live and
        the scripts folder, with Get-CommentHelpProblem.

    .EXAMPLE
        Get-HelpProblem

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $files = Get-ChildItem -Path ($sourceFolders + (Join-Path $root 'tests')) -Recurse -Include '*.ps1', '*.psm1' -File
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($file.DirectoryName -in (Join-Path $root 'scripts'), (Join-Path $root 'tests\live')) {
            $script = @{ Help = $ast.GetHelpContent(); Name = $file.Name; Parameter = $ast.ParamBlock.Parameters; Location = "$($file.FullName):1" }
            Get-CommentHelpProblem @script
        }
        foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $definition = @{
                Help      = $function.GetHelpContent()
                Name      = $function.Name
                Parameter = $function.Body.ParamBlock.Parameters
                Location  = "$($file.FullName):$($function.Extent.StartLineNumber)"
            }
            Get-CommentHelpProblem @definition
        }
    }
}

function Get-CommentHelpProblem {
    <#
    .SYNOPSIS
        Checks one comment-based help block for completeness.

    .DESCRIPTION
        Requires .SYNOPSIS, .DESCRIPTION, a .PARAMETER for each declared parameter and none for undeclared ones, at least
        one .EXAMPLE, .OUTPUTS, and .NOTES with 'Author:' and 'Version:' lines. Each example must be a single command line,
        without blank lines or remarks, because Get-Help shows text without a blank line as part of the code. The line
        must parse, must call the function or script, and may use only its parameters, aliases and the common
        parameters.

    .PARAMETER Help
        Help content from GetHelpContent(), or $null when there is none.

    .PARAMETER Name
        Function name, or the file name of a script.

    .PARAMETER Parameter
        Declared parameters from the param block.

    .PARAMETER Location
        '<file>:<line>' prefix of the messages.

    .EXAMPLE
        Get-CommentHelpProblem -Help $function.GetHelpContent() -Name $function.Name -Parameter $function.Body.ParamBlock.Parameters -Location "$($file.FullName):$($function.Extent.StartLineNumber)"

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_comment_based_help
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [System.Management.Automation.Language.CommentHelpInfo]$Help,
        [Parameter(Mandatory)]
        [string]$Name,
        [AllowNull()]
        [System.Management.Automation.Language.ParameterAst[]]$Parameter,
        [Parameter(Mandatory)]
        [string]$Location
    )
    if (-not $Help) { return "${Location}: $Name has no comment-based help." }
    $declared = @($Parameter | ForEach-Object { $_.Name.VariablePath.UserPath })
    $accepted = $declared + @($Parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Alias' } | ForEach-Object { $_.PositionalArguments.Value }) + [System.Management.Automation.Cmdlet]::CommonParameters + [System.Management.Automation.Cmdlet]::OptionalCommonParameters
    foreach ($section in 'Synopsis', 'Description') {
        if ([string]::IsNullOrWhiteSpace($Help.$section)) { "${Location}: $Name help has no .$($section.ToUpperInvariant())." }
    }
    foreach ($parameterName in $declared) {
        if ([string]::IsNullOrWhiteSpace($Help.Parameters[$parameterName.ToUpperInvariant()])) { "${Location}: $Name help does not describe -$parameterName." }
    }
    foreach ($documented in $Help.Parameters.Keys) {
        if ($documented -notin $declared) { "${Location}: $Name help describes -$documented, which is not a parameter." }
    }
    if ($Help.Examples.Count -eq 0) { "${Location}: $Name help has no .EXAMPLE." }
    if ($Help.Outputs.Count -eq 0) { "${Location}: $Name help has no .OUTPUTS." }
    if ($Help.Notes -notmatch '(?m)^\s*Author:\s+\S' -or $Help.Notes -notmatch '(?m)^\s*Version:\s+\d+\.\d+\.\d+') {
        "${Location}: $Name help .NOTES must contain 'Author:' and 'Version:' lines."
    }
    foreach ($example in $Help.Examples) {
        $code = $example.Trim()
        if ($code -match '\r?\n') {
            "${Location}: $Name example must be a single command line without blank lines or remarks."
            continue
        }
        $exampleTokens = $null
        $exampleErrors = $null
        $exampleAst = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$exampleTokens, [ref]$exampleErrors)
        if ($exampleErrors) {
            "${Location}: $Name example does not parse: $($exampleErrors[0].Message)"
            continue
        }
        $calls = $exampleAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and [System.IO.Path]::GetFileNameWithoutExtension([string]$node.GetCommandName()) -eq [System.IO.Path]::GetFileNameWithoutExtension($Name) }, $true)
        if (-not $calls -and $code -notmatch [regex]::Escape([System.IO.Path]::GetFileNameWithoutExtension($Name))) {
            "${Location}: $Name example does not call $Name."
        }
        foreach ($argument in $calls.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }) {
            if ($argument.ParameterName -notin $accepted) { "${Location}: $Name example uses -$($argument.ParameterName), which is not a parameter." }
        }
    }
}

function Get-NestedFunctionProblem {
    <#
    .SYNOPSIS
        Reports nested functions and script-block helpers in src, scripts and tests.

    .DESCRIPTION
        Reports every function that is not declared at the top level of its file, and every script block with a param
        block that is assigned to a variable, which acts as a hidden local function (INVARIANTS.md, Code #3).

    .EXAMPLE
        Get-NestedFunctionProblem

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $folders = $sourceFolders + (Join-Path $root 'tests')
    foreach ($file in Get-ChildItem -Path $folders -Recurse -Include '*.ps1', '*.psm1' -File) {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($function in $functions) {
            if ($function.Parent.Parent -ne $ast) {
                "$($file.FullName):$($function.Extent.StartLineNumber): function '$($function.Name)' must be declared at the top level of the file."
            }
        }
        $helpers = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and $node.Right.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and $node.Right.Expression.ScriptBlock.ParamBlock
            }, $true)
        foreach ($helper in $helpers) {
            "$($file.FullName):$($helper.Extent.StartLineNumber): script block assigned to $($helper.Left.Extent.Text) acts as a nested function; declare a top-level function."
        }
    }
}

function Get-SkillFrontmatter {
    <#
    .SYNOPSIS
        Reads the YAML frontmatter fields of a skill file.

    .DESCRIPTION
        Returns the 'key: value' lines between the opening and closing '---' lines as a hashtable, or $null when the file
        has no frontmatter. Only single-line scalar values are read, which is all the skill definitions use.

    .PARAMETER Path
        Path of a SKILL.md file.

    .EXAMPLE
        Get-SkillFrontmatter -Path '.\.agents\skills\senior-powershell-developer\SKILL.md'

    .OUTPUTS
        System.Collections.Hashtable

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -lt 3 -or $lines[0] -ne '---') { return $null }
    $end = [array]::IndexOf($lines, '---', 1)
    if ($end -lt 0) { return $null }
    $fields = @{}
    foreach ($line in $lines[1..($end - 1)]) {
        if ($line -match '^([a-z][a-z0-9_-]*):\s*(.*)$') { $fields[$Matches[1]] = $Matches[2].Trim() }
    }
    $fields
}

function Get-SkillDefinitionProblem {
    <#
    .SYNOPSIS
        Reports problems in the agent skill definitions.

    .DESCRIPTION
        Each skill in .agents\skills must have frontmatter whose name equals its folder name and is lowercase words joined
        by hyphens, and a plain single-line description of at most 1024 characters. Each must have a Claude Code adapter
        in .claude\skills with the same name and description that points to the skill file, and no adapter may lack a
        skill. Relative Markdown links in the skill files must resolve.

    .EXAMPLE
        Get-SkillDefinitionProblem

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $canonicalRoot = Join-Path $root '.agents\skills'
    $adapterRoot = Join-Path $root '.claude\skills'
    $canonical = @(Get-ChildItem -LiteralPath $canonicalRoot -Directory -ErrorAction Stop | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
    if ($canonical.Count -eq 0) {
        return "No skills found under $canonicalRoot."
    }
    foreach ($skill in $canonical) {
        $path = Join-Path $skill.FullName 'SKILL.md'
        $frontmatter = Get-SkillFrontmatter -Path $path
        if (-not $frontmatter) {
            "${path}: missing YAML frontmatter delimited by '---' lines."
            continue
        }
        $name = $frontmatter['name']
        $description = $frontmatter['description']
        if ($name -ne $skill.Name) {
            "${path}: name '$name' must equal the folder name '$($skill.Name)'."
        }
        if ($name -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$' -or $name.Length -gt 64) {
            "${path}: name must be lowercase words joined by hyphens, at most 64 characters."
        }
        if (-not $description) {
            "${path}: description is required."
        }
        elseif ($description.Length -gt 1024) {
            "${path}: description is $($description.Length) characters; the limit is 1024."
        }
        elseif ($description -match ': | #|^[''"\[{>|*&!%@`]') {
            "${path}: description must be a plain single-line YAML scalar (no ': ', ' #' or leading indicator characters)."
        }
        $adapter = Join-Path $adapterRoot "$($skill.Name)\SKILL.md"
        if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) {
            "${adapter}: missing Claude Code adapter for $($skill.Name)."
            continue
        }
        $adapterFrontmatter = Get-SkillFrontmatter -Path $adapter
        if (-not $adapterFrontmatter -or $adapterFrontmatter['name'] -ne $name -or $adapterFrontmatter['description'] -ne $description) {
            "${adapter}: name and description must match $path exactly."
        }
        if (-not (Select-String -LiteralPath $adapter -SimpleMatch ".agents/skills/$($skill.Name)/SKILL.md" -Quiet)) {
            "${adapter}: must point to .agents/skills/$($skill.Name)/SKILL.md."
        }
    }
    foreach ($adapter in @(Get-ChildItem -LiteralPath $adapterRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($adapter.Name -notin $canonical.Name) {
            "$($adapter.FullName): adapter has no canonical skill in $canonicalRoot."
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $canonicalRoot -Recurse -Filter '*.md' -File) {
        foreach ($match in Select-String -LiteralPath $file.FullName -Pattern '\]\(([^)#\s]+)(#[^)]*)?\)' -AllMatches) {
            foreach ($link in $match.Matches) {
                $target = $link.Groups[1].Value
                if ($target -match '^[a-z]+:') {
                    continue
                }
                if (-not (Test-Path -LiteralPath (Join-Path $file.DirectoryName $target))) {
                    "$($file.FullName):$($match.LineNumber): broken link '$target'."
                }
            }
        }
    }
}

function Invoke-Typecheck {
    <#
    .SYNOPSIS
        Runs the Typecheck stage of the quality gate.

    .DESCRIPTION
        Parses every .ps1, .psm1 and .psd1 file in the repository, outside .git, and validates the module manifest with
        Test-ModuleManifest. Throws when a file has parse errors.

    .EXAMPLE
        Invoke-Typecheck

    .OUTPUTS
        None. Results go to the information stream.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param()
    $errors = foreach ($file in Get-ChildItem -Path $root -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File | Where-Object FullName -NotMatch '\\\.git\\') {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in $parseErrors) {
            "$($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)"
        }
    }
    $errors | Write-Information -InformationAction Continue
    $null = Test-ModuleManifest -Path (Join-Path $root 'src\WindowsIsoServicing\WindowsIsoServicing.psd1')
    if (@($errors).Count -gt 0) {
        throw "Typecheck failed: $(@($errors).Count) parse errors."
    }
    Write-Information 'Typecheck passed.' -InformationAction Continue
}

function Invoke-Test {
    <#
    .SYNOPSIS
        Runs the Test stage of the quality gate.

    .DESCRIPTION
        Runs the Pester 5 unit tests in tests\Unit and throws when a test fails. With ResultPath, the results are also
        written as JUnit XML.

    .PARAMETER ResultPath
        Path of the JUnit XML result file.

    .EXAMPLE
        Invoke-Test -ResultPath '.\TestResults.xml'

    .OUTPUTS
        None. Results go to the Pester output.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://pester.dev/docs/quick-start
    #>
    [CmdletBinding()]
    param(
        [string]$ResultPath
    )
    Import-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path $root 'tests\Unit'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    if ($ResultPath) {
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'JUnitXml'
        $configuration.TestResult.OutputPath = $ResultPath
    }
    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
        throw "Tests failed: $($result.FailedCount) failed."
    }
}

switch ($Task) {
    'Lint' { Invoke-Lint }
    'Typecheck' { Invoke-Typecheck }
    'Test' { Invoke-Test -ResultPath $TestResultPath }
    'All' { Invoke-Lint; Invoke-Typecheck; Invoke-Test -ResultPath $TestResultPath }
}
