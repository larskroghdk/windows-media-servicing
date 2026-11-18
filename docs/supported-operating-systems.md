# 🪟 Supported operating systems

The release is identified from the image itself (`Get-WindowsImage`): build number, installation type (`Client`,
`Server`, `Server Core`) and EditionId. Lifecycle status is evaluated **per edition** on the day of the run, from
`src/WindowsIsoServicing/Data/OperatingSystems.psd1`. Keep that file in line with the
[Microsoft Lifecycle Policy](https://learn.microsoft.com/lifecycle/) site.

| Release | Build | Servicing model | Checkpoint CUs | Separate SSU | Safe OS / Setup DU |
| --- | --- | --- | --- | --- | --- |
| Windows Server 2012 | 9200 | Monthly rollup, install.wim only | No | Yes | No |
| Windows Server 2012 R2 | 9600 | Monthly rollup, install.wim only | No | Yes | No |
| Windows Server 2016 | 14393 | Cumulative | No | Yes | Yes |
| Windows Server 2019 | 17763 | Cumulative | No | Yes | Yes |
| Windows Server 2022 | 20348 | Combined SSU + LCU | No | Only when published as a prerequisite | Yes |
| Windows Server 2025 | 26100 | Combined SSU + LCU | Yes | Only when published as a prerequisite | Yes |
| Windows 10 Enterprise LTSB 2016 | 14393 | Cumulative | No | Yes | Yes |
| Windows 10 Enterprise LTSC 2019 | 17763 | Cumulative | No | Yes | Yes |
| Windows 10 Enterprise LTSC 2021 / IoT | 19044 | Combined | No | Only when published as a prerequisite | Yes |
| Windows 10 22H2 | 19045 | Combined | No | Only when published as a prerequisite | Yes |
| Windows 11 23H2 | 22631 | Combined | No | Only when published as a prerequisite | Yes |
| Windows 11 24H2 | 26100 | Combined | Yes | Only when published as a prerequisite | Yes |
| Windows 11 25H2 | 26200 | Combined | Yes | Only when published as a prerequisite | Yes |

End-of-support and ESU dates per edition channel are maintained only in the data file.

Builds that are identified but always out of support: Windows 8.1, Windows 10 LTSB 2015, Windows 10 2004/20H2/21H1,
Windows 11 21H2 and Windows Server 2008 R2. Windows Server, version 23H2 (25398) is identified; its support ended
2025-10-24.

## ⏳ Lifecycle behavior

| Status | Behavior |
| --- | --- |
| `Supported` | Serviced. |
| `ExtendedSecurityUpdates` | Refused with `EsuEntitlementRequired` unless `-EsuEntitled` is given. The switch is the operator's statement that every device installed from the media is covered by an ESU entitlement. |
| `OutOfSupport` | Refused with `OutOfSupportMedia`. Microsoft publishes no further updates. |
| `Unknown` | Refused with `UnsupportedMedia`. The build is not in the data file. |

A failure raised before servicing starts has one of the error IDs above, so you can tell unsupported media apart from a
servicing failure (DISM, download or validation).

Multi-edition media can mix lifecycle states. Windows 11 24H2 consumer media is one example: after 2026-10-13, Home and
Pro are out of support while Education and Enterprise are not. In that case:

- Without `-Index`, only the editions that can be serviced are serviced. The others stay in the ISO unchanged and are flagged `serviced: false` in the manifest.
- With `-Index`, every selected edition must be serviceable.

## 📌 Release-specific notes

- **Windows Server 2012 vs 2012 R2** are told apart by build (9200 vs 9600), not by name.
- **Server 2016/2019 and LTSB 2016/LTSC 2019** share builds with Windows 10 1607/1809. Installation type decides Server vs client, and the client lifecycle is per EditionId (`EnterpriseS` is LTSB/LTSC).
- **Windows 11 24H2 and Windows Server 2025** share build 26100 and both use checkpoint cumulative updates.
- **install.esd** media is exported to WIM before servicing, and the output contains `install.wim`.
- **ARM64** media is serviced and built as UEFI-only. The Hyper-V boot test is x64 only.

## 🗃️ Release data

Every release-specific value lives in `src/WindowsIsoServicing/Data/OperatingSystems.psd1`. Lifecycle dates come from
the [Microsoft Lifecycle Policy](https://learn.microsoft.com/lifecycle/) site. They are the only time-sensitive data in
the module, so review the file when Microsoft changes a lifecycle. `RetiredReleases` lists builds that are identified
explicitly so that they are reported as out of support rather than unknown.

| Field | Meaning |
| --- | --- |
| `Family` | `Server` when the image `InstallationType` is `Server` or `Server Core`, otherwise `Client`. |
| `Build` | Major build number from the image version (`10.0.<Build>.<Revision>`). |
| `Lifecycle` | Rules evaluated top to bottom; the first whose `EditionPattern` matches the image `EditionId` wins. `EndOfSupport` is the last day of support for that edition channel, `EsuEnd` the last day of the paid Extended Security Updates program, when one exists. |
| `Servicing.Model` | `MonthlyRollup` for Windows Server 2012 / 2012 R2 (install.wim only), `Cumulative` for Windows 10 / Server 2016 and later. |
| `Servicing.ServicingStackSeparate` | Search for and apply a standalone servicing stack update before the cumulative update. |
| `Servicing.ServicingStackCombined` | The cumulative update carries the servicing stack (February 2021 and later releases). |
| `Servicing.CheckpointUpdates` | Cumulative updates can require checkpoint cumulative updates (24H2 / Server 2025 and later). |
| `Servicing.SafeOsDynamicUpdate` | Microsoft publishes Safe OS Dynamic Updates, used to service WinRE. |
| `Servicing.SetupDynamicUpdate` | Microsoft publishes Setup Dynamic Updates for the media `sources` folder. |
| `UpdateProductText` | Product text in Microsoft update titles, as in `2026-11 Cumulative Update for <UpdateProductText> for x64-based Systems (KB5000000)`. |
| `DynamicUpdateProductText` | Optional. Product text in Dynamic Update titles when it differs: Microsoft publishes the Windows Server 2016 and 2019 Dynamic Updates as Windows 10 version 1607 and 1809 updates (for example KB5131093). |
| `MsrcProductName` | Product name in the MSRC Security Updates API (CVRF `ProductTree`). `{0}` is replaced by `x64-based`, `ARM64-based` or `32-bit`. `$null` when MSRC no longer lists the release. |

## 🧪 Test status

| Release | Unit tests | Live update discovery (2026-11-18) | Integration (real media) | Hyper-V install test |
| --- | --- | --- | --- | --- |
| Windows Server 2025 | ✅ Yes | ✅ Plan built and checked against MSRC | ⏳ Not yet run | ⏳ Not yet run |
| Windows Server 2022 | ✅ Yes | ✅ Plan built and checked against MSRC | ⏳ Not yet run | ⏳ Not yet run |
| Windows Server 2019 | ✅ Yes | ✅ Plan built and checked against MSRC | ⏳ Not yet run | ⏳ Not yet run |
| Windows Server 2016 | ✅ Yes | ✅ Plan built and checked against MSRC | ⏳ Not yet run | ⏳ Not yet run |
| Windows 10 22H2 (ESU) | ✅ Yes | ✅ Plan built and checked against MSRC | ⏳ Not yet run | ⏳ Not yet run |
| Windows 11 24H2 (x64, arm64) | ✅ Yes | ✅ Plan built and checked against MSRC | ⏳ Not yet run | ⏳ Not yet run |
| Other releases above | ✅ Yes | ⬜ Not run | ⏳ Not yet run | ⏳ Not yet run |

Unit tests cover detection, lifecycle, update classification and selection, and the Catalog and MSRC parsers against
real captured responses. Live discovery ran `Get-UpdatePlan` against the real Microsoft Update Catalog and MSRC API on
2026-11-18 without media; it confirms that discovery finds the expected updates, not that they install. Servicing has
not been run against real installation media, because the development host had no installation ISOs. Before relying
on a release, run it through `tests/live/Invoke-LiveIsoServicing.ps1` ([tests/live/README.md](../tests/live/README.md)),
install the result with `tests/live/Test-WindowsIsoInstallation.ps1`, or add it to `tests/Integration/integration.example.json` and run the integration suite. Windows Server 2012
and 2012 R2 cannot be integration-tested because no updates are published for them any more.
