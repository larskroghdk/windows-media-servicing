function Publish-WindowsISO {

    <#
    .SYNOPSIS
        Publishes a validated ISO to an artifact store and makes it the latest known-good media.

    .DESCRIPTION
        Copies the ISO, manifest and checksum file to '<StorePath>\<MediaKey>\<IsoName>\', verifies the copied ISO
        against the manifest checksum and only then replaces '<StorePath>\<MediaKey>\latest.json'. ISOs whose manifest
        does not record a passed validation are refused, so the latest known-good media is never replaced by unvalidated
        media.
        Publishing an ISO that is already in the store only moves the latest pointer, which is how a rollback is done.
        After publishing, older versions beyond -RetainCount are removed; the latest version is always kept.

    .PARAMETER ManifestPath
        Manifest of the ISO to publish ('<iso>.json'). An ISO path is also accepted.

    .PARAMETER StorePath
        Artifact store root, typically a file share outside source control.

    .PARAMETER RetainCount
        Number of published versions to keep per media key.

    .EXAMPLE
        Publish-WindowsISO -ManifestPath 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso.json' -StorePath '\\fs01\iso'

    .EXAMPLE
        Publish-WindowsISO -ManifestPath '\\fs01\iso\WindowsServer2025_x64_en-us\Windows_Server_2025_x64_26100_2026-10\Windows_Server_2025_x64_26100_2026-10.iso.json' -StorePath '\\fs01\iso'

    .OUTPUTS
        WindowsIsoServicing.Publication

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        Update-WindowsISO

    .LINK
        Get-WindowsISOManifest
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType('WindowsIsoServicing.Publication')]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('IsoPath')]
        [ValidateNotNullOrEmpty()]
        [string]$ManifestPath,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$StorePath,
        [ValidateRange(1, 100)]
        [int]$RetainCount = 3
    )

    process {
        $manifestFile = Resolve-TrustedFilePath -Path $(if ($ManifestPath -like '*.iso') { "$ManifestPath.json" } else { $ManifestPath }) -AllowedExtension '.json'
        $manifest = Read-ServicingManifest -Path $manifestFile
        if (-not $manifest.validation.passed) {
            throw "Refusing to publish $($manifest.output.fileName): its manifest does not record a passed validation."
        }
        $isoName = $manifest.output.fileName
        $sourceIso = Resolve-TrustedFilePath -Path (Join-Path (Split-Path $manifestFile) $isoName) -AllowedExtension '.iso'
        $language = if ($manifest.operatingSystem.language) { $manifest.operatingSystem.language.ToLowerInvariant() } else { 'neutral' }
        $mediaKey = '{0}_{1}_{2}' -f $manifest.operatingSystem.key, $manifest.operatingSystem.architecture, $language
        $store = Resolve-DirectoryPath -Path $StorePath
        $keyPath = Join-Path $store $mediaKey
        $versionName = [System.IO.Path]::GetFileNameWithoutExtension($isoName)
        $versionPath = Join-Path $keyPath $versionName
        $publishedIso = Join-Path $versionPath $isoName
        if (-not $PSCmdlet.ShouldProcess($mediaKey, "Publish $isoName as latest known-good media")) { return }
        $null = New-Item -Path $versionPath -ItemType Directory -Force
        $lock = Lock-Directory -Directory $keyPath
        try {
            $alreadyPublished = (Test-Path -LiteralPath $publishedIso -PathType Leaf) -and ((Get-FileSha256 -Path $publishedIso) -eq $manifest.output.sha256)
            if (-not $alreadyPublished) {
                $sourceHash = Get-FileSha256 -Path $sourceIso
                if ($sourceHash -ne $manifest.output.sha256) {
                    throw "Checksum of '$sourceIso' ($sourceHash) does not match its manifest ($($manifest.output.sha256))."
                }
                $partial = "$publishedIso.partial"
                try {
                    Copy-Item -LiteralPath $sourceIso -Destination $partial -Force -ErrorAction Stop
                    if ((Get-FileSha256 -Path $partial) -ne $manifest.output.sha256) {
                        throw "Checksum mismatch after copying '$isoName' to the store."
                    }
                    Move-Item -LiteralPath $partial -Destination $publishedIso -Force -ErrorAction Stop
                }
                catch {
                    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
                    throw
                }
                Copy-Item -LiteralPath $manifestFile -Destination "$publishedIso.json" -Force
                Set-Content -LiteralPath "$publishedIso.sha256" -Value "$($manifest.output.sha256) *$isoName" -Encoding ascii
            }
            $publishedAt = [DateTimeOffset]::Now.ToString('o')
            $latest = $manifest | Select-Object *
            $latest | Add-Member -NotePropertyName publication -NotePropertyValue ([ordered]@{
                    mediaKey    = $mediaKey
                    publishedAt = $publishedAt
                    isoPath     = $publishedIso
                    publishedBy = "$env:USERDOMAIN\$env:USERNAME"
                }) -Force
            $latestPath = Join-Path $keyPath 'latest.json'
            $latest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath "$latestPath.tmp" -Encoding utf8NoBOM
            Move-Item -LiteralPath "$latestPath.tmp" -Destination $latestPath -Force
            $historyPath = Join-Path $keyPath 'history.json'
            $history = @(if (Test-Path -LiteralPath $historyPath) { Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json })
            $history += [pscustomobject]@{ publishedAt = $publishedAt; fileName = $isoName; sha256 = $manifest.output.sha256; rollback = $alreadyPublished }
            ConvertTo-Json -InputObject @($history) -Depth 4 | Set-Content -LiteralPath "$historyPath.tmp" -Encoding utf8NoBOM
            Move-Item -LiteralPath "$historyPath.tmp" -Destination $historyPath -Force
            $versions = foreach ($directory in Get-ChildItem -LiteralPath $keyPath -Directory) {
                $versionManifest = Join-Path $directory.FullName "$($directory.Name).iso.json"
                if (Test-Path -LiteralPath $versionManifest) {
                    [pscustomobject]@{ Path = $directory.FullName; CreatedAt = [datetime](Get-Content -LiteralPath $versionManifest -Raw | ConvertFrom-Json).createdAt }
                }
            }
            $keep = @($versions | Sort-Object CreatedAt -Descending | Select-Object -First $RetainCount | ForEach-Object Path) + $versionPath
            $removed = foreach ($version in $versions | Where-Object { $_.Path -notin $keep }) {
                if ($PSCmdlet.ShouldProcess($version.Path, 'Remove version beyond retention')) {
                    Remove-Item -LiteralPath $version.Path -Recurse -Force
                    $version.Path
                }
            }
            [pscustomobject]@{
                PSTypeName = 'WindowsIsoServicing.Publication'
                MediaKey   = $mediaKey
                IsoPath    = $publishedIso
                LatestPath = $latestPath
                Sha256     = $manifest.output.sha256
                IsRollback = $alreadyPublished
                Removed    = @($removed)
            }
        }
        finally {
            Unlock-Directory -Lock $lock
        }
    }
}
