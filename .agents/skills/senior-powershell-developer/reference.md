# PowerShell patterns

Patterns for the rules in [SKILL.md](SKILL.md). Adapt names to the project. Don't paste a block whose purpose the
function doesn't share.

## Public function skeleton

```powershell
function Set-ServiceStartupType {
    <#
    .SYNOPSIS
        Sets the startup type of one or more Windows services.

    .DESCRIPTION
        Changes the startup type only when it differs from the requested value, so repeated runs make no changes.

    .PARAMETER Name
        Service name (not display name). Accepts pipeline input by value and by property name.

    .PARAMETER StartupType
        Startup type to apply.

    .PARAMETER PassThru
        Returns the service after the change.

    .EXAMPLE
        Get-Service -Name 'Spooler' | Set-ServiceStartupType -StartupType Disabled -WhatIf

    .OUTPUTS
        System.ServiceProcess.ServiceController when -PassThru is used; otherwise none.

    .NOTES
        Author:  <name>
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([System.ServiceProcess.ServiceController])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Automatic', 'Manual', 'Disabled')]
        [string]$StartupType,

        [switch]$PassThru
    )

    process {
        foreach ($serviceName in $Name) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if (-not $service) {
                # Non-terminating: report this service and continue with the rest of the pipeline.
                Write-Error -Message "Service '$serviceName' was not found." -Category ObjectNotFound -TargetObject $serviceName -ErrorId 'ServiceNotFound'
                continue
            }
            if ($service.StartType -ne $StartupType -and $PSCmdlet.ShouldProcess($serviceName, "Set startup type to $StartupType")) {
                Set-Service -Name $serviceName -StartupType $StartupType -ErrorAction Stop
            }
            if ($PassThru) { Get-Service -Name $serviceName }
        }
    }
}
```

The `SilentlyContinue` above is deliberate: the missing service is reported through `Write-Error` on the next line.

## Terminating error with a stable ID

```powershell
$exception = [System.IO.FileNotFoundException]::new("Configuration file '$Path' was not found. Create it from config\example.json.")
$PSCmdlet.ThrowTerminatingError(
    [System.Management.Automation.ErrorRecord]::new($exception, 'ConfigurationNotFound', 'ObjectNotFound', $Path))
```

Callers and tests can match on the ID: `catch { if ($_.FullyQualifiedErrorId -like 'ConfigurationNotFound*') { ... } }`,
or `Should -Throw -ErrorId 'ConfigurationNotFound'`.

## Keep the original error when cleanup fails

```powershell
$session = $null   # under StrictMode, reading an unassigned variable in finally would throw
try {
    $session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
    Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ErrorAction Stop
}
finally {
    if ($session) {
        try { Remove-PSSession -Session $session -ErrorAction Stop }
        catch { Write-Warning "Could not close the session to ${ComputerName}: $_" }
    }
}
```

Never let a cleanup failure replace the exception that got you into `finally` or `catch`.

## Native executables

```powershell
$arguments = @('/Online', '/Get-Packages', '/English')
$output = & "$env:SystemRoot\System32\dism.exe" @arguments 2>&1
if ($LASTEXITCODE -notin 0, 3010) {
    throw "dism.exe /Get-Packages failed with exit code $LASTEXITCODE (0x$('{0:X8}' -f $LASTEXITCODE)): $($output -join [Environment]::NewLine)"
}
```

- Use the full path to system tools, so a binary planted on `PATH` can't be picked up instead.
- Splat an argument array. Never use `Invoke-Expression` or concatenated command strings.
- From 7.4 on, `$PSNativeCommandUseErrorActionPreference = $true` together with `$ErrorActionPreference = 'Stop'` turns
  a non-zero exit code into an error. You still need an explicit list when other exit codes mean success.

## StrictMode and optional properties

`Set-StrictMode -Version 3.0` (or `Latest`) throws when you read a property that doesn't exist. JSON-derived objects
often lack optional properties:

```powershell
$timeout = $config.PSObject.Properties['timeoutSeconds']?.Value ?? 300
```

`?` is a legal character in variable names. Directly after a variable you must write `${config}?.Name`;
`$config?.Name` reads a variable named `config?`.

`ConvertFrom-Json` in PowerShell 7 converts ISO 8601 strings to `[datetime]`. Cast the value instead of parsing it
again.

## Collections

```powershell
# Assign loop output: no array copies.
$report = foreach ($file in $files) {
    [pscustomobject]@{ Name = $file.Name; Sha256 = (Get-FileHash -LiteralPath $file.FullName).Hash }
}

# Use a List when items are added conditionally from several places.
$failures = [System.Collections.Generic.List[string]]::new()
$failures.Add($message)
```

Wrap with `@()` when you need a count from a command that may return zero or one item: `@(Get-ChildItem ...).Count`.

## Credentials

```powershell
param(
    [Parameter(Mandatory)]
    [pscredential]$Credential
)
```

- Get stored secrets from `Microsoft.PowerShell.SecretManagement` (`Get-Secret`) or a managed identity.
- `ConvertFrom-SecureString` without `-Key` is bound to the current user and machine (DPAPI). Don't use it to move
  secrets between hosts.

## Analyzer suppression

```powershell
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive menu; output is intentionally not pipeline data.')]
```

Put the suppression on the narrowest scope that applies, and give the real reason.
