# Engineering standards

Shared by every skill in `.agents/skills`. Each skill links here instead of repeating these rules.

## Precedence

1. The user's explicit instructions in the current task.
2. Project instruction files: `AGENTS.md`, `CLAUDE.md`, `INVARIANTS.md`, `CONTRIBUTING.md` or their equivalents, read
   from the repository root down to the folder being changed.
3. The skill in use, then this file.

If two of these conflict, follow the higher one and say in your report which rule you followed.

## Evidence

- Read the code before you describe or change it. Cite findings as `path:line`.
- Check every cmdlet, parameter, API and configuration key against the code or the vendor's documentation (Microsoft
  Learn for Windows and PowerShell). If you can't check it, don't use it, or label it as unverified.
- Label claims **verified** (you read the code or ran it), **inferred** (it follows from what you read) or
  **unverified** (an assumption that still needs a test or a real environment).
- Report a test, build or lint step as passed only when it ran in this session and you saw the result. Otherwise state
  that it did not run and why.

## Changes

- Make the smallest change that solves the stated problem. No drive-by refactors, renames or reformatting.
- No speculative features, options or extension points. Add a parameter when a caller needs it.
- Add a dependency only when it removes more code or risk than it adds, and state that benefit.
- Keep public interfaces stable (command names, parameters, output shape, file formats, exit codes). A breaking change
  needs the user's approval and a changelog entry.
- Never suppress an error to make something pass. An exception that is genuinely harmless gets a comment saying why.
- Never weaken a test, a check or a security control to get a green result.

## Writing, in code, tests and documentation

Remove these patterns on sight:

- comments or prose that restate the code or the heading above them;
- generic error messages ("An error occurred") that do not name the operation, the target and the next step;
- wrappers around a single call, layers with one caller, and options nobody asked for;
- retry or fallback logic without a failure mode it actually handles;
- marketing words ("robust", "seamless", "powerful", "simply") and filler openings or closings;
- repeated content that belongs in one place and should be linked from the others.

## Working together

Every file has one owner. The owner changes it; other skills report findings to the owner.

| Skill | Owns | Does not do |
| --- | --- | --- |
| `senior-powershell-developer` | PowerShell standards for all code; module structure, public command contracts, `Environment.ps1`, `Logging.ps1`, `Manifest.ps1`, `Workspace.ps1`, `Invoke-QualityGate.ps1` lint rules; code review | Domain decisions in the areas below, test strategy, documentation files |
| `windows-servicing-engineer` | `ImageServicing.ps1`, `OperatingSystem.ps1`, `Data/OperatingSystems.psd1`, docs/servicing.md | Package selection, ISO build and boot |
| `windows-media-engineer` | `IsoMedia.ps1`, `IsoBuild.ps1`, `Validation.ps1`, `Test-WindowsISO`, `Find-Oscdimg`, the live installation test | What goes into the images |
| `microsoft-update-specialist` | `MicrosoftUpdateCatalog.ps1`, `MsrcSecurityUpdate.ps1`, `UpdateDiscovery.ps1`, `PackageCache.ps1`, `tests/Unit/Fixtures`, docs/update-discovery.md | Applying packages |
| `release-engineer` | `.github/`, packaging, publish and dependency scripts, `Invoke-IsoServicingPipeline.ps1`, `Publish-WindowsISO`, docs/automation.md | Servicing logic, unit test design |
| `senior-software-tester` | Test strategy, Pester tests, running tests, defect reports, release readiness | Production fixes |
| `senior-technical-writer` | README, docs, examples, changelog, terminology | Changing code to match the docs |

Domain skills write their code to the rules of `senior-powershell-developer`; they do not restate them. Security is
part of each owner's rules (credentials and input handling in the developer skill, package authenticity in the update
specialist, workflow secrets in the release engineer), so there is no separate security role.

For a change that needs more than one skill, go through these steps once, in this order:

1. **Analyze** the request and the existing implementation (owner of the files touched).
2. **Implement** the smallest suitable change (owner).
3. **Review** it against these standards, the project rules and the owner's domain rules. When a domain skill
   implemented it, `senior-powershell-developer` reviews the PowerShell; when the developer implemented it in a domain
   area, the domain owner reviews correctness. Fix what the review finds now, before the tests are written.
4. **Test**: write or update tests for the changed behavior and run them (tester).
5. **Fix** verified defects (owner), then re-run only the affected tests (tester).
6. **Document** behavior, examples and changelog for what actually changed (writer).
7. **Final check**: the full project quality gate runs once; report what ran and what didn't (whoever finishes).

Hand over with facts: changed files, behavior before and after, commands run with their results, and open questions.
Don't send work back for another review round unless there's a verified defect.

## Final report

- What changed, by file.
- What ran (command and result) and what did not run, with the reason.
- Open risks and unverified assumptions.
