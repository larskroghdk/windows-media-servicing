# 🤖 Automation

`scripts/Invoke-IsoServicingPipeline.ps1` is the single entry point for unattended runs. It:

1. Reads a JSON configuration (see [config/servicing.example.json](../config/servicing.example.json)).
2. Does nothing until Patch Tuesday (the second Tuesday) plus `patchTuesdayDelayDays` has passed in the current month. The delay gives Microsoft time to publish the packages in the Microsoft Update Catalog and the monthly document in the MSRC Security Updates API.
3. For each media entry, looks up the latest published manifest in `storePath` built from the same source ISO (by SHA-256) and the same index selection, and passes it to `Update-WindowsISO -BaselineManifestPath`. Media with an unchanged update set is skipped (`Unchanged`).
4. Publishes each `Created` ISO with `Publish-WindowsISO`. Only ISOs whose manifest records a passed validation are published, and the previous known-good version stays `latest` until then.
5. Writes a Markdown summary (to `$env:GITHUB_STEP_SUMMARY` when set) and `servicing-summary.json` to `outputPath`.
6. Exits 0 on success or no change, 1 if any media entry failed (the others are still processed), and 2 on configuration errors.

`-Force` skips both the Patch Tuesday gate and the baseline comparison.

## ⚙️ Configuration

| Property | Required | Meaning |
| --- | --- | --- |
| `outputPath` | Yes | Build output, manifests and logs |
| `storePath` | Yes | Artifact store root (file share). ISOs are stored here, outside Git. |
| `updateSource.repositoryPath` | No | Service from a package repository instead of the Microsoft Update Catalog. Omit `updateSource` to use the Catalog. Any other `updateSource` property (such as the removed `wsusServer`) is a configuration error. |
| `workspacePath`, `cachePath` | No | Defaults to `%ProgramData%\WindowsIsoServicing\…` |
| `oscdimgPath` | No | `oscdimg.exe`, or a Windows ADK folder, passed to `Update-WindowsISO -OscdimgPath`. Omit it to use the installed Windows ADK ([requirements.md](requirements.md#-oscdimg)). |
| `retainCount` | No | Versions kept per media key (default 3) |
| `patchTuesdayDelayDays` | No | Default 2 |
| `media[].name`, `media[].sourceIso` | Yes | Media entry |
| `media[].indexes` | No | Indexes to service |
| `media[].noBootPrompt` | No | Obsolete and ignored, with a warning. Every serviced ISO boots without "Press any key" ([servicing.md](servicing.md#-boot-without-press-any-key)). Remove it from the configuration. |
| `media[].bootTest` | No | Hyper-V installation test before the ISO is accepted |
| `media[].esuEntitled` | No | ESU entitlement statement for ESU-only media |

## 🗄️ Artifact store, retention and rollback

```text
<storePath>\<ReleaseKey>_<arch>_<language>\
    latest.json                          manifest of the current known-good ISO, with a publication block
    history.json                         every publication, including rollbacks
    <IsoName>\<IsoName>.iso, .iso.json, .iso.sha256
```

- The ISO is copied to `.partial`, its SHA-256 is checked against the manifest, and only then is it renamed and `latest.json` replaced (write to a temporary file, then rename).
- Retention keeps the newest `retainCount` versions by manifest `createdAt`, and always keeps the current latest.
- To roll back, publish an older version that is already in the store. Only the pointer moves:

  ```powershell
  Publish-WindowsISO -ManifestPath '\\fs01\iso\WindowsServer2025_x64_en-us\Windows_Server_2025_x64_26100_2026-10\Windows_Server_2025_x64_26100_2026-10.iso.json' -StorePath '\\fs01\iso'
  ```

- Consumers such as Packer should read `latest.json` (`publication.isoPath`, `output.sha256`) rather than guess file names.

## ⚡ GitHub Actions

- [.github/workflows/ci.yml](../.github/workflows/ci.yml) runs PSScriptAnalyzer and the Pester unit tests on `windows-latest`. Those tests need no elevation, media or network access.
- [.github/workflows/patch-tuesday.yml](../.github/workflows/patch-tuesday.yml) runs at 06:00 UTC daily from the 9th to the 28th, plus manual `workflow_dispatch` with `force` and `delay_days` inputs. The script's gate makes the daily runs idempotent. A single `concurrency` group without cancellation makes sure servicing runs never overlap or get interrupted.
- [.github/workflows/publish-module.yml](../.github/workflows/publish-module.yml) packages the module and publishes it to the PowerShell Gallery when a GitHub release is published, on `windows-latest`. See [Packaging and publishing](../README.md#-packaging-and-publishing) for the release procedure and the `PSGALLERY_API_KEY` secret.

GitHub-hosted runners are not suitable for servicing. They lack the free disk space for several full images,
Hyper-V for boot tests, and network access to the internal file share. Use a **self-hosted
Windows runner** with the labels `self-hosted, windows, iso-servicing`. Set it up as follows:

- Run the runner service as an account that is a local administrator, because DISM requires elevation.
- The repository is public, and a pull request from a fork can change any workflow to run on this runner. Under Settings > Actions > General > *Approval for running fork pull request workflows from contributors*, select *Require approval for all external contributors*, and review a fork pull request's workflow changes before approving it. GitHub recommends against self-hosted runners for public repositories; a private repository avoids the problem.
- Install PowerShell 7.4+ and the Windows ADK Deployment Tools ([requirements.md](requirements.md#-oscdimg)).
- Provide a dedicated local NTFS data volume, excluded from antivirus scanning.
- Set the repository variable `ISO_SERVICING_CONFIG` to the configuration path on the runner.
- Allow outbound HTTPS to the Microsoft Update Catalog, the MSRC API and the Microsoft download hosts (see [requirements.md](requirements.md#-update-source)), and give the runner account access to the store share. No credentials are kept in the repository.

The workflow uploads only manifests, checksums, the summary and recent logs as run artifacts (90-day retention). ISOs
stay in the artifact store.

## ⏰ Windows Task Scheduler

```powershell
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -NonInteractive -File "C:\windows-iso-servicing\scripts\Invoke-IsoServicingPipeline.ps1" -ConfigurationPath "D:\IsoServicing\servicing.json"'
$trigger = New-ScheduledTaskTrigger -Daily -At '06:00'
$principal = New-ScheduledTaskPrincipal -UserId 'CONTOSO\svc-isoservicing' -LogonType Password -RunLevel Highest
Register-ScheduledTask -TaskName 'Windows ISO servicing' -Action $action -Trigger $trigger -Principal $principal
```

Registering with `-LogonType Password` prompts for the account password; use a group Managed Service Account where
possible. The daily trigger is safe, because the script exits immediately outside the servicing window and skips
unchanged media.

## ☁️ Azure DevOps

Use a self-hosted agent pool with the same prerequisites:

```yaml
schedules:
  - cron: '0 6 9-28 * *'
    displayName: Patch Tuesday window
    branches: { include: [main] }
    always: true
pool: IsoServicing
steps:
  - pwsh: ./scripts/Invoke-IsoServicingPipeline.ps1 -ConfigurationPath '$(IsoServicingConfig)' -SummaryPath '$(Build.ArtifactStagingDirectory)/summary.md'
    displayName: Service media
  - publish: $(Build.ArtifactStagingDirectory)
    artifact: servicing-report
    condition: always()
```
