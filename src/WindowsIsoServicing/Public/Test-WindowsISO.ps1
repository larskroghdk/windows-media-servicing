function Test-WindowsISO {

    <#
    .SYNOPSIS
        Validates a Windows installation ISO structurally and, optionally, by installing it in a Hyper-V VM.

    .DESCRIPTION
        Structural validation mounts the ISO and checks the boot files for each boot mode, the setup files, and that
        boot.wim and the installation image are readable. With a manifest, the SHA-256 checksum, editions and image
        versions are compared with the recorded values. -Deep additionally mounts each serviced index read-only with
        integrity checking and compares the installed cumulative update package version.
        Structural validation does not prove that the media boots or installs. -BootTest performs an unattended
        installation of one index in a temporary Hyper-V VM and passes only when Setup reaches the specialize pass on
        the installed disk. When the manifest records a UEFI boot entry without "Press any key" (uefiNoPrompt), no key is
        pressed, so the test also shows that the ISO reaches Setup unattended; otherwise Enter is sent for media that
        still prompts.

    .PARAMETER Path
        Path to the ISO.

    .PARAMETER ManifestPath
        Manifest produced by Update-WindowsISO. Defaults to '<Path>.json' when that file exists.

    .PARAMETER Deep
        Mounts serviced indexes read-only and verifies installed package versions.

    .PARAMETER BootTest
        Installs one index in a temporary Hyper-V VM.

    .PARAMETER BootTestIndex
        Index installed by the boot test. Defaults to the first serviced index, or index 1.

    .PARAMETER Firmware
        Firmware used by the boot test VM: UEFI (generation 2, Secure Boot) or BIOS (generation 1).

    .PARAMETER ProductKey
        Product key for the boot test answer file, for media that requires one during Setup.

    .PARAMETER TimeoutMinutes
        Maximum duration of the boot test.

    .PARAMETER WorkspacePath
        Folder for mount points and boot test files.

    .PARAMETER OscdimgPath
        Path to oscdimg.exe, or to a folder that contains it or the Windows ADK, used to build the boot test answer file
        media. Defaults to the installed Windows ADK Deployment Tools.

    .EXAMPLE
        Test-WindowsISO -Path 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso'

    .EXAMPLE
        Test-WindowsISO -Path 'D:\ISO\Updated\Windows_Server_2022_x64_20348_2026-11.iso' -Deep -BootTest -Firmware BIOS

    .OUTPUTS
        WindowsIsoServicing.ValidationResult

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        Update-WindowsISO

    .LINK
        Get-WindowsISOManifest
    #>

    [CmdletBinding()]
    [OutputType('WindowsIsoServicing.ValidationResult')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('IsoPath', 'FullName')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [string]$ManifestPath,
        [switch]$Deep,
        [switch]$BootTest,
        [ValidateRange(1, 256)]
        [int]$BootTestIndex,
        [ValidateSet('UEFI', 'BIOS')]
        [string]$Firmware = 'UEFI',
        [ValidatePattern('^([A-Z0-9]{5}-){4}[A-Z0-9]{5}$')]
        [string]$ProductKey,
        [ValidateRange(10, 240)]
        [int]$TimeoutMinutes = 90,
        [ValidateNotNullOrEmpty()]
        [string]$WorkspacePath = (Get-DefaultServicingPath -Kind Workspace),
        [string]$OscdimgPath
    )

    process {
        Assert-Administrator
        $isoPath = Resolve-TrustedFilePath -Path $Path -AllowedExtension '.iso'
        if (-not $ManifestPath -and (Test-Path -LiteralPath "$isoPath.json" -PathType Leaf)) { $ManifestPath = "$isoPath.json" }
        $manifest = if ($ManifestPath) { Read-ServicingManifest -Path (Resolve-TrustedFilePath -Path $ManifestPath -AllowedExtension '.json') }
        $workspace = Resolve-DirectoryPath -Path $WorkspacePath -Create
        Protect-ServicingDirectory -Path $workspace -Confirm:$false
        $runPath = Join-Path $workspace "validate-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $null = New-Item -Path $runPath -ItemType Directory -Force
        try {
            $structural = Test-IsoStructure -IsoPath $isoPath -Manifest $manifest -Deep:$Deep -MountRoot $runPath
            $bootResult = [pscustomobject]@{ performed = $false }
            if ($BootTest) {
                $index = if ($BootTestIndex) { $BootTestIndex }
                elseif ($manifest) { @($manifest.images.install | Where-Object serviced)[0].index }
                else { 1 }
                $noPromptRecorded = [bool]${manifest}?.output.bootModes.PSObject.Properties['uefiNoPrompt']?.Value
                $language = if ($manifest -and $manifest.operatingSystem.language) { $manifest.operatingSystem.language } else { 'en-US' }
                $bootResult = Invoke-HyperVBootTest -IsoPath $isoPath -Index $index -Language $language -WorkPath $runPath -OscdimgPath (Find-Oscdimg -Path $OscdimgPath).Path -Firmware $Firmware -TimeoutMinutes $TimeoutMinutes -ProductKey $ProductKey -SendBootKeys:(-not $noPromptRecorded)
            }
            [pscustomobject]@{
                PSTypeName   = 'WindowsIsoServicing.ValidationResult'
                IsoPath      = $isoPath
                ManifestPath = $ManifestPath
                Passed       = $structural.passed -and (-not $bootResult.performed -or $bootResult.result -eq 'Passed')
                Sha256       = $structural.sha256
                Structural   = $structural
                BootTest     = $bootResult
            }
        }
        finally {
            $null = Clear-ServicingMount -Root $runPath -Confirm:$false
            Remove-Item -LiteralPath $runPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
