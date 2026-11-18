function Mount-IsoImage {
    <#
    .SYNOPSIS
        Mounts an ISO read-only and returns its drive root.

    .DESCRIPTION
        Mounts the ISO with -Access ReadOnly, so the source ISO is never modified (INVARIANTS.md, Media #1), or reuses an
        existing mount. The volume appears shortly after the mount returns, so its drive letter is polled for up to five
        seconds. When no drive letter is assigned, the ISO is dismounted on a best-effort basis and the function throws
        with the remedy (mountvol /E).

    .PARAMETER Path
        Full path of the ISO.

    .EXAMPLE
        Mount-IsoImage -Path 'D:\ISO\Windows_Server_2025.iso'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/storage/mount-diskimage
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'Mount ISO read-only')) { return }
    $diskImage = Get-DiskImage -ImagePath $Path -ErrorAction Stop
    if (-not $diskImage.Attached) {
        $diskImage = Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly -PassThru -ErrorAction Stop
    }
    $volume = $null
    foreach ($attempt in 1..10) {
        $volume = $diskImage | Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveLetter | Select-Object -First 1
        if ($volume) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $volume) {
        Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue | Out-Null
        throw "ISO '$Path' was mounted but no drive letter was assigned. Check that automatic drive letter assignment is enabled (mountvol /E)."
    }
    Write-ServicingLog -Operation 'MountIso' -Target $Path -Message "Mounted at $($volume.DriveLetter):\"
    "$($volume.DriveLetter):\"
}

function Dismount-IsoImage {
    <#
    .SYNOPSIS
        Dismounts an ISO when it is mounted.

    .DESCRIPTION
        Dismounts the ISO when Get-DiskImage reports it as attached (subject to -WhatIf and -Confirm). A path that is not a
        known disk image is not mounted, so it is ignored.

    .PARAMETER Path
        Full path of the ISO.

    .EXAMPLE
        Dismount-IsoImage -Path 'D:\ISO\Windows_Server_2025.iso'

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $diskImage = Get-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue
    if ($diskImage -and $diskImage.Attached -and $PSCmdlet.ShouldProcess($Path, 'Dismount ISO')) {
        Dismount-DiskImage -ImagePath $Path -ErrorAction Stop | Out-Null
        Write-ServicingLog -Operation 'DismountIso' -Target $Path -Message 'Dismounted'
    }
}

function Get-IsoVolumeLabel {
    <#
    .SYNOPSIS
        Returns the volume label of a mounted ISO.

    .DESCRIPTION
        Reads the file system label of the volume whose drive letter is the first character of MediaRoot.

    .PARAMETER MediaRoot
        Drive root of the mounted ISO, for example 'F:\'.

    .EXAMPLE
        Get-IsoVolumeLabel -MediaRoot 'F:\'

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
        [string]$MediaRoot
    )
    $volume = Get-Volume -DriveLetter $MediaRoot.Substring(0, 1) -ErrorAction Stop
    $volume.FileSystemLabel
}

function Get-InstallImagePath {
    <#
    .SYNOPSIS
        Returns the path of the installation image on Windows media.

    .DESCRIPTION
        Returns sources\install.wim or sources\install.esd. Split images (install.swm) are refused as servicing input, and
        media without an installation image is reported as not being Windows installation media.

    .PARAMETER MediaRoot
        Root of the mounted media.

    .EXAMPLE
        Get-InstallImagePath -MediaRoot 'F:\'

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
        [string]$MediaRoot
    )
    foreach ($name in 'install.wim', 'install.esd', 'install.swm') {
        $candidate = Join-Path $MediaRoot "sources\$name"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            if ($name -eq 'install.swm') {
                throw "Split installation images (install.swm) are not supported as servicing input. Use the original Microsoft ISO."
            }
            return $candidate
        }
    }
    throw "No installation image (sources\install.wim or sources\install.esd) was found under '$MediaRoot'. The ISO is not Windows installation media."
}

function Get-MediaBootConfiguration {
    <#
    .SYNOPSIS
        Detects the BIOS and UEFI boot files of Windows media.

    .DESCRIPTION
        BIOS boot needs boot\etfsboot.com and bootmgr. UEFI boot needs efi\microsoft\boot\efisys.bin and an
        efi\boot\boot*.efi loader; BIOS-only media has no efi\boot folder. Also reports whether efisys_noprompt.bin exists.

    .PARAMETER MediaRoot
        Root of the media.

    .EXAMPLE
        Get-MediaBootConfiguration -MediaRoot 'F:\'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Bios, Uefi, UefiLoader and UefiNoPromptAvailable.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$MediaRoot
    )
    $efiLoader = Get-ChildItem -LiteralPath (Join-Path $MediaRoot 'efi\boot') -Filter 'boot*.efi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $efiBootImage = Join-Path $MediaRoot 'efi\microsoft\boot\efisys.bin'
    $efiBootImageNoPrompt = Join-Path $MediaRoot 'efi\microsoft\boot\efisys_noprompt.bin'
    $biosBootSector = Join-Path $MediaRoot 'boot\etfsboot.com'
    [pscustomobject]@{
        Bios                  = (Test-Path -LiteralPath $biosBootSector -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $MediaRoot 'bootmgr') -PathType Leaf)
        Uefi                  = $null -ne $efiLoader -and (Test-Path -LiteralPath $efiBootImage -PathType Leaf)
        UefiLoader            = if ($efiLoader) { "efi\boot\$($efiLoader.Name)" }
        UefiNoPromptAvailable = Test-Path -LiteralPath $efiBootImageNoPrompt -PathType Leaf
    }
}

function Get-IsoBootEntry {
    <#
    .SYNOPSIS
        Reads the bootable entries of an ISO's El Torito boot catalog.

    .DESCRIPTION
        Finds the El Torito boot record among the ISO 9660 volume descriptors (from sector 16) and reads the boot catalog it points to. Returns one object per bootable entry, the initial entry and the entries of each section, with the platform ('BIOS' for 0x00, 'UEFI' for 0xEF, otherwise 'Platform0x..') and the 2048-byte sector (LoadRba) where OSCDIMG stored the boot image. Validation uses LoadRba to compare the stored UEFI boot image with efisys_noprompt.bin byte for byte, which proves which image the firmware starts, rather than which files happen to be on the media. Returns nothing for an ISO without an El Torito boot record, and throws when the boot catalog is invalid.

    .PARAMETER Path
        Path to the ISO file.

    .EXAMPLE
        Get-IsoBootEntry -Path 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Platform, LoadRba and SectorCount.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows-hardware/manufacture/desktop/oscdimg-command-line-options
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
            if ([System.Text.Encoding]::ASCII.GetString($sector, 1, 5) -ne 'CD001' -or $sector[0] -eq 255) {
                break
            }
            if ($sector[0] -eq 0 -and [System.Text.Encoding]::ASCII.GetString($sector, 7, 23) -eq 'EL TORITO SPECIFICATION') {
                $catalogSector = [System.BitConverter]::ToUInt32($sector, 0x47)
                break
            }
        }
        if ($null -eq $catalogSector) {
            return
        }
        $catalog = [byte[]]::new($sectorSize)
        $null = $stream.Seek([long]$catalogSector * $sectorSize, [System.IO.SeekOrigin]::Begin)
        $stream.ReadExactly($catalog, 0, $sectorSize)
        if ($catalog[0] -ne 1 -or $catalog[30] -ne 0x55 -or $catalog[31] -ne 0xAA) {
            throw "'$Path' has an El Torito boot record, but sector $catalogSector holds no valid boot catalog."
        }
        $entries = [System.Collections.Generic.List[object]]::new()
        $sections = [System.Collections.Generic.List[object]]::new()
        $sections.Add([pscustomobject]@{
                Platform = $catalog[1]
                Offset   = 32
                Count    = 1
            })
        $offset = 64
        while ($offset + 32 -le $sectorSize -and $catalog[$offset] -in 0x90, 0x91) {
            $sections.Add([pscustomobject]@{
                    Platform = $catalog[$offset + 1]
                    Offset   = $offset + 32
                    Count    = [System.BitConverter]::ToUInt16($catalog, $offset + 2)
                })
            $isLastSection = $catalog[$offset] -eq 0x91
            $offset += 32 * (1 + [System.BitConverter]::ToUInt16($catalog, $offset + 2))
            if ($isLastSection) {
                break
            }
        }
        foreach ($section in $sections) {
            for ($entryOffset = $section.Offset; $entryOffset -lt $section.Offset + 32 * $section.Count -and $entryOffset + 32 -le $sectorSize; $entryOffset += 32) {
                if ($catalog[$entryOffset] -ne 0x88) {
                    continue
                }
                $platform = switch ($section.Platform) {
                    0 { 'BIOS' }
                    0xEF { 'UEFI' }
                    default { 'Platform0x{0:X2}' -f $section.Platform }
                }
                $entries.Add([pscustomobject]@{
                        Platform    = $platform
                        LoadRba     = [System.BitConverter]::ToUInt32($catalog, $entryOffset + 8)
                        SectorCount = [System.BitConverter]::ToUInt16($catalog, $entryOffset + 6)
                    })
            }
        }
        $entries.ToArray()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-IsoBootImageSha256 {
    <#
    .SYNOPSIS
        Returns the SHA-256 of a boot image as stored in an ISO.

    .DESCRIPTION
        Reads Length bytes from the 2048-byte sector LoadRba of the ISO, which is where an El Torito boot catalog entry (Get-IsoBootEntry) points the firmware, and returns their SHA-256 as lowercase hexadecimal, like Get-FileSha256. The ISO is opened for reading and shared for reading and writing, so it can be read while it is mounted. Throws when the ISO ends before Length bytes.

    .PARAMETER Path
        Path to the ISO file.

    .PARAMETER LoadRba
        Sector of the boot image, from Get-IsoBootEntry.

    .PARAMETER Length
        Number of bytes to hash, normally the length of the boot image file it is compared with.

    .EXAMPLE
        Get-IsoBootImageSha256 -Path 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso' -LoadRba 1024 -Length 1474560

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
        [Parameter(Mandatory)]
        [uint32]$LoadRba,
        [Parameter(Mandatory)]
        [ValidateRange(1, 67108864)]
        [int]$Length
    )
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $buffer = [byte[]]::new($Length)
        $null = $stream.Seek([long]$LoadRba * 2048, [System.IO.SeekOrigin]::Begin)
        $stream.ReadExactly($buffer, 0, $Length)
        [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($buffer)).ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-InstallImageInventory {
    <#
    .SYNOPSIS
        Lists the indexes of an installation image with their release and lifecycle status.

    .DESCRIPTION
        Reads every index with Get-WindowsImage and identifies its release with Resolve-WindowsRelease for the AsOf date.

    .PARAMETER ImagePath
        Path of install.wim or install.esd.

    .PARAMETER AsOf
        Date the lifecycle status is evaluated for. Defaults to today.

    .EXAMPLE
        Get-InstallImageInventory -ImagePath 'F:\sources\install.wim'

    .OUTPUTS
        WindowsIsoServicing.ImageIndex

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/dism/get-windowsimage
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ImagePath,
        [datetime]$AsOf = [datetime]::Today
    )
    $summaries = Get-WindowsImage -ImagePath $ImagePath -ErrorAction Stop
    foreach ($summary in $summaries) {
        $image = Get-WindowsImage -ImagePath $ImagePath -Index $summary.ImageIndex -ErrorAction Stop
        $os = Resolve-WindowsRelease -Build $image.Build -InstallationType $image.InstallationType -EditionId $image.EditionId -AsOf $AsOf
        [pscustomobject]@{
            PSTypeName       = 'WindowsIsoServicing.ImageIndex'
            Index            = $image.ImageIndex
            Name             = $image.ImageName
            Description      = $image.ImageDescription
            EditionId        = $image.EditionId
            InstallationType = $image.InstallationType
            Architecture     = ConvertTo-ArchitectureName -Architecture $image.Architecture
            Version          = [version]$image.Version
            Build            = $image.Build
            Revision         = $image.SPBuild
            Languages        = @($image.Languages)
            DefaultLanguage  = if ($image.Languages) { @($image.Languages)[$image.DefaultLanguageIndex] }
            SizeBytes        = [long]$image.ImageSize
            OperatingSystem  = $os
        }
    }
}

function Copy-MediaContent {
    <#
    .SYNOPSIS
        Copies the media files, except the installation image, to a writable folder.

    .DESCRIPTION
        Copies every file and folder of the mounted media to Destination and clears the read-only attribute that files
        copied from an ISO carry (subject to -WhatIf and -Confirm). sources\install.wim and sources\install.esd are left
        out, because the installation image is serviced separately and exported into the copy afterwards. boot\bootfix.bin
        is left out too: etfsboot.com shows "Press any key to boot from CD or DVD" on BIOS systems only when that file is on
        the media, so without it the BIOS entry starts Windows Setup directly. No Microsoft boot file is changed.

    .PARAMETER MediaRoot
        Root of the mounted media.

    .PARAMETER Destination
        Folder that receives the copy.

    .EXAMPLE
        Copy-MediaContent -MediaRoot 'F:\' -Destination $context.MediaPath

    .OUTPUTS
        None

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$MediaRoot,
        [Parameter(Mandatory)]
        [string]$Destination
    )
    if (-not $PSCmdlet.ShouldProcess($Destination, "Copy media from $MediaRoot")) { return }
    $excluded = 'sources\install.wim', 'sources\install.esd', 'boot\bootfix.bin'
    $sourceRoot = $MediaRoot.TrimEnd('\')
    foreach ($item in Get-ChildItem -LiteralPath $MediaRoot -Recurse -Force) {
        $relative = $item.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $target = Join-Path $Destination $relative
        if ($item.PSIsContainer) {
            $null = New-Item -Path $target -ItemType Directory -Force
            continue
        }
        if ($relative -in $excluded) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop
        $copied = Get-Item -LiteralPath $target -Force
        if ($copied.IsReadOnly) { $copied.IsReadOnly = $false }
    }
    Write-ServicingLog -Operation 'CopyMedia' -Target $Destination -Message "Copied media from $MediaRoot"
}
