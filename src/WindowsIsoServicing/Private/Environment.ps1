function Invoke-ExternalTool {
    <#
    .SYNOPSIS
        Runs a native executable and fails unless it returns an expected exit code.

    .DESCRIPTION
        Starts FilePath directly, without a shell, and passes each ArgumentList element as one argument, so arguments are
        never re-parsed by cmd.exe or PowerShell. Standard error is read asynchronously while standard output is read, so a
        process that fills both pipes cannot deadlock. The command line is logged at Verbose level.
        When the exit code is not in SuccessExitCodes, the output is written to the run log and the function throws an
        error that names the operation, the exit code in decimal and hexadecimal, and the first non-empty output. Every
        native tool in the module runs through this function (INVARIANTS.md, Code #2).

    .PARAMETER FilePath
        Full path of the executable. The file must exist.

    .PARAMETER ArgumentList
        Arguments for the executable, one per element.

    .PARAMETER Operation
        Name of the operation for the log and the error message, for example 'BuildIso'.

    .PARAMETER SuccessExitCodes
        Exit codes that count as success. Defaults to 0. HRESULT exit codes are passed as signed integers, for example
        -2146498554 for 0x800F0806.

    .EXAMPLE
        Invoke-ExternalTool -FilePath "$env:SystemRoot\System32\expand.exe" -ArgumentList 'E:\Cache\packages\KB5135883\setup.cab', '-F:*', 'D:\Work\media\sources' -Operation 'ExpandSetupDynamicUpdate'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with ExitCode, StandardOutput and StandardError.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/dotnet/api/system.diagnostics.processstartinfo.argumentlist
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory)]
        [string]$Operation,
        [int[]]$SuccessExitCodes = @(0)
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "Executable '$FilePath' was not found."
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    Write-ServicingLog -Operation $Operation -Level Verbose -Message "Running $FilePath $($ArgumentList -join ' ')"
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $standardOutput = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
    $result = [pscustomobject]@{
        ExitCode       = $exitCode
        StandardOutput = $standardOutput
        StandardError  = $standardError
    }
    if ($exitCode -notin $SuccessExitCodes) {
        $detail = ($standardError, $standardOutput | Where-Object { $_ } | Select-Object -First 1)
        Write-ServicingLog -Operation $Operation -Level Error -Message "Exit code $exitCode" -Data @{ output = $standardOutput; error = $standardError }
        throw ('{0} failed with exit code {1} (0x{1:X8}). {2}' -f $Operation, $exitCode, $detail)
    }
    $result
}

function Assert-Administrator {
    <#
    .SYNOPSIS
        Throws unless the current PowerShell session is elevated.

    .DESCRIPTION
        Checks that the current Windows identity holds the built-in Administrators role with an elevated token. DISM image
        servicing, ISO mounting and Hyper-V require elevation, so commands call this before they change anything.

    .EXAMPLE
        Assert-Administrator

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param()
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This operation requires an elevated PowerShell session (Run as administrator).'
    }
}

function Resolve-FileSystemPath {
    <#
    .SYNOPSIS
        Converts a PowerShell path to a full file system path.

    .DESCRIPTION
        Resolves Path against the current PowerShell location, not the process working directory, which PowerShell does
        not change on Set-Location. The path does not have to exist. Paths of other providers, such as HKLM: or Env:, are
        rejected.

    .PARAMETER Path
        Absolute or relative path. PowerShell drive names are allowed.

    .EXAMPLE
        Set-Location -Path 'D:\ISO'; Resolve-FileSystemPath -Path '.\Updated'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/dotnet/api/system.management.automation.pathintrinsics.getunresolvedproviderpathfrompspath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $provider = $null
    $drive = $null
    $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') {
        throw "'$Path' is a $($provider.Name) provider path; a file system path is required."
    }
    [System.IO.Path]::GetFullPath($providerPath)
}

function Resolve-TrustedFilePath {
    <#
    .SYNOPSIS
        Validates a user-supplied file path and returns the full path of the file.

    .DESCRIPTION
        Rejects device paths (\\?\ and \\.\), wildcard characters, directories, reparse points such as symbolic links and
        junctions, and, when AllowedExtension is given, other extensions. Opens the file for reading once, so a missing
        read permission fails before a run starts. Used for source ISOs and manifests, which the module reads and never
        writes.

    .PARAMETER Path
        Path of the file. Relative paths resolve against the current PowerShell location.

    .PARAMETER AllowedExtension
        Accepted file extensions including the dot, for example '.iso'. Any extension is accepted when omitted.

    .EXAMPLE
        Resolve-TrustedFilePath -Path 'D:\ISO\Windows_Server_2025.iso' -AllowedExtension '.iso'

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
        [string]$Path,

        [string[]]$AllowedExtension
    )
    if ($Path -match '^\\\\[?.]\\') {
        throw "Device paths are not accepted: '$Path'."
    }
    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Path)) {
        throw "Wildcard characters are not accepted in '$Path'."
    }
    $fullPath = Resolve-FileSystemPath -Path $Path
    $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        throw "'$fullPath' is a directory, expected a file."
    }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "'$fullPath' is a reparse point (symbolic link or junction) and is not accepted."
    }
    if ($AllowedExtension -and $item.Extension -notin $AllowedExtension) {
        throw "'$fullPath' must have one of the extensions: $($AllowedExtension -join ', ')."
    }
    $stream = [System.IO.File]::Open($fullPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $stream.Dispose()
    $item.FullName
}

function Resolve-DirectoryPath {
    <#
    .SYNOPSIS
        Validates a directory path, optionally creates the directory, and returns its full path.

    .DESCRIPTION
        Rejects device paths, resolves relative paths against the current PowerShell location and returns the full path
        without a trailing backslash. A missing directory is an error unless Create is set, in which case it is created
        (subject to -WhatIf and -Confirm).

    .PARAMETER Path
        Path of the directory.

    .PARAMETER Create
        Creates the directory when it does not exist.

    .EXAMPLE
        Resolve-DirectoryPath -Path 'D:\ISO\Updated' -Create

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
        [string]$Path,
        [switch]$Create
    )
    if ($Path -match '^\\\\[?.]\\') {
        throw "Device paths are not accepted: '$Path'."
    }
    $fullPath = Resolve-FileSystemPath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        if (-not $Create) { throw "Directory '$fullPath' does not exist." }
        if ($PSCmdlet.ShouldProcess($fullPath, 'Create directory')) {
            $null = New-Item -Path $fullPath -ItemType Directory -Force
        }
    }
    $fullPath.TrimEnd('\')
}

function Lock-Directory {
    <#
    .SYNOPSIS
        Takes an exclusive lock on a directory for the current process.

    .DESCRIPTION
        Opens a lock file in the directory with FileShare.None and writes the process ID, host name and start time into it
        for diagnostics. A second open fails while the handle is held, which is how concurrent runs are kept from sharing
        a workspace, output folder, cache or store key. The operating system releases the lock when the process exits, so
        a crashed run never leaves a stale lock.

    .PARAMETER Directory
        Directory to lock. It must exist.

    .PARAMETER Name
        File name of the lock file. Defaults to '.windows-iso-servicing.lock'.

    .EXAMPLE
        $lock = Lock-Directory -Directory 'D:\IsoServicing\Workspace'

    .OUTPUTS
        System.IO.FileStream

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [string]$Name = '.windows-iso-servicing.lock'
    )
    $lockPath = Join-Path $Directory $Name
    try {
        $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        throw "Directory '$Directory' is locked by another windows-iso-servicing process ($lockPath)."
    }
    $info = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID;host=$env:COMPUTERNAME;started=$([DateTimeOffset]::Now.ToString('o'))")
    $stream.SetLength(0)
    $stream.Write($info, 0, $info.Length)
    $stream.Flush()
    $stream
}

function Unlock-Directory {
    <#
    .SYNOPSIS
        Releases a lock taken with Lock-Directory.

    .DESCRIPTION
        Closes the lock file handle and then tries to delete the lock file. The lock is the open handle, not the file, so a
        file that cannot be deleted, for example because another run has just opened it, is left in place without an
        error. A null Lock is ignored, so the function can be called unconditionally in a finally block.

    .PARAMETER Lock
        File stream returned by Lock-Directory.

    .EXAMPLE
        Unlock-Directory -Lock $workspaceLock

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [System.IO.FileStream]$Lock
    )
    if ($Lock) {
        $lockPath = $Lock.Name
        $Lock.Dispose()
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-FreeSpace {
    <#
    .SYNOPSIS
        Throws when the volume of a path has less free space than required.

    .DESCRIPTION
        Reads the space available to the current user on the volume that holds Path and throws an error stating the
        available and required space in GB when it is too small. Works for drive and UNC paths; see
        Get-AvailableFreeSpace.

    .PARAMETER Path
        Any path on the volume to check.

    .PARAMETER RequiredBytes
        Minimum free space in bytes.

    .EXAMPLE
        Assert-FreeSpace -Path 'D:\IsoServicing\Workspace' -RequiredBytes 40GB

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [long]$RequiredBytes
    )
    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    $available = Get-AvailableFreeSpace -Root $root
    if ($available -lt $RequiredBytes) {
        throw ('Insufficient free space on {0}: {1:N1} GB available, {2:N1} GB required.' -f $root, ($available / 1GB), ($RequiredBytes / 1GB))
    }
}

function Get-AvailableFreeSpace {
    <#
    .SYNOPSIS
        Returns the free space available to the current user on a drive or UNC share.

    .DESCRIPTION
        System.IO.DriveInfo accepts only drive roots, so a UNC share root (\\server\share) is read through
        Scripting.FileSystemObject, whose GetDrive accepts network shares. An unreachable share throws instead of
        returning a value.

    .PARAMETER Root
        Drive root (D:\) or UNC share root (\\server\share), as returned by System.IO.Path.GetPathRoot.

    .EXAMPLE
        Get-AvailableFreeSpace -Root '\\fs01\iso'

    .OUTPUTS
        System.Int64

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/office/vba/language/reference/user-interface-help/getdrive-method
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [string]$Root
    )
    if (-not $Root.StartsWith('\\')) {
        return [System.IO.DriveInfo]::new($Root).AvailableFreeSpace
    }
    $fileSystem = New-Object -ComObject Scripting.FileSystemObject
    try {
        [long]$fileSystem.GetDrive($Root.TrimEnd('\')).AvailableSpace
    }
    catch {
        throw "Cannot read the free space of the share '$Root': $($_.Exception.Message)"
    }
    finally {
        $null = [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fileSystem)
    }
}

function Get-FileSha256 {
    <#
    .SYNOPSIS
        Returns the SHA-256 hash of a file as lowercase hexadecimal.

    .DESCRIPTION
        Computes the hash with Get-FileHash. Manifests and checksum files store SHA-256 values in lowercase, so this
        function is used wherever a hash is compared with one of them.

    .PARAMETER Path
        Path of the file.

    .EXAMPLE
        Get-FileSha256 -Path 'D:\ISO\Windows_Server_2025.iso'

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
        [string]$Path
    )
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-MicrosoftSignature {
    <#
    .SYNOPSIS
        Tests whether a file carries a valid Authenticode signature from Microsoft Corporation.

    .DESCRIPTION
        Returns $true only when Get-AuthenticodeSignature reports the status Valid and the signer certificate subject has
        the organization O=Microsoft Corporation. Used for update packages and for oscdimg.exe before they are used.

    .PARAMETER Path
        Path of the file to check.

    .EXAMPLE
        Test-MicrosoftSignature -Path 'E:\UpdateCache\packages\KB5131080\windows11.0-kb5131080-x64.msu'

    .OUTPUTS
        System.Boolean

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid -and $null -ne $signature.SignerCertificate -and $signature.SignerCertificate.Subject -match '(^|,\s*)O=Microsoft Corporation(,|$)'
}
