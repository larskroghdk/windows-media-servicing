function Start-ServicingLog {
    <#
    .SYNOPSIS
        Starts the structured run log for a servicing run.

    .DESCRIPTION
        Creates the log directory when needed (subject to -WhatIf and -Confirm) and makes <RunId>.log.jsonl in it the
        target of Write-ServicingLog for the rest of the session. When the directory does not exist after a -WhatIf run,
        entries are not written to a file.

    .PARAMETER Directory
        Folder for the log file.

    .PARAMETER RunId
        Run identifier, used as the log file name.

    .EXAMPLE
        Start-ServicingLog -Directory 'D:\ISO\Updated\logs\20261118-080000-1a2b3c4d' -RunId '20261118-080000-1a2b3c4d'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [Parameter(Mandatory)]
        [string]$RunId
    )
    if (-not (Test-Path -LiteralPath $Directory)) {
        if ($PSCmdlet.ShouldProcess($Directory, 'Create log directory')) {
            $null = New-Item -Path $Directory -ItemType Directory -Force
        }
    }
    $path = Join-Path $Directory "$RunId.log.jsonl"
    $script:LogFilePath = if (Test-Path -LiteralPath $Directory -PathType Container) { $path }
    $path
}

function Stop-ServicingLog {
    <#
    .SYNOPSIS
        Stops writing servicing log entries to the run log file.

    .DESCRIPTION
        Clears the module's log file path. Write-ServicingLog then writes only to the PowerShell streams.

    .EXAMPLE
        Stop-ServicingLog

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only clears the module log file variable.')]
    [CmdletBinding()]
    param()
    $script:LogFilePath = $null
}

function Write-ServicingLog {
    <#
    .SYNOPSIS
        Writes an entry to the structured run log and to the matching PowerShell stream.

    .DESCRIPTION
        Appends one JSON line with timestamp, level, operation, target, message and optional data to the run log started
        by Start-ServicingLog. The same text goes to the information stream (tagged with the operation), the warning
        stream or the verbose stream. Error entries go to the verbose stream only, because the caller reports the error
        itself by throwing.

    .PARAMETER Operation
        Operation name, for example 'Download' or 'AddPackage'.

    .PARAMETER Message
        Message text.

    .PARAMETER Level
        Information (default), Warning, Error or Verbose.

    .PARAMETER Target
        Object the entry is about, for example a file path or KB number.

    .PARAMETER Data
        Additional structured data written to the log file only.

    .EXAMPLE
        Write-ServicingLog -Operation 'Download' -Level Warning -Target 'windows11.0-kb5131080-x64.msu' -Message 'Download failed, retrying in 30 s'

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation,
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('Information', 'Warning', 'Error', 'Verbose')]
        [string]$Level = 'Information',
        [string]$Target,
        [hashtable]$Data
    )
    $entry = [ordered]@{
        timestamp = [DateTimeOffset]::Now.ToString('o')
        level     = $Level
        operation = $Operation
        target    = $Target
        message   = $Message
    }
    if ($Data) { $entry.data = $Data }
    if ($script:LogFilePath) {
        $line = $entry | ConvertTo-Json -Compress -Depth 6
        [System.IO.File]::AppendAllText($script:LogFilePath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    }
    $text = if ($Target) { "[$Operation] $Target - $Message" } else { "[$Operation] $Message" }
    switch ($Level) {
        'Warning' { Write-Warning $text }
        'Error' { Write-Verbose "ERROR: $text" }
        'Verbose' { Write-Verbose $text }
        default { Write-Information $text -Tags $Operation }
    }
}
