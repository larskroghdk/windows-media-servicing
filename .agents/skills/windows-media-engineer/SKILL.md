---
name: windows-media-engineer
description: Designs, changes and reviews Windows installation media and its validation - media copy, OSCDIMG from the required Windows ADK, El Torito boot catalogs, BIOS and UEFI boot without the boot prompt, Secure Boot, FAT32 splitting, structural ISO validation, unattended Windows Setup and the Hyper-V installation test. Use for changes to IsoMedia.ps1, IsoBuild.ps1, Validation.ps1 or the live installation test, and for ISOs that do not boot or install. Not for image servicing or update discovery.
---

# Windows Media Engineer

You own the ISO from the copied media to the proof that it installs. A media change is right only when the built ISO
boots on both firmware types with Microsoft's own boot files, and validation can tell when it doesn't.

- Read [../\_shared/engineering-standards.md](../_shared/engineering-standards.md) first, and the Media and artifacts
  section of [INVARIANTS.md](../../../INVARIANTS.md).
- Write PowerShell to the rules in [senior-powershell-developer](../senior-powershell-developer/SKILL.md#rules).

**Scope.** `Private/IsoMedia.ps1`, `Private/IsoBuild.ps1`, `Private/Validation.ps1`, `Test-WindowsISO`,
`tests/live/Test-WindowsIsoInstallation.ps1` and `tests/live/Test-IsoServicingResult.ps1`. What
goes into boot.wim and the Setup binaries belongs to `windows-servicing-engineer`.

## Sources of truth

| Question | Source |
| --- | --- |
| OSCDIMG options and boot data | [OSCDIMG command-line options](https://learn.microsoft.com/windows-hardware/manufacture/desktop/oscdimg-command-line-options) |
| Where oscdimg.exe comes from | [docs/requirements.md](../../../docs/requirements.md#-oscdimg), `Find-Oscdimg` |
| Boot prompt behavior and how it is removed | [docs/servicing.md](../../../docs/servicing.md#-boot-without-press-any-key) |
| Answer file settings | [Unattended Windows Setup reference](https://learn.microsoft.com/windows-hardware/customize/desktop/unattend/), [Windows Setup states](https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-states) |
| Setup logs | [Windows Setup log file locations](https://learn.microsoft.com/troubleshoot/windows-client/setup-upgrade-and-drivers/windows-setup-log-file-locations) |
| VM control from the host | [PowerShell Direct](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct) |

## Rules

- **Microsoft boot files from the source media, unmodified.** `etfsboot.com` and `efisys_noprompt.bin` come from the
  media, so they match its boot manager and Secure Boot signing. Never patch, re-sign, download or bundle boot images,
  and never fall back to the prompting `efisys.bin`.
- **The boot catalog matches the source:** BIOS + UEFI, UEFI only or BIOS only, as `Get-MediaBootConfiguration` found it.
  Media without `efisys_noprompt.bin` or still holding `boot\bootfix.bin` is refused before servicing starts.
- **oscdimg.exe is the only ADK file.** `Find-Oscdimg` decides: `-OscdimgPath`, then the installed
  ADK. Nothing from the ADK is bundled. Every candidate needs a Microsoft Authenticode signature; an explicit path is never replaced. The module
  never installs the ADK.
- **Arguments as an array** through `Invoke-ExternalTool`. Workspace paths have no whitespace, because OSCDIMG
  boot-data paths can't be quoted; check this before any work starts.
- **Validate what the firmware reads,** not what the folder contains: `Get-IsoBootEntry` parses the El Torito catalog
  and `UefiBootPrompt` compares the image at the entry's `LoadRba` with `efisys_noprompt.bin` byte for byte. A new boot
  property gets a check in `Test-IsoStructure` and a manifest field.
- **Report installation only when it ran.** Structural checks go to `validation.structural`; the Hyper-V result goes to
  `validation.bootTest` and defaults to `Failed`. Passing means the specialize-pass marker was found on the installed
  disk, not that the VM started.
- **Boot test VMs:** generation 2 with Secure Boot and a vTPM for UEFI, generation 1 with `IDE` before `CD` for BIOS.
  Keys are sent only for media without `uefiNoPrompt`. The VM, its disk and the answer ISO are removed in `finally`.
- **The source ISO is mounted read-only** and never written.

## Failure patterns

| Symptom | Usual cause | Response |
| --- | --- | --- |
| UEFI VM shows "Press any key" | UEFI entry built from `efisys.bin` | `UefiBootPrompt` must fail; fix the build, not the check |
| Secure Boot violation | Boot manager on the media and in boot.wim differ, or a modified boot file | Media binaries must be replaced from WinPE (servicing step 5) |
| Setup loops back to the DVD after restart | DVD before disk in the boot order | BIOS: disk first; UEFI: Windows Boot Manager first |
| install.wim over 4 GB on FAT32 USB | No split | `-SplitInstallImage` |
| OSCDIMG exit 1 | Bad boot-data path or whitespace | Check the arguments in the log; exit codes come from `Invoke-ExternalTool` |
| Boot test times out | Product key required, edition needs a key, or Setup stopped on a page | Re-run `tests/live/Test-WindowsIsoInstallation.ps1`, which collects the Setup logs; `Invoke-HyperVBootTest` removes its VM and disk in `finally` |

## Validation

- Unit tests use fake media in `TestDrive:` and mock the native and elevated boundaries (`Invoke-ExternalTool`, ISO
  mounting, DISM) in `tests/Unit/IsoBuild.Tests.ps1` and `tests/Unit/Validation.Tests.ps1`. Boot catalog parsing runs
  against real bytes, not mocks.
- Boot behavior changes need `tests/live/Test-WindowsIsoInstallation.ps1` on UEFI and BIOS, elevated with Hyper-V.
  Record the result in docs/supported-operating-systems.md only after it passed.

## Done when

- Validation fails for the defect the change prevents, and the unit tests show it.
- The report lists which firmware types a Hyper-V installation test covered, or that none ran.
