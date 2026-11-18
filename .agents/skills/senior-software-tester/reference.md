# Pester 5 reference

For Pester 5.x. Pester 6 changes some defaults; check the version the project pins before you use anything
version-specific.

## Discovery and run phases

Pester runs each file twice: first to **discover** tests, then to **run** them.

- Code directly inside `Describe` or `Context` runs during discovery only. Put setup in `BeforeAll` or `BeforeEach`.
- Data used to *generate* tests (for `-ForEach` on `Describe` or `It`) must exist at discovery time. Define it in
  `BeforeDiscovery`, or inline in the `-ForEach` argument.
- Variables from `BeforeDiscovery` aren't available inside `It`. Pass them through `-ForEach`.

```powershell
BeforeAll {
    Import-Module "$PSScriptRoot/../../src/MyModule/MyModule.psd1" -Force
}

Describe 'ConvertTo-ArchitectureName' {
    It 'maps <Value> to <Expected>' -ForEach @(
        @{ Value = 9; Expected = 'x64' }
        @{ Value = 12; Expected = 'arm64' }
    ) {
        InModuleScope MyModule -Parameters $_ {
            ConvertTo-ArchitectureName -Architecture $Value | Should -Be $Expected
        }
    }
}
```

## Testing module code

- Test the public command first. Reach private functions with `InModuleScope` inside the `It` or `BeforeAll`, never
  wrapped around a whole `Describe`.
- To mock a command that the module calls, use `Mock -CommandName Get-Thing -ModuleName MyModule`. Assert it with
  `Should -Invoke Get-Thing -ModuleName MyModule -Times 1 -Exactly`.
- A mock only catches calls made by name. A native tool called by full path (`& "$env:SystemRoot\System32\dism.exe"`)
  can't be mocked directly. Mock the function that wraps it.
- Narrow a mock to certain calls with `-ParameterFilter { $Path -like '*.iso' }`. Add one unfiltered mock that throws
  when an unexpected call must fail the test.

## Assertions

```powershell
{ Get-Config -Path 'missing.json' } | Should -Throw -ErrorId 'ConfigurationNotFound'
{ Remove-Thing -Name x -WhatIf } | Should -Not -Throw
Should -Invoke Remove-Item -ModuleName MyModule -Times 0          # -WhatIf changed nothing
$result.Status | Should -Be 'Unchanged'
(Get-Content -LiteralPath "$TestDrive/out.json" -Raw | ConvertFrom-Json).version | Should -Be 2
```

- `Should -Throw` takes a script block. `-ExpectedMessage` uses wildcards; prefer `-ErrorId` when the code sets one.
- `Should -BeExactly` compares case-sensitively. `Should -Be` does not.
- Avoid `Should -Not -BeNullOrEmpty` as the only assertion on a result. It passes for wrong values.

## Isolation helpers

- `$TestDrive` / `TestDrive:` is a temporary folder per `Describe` or `Context`, deleted afterwards.
- `TestRegistry:` is a temporary registry key with the same lifetime.
- For time-dependent logic, use a parameter such as `-AsOf`. Mocking `Get-Date` works, but couples the test to how the
  code reads the clock.

## Skipping with a reason

```powershell
It 'services real media' -Tag 'Integration' {
    if (-not $env:INTEGRATION_CONFIG) {
        Set-ItResult -Skipped -Because 'INTEGRATION_CONFIG is not set'
        return
    }
    # ...
}
```

The reason is shown in the results, so a skipped test is never mistaken for a passing one.

## CI configuration

```powershell
$configuration = New-PesterConfiguration
$configuration.Run.Path = 'tests/Unit'
$configuration.Run.Exit = $true                    # non-zero exit code when tests fail
$configuration.Filter.ExcludeTag = 'Integration'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = 'JUnitXml'  # or NUnitXml
$configuration.TestResult.OutputPath = 'TestResults.xml'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = 'src'
$configuration.CodeCoverage.OutputFormat = 'JaCoCo'
Invoke-Pester -Configuration $configuration
```

- Code coverage instruments every command and slows runs noticeably. Enable it in a separate CI job when the unit run
  must stay fast.
- Read the coverage report for untested branches in risky code: error paths, cleanup, security checks.

## Defect report

```text
ID:          <short id>
Severity:    Critical | High | Medium | Low
Component:   <path>:<line> (<function>)
Summary:     <one sentence: what is wrong>
Reproduce:   <exact command or test, with input>
Expected:    <behavior and its source: requirement, documentation, invariant>
Actual:      <observed behavior, quoted output or error ID>
Evidence:    <failing test name, log excerpt, or "inferred from code" with the reasoning>
Impact:      <who or what is affected, and how>
Remediation: <concrete fix; the regression test that will cover it>
```

Severity guide:

- **Critical:** data loss, a security bypass, or false success on a production path.
- **High:** wrong results, or a failure without a workaround.
- **Medium:** a failure with a workaround, or degraded diagnostics.
- **Low:** cosmetic, or a minor inefficiency.
