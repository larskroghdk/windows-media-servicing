# 🔎 Update discovery

Updates come from Microsoft's public sources only. The module never reads or changes the servicing host's own Windows
Update, WSUS or Group Policy configuration, and it does not use the Windows Update Agent.

## 📡 Sources

| Source | Status | Used for |
| --- | --- | --- |
| **MSRC Security Updates API** (`https://api.msrc.microsoft.com/cvrf/v3.0`) | Documented, supported public API ([MSRC API](https://msrc.microsoft.com/update-guide/), [API repository](https://github.com/microsoft/MSRC-Microsoft-Security-Updates-API)). No key required. | The security baseline: for each release, the KB and build of the newest monthly security update, from the remediations in the latest CVRF document. |
| **Microsoft Update Catalog** (`https://www.catalog.update.microsoft.com`) | Microsoft's official distribution site for these packages, and the place Microsoft documents for downloading Dynamic Updates ([Update Windows installation media with Dynamic Update](https://learn.microsoft.com/windows/deployment/update/media-dynamic-update)). **It has no documented or supported API.** | Discovery of all categories, supersedence, file URLs and hashes, through three website pages (below). |
| **Local package repository** (`-RepositoryPath`, `updates.json`) | Local, deterministic | Disconnected hosts, or a fixed, reviewed package set. When you pass a repository, no online source is contacted. |

Not used:

| Mechanism | Reason |
| --- | --- |
| WSUS (administration API, `UpdateServices` module) | Requires a WSUS server and its synchronization configuration. Removed. |
| Windows Update Agent API (`Microsoft.Update.Session`), `wsusscn2.cab` | Evaluates applicability against the *running* host, not an offline image, and has no Dynamic Update packages. |
| Any other endpoint | Not documented by Microsoft. The lint gate rejects Catalog page names outside the one file that is allowed to use them. |

### How the Catalog is used

Microsoft publishes no Catalog API, so the module reads the same pages the website uses. This access is confined to
[`Private/MicrosoftUpdateCatalog.ps1`](../src/WindowsIsoServicing/Private/MicrosoftUpdateCatalog.ps1):

| Page | Request | Returns |
| --- | --- | --- |
| `Search.aspx?q=<text>` | GET | Result rows: update ID, title, products, classification, last-updated date, size |
| `ScopedViewInline.aspx?updateid=<id>` | GET | Details: description, products, classification, and the updates that supersede this one |
| `DownloadDialog.aspx` | POST `updateIDs=[…]` | File names, URLs, SHA-1 and (for newer files) SHA-256 |

Safeguards:

- Requests go over HTTPS to `www.catalog.update.microsoft.com` and `api.msrc.microsoft.com` only. Transport errors,
  HTTP 429 and 5xx responses are retried with an increasing delay. Other errors stop the run.
- Package URLs must point to a Microsoft download host (`*.delivery.mp.microsoft.com` or `download.windowsupdate.com`),
  and the file name must match the URL. Some older files are served over plain HTTP. Their download is logged as a
  warning, and their integrity rests on the hash and the signature.
- Every parser checks for the page elements it expects. If one is missing, it throws `CatalogFormatChanged` instead of
  returning an empty result, so a site change can never look like "no updates available".
- The unit tests run the parsers against real responses captured on 2026-11-18 (`tests/Unit/Fixtures`). When the site
  changes, capture new responses and fix the parser. Don't edit a fixture to make a test pass.

## 🎯 Selection

For the release identified from the image, `Get-WindowsISOUpdates` (and `Update-WindowsISO`):

1. Searches the Catalog with one query per category the release needs (from
   [`Data/OperatingSystems.psd1`](../src/WindowsIsoServicing/Data/OperatingSystems.psd1)):

   | Query | When |
   | --- | --- |
   | `Cumulative Update for <product> for <arch>-based Systems` | Cumulative releases |
   | `Security Monthly Quality Rollup for <product> for <arch>-based Systems` | Windows Server 2012 / 2012 R2 |
   | `Servicing Stack Update for <product> for <arch>-based Systems` | Releases with a standalone servicing stack |
   | `Cumulative Update for .NET Framework for <product> for <arch>` | Cumulative releases |
   | `Dynamic Update for <Dynamic Update product> for <arch>-based Systems` | Releases with Safe OS or Setup Dynamic Updates |

   Microsoft publishes the Dynamic Updates for Windows Server 2016 and 2019 under *Windows 10 Version 1607* and
   *Windows 10 Version 1809*. The release data records this as `DynamicUpdateProductText`.
2. Keeps results last updated within `-MaximumAgeDays` (default 400) and classifies each one by title:

   | Category | Title form |
   | --- | --- |
   | `CumulativeUpdate` | `YYYY-MM Cumulative Update [Preview] for <product> for <arch>-based Systems (KB…)`, optionally followed by `(build.revision)`; `YYYY-MM Security Monthly Quality Rollup …` for 2012/2012 R2 |
   | `ServicingStack` | `[YYYY-MM] Servicing Stack Update for <product> for <arch>-based Systems (KB…)` |
   | `DotNetCumulativeUpdate` | `YYYY-MM Cumulative Update for .NET Framework … for <product> for <arch> (KB…)` |
   | `SafeOsDynamicUpdate` | `YYYY-MM Safe OS Dynamic Update for …`, or `YYYY-MM Dynamic Update for …` whose description starts with *ComponentUpdate* |
   | `SetupDynamicUpdate` | `YYYY-MM Setup Dynamic Update for …`, or `YYYY-MM Dynamic Update for …` whose description starts with *SetupUpdate* |

   For the generic `Dynamic Update for …` titles, the module reads the details page, because the description decides.
   A Safe OS Dynamic Update lists both *Windows Safe OS Dynamic Update* and *Windows 10 and later Dynamic Update* as
   products, so the product alone isn't enough. Product text accepts both `Version 24H2` and `, version 24H2`. Other
   architectures and products are ignored.
3. Treats a cumulative update as a preview when its title says *Preview*, or when the Catalog classification is not
   *Security Updates*. Recent optional preview releases no longer carry *Preview* in the title, and the Catalog
   classifies them as *Updates*. It classifies non-security out-of-band releases the same way, so the two can't be
   told apart (see [Limitations](#-limitations)).
4. Keeps the newest update per category by release month, then date. Previews count only with `-IncludePreview`.
   Category-specific rules:
   - On releases with a combined servicing stack, a standalone servicing stack update is taken only from the same
     month as the cumulative update, because Microsoft publishes one only as a prerequisite.
   - All .NET cumulative updates from the newest month are kept, because a release can have one per framework
     version. Those that don't apply to an image are skipped at install time (0x800F081E). A combined .NET rollup ships
     the same MSUs as the per-framework updates; each MSU is installed once.
   - Safe OS and Setup Dynamic Updates are taken only for releases that have them. If none exists for the cumulative
     update's month, the most recent one is used, as Microsoft documents.
5. Checks the selection, and stops rather than skip a required update:
   - **MSRC baseline.** The newest MSRC monthly document (released on or before the run date) names the security
     update for the release, for example `Windows Server 2025` or `Windows 11 Version 24H2 for x64-based Systems`.
     When several remediations exist (for example a hotpatch and the cumulative update), the one with the highest
     fixed build is used. Discovery stops if the Catalog search didn't return that KB, or if the selected cumulative
     update is older than it. If MSRC lists no update for the release (support ended, or the release isn't in MSRC
     data), this is reported as a note.
   - **Supersedence.** For every selected update, the details page lists the updates that supersede it. If one of the
     same category wasn't in the search results, discovery stops. Superseding previews are allowed unless
     `-IncludePreview` is set.
   - **Newer non-security releases.** A non-security cumulative update newer than the selected security update is
     reported as a note, with the advice to pass `-IncludePreview` if you need it (for example an out-of-band fix).
6. Requests the file list of each selected update from `DownloadDialog.aspx` and assigns package roles. For cumulative
   updates on checkpoint releases, the MSU whose name contains the update's KB is the `Target`, and the other `kb…`
   MSUs the Catalog returns with it are `Checkpoint` packages.

The plan lists notes for missing components and for the checks above, for example that no Safe OS Dynamic Update
exists, so WinRE will not be serviced. Lifecycle and ESU are checked before discovery: out-of-support media is refused
(`OutOfSupportMedia`), and ESU-only media requires `-EsuEntitled` (`EsuEntitlementRequired`). ESU updates for Windows 10
22H2 are public in the Catalog; the module does not activate or check ESU licenses on the image.

## ⚠️ Limitations

- **The Catalog has no supported API.** The pages can change without notice. The parsers fail with
  `CatalogFormatChanged` when that happens, and a repository (`-RepositoryPath`) is the fallback until the parser is
  updated.
- **One result page per query.** `Search.aspx` returns at most 25 rows per page, newest first. The module reads the
  first page only, and logs when more exist. The MSRC baseline check and the supersedence check catch a newer update
  that didn't fit, but an old Setup Dynamic Update may not be found for releases whose Dynamic Update query matches
  many titles.
- **Previews and out-of-band releases look the same.** Both are classified *Updates*. Without `-IncludePreview` both
  are left out and reported; with it both are eligible. A security out-of-band release is classified *Security
  Updates* and is selected normally.
- **Older files have no SHA-256.** The Catalog publishes only SHA-1 for many older files. Those are checked against
  SHA-1 and the Microsoft Authenticode signature.
- **MSRC covers security updates only.** Servicing stack, .NET and Dynamic Updates have no MSRC baseline. They rely on
  the Catalog search and supersedence check.
- **Speed.** A full plan takes about 20–60 seconds. The MSRC monthly document is about 30 MB and is cached per
  session.

## 🔏 Download and validation

`Save-WindowsISOUpdate`, which `Update-WindowsISO` also calls:

- Downloads each file from its Catalog URL, with retries, into `<cache>\packages\<KB>\<file>`.
- Accepts only `.msu` and `.cab` file names.
- Checks the SHA-256 from the Catalog when present, otherwise the SHA-1, and requires a valid Authenticode signature
  from Microsoft Corporation. Files that fail are deleted.
- Reuses cached files only after they validate again.
- Records each update in `<cache>\updates.json`, so the cache can be used as a repository.

## 📁 Repository format

`updates.json`, schema version 1. Paths are relative to the repository folder and must stay inside it.

```json
{
  "schemaVersion": 1,
  "updates": [
    {
      "category": "CumulativeUpdate",
      "kb": "KB5048667",
      "title": "2024-12 Cumulative Update for Windows 11 Version 24H2 for x64-based Systems (KB5048667)",
      "releaseKey": "Windows11Version24H2",
      "architecture": "x64",
      "releaseMonth": "2024-12",
      "isPreview": false,
      "osBuild": "26100.2605",
      "files": [
        { "name": "windows11.0-kb5043080-x64_953449672073f8fb99badb4cc6d5d7849b9c83e8.msu", "path": "packages\\KB5048667\\windows11.0-kb5043080-x64_953449672073f8fb99badb4cc6d5d7849b9c83e8.msu", "role": "Checkpoint", "sha256": null },
        { "name": "windows11.0-kb5048667-x64_d4ad0ca69de9a02bc356757581e0e0d6960c9f93.msu", "path": "packages\\KB5048667\\windows11.0-kb5048667-x64_d4ad0ca69de9a02bc356757581e0e0d6960c9f93.msu", "role": "Target", "sha256": null }
      ]
    }
  ]
}
```

`category` must be one of `ServicingStack`, `CumulativeUpdate`, `DotNetCumulativeUpdate`, `SafeOsDynamicUpdate` or
`SetupDynamicUpdate`, and `releaseKey` must be a `Key` from `Data/OperatingSystems.psd1`. When you register Catalog
downloads by hand, add `sha256` values you computed from files whose Microsoft signature you checked. The signature is
always enforced. Supersedence and the MSRC baseline are not evaluated for repository content: the newest
`releaseMonth` per category wins, so keep only current packages in the repository.
