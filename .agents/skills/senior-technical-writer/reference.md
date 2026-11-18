# Documentation reference

## Style

Based on the Microsoft Writing Style Guide. The project's own conventions take precedence.

- Use second person and active voice in the present tense: "Run `make check`", not "The checks can be run".
- Use sentence-style capitalization in headings. Write each heading so it says what the section helps the reader do or
  know.
- Put the condition first in instructions: "To publish without a boot test, omit `-BootTest`."
- Use code formatting for literal values: commands, parameters, paths, file names, registry keys, error IDs and
  configuration keys.
- Use numbered lists only for steps that happen in order, and bullets for everything else. Use a table when items share
  the same attributes.
- Write short sentences with one idea each. Cut words that add nothing: "simply", "just", "easily", "in order to",
  "please note".
- Use exact numbers and units: "at least 20 GB free on the workspace volume", not "sufficient disk space".
- Spell out an abbreviation the first time it appears on a page, unless the audience uses it every day (DISM, WIM, CI).
- Make link text name the target ("see Requirements"), never "click here" or a bare URL.

## Checklists by document type

### README

- What the project does and for whom, in two or three sentences.
- Supported platforms and versions, linked to where test status is recorded.
- Quick start that works from a clean checkout, with prerequisites.
- Command or feature overview, linked to detailed docs.
- How to run the tests.
- Where to report issues or find contributor guidance.

### Reference (commands, configuration, file formats)

- Every parameter or key with its type, default, allowed values and effect, taken from the code.
- Required versus optional, and which options exclude each other.
- Output, exit codes and error IDs that callers can rely on.

### How-to and operations

- Prerequisites first, including permissions and elevation.
- Steps that can be followed in order, each with the expected result when it isn't obvious.
- Verification: how the reader confirms it worked.
- Rollback or recovery when a step changes state.

### Troubleshooting

- Organize by symptom: the message or behavior the reader actually sees, quoted exactly.
- Give the cause and the fix for each symptom. Point to the log or the command that confirms the cause.

### Architecture and design

- Components and their responsibilities, plus the data or control flow between them.
- Decisions with their reasons and the alternatives that were rejected.
- Constraints and invariants a maintainer must not break, linked to where they are enforced.

### Changelog

```markdown
## [Unreleased]

### Fixed

- `Import-Settings` reports `SettingsNotFound` instead of returning an empty object when `-Path` does not exist.
```

Each entry says what changed for the user, names the affected command or file, and gives the new error ID or option
where there is one.

## Verifying statements

| Statement | How to verify |
| --- | --- |
| Parameter exists, its type and default | Read the `param()` block; run `Get-Command <name> -Syntax` |
| Configuration key | Find where the code reads it; check the default and validation |
| Error message or ID | Search the code for the literal |
| "Supported" or "tested" | A test that ran, with its result recorded in the project |
| External behavior (Windows, DISM, a vendor API) | Vendor documentation, linked |
| Link or anchor | Check that the target file and heading exist |
