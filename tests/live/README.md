# 🧪 Live ISO servicing tests

`Invoke-LiveIsoServicing.ps1` services an original Microsoft Windows ISO end to end with real updates from Microsoft.
It uses the production commands of this repository's `WindowsIsoServicing` module and then verifies the new ISO with
`Test-IsoServicingResult.ps1`, which inspects the media itself instead of trusting the run's own report.

`Test-WindowsIsoInstallation.ps1` installs a serviced ISO in a temporary Hyper-V VM without user interaction and checks the installed system; see [Hyper-V installation test](#-hyper-v-installation-test).

These are standalone scripts, not Pester tests. They never run as part of the quality gate or CI, because they need an
elevated session, real installation media, network access and tens of gigabytes of disk. The Pester suite in
`tests/Integration` drives the same production commands with fewer checks on the result.

## ▶️ What a run does

For each ISO:

1. Hashes the source ISO (SHA-256).
2. `Get-WindowsISOInfo` detects the release, build, architecture, editions and lifecycle status.
3. Compares the host's DISM version with the DISM version on the media (`sources\dismcore.dll`). DISM can't service
   images newer than itself, and the image build alone is misleading: Windows 11 25H2 media reports build 26200, but
   ships DISM 10.0.26100.
4. `Get-WindowsISOUpdates` discovers the latest applicable servicing stack, cumulative and checkpoint updates from the
   Microsoft Update Catalog, checked against the MSRC Security Updates API. With `-RepositoryPath`, a local repository
   is used instead. The run stops if no cumulative update is found.
5. `Update-WindowsISO` downloads the packages, checks their hash and Microsoft signature, services WinRE, install.wim
   and boot.wim with DISM, rebuilds the ISO with OSCDIMG and validates it. See [docs/servicing.md](../../docs/servicing.md)
   for the sequence.
6. `Test-IsoServicingResult.ps1` verifies the result (see [Checks](#-checks)).
7. Writes `report.json` and `report.txt`.

No servicing logic lives in `tests/live`. A defect found here is a defect in the module.

## 📋 Prerequisites

| Requirement | Details |
| --- | --- |
| Session | PowerShell 7.4 or later, **elevated**. Both scripts declare `#Requires -RunAsAdministrator`. |
| Host | The host requirements in [docs/requirements.md](../../docs/requirements.md). The host DISM must be at least the DISM version of the media; the script refuses an older host before servicing. |
| Media | An original Microsoft Windows installation ISO with `sources\install.wim` or `sources\install.esd`. The scripts never download Windows media. |
| Network | Outbound HTTPS to the Microsoft update hosts listed in [docs/requirements.md](../../docs/requirements.md#-update-source). Not needed with `-RepositoryPath`. |
| Disk | `Update-WindowsISO` checks free space before it starts: twice the ISO size, plus twice the update size, plus the largest image, plus 20 GB in the workspace, and 1.5 times the ISO size in the output folder. The cache needs room for the downloaded packages. |
| Hyper-V | Only for `-BootTest`. |

## 💿 Supported media

Releases are those in [src/WindowsIsoServicing/Data/OperatingSystems.psd1](../../src/WindowsIsoServicing/Data/OperatingSystems.psd1),
with the lifecycle rules in [docs/supported-operating-systems.md](../../docs/supported-operating-systems.md). Before any
update discovery, the script applies the module's lifecycle check (`Assert-ServiceableRelease`) to the selected
indexes. When no index is selected, it checks them only if no index is serviceable. On the run date:

- Supported releases are serviced.
- Media in Extended Security Updates only (for example Windows 10 22H2) needs `-EsuEntitled`. Without it, the run fails
  with `EsuEntitlementRequired`.
- Out-of-support media fails with `OutOfSupportMedia`. This includes Windows Server 2012 and 2012 R2, whose ESU program
  ended on 2026-10-13. Unknown media, such as Insider builds, fails with `UnsupportedMedia`. Neither counts as a
  servicing defect.

## 🏃 Running

Service one ISO:

```powershell
.\tests\live\Invoke-LiveIsoServicing.ps1 -IsoPath 'D:\ISO\WindowsServer2025.iso' -OutputDirectory 'D:\ISO\Updated'
```

Service specific indexes, keep the workspace and show verbose output:

```powershell
.\tests\live\Invoke-LiveIsoServicing.ps1 -IsoPath 'D:\ISO\Windows_11_24H2.iso' -OutputDirectory 'D:\ISO\Updated' -WorkingDirectory 'D:\IsoWork' -Index 3 -KeepTemporaryFiles -Verbose
```

Service every ISO listed in a configuration file:

```powershell
.\tests\live\Invoke-LiveIsoServicing.ps1 -ConfigurationPath 'D:\IsoTest\config.json'
```

Verify an ISO serviced earlier without servicing it again:

```powershell
.\tests\live\Test-IsoServicingResult.ps1 -ManifestPath 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso.json' -ExpectedIndex 2, 4
```

`Get-Help .\tests\live\Invoke-LiveIsoServicing.ps1 -Full` describes every parameter. The main ones:

| Parameter | Effect |
| --- | --- |
| `-Index` / `-AllIndexes` | Which install.wim indexes to service. By default, every index whose edition is in support. With `-AllIndexes`, the run fails if any index can't be serviced. With either, the validator requires exactly those indexes to be serviced. |
| `-CachePath` | Package cache. Cached packages are reused after their hash and signature are checked again, so a re-run downloads only what is missing. |
| `-RepositoryPath` | Uses a local `updates.json` repository, such as an earlier cache, instead of the Microsoft Update Catalog. Nothing is downloaded. |
| `-KeepTemporaryFiles` | Keeps the servicing workspace for diagnostics. |
| `-Force` | Replaces an existing serviced ISO with the same name. Without it, an existing file fails the run for that ISO, and nothing is overwritten. |
| `-EsuEntitled` | States that you hold a valid ESU entitlement. The tool never activates or bypasses ESU licensing. |
| `-BootTest` | Also runs the Hyper-V installation test of `Update-WindowsISO`. |

The run is unattended and never prompts.

## ⚙️ Configuration file

`config.json` next to the scripts is read by default. A parameter on the command line overrides the matching setting.
With `-IsoPath`, the `isos` list is ignored. A setting left at `null` uses the default.

```json
{
  "outputDirectory": "D:\\IsoServicingLive\\Output",
  "workingDirectory": "D:\\IsoServicingLive\\Workspace",
  "cachePath": "D:\\IsoServicingLive\\Cache",
  "repositoryPath": null,
  "isos": [
    { "path": "D:\\ISO\\Windows_Server_2025.iso", "expectedRelease": "WindowsServer2025", "index": [2, 4], "bootTest": true },
    { "path": "D:\\ISO\\Windows_Server_2019.iso", "expectedRelease": "WindowsServer2019", "allIndexes": true },
    { "path": "D:\\ISO\\Windows_10_22H2.iso", "expectedRelease": "Windows10Version22H2", "esuEntitled": true },
    { "path": "D:\\ISO\\Windows_11_24H2.iso", "expectedRelease": "Windows11Version24H2" }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `outputDirectory` | Serviced ISOs and run reports. Required here or as `-OutputDirectory`. |
| `workingDirectory` | Workspace: local NTFS, no whitespace. Default `%ProgramData%\WindowsIsoServicing\Workspace`. |
| `cachePath` | Package cache. Default `%ProgramData%\WindowsIsoServicing\Cache`. |
| `repositoryPath` | Local repository instead of the Catalog. |
| `isos[].path` | Source ISO. Required. |
| `isos[].expectedRelease` | Release key from the data file. The run fails if detection returns a different release. |
| `isos[].index`, `isos[].allIndexes` | As `-Index` and `-AllIndexes`. They can't be combined. |
| `isos[].esuEntitled`, `isos[].bootTest` | As the switches. When omitted, the command-line switch applies. |

The configuration holds paths only. No credentials are needed or read.

## ✅ Checks

A run passes only when every check is `Passed` or `NotApplicable`, and the cumulative update check passed for every
serviced index. A check that can't be performed is reported as `Skipped` or `Failed` with the reason. A DISM exit code
alone never counts as success.

| Check | Passes when |
| --- | --- |
| `Detection` | The media is a release this tool knows, and the expected release when one is configured. |
| `HostCompatibility` | Host DISM version ≥ media DISM version. |
| `DiscoveryConsistent` | `Update-WindowsISO` serviced the same KBs that discovery returned before the run. |
| `OutputChecksum` | The SHA-256 of the new ISO matches the manifest and the `.sha256` file. |
| `SourceUnchanged` | The SHA-256 of the source ISO still matches the value taken before servicing. |
| `ProductionValidation` | The structural validation of `Update-WindowsISO` passed, as recorded in the manifest. |
| `CumulativeUpdatePlanned` | The manifest lists a cumulative update. |
| `FileName` | The name follows `<release>_<arch>_<build>_<yyyy-MM>.iso`, with the month of the cumulative update. |
| `BootCatalog` | Every boot platform (BIOS, UEFI) in the El Torito boot catalog of the source, read from the ISO bytes, is also in the new ISO. |
| `Mount`, `VolumeLabel` | Both ISOs mount read-only, and the volume label is unchanged. |
| `UefiBootPrompt` | The boot image the UEFI entry points to, read from the ISO bytes, is identical to `efi\microsoft\boot\efisys_noprompt.bin` on the new ISO, so UEFI starts Setup without "Press any key". |
| `BiosBootPrompt` | The new ISO has a BIOS entry and no `boot\bootfix.bin`, so `etfsboot.com` doesn't wait for a key. |
| `BootAndSetupFiles` | Every BIOS and UEFI boot file the source has, plus `setup.exe`, `sources\setup.exe` and `sources\boot.wim`, exists on the new ISO. |
| `BootImage` | boot.wim has the same number of indexes as the source. |
| `InstallIndexes` | Same indexes, edition IDs and names as the source. |
| `ServicedIndexes` | The serviced indexes equal `-Index` / `-AllIndexes`, or at least one index was serviced. |
| `Index<n>CumulativeUpdate` | Read from the serviced image itself: the `Package_for_RollupFix` revision equals the OS build revision in the cumulative update title. For rollup-serviced releases, which carry no OS build in the title, `Package_for_KB<number>` is installed or the rollup version increased. |
| `Index<n>ServicingStack` | **Standalone servicing stack update:** it is in the applied sequence, and either `Package_for_KB<number>` or a new `Package_for_ServicingStack*` package is in the image, or DISM reported it not applicable (already present or superseded). **Combined releases:** the cumulative update check passed. **Both cases:** the `TrustedInstaller.exe` version did not decrease. |
| `Index<n>Checkpoint` | Releases with checkpoint cumulative updates: the target MSU is recorded and the target revision is verified. DISM installs the target only after its checkpoints, so the verified revision confirms the chain. |
| `Index<n>PackageState` | No package in the image is `PartiallyInstalled`. |
| `Index<n>WinRE` | A WinRE image recorded as serviced differs from the original `Winre.wim`. |
| `Index<n>ImageVersion` | The image version did not decrease. |
| `NoMountedImages` | No validation mount is left behind. |
| `RunLog` | The structured run log has entries and none at level `Error`. |

## 📊 Results

Reports go to `<outputDirectory>\live-<yyyyMMdd-HHmmss>\<nn>-<iso name>\`:

| File | Content |
| --- | --- |
| `report.json` | The structured result:<br>• host and DISM versions<br>• source ISO and checksum<br>• detected release and editions<br>• update plan: servicing stack, cumulative and checkpoint updates<br>• downloaded packages with SHA-256<br>• per serviced index: cumulative update package and servicing stack version before and after, and the applied update sequence with DISM results<br>• output ISO and checksum<br>• all checks<br>• errors<br>• start time, end time and duration |
| `report.txt` | The same, as text. It is also written to the information stream at the end of each ISO. |
| `logs\` | The run log (`<run id>.log.jsonl`) and the DISM logs of `Update-WindowsISO`. They are kept when the run fails. |

The serviced ISO, its manifest (`.json`) and its `.sha256` file are written to `outputDirectory` only after validation
passed (INVARIANTS.md, Media and artifacts #2). The script writes a report object for each ISO. After processing every
ISO, it throws if any of them failed, so `pwsh -File` exits with code 1.

## ⏱️ Runtime

Not measured yet; no live run has been recorded. The time is spent on these steps:

- package download, on the first run only;
- one mount and commit per serviced index;
- the WinRE and boot.wim servicing;
- the image export;
- OSCDIMG;
- two read-only mounts per serviced index during verification.

`-BootTest` adds a full Windows installation in a VM.

## 🧹 Cleanup and artifacts

- The source ISO is only mounted read-only. If it was already attached, it stays attached.
- `Update-WindowsISO` discards mounted images on failure and removes its run workspace unless `-KeepTemporaryFiles` is
  given.
- The validator mounts into a new `live-validate-<id>` folder under the working directory. It always dismounts with
  `-Discard` and removes the folder only when it is empty. Other files in the working directory are never touched.
- Reports, logs, serviced ISOs and the package cache are kept. Delete them when no longer needed.

## 🩺 Troubleshooting

| Symptom | Cause and action |
| --- | --- |
| `...cannot be run because it contains a "#requires" statement for running as Administrator` | Start PowerShell 7 as administrator. |
| `HostCompatibility` failed | The host DISM is older than the media. Run on a newer host, for example Windows 11 24H2 or Windows Server 2025 for 26100-based media. |
| `OutOfSupportMedia`, `UnsupportedMedia`, `EsuEntitlementRequired` | The lifecycle refusals described in [Supported media](#-supported-media). |
| `... already exists. Use -Force ...` | A serviced ISO for the same release, build and month is already in `outputDirectory`. Use `-Force` or another folder. |
| `CatalogFormatChanged` | The Microsoft Update Catalog pages changed. See [docs/troubleshooting.md](../../docs/troubleshooting.md). |
| `ISO ... has no drive letter` | Automatic drive letter assignment is off. Run `mountvol /E`. |
| `NoMountedImages` failed | Run `dism /Get-MountedWimInfo` and `dism /Cleanup-Mountpoints`. |
| `Index<n>CumulativeUpdate` failed | Compare `rollupAfter` in the report with the OS build in the update title, and read the DISM logs in `logs\`. |

## ⚠️ Limitations

- **install.esd sources:** their indexes can't be mounted. The before values come from the manifest, and the comparison
  with the source package list is skipped. The servicing stack check then relies on the package name or the DISM
  result.
- **Servicing stack packages:** identified by the package names `Package_for_KB<number>` and
  `Package_for_ServicingStack*`, and by the version of `TrustedInstaller.exe`. Microsoft doesn't document these names.
  A naming change shows up as a failed check, never as a silent pass.
- **Media DISM version:** read from `sources\dismcore.dll`. If the file is missing, the image build is compared
  instead. This is stricter: it refuses Windows 11 25H2 media on a 26100 host.
- **Split images:** the scripts don't use `-SplitInstallImage`, and the validator expects `sources\install.wim`.
- **Test status:** no live run has been recorded for any release. Record results in
  [docs/supported-operating-systems.md](../../docs/supported-operating-systems.md#-test-status).

## 🖥️ Hyper-V installation test

`Test-WindowsIsoInstallation.ps1` proves that a serviced ISO installs and boots. It installs one edition in a temporary
Hyper-V VM without any user interaction, logs on to the installed system and checks it. Like the scripts above, it's a
standalone script, not a Pester test, and it never runs in CI.

### Prerequisites

| Requirement | Detail |
| --- | --- |
| PowerShell | 7.4 or later, elevated (`#Requires -RunAsAdministrator`). |
| Hyper-V | The Hyper-V role and its PowerShell module on an x64 host running Windows 10, Windows Server 2016 or later (PowerShell Direct needs that host). Your account must be allowed to manage Hyper-V; an elevated administrator is. |
| Host resources | Free memory of at least `-MemoryGB` (4 GB by default) and 40 GB free in `-WorkingDirectory`. |
| OSCDIMG | Not installed separately. The answer ISO is built with the Microsoft-signed `oscdimg.exe` in the module's `Resources` folder, or from an installed Windows ADK when that copy is missing; the signature is checked before use. The Windows ADK isn't required. |
| Media | An x64 ISO, normally one created by `Update-WindowsISO`. The ISO must not be mounted on the host. |
| Network | Not required. Without `-SwitchName` the VM has no network adapter and installs offline. |

### Supported media

The script detects the release, editions, languages and versions with `Get-WindowsISOInfo`.

| Release | VM | Validation |
| --- | --- | --- |
| Windows 11 | Generation 2 only, Secure Boot, TPM 2.0, at least 4 GB, 2 vCPU, 64 GB disk. Settings below that are refused, never bypassed. | PowerShell Direct |
| Windows 10, Windows Server 2016, 2019, 2022, 2025 | Generation 2 (default) or 1. The TPM is added when the host can provide one. | PowerShell Direct |
| Windows Server 2012, 2012 R2 | Generation 2 (default) or 1 | Hyper-V data exchange only (see [Limitations](#limitations-of-the-installation-test)) |

### Running

```powershell
.\tests\live\Test-WindowsIsoInstallation.ps1 -IsoPath 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso' -Edition 'ServerStandard' -AdministratorCredential (Get-Credential -UserName 'Administrator') -KeepVMOnFailure -Verbose
.\tests\live\Test-WindowsIsoInstallation.ps1 -IsoPath 'D:\ISO\Updated\Windows_11_24H2_x64_26100_2026-11.iso' -Edition 'Enterprise' -AdministratorCredential (Get-Credential -UserName 'Administrator') -Language 'en-US' -KeyboardLayout 'da-DK' -TimeZone 'Romance Standard Time' -MemoryGB 4 -ProcessorCount 2 -TimeoutMinutes 90
```

On Windows Server media, `-Edition` selects the Desktop Experience image; add `-ServerCore` for Server Core, or use
`-Index`. An installation takes 15 to 60 minutes, depending on the release and the host. This hasn't been measured
yet, because no run has been recorded.

### Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `IsoPath` | required | ISO to install |
| `Edition`, `ServerCore` / `Index` | required | Image to install, by EditionId or by index |
| `AdministratorCredential` | required | Password for the built-in `Administrator` account (see [Credentials](#credentials)) |
| `ManifestPath` | `<IsoPath>.json` | Manifest with the expected cumulative update and servicing stack |
| `Language` | `en-US` | Setup and system UI language; must be in the image |
| `SystemLocale`, `UserLocale` | `en-US` | System locale and the user's formats |
| `KeyboardLayout` | `da-DK` | Input locale, as a culture name |
| `TimeZone` | `Romance Standard Time` | Windows time zone ID |
| `ComputerName` | `WIS-<8 hex>` | Computer name of the installed system |
| `ProductKey` | none | For editions whose Setup requires a key |
| `Generation` | `2` | 2 (UEFI, Secure Boot, TPM) or 1 (BIOS) |
| `MemoryGB`, `DynamicMemory` | `4`, off | Startup memory; dynamic memory uses it as the minimum |
| `ProcessorCount` | `2` | Virtual processors |
| `DiskSizeGB` | `64` | Dynamically expanding VHDX |
| `SwitchName` | none | Virtual switch; without it the VM has no network adapter |
| `TimeoutMinutes` | `90` | From VM start to Setup complete |
| `OutputDirectory` | `%ProgramData%\WindowsIsoServicing\InstallationTests` | Result and logs |
| `WorkingDirectory` | `%ProgramData%\WindowsIsoServicing\Workspace` | VM, VHDX and answer ISO |
| `KeepVM` / `KeepVMOnFailure` | off | Keep the VM, turned off, always or only after a failure |

### How it works

1. Writes `Autounattend.xml` with the windowsPE, specialize and oobeSystem passes. It sets the languages, locales, input
   locale and time zone, wipes disk 0 (GPT for UEFI, MBR for BIOS), installs the selected index, accepts the license
   terms, and sets the computer name and the Administrator password. Client releases hide the online account, wireless
   and privacy pages. The built-in Administrator account, which client editions disable by default, is enabled through
   one automatic logon (`AutoLogon`, `LogonCount` 1). That's the method Microsoft documents. No other account is
   created, no domain is joined and Windows isn't activated.
2. Builds `answer.iso` (label `AUTOUNATTEND`) that holds only that file. Windows Setup searches the root of removable
   and CD/DVD drives for `Autounattend.xml`.
3. Creates the VM `wis-install-<8 hex>` with automatic checkpoints off, automatic start off and automatic stop set to
   shut down. It attaches the Windows ISO and the answer ISO as two DVD drives. The boot order puts the disk first: the
   blank disk falls through to the Windows ISO, and after Setup's first restart the installed disk starts, so the ISO
   can't start the installation again. The serviced ISO doesn't wait for "Press any key"
   ([docs/servicing.md](../../docs/servicing.md#-boot-without-press-any-key)), so no key is pressed.
4. Polls the VM every 20 seconds. The run fails if the VM turns off, restarts more than eight times (a sign that Setup
   starts again or fails), or reaches the timeout. Setup is complete when `%SystemRoot%\Setup\State\State.ini` reports
   `IMAGE_STATE_COMPLETE`, read over PowerShell Direct. A running VM alone doesn't count.
5. Checks the installed system (see the table below), shuts the VM down, mounts its disk read-only and copies the logs.
6. Writes `result.json`, removes the answer files and, unless a keep switch applies, the VM and its folder.

### Installation checks

| Check | Passes when |
| --- | --- |
| `InstalledSystemBooted` | The installed system publishes its OS name and build through Hyper-V data exchange (KVP), which runs only in a booted Windows with integration services. |
| `AdministratorPassword` | PowerShell Direct logs on as `Administrator` with the supplied password. |
| `Edition` | `EditionID` and `InstallationType` in the registry match the selected image. |
| `Version` | The OS version plus UBR equals the image version on the ISO, for example `10.0.26100.7171`. |
| `Architecture` | `PROCESSOR_ARCHITECTURE` is `AMD64`. |
| `CumulativeUpdate` | The installed `Package_for_RollupFix` equals the manifest's `rollupAfter` for the index. Without a manifest, its build and revision must equal the image version's. |
| `ServicingStack` | The installed `Package_for_ServicingStack` is at least the version the manifest lists for the index. `Skipped` when the manifest lists none: combined releases often have no separate package, and nothing else independent exists to compare with. |
| `UiLanguage`, `SystemLocale`, `UserLocale`, `KeyboardLayout`, `TimeZone`, `ComputerName` | The installed values match the parameters. `KeyboardLayout` compares the first layout in the Administrator's `Keyboard Layout\Preload` with the culture's keyboard layout ID (`da-DK`: `00000406`). |
| `AdministratorAccount` | The built-in account (SID ending in `-500`) is enabled. |
| `NoDomainJoin` | The computer isn't part of a domain. |
| `SetupCompleted` | `State.ini` on the disk, read after shutdown, reports `IMAGE_STATE_COMPLETE`. |
| `UnattendErrors` | `Windows\Panther\UnattendGC\setuperr.log` (errors from the specialize and oobeSystem passes) is empty or absent. |
| `Installation` | Added as `Failed`, with the reason, when Setup didn't complete. |

The script exits with code 1 when any check fails.

### Credentials

- Pass the password as a `PSCredential` at run time, for example with `Get-Credential -UserName 'Administrator'`. It's
  never stored in the repository, a parameter default or a log.
- Use a test password that is used nowhere else. It must meet the default Windows complexity rules, or Setup would stop
  at the password page, so the script checks this before it starts.
- The answer file stores the password in the Base64 form that Windows Setup reads. That's encoding, not encryption, so
  treat `Autounattend.xml` and `answer.iso` as secrets. They're created in a folder only Administrators and SYSTEM can
  read. On every exit path, also with `-KeepVM`, the answer ISO is detached and both files are deleted.
- Windows Setup replaces the passwords in its own copy of the answer file (`Windows\Panther\unattend.xml`) with
  `*SENSITIVE*DATA*DELETED*`. The script doesn't copy that file into the logs anyway.
- A kept VM still has the test password. Delete it, or change the password, when you're done.

### Results and logs

`<OutputDirectory>\wis-install-<8 hex>\` contains:

| File | Content |
| --- | --- |
| `result.json` | Test name, start and end time, duration, ISO, expected and installed version, build and edition, VM configuration, restarts, installation status, checks, failure reason and log locations |
| `logs\Windows_Panther_setupact.log`, `..._setuperr.log` | Windows Setup log of the installed system |
| `logs\Windows_Panther_UnattendGC_*.log` | Setup log of the specialize and oobeSystem passes |
| `logs\_WINDOWS._BT_Sources_Panther_*.log` | Setup log of the windowsPE pass, present when Setup failed before the first restart |
| `logs\Windows_Setup_State_State.ini` | Setup image state |
| `logs\Windows_System32_winevt_Logs_Setup.evtx` | Setup event log |
| `logs\Windows_Logs_CBS_CBS.log`, `logs\Windows_Logs_DISM_dism.log` | Servicing logs |

The logs are copied from the VM's disk after shutdown, so they're there after failures too, as long as Setup
partitioned the disk.

### Cleanup

- The VM, `disk.vhdx` and `<WorkingDirectory>\wis-install-<8 hex>\` are removed at the end. `-KeepVM` keeps them always,
  and `-KeepVMOnFailure` keeps them after a failure. A kept VM is turned off.
- Only the VM created by the run is removed, found by its ID, together with the folder the run created. The script
  refuses to start if a VM or folder with the generated name already exists. Other VMs, switches and files aren't
  touched.
- The result and the logs in `OutputDirectory` are kept.
- If cleanup fails, a warning names the VM and folder to remove by hand.

### Troubleshooting the installation test

| Symptom | Cause and action |
| --- | --- |
| `is mounted on the host` | Dismount it with `Dismount-DiskImage`. Hyper-V can't attach an ISO that the host has mounted. |
| `Exactly one image must match the selection` | The message lists the images. On Server media, use `-ServerCore` or `-Index`. |
| `Language … is not in image` | Pass one of the listed languages with `-Language`. |
| Timeout with heartbeat `NoContact` | Setup is still in WinPE or waiting for input. Run with `-KeepVMOnFailure` and open the VM in Hyper-V Manager. A product key page means the edition needs `-ProductKey`. |
| `The VM restarted … times` | Setup starts again or fails during a restart. Read `_WINDOWS._BT_Sources_Panther_setuperr.log` and `Windows_Panther_setuperr.log`. |
| `The VM turned off` | Setup or the installed system shut the VM down. Read the Panther logs. |
| `UnattendErrors` failed | An answer file setting was rejected in the specialize or oobeSystem pass. The first line is in the check detail; the full text is in `Windows_Panther_UnattendGC_setuperr.log`. |
| `KeyboardLayout`, `UserLocale` or `TimeZone` failed | Compare the installed value in the detail with the parameter. Check that the language and input locale exist in the image. |
| Windows 11 client OOBE stops at a network or account page | Pass `-SwitchName` with a switch that has internet access. The script doesn't bypass OOBE requirements. |
| `The virtual TPM could not be enabled` | The host can't create a local key protector (Host Guardian Service). Windows 11 then stops; other releases install without a TPM. |

### Limitations of the installation test

- **Not run yet.** No installation has been recorded for any release. Until one is, nothing here is a test result.
  Record runs in [docs/supported-operating-systems.md](../../docs/supported-operating-systems.md#-test-status).
- **Restarts** are counted from the VM's uptime, which Hyper-V resets when the guest restarts.
- **Windows Server 2012 and 2012 R2** don't support PowerShell Direct. Completion means that the guest has published its
  build through data exchange for five minutes without a restart. `SetupCompleted` then confirms it from `State.ini`
  after shutdown. The checks that need a logon (password, edition, packages, regional settings, account) are `Skipped`.
  This project can't service these releases (they're out of support), so the fallback matters only for original media.
- **Client OOBE without network** relies on `HideOnlineAccountScreens` and the Administrator automatic logon. Microsoft
  doesn't document whether every client release completes OOBE offline with those settings; only a run shows it.
- **`UnattendErrors`** fails on any line in `UnattendGC\setuperr.log`. Setup can log non-fatal errors there, so read
  the line before treating it as a defect.
- **BIOS boot prompt:** a generation 1 run can't show that the ISO doesn't wait for a key, because a blank disk never
  shows the prompt.
- **x64 only**, on x64 hosts.
