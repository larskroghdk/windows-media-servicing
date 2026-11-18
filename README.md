# 💿 windows-iso-servicing

A PowerShell module that integrates Microsoft updates into Windows installation ISOs offline and produces validated,
bootable, versioned ISO files with a machine-readable manifest.

- 🔄 Services install.wim, boot.wim and WinRE offline, in Microsoft's Dynamic Update order ([servicing](docs/servicing.md)).
- ⏩ The ISOs start Windows Setup on BIOS and UEFI without "Press any key to boot from CD or DVD".
- 🔏 Uses only Microsoft tooling and sources: DISM, OSCDIMG, Hyper-V, the Microsoft Update Catalog and the MSRC Security
  Updates API. Every package must match its published hash and carry a Microsoft signature.
- 🛡️ The source ISO is never modified, and nothing reaches the output folder until validation has passed.
- 🚫 The servicing host's own Windows Update or WSUS configuration is never used.

Serviceable media (as of November 2026): Windows Server 2016, 2019, 2022 and 2025; Windows 10 Enterprise LTSC 2019 and
LTSC 2021; Windows 10 22H2 with ESU (`-EsuEntitled`); and Windows 11 24H2 and 25H2, per edition lifecycle. Other releases,
such as Windows Server 2012/2012 R2, Windows 10 LTSB 2016 and Windows 11 23H2, are detected and refused as out of
support. See [docs/supported-operating-systems.md](docs/supported-operating-systems.md).

## 📦 Installation

The module is published to the PowerShell Gallery as `WindowsIsoServicing` by the release workflow
([Packaging and publishing](#-packaging-and-publishing)). No version has been published yet, so until the first release
use the module from a clone of this repository, as in the quick start below. Installation itself needs no elevation;
servicing does.

```powershell
Install-PSResource -Name WindowsIsoServicing -Repository PSGallery -Scope CurrentUser
Install-PSResource -Name WindowsIsoServicing -Repository PSGallery -Version '1.0.0'      # a specific version
Install-PSResource -Name WindowsIsoServicing -Repository PSGallery -Prerelease          # include prereleases
Update-PSResource -Name WindowsIsoServicing                                             # latest stable version
Update-PSResource -Name WindowsIsoServicing -Prerelease                                 # latest version, prereleases included
Get-InstalledPSResource -Name WindowsIsoServicing
```

`Update-PSResource` installs the new version next to the old one; `Import-Module WindowsIsoServicing` loads the highest.

## 🚀 Quick start

```powershell
# Elevated PowerShell 7.4+, the Windows ADK Deployment Tools, HTTPS access to the Microsoft Update Catalog and the MSRC API
Import-Module .\src\WindowsIsoServicing
Get-WindowsISOInfo -SourceISO 'D:\ISO\Windows_Server_2025.iso'
Get-WindowsISOUpdates -SourceISO 'D:\ISO\Windows_Server_2025.iso'
Update-WindowsISO -SourceISO 'D:\ISO\Windows_Server_2025.iso' -OutputPath 'D:\ISO\Updated'
Test-WindowsISO -Path 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso' -Deep
```

The output folder then contains:

```text
Windows_Server_2025_x64_26100_2026-11.iso
Windows_Server_2025_x64_26100_2026-11.iso.json     # manifest
Windows_Server_2025_x64_26100_2026-11.iso.sha256
logs\<run id>\                                      # structured run log and DISM logs
```

## 🧰 Commands

| Command | Purpose |
| --- | --- |
| `Get-WindowsISOInfo` | Identify release, build, architecture, editions, lifecycle status and (with `-IncludePackages`) installed packages. |
| `Get-WindowsISOUpdates` | Discover applicable updates from the Microsoft Update Catalog (checked against MSRC) or a local package repository. |
| `Save-WindowsISOUpdate` | Download and validate packages into the update cache. |
| `Update-WindowsISO` | Service the media, rebuild and validate the ISO, write the manifest. |
| `Test-WindowsISO` | Structural validation, optional deep inspection and Hyper-V installation test. |
| `Get-WindowsISOManifest` | Read and validate a manifest, or the latest published manifest in a store. |
| `Publish-WindowsISO` | Publish a validated ISO to an artifact store, with retention and rollback. |

All commands have comment-based help: `Get-Help Update-WindowsISO -Full`.

## 📚 Documentation

- [AGENTS.md](AGENTS.md) and [INVARIANTS.md](INVARIANTS.md): contributor and agent guidance, hard constraints
- [Requirements](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [Supported operating systems](docs/supported-operating-systems.md)
- [Update discovery](docs/update-discovery.md)
- [Servicing sequence](docs/servicing.md)
- [Automation (GitHub Actions, Task Scheduler, Azure DevOps)](docs/automation.md)
- [Troubleshooting](docs/troubleshooting.md)

## 🧪 Testing

```powershell
pwsh -File .\scripts\Invoke-QualityGate.ps1 -Task All    # or: make check
# Integration tests against real media (elevated; see tests\Integration\integration.example.json)
$env:WIS_INTEGRATION_CONFIG = 'D:\IsoServicingTest\integration.json'
Invoke-Pester -Path .\tests\Integration -Tag Integration
# Live end-to-end servicing of one ISO with independent verification (elevated; see tests\live\README.md)
.\tests\live\Invoke-LiveIsoServicing.ps1 -IsoPath 'D:\ISO\WindowsServer2025.iso' -OutputDirectory 'D:\ISO\Updated'
# Unattended installation of a serviced ISO in a temporary Hyper-V VM, with checks on the installed system
.\tests\live\Test-WindowsIsoInstallation.ps1 -IsoPath 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso' -Edition 'ServerStandard' -AdministratorCredential (Get-Credential -UserName 'Administrator')
```

Test status of this release: unit tests and PSScriptAnalyzer pass. The integration suite has **not yet been run against
real installation media**, so no release is confirmed to service correctly end to end. Run the integration suite for
each release you depend on before production use. See [docs/supported-operating-systems.md](docs/supported-operating-systems.md#-test-status).

## 🚢 Packaging and publishing

The module is packaged as a NuGet package (`.nupkg`) with `Microsoft.PowerShell.PSResourceGet` and published with
`Publish-PSResource`. There is no separate NuGet tooling.

| Script | Purpose |
| --- | --- |
| [scripts/Build-ModulePackage.ps1](scripts/Build-ModulePackage.ps1) | Validates the manifest, builds the package with `Compress-PSResource`, checks it, and installs and imports it in a clean process. Needs no network or elevation. |
| [scripts/Publish-ModulePackage.ps1](scripts/Publish-ModulePackage.ps1) | Publishes a validated package to the PowerShell Gallery, after checking its SHA-256 and that the version is new. |
| [.github/workflows/publish-module.yml](.github/workflows/publish-module.yml) | Runs both on a published GitHub release. |

Both scripts need PowerShell 7.4+ and PSResourceGet 1.1.0 or later, the first version whose `Publish-PSResource` has
`-NupkgPath`. PowerShell 7.4.13 and 7.5 include 1.1.x; otherwise run
`Install-PSResource -Name Microsoft.PowerShell.PSResourceGet`.

The workflows install their tools with [scripts/Install-BuildDependency.ps1](scripts/Install-BuildDependency.ps1),
which saves PSResourceGet 1.2.0, Pester 5.6.1 and PSScriptAnalyzer 1.22.0 into a folder that is put first in
`PSModulePath`. Those exact versions are then loaded, even when the runner has newer ones, and a failed download stops
the job. The same script works locally:

```powershell
.\scripts\Install-BuildDependency.ps1 -Path "$env:TEMP\wis-modules"
$env:PSModulePath = "$env:TEMP\wis-modules;$env:PSModulePath"
```

### Versions

The manifest is the only source of the version: `ModuleVersion` (three parts, `Major.Minor.Patch`) plus, for a
prerelease, `PrivateData.PSData.Prerelease` (ASCII letters and digits only, for example `beta1`, which the PowerShell
Gallery requires). The package version is `1.1.0` or `1.1.0-beta1`, and the GitHub release tag must be `v` followed by
that version. Nothing changes a version automatically: a tag that doesn't match stops the build, and a GitHub release
marked as prerelease must have a `Prerelease` value (and the reverse). The Gallery never lets a published version be
replaced and accepts only a version above the latest one, so the publish script refuses both cases before it uploads
(`VersionAlreadyPublished`, `VersionNotGreater`).

### Building a package

```powershell
.\scripts\Build-ModulePackage.ps1                                   # writes output\package\WindowsIsoServicing.<version>.nupkg
.\scripts\Build-ModulePackage.ps1 -ReleaseTag 'v1.0.0' -OutputPath 'D:\Packages'
```

The build:

1. finds the module under `src`, runs `Test-ModuleManifest`, and checks what the Gallery requires: author,
   description, an https `ProjectUri`, and `FunctionsToExport` without wildcards, each with its `Public\<name>.ps1`;
2. copies only runtime files to a staging folder: the manifest, `WindowsIsoServicing.psm1`, `Public\*.ps1`,
   `Private\*.ps1` and `Data\*.psd1`. No executables are packaged; `oscdimg.exe` comes from the Windows ADK.
   Any other file in the module folder is left out with a warning. Tests, docs, scripts and configuration are outside
   the module folder and are never included;
3. builds the package with `Compress-PSResource` and checks the nuspec id, version and dependencies against the
   manifest, and that the package holds exactly the staged files;
4. installs the package with `Save-PSResource` from a temporary local repository, which is unregistered afterwards,
   and imports it in a separate `pwsh` process whose module path holds only that installation and the system module
   folders. The imported version and exported functions must match the manifest;
5. only then writes the package and its build report `<package>.json` (name, version, SHA-256, files, the PowerShell
   and PSResourceGet versions used, checks) to the output folder. The package is packed once: its SHA-256 is taken
   right after packing and must still be the same after validation and in the written copy.

Two builds of the same source produce different SHA-256 values, because the package contains timestamps. That's why
the workflow publishes the artifact it validated instead of rebuilding.

The manifest declares no `RequiredModules`. DISM is a Windows module that isn't in the PowerShell Gallery, and a
dependency on it would make `Install-PSResource` fail. `WindowsIsoServicing.psm1` imports `Dism` instead, so loading
the module still fails at once on a host without it.

### GitHub setup

Do this once, before the first release. The publish job runs in the GitHub environment `psgallery`
(`environment: name: psgallery` in the workflow), which holds the API key and the approval rules.

1. Create an API key on powershellgallery.com (account > API Keys) with the scope *Push new packages and package
   versions* and the glob pattern `WindowsIsoServicing`. Keys expire after at most 365 days, so note the date.
2. In the repository, open Settings > Environments > New environment and name it `psgallery`.
3. Under *Deployment protection rules*, add yourself or a team as *Required reviewers*. The publish job then waits for
   approval after the build job has validated the package.
4. Under *Deployment branches and tags*, choose *Selected branches and tags* and add the tag rule `v*`, so only release
   tags can publish.
5. Under *Environment secrets*, add `PSGALLERY_API_KEY` with the key from step 1.

The environment can also be created from the command line; the reviewers, the tag rule and the secret are easiest to
add in the web UI afterwards:

```bash
gh api --method PUT repos/larskroghdk/windows-media-servicing/environments/psgallery
```

| Secret | Where | Value |
| --- | --- | --- |
| `PSGALLERY_API_KEY` | Environment `psgallery` (recommended) or repository | PowerShell Gallery API key from step 1 |

A repository secret with the same name also works, but without the environment's approval and tag rules. The workflow
passes the key to `Publish-PSResource` only. It's never written to a file or the log, and GitHub masks it in the output.
No other secret is needed: the workflow's `GITHUB_TOKEN` has only `contents: read`. When the key expires, create a new
one and replace the secret; nothing in the repository changes.

### Releasing

1. Set `ModuleVersion`, and `Prerelease` for a prerelease (remove it for a stable release), in
   `src/WindowsIsoServicing/WindowsIsoServicing.psd1`. Move the `Unreleased` entries in `CHANGELOG.md` under the new
   version, and merge to `main`.
2. Optionally run the workflow manually (Actions > Publish module > Run workflow) with `publish` off. It runs the quality
   gate and builds and validates the package without publishing it, and the package is available as the
   `module-package` artifact.
3. Create a GitHub release with the tag `v<version>`, for example `v1.1.0` or `v1.1.0-beta1`. Tick *Set as a
   pre-release* exactly when the version has a prerelease label. Publishing the release starts the workflow.
4. The **build** job first resolves the release: it refuses forks and branches, checks that the tag points to the
   checked-out commit, and reads the release's *pre-release* setting. It then runs the quality gate (lint, typecheck,
   unit tests), builds and validates the package with that tag and setting, and uploads it with its build report as the
   `module-package` artifact (kept 90 days). The **publish** job waits for the `psgallery` environment's reviewers, if
   there are any. It downloads that artifact and refuses it when the folder holds anything besides the package and its
   report, when the file name doesn't match the report, or when the SHA-256 differs from the one the build job
   recorded. It then refuses an existing or lower version, publishes the package unchanged with
   `Publish-PSResource -NupkgPath`, and waits up to ten minutes until the Gallery lists it. The run summary shows the
   module name, version, SHA-256 and Gallery address.

A manual run with `publish` on is accepted only on the tag of a published (not draft) GitHub release (*Use workflow
from: Tags*), so a Gallery version always has a matching release. Use it to retry a publish that failed, for example
because the key had expired. A manual run with `publish` off validates and packages on any branch or tag. If the tag or
the version is wrong, don't move the tag: fix the manifest, and release a new version.

The workflow runs one at a time (`concurrency: publish-module`, never cancelled), and the version check refuses a
second publish of the same version, so re-running a finished publish job fails with `VersionAlreadyPublished` instead
of publishing twice.

### Publishing manually

```powershell
$apiKey = Read-Host -AsSecureString -Prompt 'PowerShell Gallery API key'
.\scripts\Publish-ModulePackage.ps1 -PackagePath '.\output\package\WindowsIsoServicing.1.0.0.nupkg' -ApiKey $apiKey -WhatIf
.\scripts\Publish-ModulePackage.ps1 -PackagePath '.\output\package\WindowsIsoServicing.1.0.0.nupkg' -ApiKey $apiKey
```

`-WhatIf` runs every check, including the version lookup in the Gallery, and skips the upload. Without it the script
asks for confirmation (pass `-Confirm:$false` to skip the prompt). The package must have its build report next to it,
must be unchanged since the build, and its folder must hold nothing else, so build into an empty folder
(`-OutputPath`) when you publish by hand. Prefer the workflow, which publishes only after the quality gate has passed.

### Troubleshooting publishing

| Symptom | Cause and action |
| --- | --- |
| VS Code (GitHub Actions extension) shows `Value 'psgallery' is not valid` in `publish-module.yml` | The extension checks environment names against the environments that exist in the GitHub repository. The workflow is valid. Create the `psgallery` environment ([GitHub setup](#github-setup)) and reload the file. |
| `The secret PSGALLERY_API_KEY is not set` | Add the secret to the `psgallery` environment or the repository. |
| `Release tag '…' is not a release tag` | Tags must be `v<Major>.<Minor>.<Patch>` or `v<Major>.<Minor>.<Patch>-<label>`, with a lowercase `v` and a label of letters and digits only. |
| `Release tag '…' does not match the manifest version` | The tag isn't `v` followed by the manifest version. Don't move the tag: fix the manifest and release a new version, or delete the unpublished release and tag and create them again. |
| `The GitHub release is marked as a prerelease, but the manifest defines …` (or the reverse) | The release's *Set as a pre-release* setting and `PSData.Prerelease` disagree. Edit the release setting, or the manifest and release again. |
| `The tag '…' points to …, but the run checked out …` | The tag was moved after the run started. Create a new release instead of moving tags. |
| `There is no GitHub release for the tag '…'` / `… is still a draft` | A manual run with `publish` on needs a published release for the tag. Publish the release, which also starts the workflow. |
| `… holds files that are not part of the validated build` | The package folder contains other files. Publish from a folder with only the package and its `.json` report. |
| `VersionAlreadyPublished` / `VersionNotGreater` | The Gallery already has this or a higher version. Raise `ModuleVersion` (or the prerelease label) and release a new version. |
| `Publishing … failed: … 403` or `401` | The API key is wrong, has expired, or doesn't cover `WindowsIsoServicing`. Replace the secret, then run the workflow manually on the tag with `publish` on. |
| `Publishing needs the tag of a published GitHub release, but this run is on the branch …` | A manual run with `publish` on was started from a branch. Start it from the release tag. |
| The publish job waits | It's waiting for a reviewer of the `psgallery` environment. Approve it in the run. |

### Limitations

- The publishing workflow hasn't run yet, and no version has been published to the PowerShell Gallery. The scripts are
  tested against a local file repository (`tests/Unit/ModulePackage.Tests.ps1`), not against the Gallery.
- The Gallery lists a new version only after its own checks. If that takes longer than ten minutes, the publish job
  succeeds with a warning, because the upload was already accepted; check the Gallery address later.
- `Find-PSResource` doesn't return unlisted versions, so the script can't refuse one before uploading. The Gallery
  then rejects the upload, and the job fails with the Gallery's error.
