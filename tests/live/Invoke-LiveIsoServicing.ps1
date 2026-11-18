#Requires -Version 7.4
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Services original Windows ISOs end to end with real Microsoft updates and verifies the result.

.DESCRIPTION
    Runs the production workflow of the WindowsIsoServicing module from this repository against real media, then checks the new ISO independently. Per ISO: the source checksum is taken; Get-WindowsISOInfo detects release, build, architecture, editions and lifecycle; the host DISM version is compared with the DISM version on the media, because DISM cannot service images newer than itself; Get-WindowsISOUpdates discovers the latest applicable servicing stack, cumulative and checkpoint updates from the Microsoft Update Catalog and the MSRC Security Updates API (or a local repository); Update-WindowsISO downloads and verifies the packages, services the images with DISM, rebuilds and validates the ISO; Test-IsoServicingResult.ps1 then inspects the source and the new ISO directly. A JSON and a text report are written per ISO to <OutputDirectory>\live-<run id>\<nn>-<iso name>, next to the run log and DISM logs, which are kept on failure. Settings not given as parameters are read from the configuration file; with -IsoPath, the ISO list of the configuration file is ignored. Every ISO is processed, failures included, and the script throws at the end when any ISO failed, so pwsh -File exits with 1. The source ISO is only read and the host's own installation is never serviced. Packages already in the cache are reused after their hash and signature are checked again; -RepositoryPath avoids discovery and download entirely.

.PARAMETER IsoPath
    Original Microsoft Windows ISO files to service. Overrides the isos list of the configuration file.

.PARAMETER OutputDirectory
    Folder for the serviced ISOs and the run reports. Overrides outputDirectory in the configuration file.

.PARAMETER ConfigurationPath
    JSON configuration file. Defaults to config.json next to this script; a missing file is ignored.

.PARAMETER WorkingDirectory
    Workspace for extracted media and mount points; a local NTFS path without whitespace. Defaults to %ProgramData%\WindowsIsoServicing\Workspace.

.PARAMETER CachePath
    Update package cache. Defaults to %ProgramData%\WindowsIsoServicing\Cache.

.PARAMETER RepositoryPath
    Local package repository (updates.json) used instead of the Microsoft Update Catalog, for example a cache filled by an earlier run.

.PARAMETER Index
    Install image indexes to service. Defaults to every index whose edition is in support.

.PARAMETER AllIndexes
    Services every install image index; the run fails if one of them cannot be serviced.

.PARAMETER EsuEntitled
    Confirms a valid Extended Security Updates entitlement for media that is past end of support. ESU licensing is never bypassed.

.PARAMETER BootTest
    Also installs the first serviced index in a temporary Hyper-V VM (Update-WindowsISO -BootTest).

.PARAMETER KeepTemporaryFiles
    Keeps the servicing workspace after the run for diagnostics.

.PARAMETER Force
    Replaces an existing serviced ISO with the same name in OutputDirectory. Without it, an existing file stops the run for that ISO.

.EXAMPLE
    .\tests\live\Invoke-LiveIsoServicing.ps1 -IsoPath 'D:\ISO\WindowsServer2025.iso' -OutputDirectory 'D:\ISO\Updated'

.EXAMPLE
    .\tests\live\Invoke-LiveIsoServicing.ps1 -IsoPath 'D:\ISO\Windows_11_24H2.iso' -OutputDirectory 'D:\ISO\Updated' -WorkingDirectory 'D:\IsoWork' -Index 3 -KeepTemporaryFiles -Verbose

.EXAMPLE
    .\tests\live\Invoke-LiveIsoServicing.ps1 -ConfigurationPath 'D:\IsoTest\config.json'

.OUTPUTS
    WindowsIsoServicing.LiveServicingReport

.NOTES
    Author:  Lars Krogh Paulsen
    Version: 1.0.0

.LINK
    https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-supported-platforms
#>

[CmdletBinding()]
[OutputType('WindowsIsoServicing.LiveServicingReport')]
param(
    [ValidateNotNullOrEmpty()]
    [string[]]$IsoPath,
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,
    [ValidateNotNullOrEmpty()]
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot 'config.json'),
    [ValidateNotNullOrEmpty()]
    [string]$WorkingDirectory,
    [ValidateNotNullOrEmpty()]
    [string]$CachePath,
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryPath,
    [ValidateRange(1, 256)]
    [int[]]$Index,
    [switch]$AllIndexes,
    [switch]$EsuEntitled,
    [switch]$BootTest,
    [switch]$KeepTemporaryFiles,
    [switch]$Force
)

function ConvertTo-LiveReportText {
    <#
    .SYNOPSIS
        Formats a live servicing report as plain text.

    .DESCRIPTION
        Renders the report built by Invoke-LiveIsoServicing.ps1 in the order a reviewer reads it: source, detection, update plan, downloaded packages, per-index servicing state before and after, output, every check with its status, errors and timing.

    .PARAMETER Report
        Report dictionary of one ISO.

    .EXAMPLE
        ConvertTo-LiveReportText -Report $report

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
        [System.Collections.IDictionary]$Report
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Live ISO servicing report, run $($Report.runId): $($Report.status.ToUpperInvariant())")
    $lines.Add("Host:       $($Report.host) build $($Report.hostBuild), DISM $($Report.hostDismVersion)")
    $lines.Add("Source:     $($Report.sourceIso.path)")
    $lines.Add("            SHA-256 $($Report.sourceIso.sha256)")
    if ($Report.detected) {
        $lines.Add("Detected:   $($Report.detected.release) $($Report.detected.version) build $($Report.detected.build) $($Report.detected.architecture), $($Report.detected.installImageFormat), $($Report.detected.lifecycleStatus), media DISM $($Report.detected.mediaDismVersion)")
        foreach ($edition in $Report.detected.editions) { $lines.Add("            index $($edition.index): $($edition.name) ($($edition.editionId), $($edition.version), $($edition.lifecycleStatus))") }
    }
    if ($Report.plan) {
        $lines.Add("Plan:       source $($Report.plan.source)")
        $lines.Add("            servicing stack: $(if ($Report.plan.servicingStack) { $Report.plan.servicingStack -join ', ' } else { 'none standalone' })")
        $lines.Add("            cumulative update: $($Report.plan.cumulativeUpdate) (OS build $($Report.plan.cumulativeOsBuild))")
        $lines.Add("            checkpoint updates: $(if ($Report.plan.checkpointFiles) { $Report.plan.checkpointFiles -join ', ' } else { 'none' })")
        foreach ($update in $Report.plan.otherUpdates) { $lines.Add("            other: $update") }
        foreach ($note in $Report.plan.notes) { $lines.Add("            note: $note") }
    }
    foreach ($package in $Report.downloadedPackages) { $lines.Add("Package:    $($package.kb) $($package.name) ($($package.role)) SHA-256 $($package.sha256), verified by $($package.hashSource) hash and signature") }
    foreach ($image in $Report.images) {
        $lines.Add("Index $($image.index):    $($image.name) ($($image.edition)) $($image.imageVersionBefore) -> $($image.imageVersionAfter)")
        $lines.Add("            cumulative update package $($image.rollupBefore) -> $($image.rollupAfter); servicing stack $($image.servicingStackBefore) -> $($image.servicingStackAfter)")
        foreach ($step in $image.appliedSequence) { $lines.Add("            applied: $step") }
    }
    if ($Report.output) {
        $lines.Add("Output:     $($Report.output.isoPath)")
        $lines.Add("            SHA-256 $($Report.output.sha256)")
        $lines.Add("            logs $($Report.output.logPath)")
    }
    foreach ($check in $Report.checks) { $lines.Add(('Check:      {0,-13} {1}: {2}' -f $check.Status, $check.Name, $check.Detail)) }
    foreach ($errorText in $Report.errors) { $lines.Add("Error:      $errorText") }
    $lines.Add("Time:       $($Report.startedAt) to $($Report.completedAt) ($($Report.durationMinutes) min)")
    $lines -join [Environment]::NewLine
}

$ErrorActionPreference = 'Stop'

Set-StrictMode -Version 3.0

if (-not $IsWindows) {
    throw 'Live ISO servicing runs on Windows only.'
}
if ($Index -and $AllIndexes) {
    throw '-Index and -AllIndexes cannot be combined.'
}
$missingCommands = @('Mount-WindowsImage', 'Get-WindowsPackage', 'Export-WindowsImage', 'Mount-DiskImage', 'Get-Volume' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missingCommands) {
    throw "Required commands are missing: $($missingCommands -join ', '). Run on Windows with the built-in Dism and Storage modules."
}
$hostDismFile = Join-Path $env:SystemRoot 'System32\Dism\DismCore.dll'
if (-not (Test-Path -LiteralPath $hostDismFile -PathType Leaf)) {
    throw "DISM is not installed on this host ('$hostDismFile' is missing)."
}

$hostDismVersion = (Get-Item -LiteralPath $hostDismFile).VersionInfo.FileVersionRaw
$module = Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force -PassThru
$configuration = if (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf) { Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json }
$outputRoot = $OutputDirectory ? $OutputDirectory : ${configuration}?.PSObject.Properties['outputDirectory']?.Value
$workRoot = $WorkingDirectory ? $WorkingDirectory : (${configuration}?.PSObject.Properties['workingDirectory']?.Value ?? (Join-Path $env:ProgramData 'WindowsIsoServicing\Workspace'))
$cacheRoot = $CachePath ? $CachePath : (${configuration}?.PSObject.Properties['cachePath']?.Value ?? (Join-Path $env:ProgramData 'WindowsIsoServicing\Cache'))
$repository = $RepositoryPath ? $RepositoryPath : ${configuration}?.PSObject.Properties['repositoryPath']?.Value
if (-not $outputRoot) {
    throw "Specify -OutputDirectory or set outputDirectory in '$ConfigurationPath'."
}

$cases = @(if ($IsoPath) {
        foreach ($path in $IsoPath) {
            [pscustomobject]@{
                path            = $path
                index           = @($Index | Where-Object { $_ })
                allIndexes      = [bool]$AllIndexes
                esuEntitled     = [bool]$EsuEntitled
                bootTest        = [bool]$BootTest
                expectedRelease = $null
            }
        }
    }
    else {
        foreach ($entry in @(${configuration}?.PSObject.Properties['isos']?.Value)) {
            if (-not $entry) { continue }
            $entryValue = $entry.PSObject.Properties
            [pscustomobject]@{
                path            = $entryValue['path']?.Value
                index           = @($entryValue['index']?.Value | Where-Object { $_ })
                allIndexes      = [bool]($entryValue['allIndexes']?.Value ?? $AllIndexes)
                esuEntitled     = [bool]($entryValue['esuEntitled']?.Value ?? $EsuEntitled)
                bootTest        = [bool]($entryValue['bootTest']?.Value ?? $BootTest)
                expectedRelease = $entryValue['expectedRelease']?.Value
            }
        }
    })
if ($cases.Count -eq 0) {
    throw "No ISO to service. Pass -IsoPath or list ISOs under 'isos' in '$ConfigurationPath'."
}
$invalidCases = @($cases | Where-Object { -not $_.path -or ($_.index.Count -gt 0 -and $_.allIndexes) })
if ($invalidCases) {
    throw "Configuration entries need a 'path' and cannot combine 'index' with 'allIndexes': $(@($invalidCases | ForEach-Object { "'$($_.path)'" }) -join ', ')."
}

$runId = '{0:yyyyMMdd-HHmmss}' -f [DateTimeOffset]::Now
$runDirectory = Join-Path (New-Item -Path $outputRoot -ItemType Directory -Force).FullName "live-$runId"
$null = New-Item -Path $runDirectory -ItemType Directory
$hostBuild = [Environment]::OSVersion.Version.Build
$verbose = $VerbosePreference -eq 'Continue'
$failed = [System.Collections.Generic.List[string]]::new()
$number = 0
Write-Information "Live ISO servicing run $runId on $env:COMPUTERNAME (build $hostBuild, DISM $hostDismVersion): $($cases.Count) ISO(s); reports in $runDirectory" -InformationAction Continue
foreach ($case in $cases) {
    $number++
    $startedAt = [DateTimeOffset]::Now
    $caseName = '{0:D2}-{1}' -f $number, [System.IO.Path]::GetFileNameWithoutExtension($case.path)
    $caseDirectory = Join-Path $runDirectory $caseName
    $logDirectory = Join-Path $caseDirectory 'logs'
    $null = New-Item -Path $logDirectory -ItemType Directory -Force
    $report = [ordered]@{
        runId              = $runId
        host               = $env:COMPUTERNAME
        hostBuild          = $hostBuild
        hostDismVersion    = [string]$hostDismVersion
        status             = 'Failed'
        sourceIso          = [ordered]@{ path = $case.path; fileName = Split-Path $case.path -Leaf; sha256 = $null; sizeBytes = $null }
        detected           = $null
        plan               = $null
        downloadedPackages = @()
        images             = @()
        output             = $null
        checks             = [System.Collections.Generic.List[object]]::new()
        errors             = [System.Collections.Generic.List[string]]::new()
        startedAt          = $startedAt.ToString('o')
        completedAt        = $null
        durationMinutes    = $null
    }
    $validation = $null
    try {
        $sourceFile = (Resolve-Path -LiteralPath $case.path).ProviderPath
        if ([System.IO.Path]::GetExtension($sourceFile) -ne '.iso') {
            throw "'$sourceFile' is not an .iso file."
        }
        Write-Information "[$caseName] Hashing source ISO $sourceFile" -InformationAction Continue
        $report.sourceIso.path = $sourceFile
        $report.sourceIso.sha256 = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $report.sourceIso.sizeBytes = (Get-Item -LiteralPath $sourceFile).Length
        Write-Information "[$caseName] Detecting release and editions" -InformationAction Continue
        $info = Get-WindowsISOInfo -SourceISO $sourceFile -SkipChecksum -WorkspacePath $workRoot
        $os = $info.OperatingSystem
        $alreadyAttached = (Get-DiskImage -ImagePath $sourceFile).Attached
        $mediaRoot = & $module { Mount-IsoImage -Path $args[0] -Confirm:$false } $sourceFile
        try {
            $mediaDismFile = Join-Path $mediaRoot 'sources\dismcore.dll'
            $mediaDismVersion = if (Test-Path -LiteralPath $mediaDismFile -PathType Leaf) { (Get-Item -LiteralPath $mediaDismFile).VersionInfo.FileVersionRaw }
        }
        finally {
            if (-not $alreadyAttached) { & $module { Dismount-IsoImage -Path $args[0] -Confirm:$false } $sourceFile }
        }
        $report.detected = [ordered]@{
            release            = $os.Name
            key                = $os.Key
            version            = $os.Version
            build              = $info.Build
            architecture       = $info.Architecture
            installImageFormat = $info.InstallImageFormat
            lifecycleStatus    = $os.LifecycleStatus
            bootModes          = [ordered]@{ bios = $info.BootConfiguration.Bios; uefi = $info.BootConfiguration.Uefi }
            mediaDismVersion   = [string]$mediaDismVersion
            editions           = @($info.Images | ForEach-Object { [ordered]@{ index = $_.Index; name = $_.Name; editionId = $_.EditionId; version = [string]$_.Version; lifecycleStatus = $_.OperatingSystem.LifecycleStatus } })
        }
        $detectionOk = -not $case.expectedRelease -or $os.Key -eq $case.expectedRelease
        $report.checks.Add([pscustomobject]@{
                Name   = 'Detection'
                Status = $detectionOk ? 'Passed' : 'Failed'
                Detail = "Detected $($os.Name) ($($os.Key), $($os.LifecycleStatus)); expected $(if ($case.expectedRelease) { $case.expectedRelease } else { 'any release' })"
            })
        if (-not $detectionOk) {
            throw "Detection failed: the media is $($os.Name) ($($os.Key)), expected $($case.expectedRelease)."
        }
        $selectedImages = @(if ($case.allIndexes) { $info.Images } elseif ($case.index.Count -gt 0) { $info.Images | Where-Object Index -In $case.index })
        $serviceableImages = @($info.Images | Where-Object { $_.OperatingSystem.LifecycleStatus -eq 'Supported' -or ($_.OperatingSystem.LifecycleStatus -eq 'ExtendedSecurityUpdates' -and $case.esuEntitled) })
        $lifecycleImages = if ($selectedImages.Count -gt 0) { $selectedImages } elseif ($case.index.Count -eq 0 -and $serviceableImages.Count -eq 0) { $info.Images }
        if ($lifecycleImages) {
            & $module { Assert-ServiceableRelease -OperatingSystem $args[0] -EsuEntitled:$args[1] } @($lifecycleImages | ForEach-Object OperatingSystem) $case.esuEntitled
        }
        $hostDismBuild = [version]('{0}.{1}.{2}' -f $hostDismVersion.Major, $hostDismVersion.Minor, $hostDismVersion.Build)
        $targetBuild = if ($mediaDismVersion) { [version]('{0}.{1}.{2}' -f $mediaDismVersion.Major, $mediaDismVersion.Minor, $mediaDismVersion.Build) } else { [version]"10.0.$($info.Build)" }
        $hostOk = $hostDismBuild -ge $targetBuild
        $report.checks.Add([pscustomobject]@{
                Name   = 'HostCompatibility'
                Status = $hostOk ? 'Passed' : 'Failed'
                Detail = "Host DISM $hostDismBuild, media $(if ($mediaDismVersion) { "DISM $targetBuild" } else { "build $targetBuild (sources\dismcore.dll not found)" })"
            })
        if (-not $hostOk) {
            throw "The host DISM ($hostDismBuild) is older than the media ($targetBuild); DISM cannot service newer images. Run on a host at build $($targetBuild.Build) or later."
        }
        Write-Information "[$caseName] Discovering applicable updates" -InformationAction Continue
        $planParameters = @{ InputObject = $info }
        if ($repository) { $planParameters.RepositoryPath = $repository }
        $plan = Get-WindowsISOUpdates @planParameters -Verbose:$verbose
        $cumulative = @($plan.Updates | Where-Object Category -EQ 'CumulativeUpdate') | Select-Object -First 1
        $report.plan = [ordered]@{
            source            = $plan.Source
            servicingStack    = @($plan.Updates | Where-Object Category -EQ 'ServicingStack' | ForEach-Object Kb)
            cumulativeUpdate  = ${cumulative}?.Kb
            cumulativeOsBuild = ${cumulative}?.OsBuild
            checkpointFiles   = @(${cumulative}?.Files | Where-Object Role -EQ 'Checkpoint' | ForEach-Object Name)
            otherUpdates      = @($plan.Updates | Where-Object Category -NotIn 'ServicingStack', 'CumulativeUpdate' | ForEach-Object { "$($_.Kb) $($_.Category)" })
            notes             = @($plan.Notes)
        }
        if (-not $cumulative) {
            throw "No applicable cumulative update was found for $($os.Name) build $($info.Build) $($info.Architecture); the live test requires one. Plan notes: $(@($plan.Notes) -join ' ')"
        }
        $servicingParameters = @{
            SourceISO         = $sourceFile
            OutputPath        = $outputRoot
            WorkspacePath     = $workRoot
            CachePath         = $cacheRoot
            LogPath           = $logDirectory
            EsuEntitled       = $case.esuEntitled
            BootTest          = $case.bootTest
            KeepWorkspace     = [bool]$KeepTemporaryFiles
            Force             = [bool]$Force
            InformationAction = 'Continue'
            Verbose           = $verbose
            Confirm           = $false
        }
        if ($repository) { $servicingParameters.RepositoryPath = $repository }
        $expectedIndex = @(if ($case.allIndexes) { $info.Images | ForEach-Object Index } elseif ($case.index.Count -gt 0) { $case.index })
        if ($expectedIndex) { $servicingParameters.Index = $expectedIndex }
        Write-Information "[$caseName] Servicing with Update-WindowsISO: $(@($plan.Updates | ForEach-Object Kb) -join ', ')" -InformationAction Continue
        $result = Update-WindowsISO @servicingParameters
        if ($result.Status -ne 'Created') {
            throw "Update-WindowsISO returned status '$($result.Status)' instead of 'Created'."
        }
        $plannedKbs = @($plan.Updates | ForEach-Object Kb | Sort-Object) -join ','
        $appliedKbs = @($result.Plan.Updates | ForEach-Object Kb | Sort-Object) -join ','
        $report.checks.Add([pscustomobject]@{
                Name   = 'DiscoveryConsistent'
                Status = ($plannedKbs -eq $appliedKbs) ? 'Passed' : 'Failed'
                Detail = "Discovered $plannedKbs; serviced $appliedKbs"
            })
        $report.downloadedPackages = @($result.Plan.Updates | ForEach-Object { $update = $_; $update.Files | ForEach-Object { [ordered]@{ kb = $update.Kb; category = $update.Category; name = $_.Name; role = $_.Role; sha256 = $_.Sha256; hashSource = $_.HashSource } } })
        $report.output = [ordered]@{ isoPath = $result.IsoPath; sha256 = $null; manifestPath = $result.ManifestPath; logPath = $result.LogPath }
        Write-Information "[$caseName] Verifying $($result.IsoPath)" -InformationAction Continue
        $validationParameters = @{ ManifestPath = $result.ManifestPath; SourceIsoPath = $sourceFile; SourceSha256 = $report.sourceIso.sha256; LogPath = $logDirectory; WorkingDirectory = $workRoot }
        if ($expectedIndex) { $validationParameters.ExpectedIndex = $expectedIndex }
        $validation = & (Join-Path $PSScriptRoot 'Test-IsoServicingResult.ps1') @validationParameters
        $report.output.sha256 = $validation.IsoSha256
        $report.images = @($validation.Images)
        foreach ($check in $validation.Checks) { $report.checks.Add($check) }
    }
    catch {
        $report.errors.Add("$($_.FullyQualifiedErrorId): $_")
    }
    $passed = $report.errors.Count -eq 0 -and $validation -and $validation.Passed -and -not ($report.checks | Where-Object Status -EQ 'Failed')
    $report.status = $passed ? 'Passed' : 'Failed'
    $completedAt = [DateTimeOffset]::Now
    $report.completedAt = $completedAt.ToString('o')
    $report.durationMinutes = [math]::Round(($completedAt - $startedAt).TotalMinutes, 1)
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $caseDirectory 'report.json') -Encoding utf8NoBOM
    $reportText = ConvertTo-LiveReportText -Report $report
    Set-Content -LiteralPath (Join-Path $caseDirectory 'report.txt') -Value $reportText -Encoding utf8NoBOM
    Write-Information $reportText -InformationAction Continue
    if (-not $passed) { $failed.Add($caseName) }
    $report.Insert(0, 'PSTypeName', 'WindowsIsoServicing.LiveServicingReport')
    [pscustomobject]$report
}

if ($failed.Count -gt 0) {
    throw "Live ISO servicing failed for $($failed.Count) of $($cases.Count) ISO(s): $($failed -join ', '). Reports and DISM logs: $runDirectory"
}
Write-Information "Live ISO servicing passed for $($cases.Count) ISO(s). Reports: $runDirectory" -InformationAction Continue
