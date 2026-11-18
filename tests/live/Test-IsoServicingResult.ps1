#Requires -Version 7.4
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Verifies a serviced Windows ISO against its source ISO by inspecting the media itself.

.DESCRIPTION
    Checks an ISO created by Update-WindowsISO without trusting its own report. The manifest only supplies what was planned and applied; every claim is confirmed on the media. The source and the serviced ISO are mounted read-only and compared: checksums, volume label, versioned file name, El Torito boot catalog entries (BIOS and UEFI, read from the ISO bytes), that the UEFI entry starts efisys_noprompt.bin and the media has no boot\bootfix.bin (so neither firmware waits for "Press any key"), boot and setup files, boot.wim indexes, and the install image indexes and editions. Each serviced install.wim index is then mounted read-only, and the matching source index too when the source is a WIM. A serviced index passes only when its Package_for_RollupFix revision equals the OS build revision in the cumulative update title (Package_for_KB<number> for rollup-serviced releases), every standalone servicing stack update is in the package list or was reported not applicable by DISM, the servicing stack version did not decrease, no package is partially installed, and a WinRE image recorded as serviced differs from the original. The run log is searched for errors, and no image may remain mounted. An install.esd source cannot be mounted, so for ESD media the before values come from the manifest and the package comparison with the source is skipped. Nothing is modified: ISOs are mounted read-only and images are discarded on dismount. The script returns a result instead of throwing for failed checks; it throws only when the inputs cannot be read.

.PARAMETER ManifestPath
    Manifest written by Update-WindowsISO next to the serviced ISO ('<iso>.json').

.PARAMETER SourceIsoPath
    Original ISO. Defaults to the source path recorded in the manifest.

.PARAMETER SourceSha256
    SHA-256 of the original ISO taken before servicing. Defaults to the value recorded in the manifest.

.PARAMETER ExpectedIndex
    Install image indexes that must have been serviced. When omitted, at least one serviced index is required.

.PARAMETER LogPath
    Folder with the structured run log (*.log.jsonl) of the servicing run. When omitted, the log check is skipped.

.PARAMETER WorkingDirectory
    Folder for the temporary read-only mount points. A uniquely named subfolder is created and removed again.

.EXAMPLE
    .\tests\live\Test-IsoServicingResult.ps1 -ManifestPath 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso.json' -ExpectedIndex 2, 4

.OUTPUTS
    WindowsIsoServicing.LiveValidationResult

.NOTES
    Author:  Lars Krogh Paulsen
    Version: 1.0.0

.LINK
    https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
#>

[CmdletBinding()]
[OutputType('WindowsIsoServicing.LiveValidationResult')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,
    [ValidateNotNullOrEmpty()]
    [string]$SourceIsoPath,
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$SourceSha256,
    [ValidateRange(1, 256)]
    [int[]]$ExpectedIndex,
    [string]$LogPath,
    [ValidateNotNullOrEmpty()]
    [string]$WorkingDirectory = (Join-Path $env:ProgramData 'WindowsIsoServicing\Workspace')
)

function Get-ElToritoBootEntry {
    <#
    .SYNOPSIS
        Reads the bootable entries of an ISO from its El Torito boot catalog.

    .DESCRIPTION
        Finds the El Torito boot record among the ISO 9660 volume descriptors (from sector 16), reads the boot catalog it points to, and returns every bootable entry, the initial entry and the entries of each section, with its platform and the 2048-byte sector (LoadRba) of its boot image. Platform 0 is returned as 'BIOS' and 0xEF as 'UEFI'. LoadRba lets the caller read the boot image the firmware actually starts. The file is read directly, so the result reflects the boot catalog OSCDIMG wrote, not just the presence of boot files. Returns nothing for media without an El Torito boot record and throws when the boot catalog is invalid.

    .PARAMETER Path
        Path to the ISO file.

    .EXAMPLE
        Get-ElToritoBootEntry -Path 'D:\ISO\Windows_Server_2025.iso'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Platform and LoadRba.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://pdos.csail.mit.edu/6.828/2014/readings/boot-cdrom.pdf
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $sectorSize = 2048
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $sector = [byte[]]::new($sectorSize)
        $catalogSector = $null
        for ($descriptor = 16; $descriptor -lt 64; $descriptor++) {
            $null = $stream.Seek([long]$descriptor * $sectorSize, [System.IO.SeekOrigin]::Begin)
            $stream.ReadExactly($sector, 0, $sectorSize)
            if ([System.Text.Encoding]::ASCII.GetString($sector, 1, 5) -ne 'CD001' -or $sector[0] -eq 255) { break }
            if ($sector[0] -eq 0 -and [System.Text.Encoding]::ASCII.GetString($sector, 7, 23) -eq 'EL TORITO SPECIFICATION') {
                $catalogSector = [System.BitConverter]::ToUInt32($sector, 0x47)
                break
            }
        }
        if ($null -eq $catalogSector) { return }
        $catalog = [byte[]]::new($sectorSize)
        $null = $stream.Seek([long]$catalogSector * $sectorSize, [System.IO.SeekOrigin]::Begin)
        $stream.ReadExactly($catalog, 0, $sectorSize)
        if ($catalog[0] -ne 1 -or $catalog[30] -ne 0x55 -or $catalog[31] -ne 0xAA) {
            throw "'$Path' has an El Torito boot record, but sector $catalogSector holds no valid boot catalog."
        }
        $entries = [System.Collections.Generic.List[object]]::new()
        if ($catalog[32] -eq 0x88) {
            $entries.Add([pscustomobject]@{
                    Platform = $catalog[1]
                    LoadRba  = [System.BitConverter]::ToUInt32($catalog, 40)
                })
        }
        $offset = 64
        while ($offset + 32 -le $sectorSize -and $catalog[$offset] -in 0x90, 0x91) {
            $isLastSection = $catalog[$offset] -eq 0x91
            $platform = $catalog[$offset + 1]
            $remaining = [System.BitConverter]::ToUInt16($catalog, $offset + 2)
            $offset += 32
            while ($remaining -gt 0 -and $offset + 32 -le $sectorSize) {
                if ($catalog[$offset] -eq 0x88) {
                    $entries.Add([pscustomobject]@{
                            Platform = $platform
                            LoadRba  = [System.BitConverter]::ToUInt32($catalog, $offset + 8)
                        })
                }
                if ($catalog[$offset] -ne 0x44) { $remaining-- }
                $offset += 32
            }
            if ($isLastSection) { break }
        }
        foreach ($entry in $entries) {
            $name = switch ($entry.Platform) {
                0 { 'BIOS' }
                0xEF { 'UEFI' }
                default { 'Platform0x{0:X2}' -f $entry.Platform }
            }
            [pscustomobject]@{
                Platform = $name
                LoadRba  = $entry.LoadRba
            }
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Mount-ValidationIso {
    <#
    .SYNOPSIS
        Mounts an ISO read-only and returns its drive root.

    .DESCRIPTION
        Uses the existing drive letter when the ISO is already attached, otherwise mounts it with Mount-DiskImage -Access ReadOnly. MountedHere tells the caller whether it must dismount the ISO again, so an ISO the user had attached stays attached. Drive letter assignment can lag behind the mount, so the volume is looked up for up to five seconds before the command gives up and dismounts.

    .PARAMETER Path
        Path to the ISO file.

    .EXAMPLE
        Mount-ValidationIso -Path 'D:\ISO\Windows_Server_2025.iso'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $diskImage = Get-DiskImage -ImagePath $Path -ErrorAction Stop
    $mountedHere = -not $diskImage.Attached
    if ($mountedHere) { $diskImage = Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly -PassThru -ErrorAction Stop }
    $volume = $null
    foreach ($attempt in 1..10) {
        $volume = $diskImage | Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
        if ($volume) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $volume) {
        if ($mountedHere) { $null = Dismount-DiskImage -ImagePath $Path -ErrorAction Stop }
        throw "ISO '$Path' is attached but has no drive letter. Enable automatic drive letter assignment (mountvol /E) and run again."
    }
    [pscustomobject]@{ Path = $Path; Root = "$($volume.DriveLetter):\"; Label = $volume.FileSystemLabel; MountedHere = $mountedHere }
}

function Get-ImageServicingState {
    <#
    .SYNOPSIS
        Mounts one image index read-only and reads its servicing state.

    .DESCRIPTION
        Returns the installed packages with their state and version, the highest installed or install-pending Package_for_RollupFix and Package_for_ServicingStack versions, the file version of Windows\servicing\TrustedInstaller.exe (the servicing stack binary), and the SHA-256 of Windows\System32\Recovery\Winre.wim. The image is always dismounted with -Discard and its mount folder removed, also when reading fails.

    .PARAMETER ImagePath
        Path to the install.wim file.

    .PARAMETER Index
        Image index to inspect.

    .PARAMETER MountPath
        Empty folder to mount the image in. It is created and removed again.

    .EXAMPLE
        Get-ImageServicingState -ImagePath 'E:\sources\install.wim' -Index 2 -MountPath 'C:\ProgramData\WindowsIsoServicing\Workspace\live-validate-1a2b3c4d\output-2'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,
        [Parameter(Mandatory)]
        [int]$Index,
        [Parameter(Mandatory)]
        [string]$MountPath
    )
    $null = New-Item -Path $MountPath -ItemType Directory -Force
    try {
        $null = Mount-WindowsImage -ImagePath $ImagePath -Index $Index -Path $MountPath -ReadOnly -ErrorAction Stop
        try {
            $packages = @(Get-WindowsPackage -Path $MountPath -ErrorAction Stop | ForEach-Object {
                    $version = $null
                    $null = [version]::TryParse(($_.PackageName -split '~')[-1], [ref]$version)
                    [pscustomobject]@{ Name = $_.PackageName; State = [string]$_.PackageState; Version = $version }
                })
            $active = @($packages | Where-Object State -In 'Installed', 'InstallPending')
            $rollup = $active | Where-Object Name -Like 'Package_for_RollupFix~*' | Sort-Object Version -Descending | Select-Object -First 1
            $servicingStack = $active | Where-Object Name -Like 'Package_for_ServicingStack*' | Sort-Object Version -Descending | Select-Object -First 1
            $trustedInstaller = Join-Path $MountPath 'Windows\servicing\TrustedInstaller.exe'
            $winRe = Join-Path $MountPath 'Windows\System32\Recovery\Winre.wim'
            [pscustomobject]@{
                Index                        = $Index
                Packages                     = $packages
                RollupVersion                = ${rollup}?.Version
                ServicingStackPackageVersion = ${servicingStack}?.Version
                TrustedInstallerVersion      = if (Test-Path -LiteralPath $trustedInstaller -PathType Leaf) { (Get-Item -LiteralPath $trustedInstaller -Force).VersionInfo.FileVersionRaw }
                WinReSha256                  = if (Test-Path -LiteralPath $winRe -PathType Leaf) { (Get-FileHash -LiteralPath $winRe -Algorithm SHA256).Hash.ToLowerInvariant() }
            }
        }
        finally {
            $null = Dismount-WindowsImage -Path $MountPath -Discard -ErrorAction Stop
        }
    }
    finally {
        if (-not (Get-ChildItem -LiteralPath $MountPath -Force)) { Remove-Item -LiteralPath $MountPath -Force }
    }
}

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1')

$startedAt = [DateTimeOffset]::Now
$manifestFile = (Resolve-Path -LiteralPath $ManifestPath).ProviderPath
$manifest = Get-WindowsISOManifest -Path $manifestFile
$isoPath = $manifestFile -replace '\.json$', ''
if (-not (Test-Path -LiteralPath $isoPath -PathType Leaf)) {
    throw "Serviced ISO '$isoPath' next to the manifest does not exist."
}

if (-not $SourceIsoPath) {
    $SourceIsoPath = $manifest.source.path
}
$sourceIso = (Resolve-Path -LiteralPath $SourceIsoPath).ProviderPath
$expectedSourceSha256 = if ($SourceSha256) {
    $SourceSha256.ToLowerInvariant()
}
else {
    $manifest.source.sha256
}
$servicing = $manifest.operatingSystem.servicing
$cumulative = @($manifest.updates | Where-Object category -EQ 'CumulativeUpdate') | Select-Object -First 1
$standaloneStacks = @($manifest.updates | Where-Object category -EQ 'ServicingStack')
$checks = [System.Collections.Generic.List[object]]::new()
$images = [System.Collections.Generic.List[object]]::new()
$isoSha256 = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumFile = "$isoPath.sha256"
$recordedSha256 = if (Test-Path -LiteralPath $checksumFile -PathType Leaf) {
    ((Get-Content -LiteralPath $checksumFile -TotalCount 1) -split '\s+')[0].ToLowerInvariant()
}
$checks.Add([pscustomobject]@{
        Name   = 'OutputChecksum'
        Status = ($isoSha256 -eq $manifest.output.sha256 -and $isoSha256 -eq $recordedSha256) ? 'Passed' : 'Failed'
        Detail = "SHA-256 $isoSha256; manifest $($manifest.output.sha256); .sha256 file $recordedSha256"
    })
$sourceActualSha256 = (Get-FileHash -LiteralPath $sourceIso -Algorithm SHA256).Hash.ToLowerInvariant()
$checks.Add([pscustomobject]@{
        Name   = 'SourceUnchanged'
        Status = ($sourceActualSha256 -eq $expectedSourceSha256 -and $sourceActualSha256 -eq $manifest.source.sha256) ? 'Passed' : 'Failed'
        Detail = "SHA-256 $sourceActualSha256; expected $expectedSourceSha256"
    })
$checks.Add([pscustomobject]@{
        Name   = 'ProductionValidation'
        Status = $manifest.validation.passed ? 'Passed' : 'Failed'
        Detail = "Update-WindowsISO structural validation passed: $($manifest.validation.passed); boot test performed: $($manifest.validation.bootTest.performed)"
    })
$checks.Add([pscustomobject]@{
        Name   = 'CumulativeUpdatePlanned'
        Status = $cumulative ? 'Passed' : 'Failed'
        Detail = $cumulative ? "$($cumulative.kb) $($cumulative.title)" : 'The manifest lists no cumulative update.'
    })
$namePattern = '_{0}_{1}_{2}\.iso$' -f [regex]::Escape($manifest.operatingSystem.architecture), $manifest.operatingSystem.build, [regex]::Escape($manifest.output.servicingMonth)
$nameOk = $manifest.output.fileName -eq (Split-Path $isoPath -Leaf) -and $manifest.output.fileName -match $namePattern -and (-not $cumulative -or $manifest.output.servicingMonth -eq $cumulative.releaseMonth)
$checks.Add([pscustomobject]@{
        Name   = 'FileName'
        Status = $nameOk ? 'Passed' : 'Failed'
        Detail = "$($manifest.output.fileName) (servicing month $($manifest.output.servicingMonth), cumulative update month $(${cumulative}?.releaseMonth))"
    })
$sourcePlatforms = @(Get-ElToritoBootEntry -Path $sourceIso | ForEach-Object Platform | Select-Object -Unique)
$outputBootEntries = @(Get-ElToritoBootEntry -Path $isoPath)
$outputPlatforms = @($outputBootEntries | ForEach-Object Platform | Select-Object -Unique)
$missingPlatforms = @($sourcePlatforms | Where-Object { $_ -notin $outputPlatforms })
$checks.Add([pscustomobject]@{
        Name   = 'BootCatalog'
        Status = ($outputPlatforms.Count -gt 0 -and $missingPlatforms.Count -eq 0) ? 'Passed' : 'Failed'
        Detail = "Source: $($sourcePlatforms -join ', '); output: $($outputPlatforms -join ', ')"
    })
$validationRoot = Join-Path (Resolve-Path -LiteralPath (New-Item -Path $WorkingDirectory -ItemType Directory -Force)).ProviderPath "live-validate-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$null = New-Item -Path $validationRoot -ItemType Directory
$sourceMedia = $null
$servicedRecords = @()
$outputMedia = $null
try {
    $sourceMedia = Mount-ValidationIso -Path $sourceIso
    $outputMedia = Mount-ValidationIso -Path $isoPath
    $checks.Add([pscustomobject]@{
            Name   = 'Mount'
            Status = 'Passed'
            Detail = "Source $($sourceMedia.Root), output $($outputMedia.Root)"
        })
    $checks.Add([pscustomobject]@{
            Name   = 'VolumeLabel'
            Status = ($outputMedia.Label -eq $sourceMedia.Label) ? 'Passed' : 'Failed'
            Detail = "Source '$($sourceMedia.Label)', output '$($outputMedia.Label)'"
        })
    $bootFiles = @('bootmgr', 'boot\bcd', 'boot\etfsboot.com', 'efi\microsoft\boot\bcd', 'efi\microsoft\boot\efisys.bin') + @(Get-ChildItem -LiteralPath (Join-Path $sourceMedia.Root 'efi\boot') -Filter 'boot*.efi' -File -ErrorAction SilentlyContinue | ForEach-Object { "efi\boot\$($_.Name)" })
    $sourceBootFiles = @($bootFiles | Where-Object { Test-Path -LiteralPath (Join-Path $sourceMedia.Root $_) -PathType Leaf })
    $missingBootFiles = @($sourceBootFiles + 'setup.exe', 'sources\setup.exe', 'sources\boot.wim' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $outputMedia.Root $_) -PathType Leaf) })
    $checks.Add([pscustomobject]@{
            Name   = 'BootAndSetupFiles'
            Status = ($missingBootFiles.Count -eq 0) ? 'Passed' : 'Failed'
            Detail = $missingBootFiles ? "Missing: $($missingBootFiles -join ', ')" : "Present: $($sourceBootFiles -join ', '), setup.exe, sources\setup.exe, sources\boot.wim"
        })
    $uefiEntry = $outputBootEntries | Where-Object Platform -EQ 'UEFI' | Select-Object -First 1
    if ($uefiEntry) {
        $noPromptImage = Join-Path $outputMedia.Root 'efi\microsoft\boot\efisys_noprompt.bin'
        $storedSha256 = $null
        if (Test-Path -LiteralPath $noPromptImage -PathType Leaf) {
            $buffer = [byte[]]::new((Get-Item -LiteralPath $noPromptImage).Length)
            $isoStream = [System.IO.File]::Open($isoPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $null = $isoStream.Seek([long]$uefiEntry.LoadRba * 2048, [System.IO.SeekOrigin]::Begin)
                $isoStream.ReadExactly($buffer, 0, $buffer.Length)
            }
            finally {
                $isoStream.Dispose()
            }
            $storedSha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($buffer)).ToLowerInvariant()
        }
        $noPromptSha256 = $storedSha256 ? (Get-FileHash -LiteralPath $noPromptImage -Algorithm SHA256).Hash.ToLowerInvariant() : $null
        $checks.Add([pscustomobject]@{
                Name   = 'UefiBootPrompt'
                Status = ($storedSha256 -and $storedSha256 -eq $noPromptSha256) ? 'Passed' : 'Failed'
                Detail = $storedSha256 ? "UEFI boot image at sector $($uefiEntry.LoadRba): SHA-256 $storedSha256; efisys_noprompt.bin $noPromptSha256" : 'The output has no efi\microsoft\boot\efisys_noprompt.bin.'
            })
    }
    if ('BIOS' -in $outputPlatforms) {
        $sourceBootFix = (Test-Path -LiteralPath (Join-Path $sourceMedia.Root 'boot\bootfix.bin')) ? 'present' : 'absent'
        $bootFixPresent = Test-Path -LiteralPath (Join-Path $outputMedia.Root 'boot\bootfix.bin')
        $checks.Add([pscustomobject]@{
                Name   = 'BiosBootPrompt'
                Status = $bootFixPresent ? 'Failed' : 'Passed'
                Detail = $bootFixPresent ? 'boot\bootfix.bin is present, so etfsboot.com waits for a key.' : "boot\bootfix.bin is absent (source: $sourceBootFix)."
            })
    }
    $sourceBootIndexes = @(Get-WindowsImage -ImagePath (Join-Path $sourceMedia.Root 'sources\boot.wim') -ErrorAction Stop).Count
    $outputBootIndexes = @(Get-WindowsImage -ImagePath (Join-Path $outputMedia.Root 'sources\boot.wim') -ErrorAction Stop).Count
    $checks.Add([pscustomobject]@{
            Name   = 'BootImage'
            Status = ($sourceBootIndexes -eq $outputBootIndexes) ? 'Passed' : 'Failed'
            Detail = "boot.wim indexes: source $sourceBootIndexes, output $outputBootIndexes"
        })
    $sourceInstallImage = @('install.wim', 'install.esd' | ForEach-Object { Join-Path $sourceMedia.Root "sources\$_" } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
    $outputInstallImage = Join-Path $outputMedia.Root 'sources\install.wim'
    if (-not $sourceInstallImage -or -not (Test-Path -LiteralPath $outputInstallImage -PathType Leaf)) {
        throw "Expected sources\install.wim or install.esd on the source and sources\install.wim on the output; source image '$sourceInstallImage'."
    }
    $sourceImages = @(Get-WindowsImage -ImagePath $sourceInstallImage -ErrorAction Stop | ForEach-Object { Get-WindowsImage -ImagePath $sourceInstallImage -Index $_.ImageIndex -ErrorAction Stop })
    $outputImages = @(Get-WindowsImage -ImagePath $outputInstallImage -ErrorAction Stop | ForEach-Object { Get-WindowsImage -ImagePath $outputInstallImage -Index $_.ImageIndex -ErrorAction Stop })
    $sourceEditions = @($sourceImages | ForEach-Object { "$($_.ImageIndex):$($_.EditionId):$($_.ImageName)" }) -join '; '
    $outputEditions = @($outputImages | ForEach-Object { "$($_.ImageIndex):$($_.EditionId):$($_.ImageName)" }) -join '; '
    $checks.Add([pscustomobject]@{
            Name   = 'InstallIndexes'
            Status = ($sourceEditions -eq $outputEditions) ? 'Passed' : 'Failed'
            Detail = "Source [$sourceEditions]; output [$outputEditions]"
        })
    $servicedRecords = @($manifest.images.install | Where-Object serviced)
    $servicedIndexes = @($servicedRecords | ForEach-Object { [int]$_.index } | Sort-Object)
    $indexOk = if ($ExpectedIndex) { ($servicedIndexes -join ',') -eq (@($ExpectedIndex | Sort-Object -Unique) -join ',') } else { $servicedIndexes.Count -gt 0 }
    $checks.Add([pscustomobject]@{
            Name   = 'ServicedIndexes'
            Status = $indexOk ? 'Passed' : 'Failed'
            Detail = "Serviced: $($servicedIndexes -join ', '); expected: $(if ($ExpectedIndex) { $ExpectedIndex -join ', ' } else { 'at least one' })"
        })
    foreach ($record in $servicedRecords) {
        $index = [int]$record.index
        $after = Get-ImageServicingState -ImagePath $outputInstallImage -Index $index -MountPath (Join-Path $validationRoot "output-$index")
        $before = if ($sourceInstallImage -like '*.wim') { Get-ImageServicingState -ImagePath $sourceInstallImage -Index $index -MountPath (Join-Path $validationRoot "source-$index") }
        $applied = @($record.applied)
        $rollupBefore = $before ? $before.RollupVersion : ($record.rollupBefore ? [version]$record.rollupBefore : $null)
        $cumulativeResult = ($applied | Where-Object { $_.kb -eq ${cumulative}?.kb -and $_.result -notlike 'ServicingStackOnly:*' } | Select-Object -Last 1)?.result
        if (-not $cumulative) {
            $cumulativeStatus = 'Failed'
            $cumulativeDetail = 'No cumulative update was planned.'
        }
        elseif (-not $cumulativeResult) {
            $cumulativeStatus = 'Failed'
            $cumulativeDetail = "$($cumulative.kb) is not in the applied sequence of index $index."
        }
        elseif ($cumulative.osBuild) {
            $expectedRevision = [int]($cumulative.osBuild -split '\.')[1]
            $cumulativeStatus = ($after.RollupVersion -and $after.RollupVersion.Minor -eq $expectedRevision) ? 'Passed' : 'Failed'
            $cumulativeDetail = "Package_for_RollupFix $rollupBefore -> $($after.RollupVersion); $($cumulative.kb) title OS build $($cumulative.osBuild); DISM result $cumulativeResult"
        }
        else {
            $kbPackage = @($after.Packages | Where-Object { $_.Name -like "Package_for_$($cumulative.kb)~*" -and $_.State -in 'Installed', 'InstallPending' })
            $rollupIncreased = $after.RollupVersion -and (-not $rollupBefore -or $after.RollupVersion -gt $rollupBefore)
            $cumulativeStatus = ($kbPackage.Count -gt 0 -or $rollupIncreased) ? 'Passed' : 'Failed'
            $cumulativeDetail = "Package_for_$($cumulative.kb) present: $($kbPackage.Count -gt 0); Package_for_RollupFix $rollupBefore -> $($after.RollupVersion); DISM result $cumulativeResult"
        }
        $checks.Add([pscustomobject]@{
                Name   = "Index${index}CumulativeUpdate"
                Status = $cumulativeStatus
                Detail = $cumulativeDetail
            })
        $stackBefore = ${before}?.TrustedInstallerVersion
        $stackAfter = $after.TrustedInstallerVersion
        $stackDecreased = $stackBefore -and $stackAfter -and $stackAfter -lt $stackBefore
        $beforeNames = @(if ($before) { $before.Packages | ForEach-Object Name })
        $stackVersions = "TrustedInstaller.exe $stackBefore -> $stackAfter; Package_for_ServicingStack $(${before}?.ServicingStackPackageVersion) -> $($after.ServicingStackPackageVersion)"
        foreach ($stack in $standaloneStacks) {
            $stackResult = ($applied | Where-Object kb -EQ $stack.kb | Select-Object -Last 1)?.result
            $stackPackage = @($after.Packages | Where-Object { $_.Name -like "Package_for_$($stack.kb)~*" -and $_.State -in 'Installed', 'InstallPending' })
            $newStackPackage = @(if ($before) { $after.Packages | Where-Object { $_.Name -like 'Package_for_ServicingStack*' -and $_.Name -notin $beforeNames } })
            $present = $stackPackage.Count -gt 0 -or $newStackPackage.Count -gt 0 -or $stackResult -eq 'NotApplicable'
            $checks.Add([pscustomobject]@{
                    Name   = "Index${index}ServicingStack"
                    Status = ($stackResult -and $present -and -not $stackDecreased) ? 'Passed' : 'Failed'
                    Detail = "$($stack.kb): DISM result $stackResult; package $(@($stackPackage + $newStackPackage | ForEach-Object Name) -join ', '); $stackVersions"
                })
        }
        if ($standaloneStacks.Count -eq 0) {
            $combinedStatus = if ($stackDecreased -or -not $stackAfter) { 'Failed' } elseif ($servicing.ServicingStackCombined) { $cumulativeStatus } else { 'NotApplicable' }
            $combinedDetail = if ($servicing.ServicingStackCombined) { "Servicing stack delivered by the combined cumulative update $(${cumulative}?.kb); $stackVersions" } else { "The plan contains no standalone servicing stack update; $stackVersions" }
            $checks.Add([pscustomobject]@{
                    Name   = "Index${index}ServicingStack"
                    Status = $combinedStatus
                    Detail = $combinedDetail
                })
        }
        if ($servicing.CheckpointUpdates) {
            $targetFiles = @(${cumulative}?.files | Where-Object role -EQ 'Target')
            $checkpointFiles = @(${cumulative}?.files | Where-Object role -EQ 'Checkpoint')
            $checkpointStatus = if ($targetFiles.Count -ne 1) { 'Failed' } else { $cumulativeStatus }
            $checks.Add([pscustomobject]@{
                    Name   = "Index${index}Checkpoint"
                    Status = $checkpointStatus
                    Detail = "Target $(@($targetFiles | ForEach-Object name) -join ', '); checkpoint $(if ($checkpointFiles) { $checkpointFiles.name -join ', ' } else { 'none required' }); DISM installs the target only after its checkpoints, so the verified target revision confirms the chain"
                })
        }
        $partial = @($after.Packages | Where-Object State -EQ 'PartiallyInstalled')
        $checks.Add([pscustomobject]@{
                Name   = "Index${index}PackageState"
                Status = ($partial.Count -eq 0) ? 'Passed' : 'Failed'
                Detail = $partial ? "Partially installed: $($partial.Name -join ', ')" : "$($after.Packages.Count) packages, none partially installed"
            })
        $winRe = $record.PSObject.Properties['winRe']?.Value
        if ($winRe -and $winRe.serviced) {
            $originalWinRe = $winRe.sourceSha256
            $winReOk = $after.WinReSha256 -and $after.WinReSha256 -ne $originalWinRe -and (-not $before -or $before.WinReSha256 -eq $originalWinRe)
            $checks.Add([pscustomobject]@{
                    Name   = "Index${index}WinRE"
                    Status = $winReOk ? 'Passed' : 'Failed'
                    Detail = "Winre.wim SHA-256 $originalWinRe -> $($after.WinReSha256); version $($winRe.versionBefore) -> $($winRe.versionAfter)"
                })
        }
        else {
            $checks.Add([pscustomobject]@{
                    Name   = "Index${index}WinRE"
                    Status = 'NotApplicable'
                    Detail = "WinRE not serviced: $(${winRe}?.reason)"
                })
        }
        $sourceImage = $sourceImages | Where-Object ImageIndex -EQ $index
        $outputImage = $outputImages | Where-Object ImageIndex -EQ $index
        $checks.Add([pscustomobject]@{
                Name   = "Index${index}ImageVersion"
                Status = ($sourceImage -and $outputImage -and [version][string]$outputImage.Version -ge [version][string]$sourceImage.Version) ? 'Passed' : 'Failed'
                Detail = "$(${sourceImage}?.Version) -> $(${outputImage}?.Version)"
            })
        $images.Add([pscustomobject][ordered]@{
                index                 = $index
                edition               = ${outputImage}?.EditionId
                name                  = ${outputImage}?.ImageName
                imageVersionBefore    = [string]${sourceImage}?.Version
                imageVersionAfter     = [string]${outputImage}?.Version
                rollupBefore          = [string]$rollupBefore
                rollupAfter           = [string]$after.RollupVersion
                servicingStackBefore  = [string]$stackBefore
                servicingStackAfter   = [string]$stackAfter
                servicingStackPackage = [string]$after.ServicingStackPackageVersion
                appliedSequence       = @($applied | ForEach-Object { "$($_.kb) $($_.category): $($_.result)" })
            })
    }
}
catch {
    $checks.Add([pscustomobject]@{
            Name   = 'Inspection'
            Status = 'Failed'
            Detail = "$_"
        })
}
finally {
    if (${outputMedia}?.MountedHere) { $null = Dismount-DiskImage -ImagePath $isoPath }
    if (${sourceMedia}?.MountedHere) { $null = Dismount-DiskImage -ImagePath $sourceIso }
    $leftovers = @(Get-WindowsImage -Mounted | Where-Object Path -Like "$validationRoot*")
    if ($leftovers.Count -eq 0 -and -not (Get-ChildItem -LiteralPath $validationRoot -Force)) { Remove-Item -LiteralPath $validationRoot -Force }
}
$checks.Add([pscustomobject]@{
        Name   = 'NoMountedImages'
        Status = ($leftovers.Count -eq 0) ? 'Passed' : 'Failed'
        Detail = $leftovers ? "Still mounted: $($leftovers.Path -join ', '); run dism /Cleanup-Mountpoints" : 'No validation mounts remain'
    })
if ($LogPath) {
    $entries = @(Get-ChildItem -LiteralPath $LogPath -Filter '*.log.jsonl' -File | Get-Content | Where-Object { $_ } | ForEach-Object { ConvertFrom-Json -InputObject $_ })
    $errors = @($entries | Where-Object level -EQ 'Error')
    $warnings = @($entries | Where-Object level -EQ 'Warning')
    $checks.Add([pscustomobject]@{
            Name   = 'RunLog'
            Status = ($entries.Count -gt 0 -and $errors.Count -eq 0) ? 'Passed' : 'Failed'
            Detail = $errors ? "Errors: $(@($errors | ForEach-Object { "[$($_.operation)] $($_.message)" }) -join ' | ')" : "$($entries.Count) entries, $($warnings.Count) warnings, no errors"
        })
}
else {
    $checks.Add([pscustomobject]@{
            Name   = 'RunLog'
            Status = 'Skipped'
            Detail = 'No -LogPath given'
        })
}
$cumulativeVerified = $servicedRecords.Count -gt 0 -and @($servicedRecords | Where-Object { $name = "Index$($_.index)CumulativeUpdate"; -not ($checks | Where-Object { $_.Name -eq $name -and $_.Status -eq 'Passed' }) }).Count -eq 0

[pscustomobject][ordered]@{
    PSTypeName      = 'WindowsIsoServicing.LiveValidationResult'
    Passed          = $cumulativeVerified -and -not ($checks | Where-Object Status -EQ 'Failed')
    IsoPath         = $isoPath
    IsoSha256       = $isoSha256
    SourceIsoPath   = $sourceIso
    SourceSha256    = $sourceActualSha256
    OperatingSystem = "$($manifest.operatingSystem.name) $($manifest.operatingSystem.version) build $($manifest.operatingSystem.build) $($manifest.operatingSystem.architecture)"
    Updates         = @($manifest.updates | ForEach-Object { [pscustomobject][ordered]@{ kb = $_.kb; category = $_.category; osBuild = $_.osBuild; files = @($_.files | ForEach-Object { "$($_.name) ($($_.role), SHA-256 $($_.sha256))" }) } })
    Images          = $images.ToArray()
    Checks          = $checks.ToArray()
    StartedAt       = $startedAt.ToString('o')
    CompletedAt     = [DateTimeOffset]::Now.ToString('o')
}
