function Get-WindowsISOInfo {

    <#
    .SYNOPSIS
        Inspects a Windows installation ISO and identifies its operating system, editions and servicing state.

    .DESCRIPTION
        Mounts the ISO read-only, locates sources\install.wim or sources\install.esd, enumerates every image index and
        identifies the Windows release, build, architecture, edition, installation type and lifecycle status of each.
        With -IncludePackages, each index of a WIM image is mounted read-only and its installed update packages are listed.
        The ISO is never modified.

    .PARAMETER SourceISO
        Path to the Windows installation ISO.

    .PARAMETER IncludePackages
        Mounts each index read-only and lists installed update packages. Not available for install.esd.

    .PARAMETER SkipChecksum
        Does not calculate the SHA-256 checksum of the ISO.

    .PARAMETER WorkspacePath
        Folder used for read-only mount points when -IncludePackages is specified.

    .EXAMPLE
        Get-WindowsISOInfo -SourceISO 'D:\ISO\Windows_Server_2025.iso'

    .EXAMPLE
        Get-WindowsISOInfo -SourceISO 'D:\ISO\Windows_11_24H2.iso' -IncludePackages | Select-Object -ExpandProperty Images

    .OUTPUTS
        WindowsIsoServicing.IsoInfo

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        Get-WindowsISOUpdates

    .LINK
        Update-WindowsISO
    #>

    [CmdletBinding()]
    [OutputType('WindowsIsoServicing.IsoInfo')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path')]
        [ValidateNotNullOrEmpty()]
        [string]$SourceISO,
        [switch]$IncludePackages,
        [switch]$SkipChecksum,
        [ValidateNotNullOrEmpty()]
        [string]$WorkspacePath = (Get-DefaultServicingPath -Kind Workspace)
    )

    process {
        Assert-Administrator
        $isoPath = Resolve-TrustedFilePath -Path $SourceISO -AllowedExtension '.iso'
        $sha256 = if (-not $SkipChecksum) { Get-FileSha256 -Path $isoPath }
        $alreadyMounted = (Get-DiskImage -ImagePath $isoPath).Attached
        $mediaRoot = Mount-IsoImage -Path $isoPath
        try {
            $installImage = Get-InstallImagePath -MediaRoot $mediaRoot
            $inventory = @(Get-InstallImageInventory -ImagePath $installImage)
            $format = [System.IO.Path]::GetExtension($installImage).TrimStart('.').ToLowerInvariant()
            if ($IncludePackages) {
                if ($format -ne 'wim') {
                    Write-Warning 'Installed packages cannot be listed for install.esd images without converting them; -IncludePackages ignored.'
                }
                else {
                    $mountRoot = Join-Path (Resolve-DirectoryPath -Path $WorkspacePath -Create) "inspect-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
                    try {
                        foreach ($image in $inventory) {
                            $mountPath = Join-Path $mountRoot "index-$($image.Index)"
                            $null = New-Item -Path $mountPath -ItemType Directory -Force
                            $null = Mount-WindowsImage -ImagePath $installImage -Index $image.Index -Path $mountPath -ReadOnly -ErrorAction Stop
                            try {
                                $image | Add-Member -NotePropertyName RollupVersion -NotePropertyValue (Get-RollupVersion -MountPath $mountPath)
                                $image | Add-Member -NotePropertyName Packages -NotePropertyValue @(Get-InstalledPackageList -MountPath $mountPath)
                            }
                            finally {
                                $null = Dismount-WindowsImage -Path $mountPath -Discard -ErrorAction Stop
                            }
                        }
                    }
                    finally {
                        $null = Clear-ServicingMount -Root $mountRoot -Confirm:$false
                        Remove-Item -LiteralPath $mountRoot -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            $builds = @($inventory | Select-Object -ExpandProperty Build -Unique)
            $architectures = @($inventory | Select-Object -ExpandProperty Architecture -Unique)
            [pscustomobject]@{
                PSTypeName         = 'WindowsIsoServicing.IsoInfo'
                SourceIso          = $isoPath
                Sha256             = $sha256
                SizeBytes          = (Get-Item -LiteralPath $isoPath).Length
                VolumeLabel        = Get-IsoVolumeLabel -MediaRoot $mediaRoot
                InstallImageFormat = $format
                BootConfiguration  = Get-MediaBootConfiguration -MediaRoot $mediaRoot
                Build              = if ($builds.Count -eq 1) { $builds[0] } else { $builds }
                Architecture       = if ($architectures.Count -eq 1) { $architectures[0] } else { $architectures }
                OperatingSystem    = $inventory[0].OperatingSystem
                Images             = $inventory
            }
        }
        finally {
            if (-not $alreadyMounted) { Dismount-IsoImage -Path $isoPath }
        }
    }
}
