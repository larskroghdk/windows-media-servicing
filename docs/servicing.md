# 🛠️ Servicing sequence

The order follows Microsoft's [Update Windows installation media with Dynamic Update](https://learn.microsoft.com/windows/deployment/update/media-dynamic-update)
and [Checkpoint cumulative updates and Microsoft Update Catalog usage](https://learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates).
Languages, Features on Demand and optional components are not added. That keeps every serviced image free of pending
operations and avoids the checkpoint *full payload* requirement.

| Step | Target | Action |
| --- | --- | --- |
| 1 | WinRE (`Windows\System32\Recovery\Winre.wim` inside each install index) | Standalone SSU if one was selected. On combined releases, the latest cumulative update, which installs only its servicing stack in WinRE; the documented 0x8007007E result is tolerated here. Then the Safe OS Dynamic Update. Optional cleanup. Export. |
| 2 | install.wim, each selected index | Copy in the serviced WinRE, then standalone SSU (0x800F081E tolerated), latest cumulative update, optional cleanup, .NET cumulative updates (0x800F081E tolerated). The cumulative update result is verified, then the image is committed with `-CheckIntegrity`. |
| 3 | install.wim | Every index, serviced or not, is exported in original order to a new `install.wim` (maximum compression, integrity table). |
| 4 | boot.wim, every index | Standalone SSU, then latest cumulative update (0x8007007E tolerated on combined releases), optional cleanup. From the index that contains `sources\setup.exe`: `setup.exe`, `setuphost.exe` (build 26100+) and `bootmgfw.efi`, `bootmgr.efi`, `boot.stl` are saved. Export. |
| 5 | Media | The Setup Dynamic Update is expanded into `\sources` (`expand.exe -F:*`). Then `setup.exe`/`setuphost.exe` and the boot manager files on the media (`bootmgfw.efi`, `boot*.efi`, `bootmgr.efi`, `efi\microsoft\boot\boot.stl`) are replaced with the WinPE versions, so the media and WinPE binaries match. |
| 6 | Media | Optional `-SplitInstallImage`: `install.wim` larger than 4 GB is split into 3800 MB `install.swm` parts. |
| 7 | ISO | OSCDIMG with `-m -o -h -u2 -udfver102`, plus a boot catalog that matches the source: BIOS + UEFI (`-bootdata:2#p0,e,b…etfsboot.com#pEF,e,b…efisys_noprompt.bin`), UEFI only, or BIOS only. Neither entry waits for "Press any key"; see [Boot without "Press any key"](#-boot-without-press-any-key). |

## 📅 Per-release rules

| Release model | WinRE | install.wim | boot.wim | Media |
| --- | --- | --- | --- | --- |
| Monthly rollup (2012 / 2012 R2) | Not serviced | SSU, rollup, .NET | Not serviced | Not changed |
| Cumulative with separate SSU (2016, 2019, LTSB 2016, LTSC 2019) | SSU + Safe OS DU | SSU, LCU, .NET | SSU, LCU | Setup DU, WinPE binaries |
| Combined SSU + LCU (2022, Windows 10 21H2/22H2, Windows 11 23H2) | LCU (SSU only) + Safe OS DU | [SSU], LCU, .NET | [SSU], LCU | Setup DU, WinPE binaries |
| Combined with checkpoints (Server 2025, Windows 11 24H2/25H2) | as combined | as combined; LCU folder holds the target and checkpoint MSUs | as combined | as combined, plus `setuphost.exe` |

WinRE is serviced only when a Safe OS Dynamic Update is available, because Microsoft supports no other way to service
WinRE. Without one, WinRE stays unchanged and the manifest records why. Media without `Winre.wim` is reported and
skipped.

Each unique `Winre.wim` (by SHA-256) is serviced once and reused for every index that carries the same original file.

## ⏩ Boot without "Press any key"

Every ISO that `Update-WindowsISO` builds starts Windows Setup directly, on BIOS and on UEFI, with no option to turn
this off. Microsoft's boot files on the media are used as they are; nothing is patched or re-signed, so Secure Boot
keeps working.

| Firmware | How the prompt is removed | When it can't be removed |
| --- | --- | --- |
| UEFI | The UEFI boot entry is built from `efi\microsoft\boot\efisys_noprompt.bin`, the no-prompt variant of `efisys.bin` that Microsoft ships on the media ([OSCDIMG command-line options](https://learn.microsoft.com/windows-hardware/manufacture/desktop/oscdimg-command-line-options)). | Media with UEFI boot files but without `efisys_noprompt.bin` is refused before servicing starts. The tool never falls back to the prompting `efisys.bin`. |
| BIOS | `boot\bootfix.bin` is left out when the media is copied. `etfsboot.com` shows the prompt only when that file exists. Microsoft Learn doesn't document this behavior; it's what the boot sector does on current media, and only a boot test on a machine with an installed disk shows it (see below). | `New-IsoImage` refuses media that still contains `boot\bootfix.bin`. |

The prompt exists so that a machine whose firmware starts from the DVD before the disk doesn't start Setup again after
its first restart. Without it:

- **UEFI:** Setup adds Windows Boot Manager to the firmware boot order, first by default, so the installed disk starts
  after the restart. Hyper-V generation 2, VMware and physical UEFI machines keep that order. If a firmware policy or an
  OEM setting puts the DVD back first, eject the ISO after Setup starts, or change the boot order.
- **BIOS:** the disk must come before the DVD in the boot order. A blank disk has no boot sector, so the machine falls
  through to the DVD on the first start and starts the installed disk after that. The Hyper-V boot test sets generation 1
  VMs to this order (`IDE`, then `CD`).

Validation checks both on the built ISO. `Test-IsoStructure` reads the El Torito boot catalog, requires an entry for each
boot mode, compares the boot image that the UEFI entry points to with `efisys_noprompt.bin` byte for byte
(`UefiBootPrompt`), and checks that `boot\bootfix.bin` is absent (`BiosBootPrompt`). The manifest records
`output.bootModes.uefiNoPrompt` and `biosNoPrompt`. The Hyper-V boot test presses no key when the manifest records
`uefiNoPrompt`, so a passing UEFI boot test shows that Setup started unattended. A passing BIOS boot test doesn't prove
the same for BIOS, because a blank disk never shows the BIOS prompt.

## 🧩 Checkpoint cumulative updates

The target MSU and its checkpoint MSUs, and nothing else, are copied to `work\packages\<KB>\`. Then `Add-WindowsPackage
-PackagePath <target.msu>` runs. DISM finds checkpoints in the target's folder and installs only the ones the image still
needs, as Microsoft documents. The same folder is used for WinPE and for WinRE's servicing stack step.

## ✅ Verification

- After the cumulative update, the `Package_for_RollupFix` version must have increased. When the update title includes the OS build, the revision must be at least that build. A cumulative update that reports success without changing the image fails the run.
- Installed packages are listed for every serviced index and recorded in the manifest.
- Commits and exports use `-CheckIntegrity`.
- Leftover mounts under the run workspace are discarded in `finally`. Validation checks that none remain.

## 🧹 Component cleanup

`-ComponentCleanup` runs `DISM /Cleanup-Image /StartComponentCleanup` on each serviced image. `/ResetBase` is never
used, so installed updates can still be uninstalled and the image stays serviceable. Cleanup is off by default.
0x800F0806 (pending operations) is logged and the step is skipped.

Unselected or out-of-support indexes are exported unchanged. `Export-WindowsImage` preserves image names,
descriptions and edition metadata.
