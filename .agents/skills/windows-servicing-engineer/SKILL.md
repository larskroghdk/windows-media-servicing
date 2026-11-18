---
name: windows-servicing-engineer
description: Designs, changes and reviews offline Windows image servicing with DISM - install.wim, boot.wim and WinRE, servicing stack, cumulative, checkpoint, .NET and Dynamic Updates, the Dynamic Update media sequence, tolerated DISM results, component cleanup, export, release and lifecycle data in OperatingSystems.psd1, and the cumulative update result check. Use for changes to ImageServicing.ps1, OperatingSystem.ps1 or the release data, for a new Windows release, and for servicing failures. Not for update discovery, ISO building or boot behavior.
---

# Windows Servicing Engineer

You own the correctness of what happens to the images between mount and export. A servicing change is right only when it
follows Microsoft's documented sequence and the image proves it took the update.

- Read [../\_shared/engineering-standards.md](../_shared/engineering-standards.md) first, and the Servicing and
  Lifecycle sections of [INVARIANTS.md](../../../INVARIANTS.md). They are not repeated here.
- Write PowerShell to the rules in [senior-powershell-developer](../senior-powershell-developer/SKILL.md#rules).

**Scope.** `Private/ImageServicing.ps1`, `Private/OperatingSystem.ps1`, `Data/OperatingSystems.psd1`, the servicing part
of `Update-WindowsISO`, and [docs/servicing.md](../../../docs/servicing.md). Package selection belongs to
`microsoft-update-specialist`; media copy, ISO build and boot validation to `windows-media-engineer`.

## Sources of truth

| Question | Source |
| --- | --- |
| Order of SSU, LCU, Safe OS and Setup Dynamic Update per image | [Update Windows installation media with Dynamic Update](https://learn.microsoft.com/windows/deployment/update/media-dynamic-update) and its sample script |
| Checkpoint cumulative updates | [Checkpoint cumulative updates](https://learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates) |
| Host DISM version against image version | [DISM supported platforms](https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-supported-platforms) |
| Component cleanup | [Clean up the WinSxS folder](https://learn.microsoft.com/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder) |
| Release model, flags, lifecycle dates | `Data/OperatingSystems.psd1`, checked against [Microsoft Lifecycle](https://learn.microsoft.com/lifecycle/) |

When Microsoft's page and the code disagree, the page wins; record the decision in docs/servicing.md.

## Rules

- **Branch on release flags, never on build numbers.** `Servicing.Model`, `ServicingStackSeparate`,
  `ServicingStackCombined`, `CheckpointUpdates`, `SafeOsDynamicUpdate` and `SetupDynamicUpdate` decide the steps. A new
  release is a data entry plus a test, not a new code path. The only documented build exception is `setuphost.exe` at
  26100+.
- **Every package goes through `Add-ServicingPackage`.** It owns the tolerated results. A new tolerated HRESULT needs a
  Microsoft Learn reference, a switch with a name that says why, and a `Test-ErrorHResult` test. Match HRESULTs through
  nested exceptions (`Test-ErrorHResult`), never through message text, which is localized.
- **WinRE gets the servicing stack and the Safe OS Dynamic Update only,** and stays untouched without a Safe OS Dynamic
  Update. Each unique `Winre.wim` (by SHA-256) is serviced once and reused.
- **Prove the cumulative update.** `Assert-CumulativeUpdateResult` compares `Package_for_RollupFix` before and after.
  Never relax it because DISM returned success; DISM does that for packages it skipped.
- **Checkpoints:** `Add-WindowsPackage -PackagePath` points at the target MSU in a folder created by
  `New-CumulativeUpdateFolder` that holds only the target and its checkpoint MSUs. Don't pass the folder, and don't
  add checkpoints one by one.
- **Mount lifecycle:** mount through `Mount-ServicingImage`, discard in `finally` through `Undo-ServicingMount` or
  `Clear-ServicingMount`, commit and export with `-CheckIntegrity`, and keep scratch and logs under the run workspace.
  A failure in cleanup must not hide the servicing error.
- **No removal:** no `/ResetBase`, no `Remove-WindowsPackage`, no feature or language changes. They make the image
  unserviceable or need the checkpoint full payload.
- **Native DISM** only for operations without a cmdlet (`/Cleanup-Image`), through `Invoke-ExternalTool` with `/English`
  and explicit success codes.
- **Lifecycle refusal** happens in `Assert-ServiceableRelease` before anything is mounted, with the distinct error IDs
  `UnsupportedMedia`, `OutOfSupportMedia` and `EsuEntitlementRequired`. Tests pass `-AsOf`.

## Failure patterns

| Symptom | Usual cause | Response |
| --- | --- | --- |
| 0x800F081E on an LCU | Wrong architecture or release selected | Fix selection; never tolerate it for an LCU |
| 0x8007007E outside the WinPE/WinRE combined LCU step | Not a documented result there | Stop; don't widen the tolerance |
| Errors on 26100 media from an older host | Host DISM older than the image | Service from a 26100+ host ([docs/requirements.md](../../../docs/requirements.md)) |
| LCU succeeds, rollup version unchanged | Superseded or already-installed package | `Assert-CumulativeUpdateResult` fails the run; check discovery |
| 0x800F0806 during cleanup | Pending operations in the image | Logged and skipped; anything that leaves pending operations is a defect |
| Dismount fails, mount left in `Get-WindowsImage -Mounted` | Antivirus or open handle on the mount folder | Discard; document the workspace exclusion |

## Validation

- Unit tests mock DISM cmdlets (`tests/Unit/UpdateWindowsIso.Tests.ps1`) and assert the order of package calls per
  release model, the tolerated codes and the result check. Pair with `senior-software-tester`.
- A change in sequence, tolerated codes or a new release needs a live run with `tests/live/Invoke-LiveIsoServicing.ps1`
  on real media before docs/supported-operating-systems.md records it as tested. Say plainly when that did not run.

## Done when

- The change is traceable to a Microsoft Learn page or to release data, and docs/servicing.md states it.
- Unit tests cover each affected release model, and the quality gate passed.
- The report says which media a live run covered, or that none ran.
