# AGENTS.md

Operational context for agents working in this repository. Hard constraints are in [INVARIANTS.md](INVARIANTS.md).

## Role

Work as a senior Windows deployment and servicing engineer. Prefer native Microsoft tooling (DISM, OSCDIMG, Hyper-V), Microsoft's public update sources (MSRC Security Updates API, Microsoft Update Catalog) and Microsoft documentation over assumptions. General PowerShell, testing and documentation standards are in the skills below; this file and [INVARIANTS.md](INVARIANTS.md) take precedence over them.

## Skills

| Skill | Use for |
| --- | --- |
| `senior-powershell-developer` | PowerShell standards, module structure and code review |
| `windows-servicing-engineer` | DISM servicing of install.wim, boot.wim and WinRE; release data |
| `windows-media-engineer` | Media copy, OSCDIMG, BIOS/UEFI boot, ISO validation, Hyper-V installation test |
| `microsoft-update-specialist` | MSRC and Catalog discovery, package integrity, repository |
| `release-engineer` | GitHub Actions, packaging, Gallery publishing, pipeline and artifact store |
| `senior-software-tester` | Pester tests, test runs, defect reports |
| `senior-technical-writer` | README, `docs/`, examples, changelog |

The instructions live once in `.agents/skills/<name>/`, which is where Codex looks, together with the shared rules, which skill owns which file, and the order for work that needs more than one skill (`_shared/engineering-standards.md`). Claude Code reads the short pointer files in `.claude/skills/<name>/SKILL.md`, which repeat only the name and description and point to the Codex copy. Edit the Codex copy. When you change a name or description, change it in both places; the Lint task fails if they differ.

## Where things are

- Module layout, execution flow, manifest schema and logging: [docs/architecture.md](docs/architecture.md)
- Servicing sequence per component and per release: [docs/servicing.md](docs/servicing.md)
- Discovery sources, title classification, repository format: [docs/update-discovery.md](docs/update-discovery.md)
- Release and lifecycle behavior, test status: [docs/supported-operating-systems.md](docs/supported-operating-systems.md)
- Pipeline, artifact store, CI: [docs/automation.md](docs/automation.md)
- Host prerequisites: [docs/requirements.md](docs/requirements.md)
- Failure symptoms: [docs/troubleshooting.md](docs/troubleshooting.md)

## Commands

| Task | Command |
| --- | --- |
| Lint + typecheck + unit tests | `make check`, or without make: `pwsh -File scripts/Invoke-QualityGate.ps1 -Task All` |
| Single stage | `make lint`, `make typecheck`, `make test` (`-Task Lint`/`Typecheck`/`Test`) |
| Build and validate the PowerShell Gallery package (no network) | `./scripts/Build-ModulePackage.ps1` ([README](README.md#-packaging-and-publishing)); publishing runs in `.github/workflows/publish-module.yml` |
| Integration tests (elevated, real media) | `$env:WIS_INTEGRATION_CONFIG = '<path>'; Invoke-Pester -Path tests/Integration -Tag Integration` |
| Live servicing run with independent verification (elevated, real media; no Pester) | `./tests/live/Invoke-LiveIsoServicing.ps1 -IsoPath '<iso>' -OutputDirectory '<folder>'` ([tests/live/README.md](tests/live/README.md)) |
| Unattended Hyper-V installation of a serviced ISO (elevated, Hyper-V; no Pester) | `./tests/live/Test-WindowsIsoInstallation.ps1 -IsoPath '<iso>' -Edition '<EditionId>' -AdministratorCredential (Get-Credential -UserName Administrator)` ([tests/live/README.md](tests/live/README.md#-hyper-v-installation-test)) |

`make` is not installed on every Windows host, so the script is the source of truth and the Makefile only wraps it.

## Footguns

- **Elevation.** DISM cmdlets, `Get-DiskImage` and `Get-WindowsImage` need an elevated session. Unit tests mock them; never call them unmocked in `tests/Unit`.
- **StrictMode 3.0** is on in the module. Reading a missing property on JSON-derived objects throws, so use `$obj.PSObject.Properties['name']?.Value`. The same applies to `$null.Property` chains: use `?.`.
- **`ConvertFrom-Json` turns ISO 8601 strings into `[datetime]`.** Don't reparse them with `[DateTimeOffset]::Parse`; cast instead.
- **Workspace paths cannot contain whitespace.** OSCDIMG boot-sector arguments can't be quoted.
- **The Microsoft Update Catalog has no documented API.** Only `src/WindowsIsoServicing/Private/MicrosoftUpdateCatalog.ps1` may use its pages (the lint enforces this). Parsers must throw `CatalogFormatChanged` rather than return nothing. Test them against the real captured responses in `tests/Unit/Fixtures`; when the site changes, capture new ones and never edit a fixture to make a test pass. Unit tests must never reach the network: mock `Search-CatalogUpdate`, `Get-CatalogUpdateDetail`, `Get-CatalogUpdateFile` and `Get-MsrcSecurityUpdate`.
- **Catalog titles are not reliable for previews.** Recent optional previews have no "Preview" in the title. A cumulative update not classified *Security Updates* counts as a preview, and the MSRC baseline decides the security update ([docs/update-discovery.md](docs/update-discovery.md)).
- **The MSRC CVRF document is about 30 MB** and takes seconds to download; it is cached per session in `$script:MsrcDocumentCache`.
- **`Resources/oscdimg.exe` is a Microsoft-signed binary** committed on purpose. Don't replace it with an unsigned file; `Find-Oscdimg` refuses it. It is the default, an installed Windows ADK is only the fallback, and `oscdimg.exe` is the only ADK file the module uses.
- **Lifecycle dates are time-sensitive.** Tests that depend on support state pass `-AsOf` explicitly; keep it that way.
- **Pester 5.x** (5.6.1 pinned in CI), not Pester 6. Private functions are tested through `InModuleScope`.
- **PSScriptAnalyzer on `tests/`** produces false positives from Pester scoping, so the lint gate covers `src` and `scripts` only.
- **Editing `.ps1` files through Python string literals or unquoted heredocs corrupts backslashes** (`\v`, `\\`). Use the Edit tool or quoted heredocs, then check with `make typecheck`.
- **No comments, one line per command.** Only `#Requires` and comment-based help are allowed; explain the reasons in the help `.DESCRIPTION`. Don't continue a command with a backtick, or with a pipe or operator at the end of a line. Each `.EXAMPLE` is a single command line with no blank line or remark, because Get-Help would show remark text as code. The Lint task enforces all of this.
- **Commits.** Don't commit or push unless the user asks.
