# Invariants

Hard constraints. A change that breaks one of these is wrong, whatever else it achieves.

## Media and artifacts

1. **The source ISO is never modified or overwritten.** It is mounted read-only, and the output path may not equal the source path.
   Enforced by: `Mount-IsoImage` (`-Access ReadOnly`) and the path check in `Update-WindowsISO`; `tests/Unit/UpdateWindowsIso.Tests.ps1`; integration test *leaves the source ISO unchanged*.
2. **Nothing reaches `OutputPath` or the artifact store unless validation passed, and the latest known-good ISO is never replaced before that.**
   Enforced by: staging plus the validation gate in `Update-WindowsISO`; `Publish-WindowsISO` refuses `validation.passed = false` and checksum mismatches; `tests/Unit/UpdateWindowsIso.Tests.ps1`, `tests/Unit/Publish.Tests.ps1`.
3. **Installation success is reported only when an installation test actually ran and passed.** Structural and installation validation are recorded separately (`validation.structural`, `validation.bootTest.performed`).
   Enforced by: `Invoke-HyperVBootTest` (result defaults to `Failed`); code review.
4. **Only SYSTEM and Administrators can change the workspace and the cache.** A run stops when the folder, a parent folder or an item in it is a link or is owned by another account.
   Enforced by: `Protect-ServicingDirectory` in `Update-WindowsISO`, `Save-WindowsISOUpdate` and `Test-WindowsISO`; `tests/Unit/UpdateWindowsIso.Tests.ps1`.

## Lifecycle and licensing

1. **Unknown and out-of-support media are refused with distinct error IDs (`UnsupportedMedia`, `OutOfSupportMedia`), so they are never reported as servicing failures.**
   Enforced by: `Assert-ServiceableRelease`; `tests/Unit/OperatingSystem.Tests.ps1`, `tests/Unit/UpdateWindowsIso.Tests.ps1`.
2. **ESU-only media requires `-EsuEntitled`. The tool never activates, installs keys for, or bypasses ESU licensing.**
   Enforced by: `Assert-ServiceableRelease` (`EsuEntitlementRequired`); `tests/Unit/OperatingSystem.Tests.ps1`.
3. **Release, servicing-model and lifecycle data live only in `src/WindowsIsoServicing/Data/OperatingSystems.psd1`.** Code branches on its flags, not on build numbers. The one exception is `setuphost.exe` at build 26100+, which Microsoft documents.
   Enforced by: code review.

## Update discovery and packages

1. **Updates come only from Microsoft's public sources: the MSRC Security Updates API (documented), the Microsoft Update Catalog pages `Search.aspx`, `ScopedViewInline.aspx` and `DownloadDialog.aspx` (undocumented; Microsoft offers no API for them), and the local repository index. Catalog access lives only in `Private/MicrosoftUpdateCatalog.ps1`, fails with `CatalogFormatChanged` instead of returning an empty result, and is documented as unsupported. Packages download only from Microsoft download hosts. WSUS, the Windows Update Agent and the host's update configuration are never used, and no other endpoint is invented.**
   Enforced by: the host allowlists in `Invoke-UpdateSourceRequest` and `ConvertFrom-CatalogDownloadDialog`; the forbidden-pattern lint in `scripts/Invoke-QualityGate.ps1` (Catalog page names outside `MicrosoftUpdateCatalog.ps1`; `UpdateServices`, `Microsoft.Update.Session`, `wsusscn2`); `tests/Unit/UpdateSources.Tests.ps1`.
2. **A required update is never skipped silently.** Discovery stops when MSRC lists a security update the Catalog search did not return, when the selected cumulative update is older than it, or when a superseding update of the same category is missing. Updates left out on purpose (previews, non-security releases, missing components) are reported in the plan notes.
   Enforced by: `Assert-CatalogUpdatePlan`; `tests/Unit/UpdateDiscovery.Tests.ps1`.
3. **Every package passes the published hash (SHA-256, else SHA-1) when one exists, and always a valid Microsoft Authenticode signature, before use.**
   Enforced by: `Assert-PackageFileIntegrity`; `tests/Unit/PackageCache.Tests.ps1`.
4. **The checkpoint folder for a cumulative update holds only the target MSU and its checkpoint MSUs.**
   Enforced by: `Select-UpdatePackageFile` and `New-CumulativeUpdateFolder`; `tests/Unit/UpdateDiscovery.Tests.ps1`.

## Servicing

 1. **The servicing order follows Microsoft's Dynamic Update media sequence ([docs/servicing.md](docs/servicing.md)). WinRE receives only the servicing stack (standalone or through the combined cumulative update) plus the Safe OS Dynamic Update, and is left unchanged when no Safe OS Dynamic Update exists.**
    Enforced by: `Update-WinReImage`, `Update-InstallImage`, `Update-BootImage`; code review.
 2. **Only these DISM results are tolerated:** 0x8007007E when the combined cumulative update is added to WinPE/WinRE, 0x800F081E for standalone servicing stack and .NET packages, and 0x800F0806 during component cleanup. Everything else stops the run.
    Enforced by: the `Add-ServicingPackage` switches and the `Invoke-ComponentCleanup` success codes; `tests/Unit/UpdateWindowsIso.Tests.ps1` (`Test-ErrorHResult`); code review for new call sites.
 3. **A cumulative update must change the image.** The `Package_for_RollupFix` version must increase, or already be at the title's OS build.
    Enforced by: `Assert-CumulativeUpdateResult`; `tests/Unit/UpdateWindowsIso.Tests.ps1`.
 4. **No `/ResetBase`, and no removal of existing packages.**
    Enforced by: the forbidden-pattern lint in `scripts/Invoke-QualityGate.ps1` (`/ResetBase`); code review.
 5. **Mounted images are always discarded on failure, and concurrent runs cannot share a workspace, output folder, cache or store key.**
    Enforced by: the `finally` blocks with `Clear-ServicingMount`; `Lock-Directory`; `tests/Unit/UpdateWindowsIso.Tests.ps1`.

## Code

 1. **State-changing commands support `-WhatIf`/`-Confirm` through `SupportsShouldProcess`.**
    Enforced by: PSScriptAnalyzer (`PSShouldProcess`, `PSUseShouldProcessForStateChangingFunctions`); the `-WhatIf` tests in `tests/Unit/UpdateWindowsIso.Tests.ps1` and `tests/Unit/Publish.Tests.ps1`.
 2. **Native tools run only through `Invoke-ExternalTool`, with explicit success exit codes.**
    Enforced by: code review; `tests/Unit/UpdateWindowsIso.Tests.ps1` (`Invoke-ExternalTool`).
 3. **PSScriptAnalyzer is clean on `src` and `scripts`. Suppressions carry a `Justification`, and there are no TODO/FIXME markers. Functions are declared only at the top level of a file in `src`, `scripts` and `tests`, and no script block with a `param` block is assigned to a variable as a local helper. Every function and script has complete comment-based help whose examples are single command lines; there are no other comments, and no command continues on the next line.**
    Enforced by: `make lint` (`scripts/Invoke-QualityGate.ps1 -Task Lint`, including `Get-NestedFunctionProblem`, `Get-HelpProblem` and `Get-FormattingProblem`); `tests/Unit/Module.Tests.ps1`; `.github/workflows/ci.yml`.
 4. **The module targets PowerShell 7.4+ (Core) only.**
    Enforced by: `PowerShellVersion`/`CompatiblePSEditions` in the module manifest; `make typecheck`.
 5. **No credentials in code, configuration or the repository.**
    Enforced by: code review.
 6. **Documentation never claims a release or feature works without a test that ran.** Test status is recorded in [docs/supported-operating-systems.md](docs/supported-operating-systems.md#-test-status).
    Enforced by: code review.
