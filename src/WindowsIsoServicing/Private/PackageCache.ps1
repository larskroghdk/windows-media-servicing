function Assert-PackageFileIntegrity {
    <#
    .SYNOPSIS
        Throws unless a package file passes its published hash and a Microsoft signature check.

    .DESCRIPTION
        Compares the file with the published SHA-256, or the SHA-1 when no SHA-256 is published, and then requires a
        valid Microsoft Authenticode signature (INVARIANTS.md, Update discovery #3). The Catalog publishes only SHA-1 for
        older files; SHA-1 is never used without the signature check. Returns which hash was checked.

    .PARAMETER Path
        Path of the package file.

    .PARAMETER Sha1
        Published SHA-1 in hexadecimal.

    .PARAMETER Sha256
        Published SHA-256 in hexadecimal.

    .EXAMPLE
        Assert-PackageFileIntegrity -Path 'E:\UpdateCache\packages\KB5131080\windows11.0-kb5131080-x64.msu' -Sha256 $file.Sha256

    .OUTPUTS
        System.String. SHA256, SHA1 or None.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingBrokenHashAlgorithms', '', Justification = 'The Microsoft Update Catalog publishes only SHA-1 for older files; it is used only with a mandatory Authenticode check.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Sha1,
        [string]$Sha256
    )
    $hashSource = 'None'
    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        if ($actual -ne $Sha256) { throw "SHA-256 mismatch for '$Path': expected $Sha256, got $actual." }
        $hashSource = 'SHA256'
    }
    elseif ($Sha1) {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash
        if ($actual -ne $Sha1) { throw "SHA-1 mismatch for '$Path': expected $Sha1, got $actual." }
        $hashSource = 'SHA1'
    }
    if (-not (Test-MicrosoftSignature -Path $Path)) {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        throw "'$Path' does not carry a valid Microsoft Authenticode signature (status: $($signature.Status); signer: $($signature.SignerCertificate?.Subject))."
    }
    $hashSource
}

function Save-PackageFile {
    <#
    .SYNOPSIS
        Downloads or validates one update package file in the cache.

    .DESCRIPTION
        File names other than <name>.msu or <name>.cab are refused. A repository file (Path without Uri) is validated in
        place. Otherwise the file is cached at <CachePath>\packages\<KB>\<name>: a cached copy that fails validation is
        deleted and downloaded again. Downloads go to a .partial file, are attempted three times, and the partial file is
        deleted after a failed attempt or a failed validation, so the cache only holds validated files. A download over
        HTTP is logged as a warning, because integrity then rests on the hash and the signature.

    .PARAMETER File
        File object from the update plan.

    .PARAMETER Kb
        KB number of the update, used as the cache folder name.

    .PARAMETER CachePath
        Root of the package cache.

    .EXAMPLE
        Save-PackageFile -File $update.Files[0] -Kb $update.Kb -CachePath 'E:\UpdateCache'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$File,
        [Parameter(Mandatory)]
        [string]$Kb,
        [Parameter(Mandatory)]
        [string]$CachePath
    )
    if ($File.Name -notmatch '^[\w.\-]+\.(msu|cab)$') {
        throw "Refusing package file name '$($File.Name)'."
    }
    $relativePath = Join-Path 'packages' (Join-Path $Kb $File.Name)
    $destination = Join-Path $CachePath $relativePath
    if ($File.Path -and -not $File.Uri) {
        if (-not (Test-Path -LiteralPath $File.Path -PathType Leaf)) { throw "Repository file '$($File.Path)' does not exist." }
        $hashSource = Assert-PackageFileIntegrity -Path $File.Path -Sha1 $File.Sha1 -Sha256 $File.Sha256
        $result = $File.PSObject.Copy()
        $result | Add-Member -NotePropertyName HashSource -NotePropertyValue $hashSource -Force
        $result.Sha256 = Get-FileSha256 -Path $File.Path
        return $result
    }
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        try {
            $hashSource = Assert-PackageFileIntegrity -Path $destination -Sha1 $File.Sha1 -Sha256 $File.Sha256
            Write-ServicingLog -Operation 'Download' -Target $File.Name -Message 'Using cached package'
        }
        catch {
            Write-ServicingLog -Operation 'Download' -Level Warning -Target $File.Name -Message "Cached file failed validation and will be downloaded again: $_"
            if ($PSCmdlet.ShouldProcess($destination, 'Remove invalid cached package')) {
                Remove-Item -LiteralPath $destination -Force
            }
        }
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        if (-not $PSCmdlet.ShouldProcess($destination, "Download $($File.Name)")) { return }
        $null = New-Item -Path (Split-Path $destination) -ItemType Directory -Force
        $partial = "$destination.partial"
        if (-not $File.Uri) { throw "No download location is available for '$($File.Name)'." }
        $uri = [uri]$File.Uri
        if ($uri.Scheme -notin 'https', 'http') { throw "Unsupported URI scheme in '$uri'." }
        if ($uri.Scheme -eq 'http') {
            Write-ServicingLog -Operation 'Download' -Level Warning -Target $File.Name -Message "Source is not HTTPS ($uri); integrity relies on the published hash and Authenticode signature."
        }
        for ($attempt = 1; ; $attempt++) {
            try {
                Write-ServicingLog -Operation 'Download' -Target $File.Name -Message "Downloading from $uri (attempt $attempt)"
                Invoke-WebRequest -Uri $uri -OutFile $partial -MaximumRetryCount 3 -RetryIntervalSec 15 -ErrorAction Stop
                break
            }
            catch {
                Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                if ($attempt -ge 3) { throw "Unable to download '$($File.Name)' from ${uri}: $_" }
                Write-ServicingLog -Operation 'Download' -Level Warning -Target $File.Name -Message "Download failed, retrying in 30 s: $_"
                Start-Sleep -Seconds 30
            }
        }

        try {
            $hashSource = Assert-PackageFileIntegrity -Path $partial -Sha1 $File.Sha1 -Sha256 $File.Sha256
        }
        catch {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            throw
        }
        Move-Item -LiteralPath $partial -Destination $destination -Force
    }
    $result = $File.PSObject.Copy()
    $result.Path = $destination
    $result.Sha256 = Get-FileSha256 -Path $destination
    $result | Add-Member -NotePropertyName HashSource -NotePropertyValue $hashSource -Force
    $result | Add-Member -NotePropertyName RelativePath -NotePropertyValue $relativePath -Force
    $result
}

function Save-UpdatePackage {
    <#
    .SYNOPSIS
        Saves the files of planned updates to the cache and records them in its index.

    .DESCRIPTION
        Holds the cache lock, saves every file of every update with Save-PackageFile and returns the updates with their
        saved files. Updates from the Microsoft Update Catalog are recorded in updates.json, replacing an earlier entry
        for the same KB, release and architecture, so the cache can later be used as a repository with -RepositoryPath.
        The index is written to a temporary file and moved into place. With -WhatIf nothing is downloaded or written.

    .PARAMETER Update
        Updates from the update plan.

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .PARAMETER CachePath
        Root of the package cache.

    .EXAMPLE
        Save-UpdatePackage -Update $plan.Updates -OperatingSystem $release -Architecture 'x64' -CachePath 'E:\UpdateCache'

    .OUTPUTS
        WindowsIsoServicing.Update

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Update,
        [Parameter(Mandatory)]
        [pscustomobject]$OperatingSystem,
        [Parameter(Mandatory)]
        [string]$Architecture,
        [Parameter(Mandatory)]
        [string]$CachePath
    )
    $cacheLock = Lock-Directory -Directory $CachePath -Name '.cache.lock'
    try {
        $index = Read-RepositoryIndex -RepositoryPath $CachePath
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($existing in $index.updates) { $entries.Add($existing) }
        foreach ($item in $Update) {
            $files = foreach ($file in $item.Files) {
                Save-PackageFile -File $file -Kb $item.Kb -CachePath $CachePath -WhatIf:$WhatIfPreference
            }
            $saved = $item.PSObject.Copy()
            $saved.Files = @($files)
            $saved
            if ($item.Source -ne 'MicrosoftUpdateCatalog' -or $WhatIfPreference) { continue }
            $entry = [pscustomobject][ordered]@{
                category     = $item.Category
                kb           = $item.Kb
                title        = $item.Title
                releaseKey   = $OperatingSystem.Key
                architecture = $Architecture
                releaseMonth = $item.ReleaseMonth
                isPreview    = $item.IsPreview
                osBuild      = $item.OsBuild
                updateId     = $item.UpdateId
                files        = @($files | ForEach-Object {
                        [pscustomobject][ordered]@{ name = $_.Name; path = $_.RelativePath; sha1 = $_.Sha1; sha256 = $_.Sha256; size = $_.Size; role = $_.Role }
                    })
            }
            $duplicates = @($entries | Where-Object { $_.kb -eq $entry.kb -and $_.releaseKey -eq $entry.releaseKey -and $_.architecture -eq $entry.architecture })
            foreach ($duplicate in $duplicates) { $null = $entries.Remove($duplicate) }
            $entries.Add($entry)
        }
        if (-not $WhatIfPreference) {
            $indexPath = Join-Path $CachePath 'updates.json'
            $temporary = "$indexPath.tmp"
            [pscustomobject]@{ schemaVersion = 1; updates = @($entries) } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8NoBOM
            Move-Item -LiteralPath $temporary -Destination $indexPath -Force
        }
    }
    finally {
        Unlock-Directory -Lock $cacheLock
    }
}
