# 🩺 Troubleshooting

Each run logs to `<OutputPath>\logs\<runId>\` (or `-LogPath`):

- `<runId>.log.jsonl`: the structured log. Filter it with `Get-Content … | ConvertFrom-Json | Where-Object level -eq 'Error'`.
- `dism-*.log`: the DISM log for each operation.
- `<iso>.failed.json`: the full manifest of an ISO that failed validation.

Add `-KeepWorkspace` to keep the media, work files and mounts folder for inspection.

| Symptom | Cause and action |
| --- | --- |
| `UnsupportedMedia` | The build is not in `Data/OperatingSystems.psd1`. It is not a supported release; no servicing was attempted. |
| `OutOfSupportMedia` | The selected edition is past end of support (and past ESU, if any). Microsoft publishes no further updates. |
| `EsuEntitlementRequired` | The media only receives ESU updates. Confirm the entitlement and pass `-EsuEntitled`. |
| `… is locked by another windows-iso-servicing process` | Another run is using the workspace, output folder, cache or store key. The lock file shows the PID and host. A lock left by a process that exited is released automatically. |
| `No applicable cumulative update was found` / `NoApplicableUpdates` | The Catalog search returned no cumulative update newer than `-MaximumAgeDays` for the release and architecture, or the repository has none. Check with `Get-WindowsISOUpdates` and read the plan notes. |
| `… provides no MSU file. Checkpoint cumulative updates …` | The file set for a 24H2/25H2/Server 2025 cumulative update contains no MSU. For a repository, add the target and checkpoint MSUs from the Microsoft Update Catalog (see [update-discovery.md](update-discovery.md#-repository-format)). |
| `CatalogFormatChanged` | A Microsoft Update Catalog page no longer has the structure the parser expects. The Catalog has no documented API, so this can happen at any time. Service from a repository (`-RepositoryPath`) until `Private/MicrosoftUpdateCatalog.ps1` and its fixtures are updated. |
| `The MSRC Security Updates API lists KB… but the Microsoft Update Catalog search returned no such … cumulative update` | The security update for the month is not in the first page of Catalog results, or not published there yet. Retry later. Discovery stops instead of servicing an older update. |
| `… supersedes the selected KB…, but the Microsoft Update Catalog search did not return it` | A newer update exists that the search did not find. Discovery stops instead of skipping it. Retry later or use a repository. |
| `Refusing request to …` / `failed after N attempt(s)` | Only HTTPS to the Catalog and the MSRC API is allowed. Check the proxy, firewall and DNS for the hosts in [requirements.md](requirements.md#-update-source). |
| `SHA-256 mismatch` / `does not carry a valid Microsoft Authenticode signature` | The download is corrupt, or not from Microsoft. The file was deleted. Check proxies and TLS inspection that rewrite content. |
| `Add-WindowsPackage` 0x800F081E on a cumulative update | The package does not apply to the image (wrong release or architecture in a repository entry). |
| `Add-WindowsPackage` 0x800F0823 / 0x800F0922 | A prerequisite servicing stack or checkpoint update is missing, or the host's DISM is older than the image. Service from a host on the same build as the media, or newer. |
| `cumulative update revision did not change` | DISM reported success but the image was not updated. Read the matching `dism-Install<N>-*.log`. |
| `Images still mounted` / `Unable to dismount` | A process (antivirus, Explorer, an open shell) holds a file in the mount folder. Close it and run `dism /Cleanup-Mountpoints`. Exclude the workspace from antivirus scanning. |
| `ISO … was mounted but no drive letter was assigned` | Automatic mounting is disabled. Run `mountvol /E` or assign letters manually. |
| `Workspace path … must not contain whitespace` | OSCDIMG cannot represent boot sector paths with spaces. Use a path such as `D:\IsoServicing\Workspace`. |
| `No usable oscdimg.exe was found` (`OscdimgNotFound`) / `does not carry a valid Microsoft Authenticode signature` | `Resources\oscdimg.exe` is missing or altered, and no Microsoft-signed copy was found in a Windows ADK installation. The message lists the folders searched and the files refused. Reinstall the module, install the ADK Deployment Tools, or pass `-OscdimgPath` ([requirements.md](requirements.md#-oscdimg)). |
| Validation `InstallIndexN` failed | The exported image version or edition differs from the servicing result. Compare `images.install` in the failed manifest with `Get-WindowsImage` output. |
| Boot test times out | Setup did not reach the specialize pass. Common causes: retail media that needs `-BootTestProductKey`, or too little host memory. If the VM console shows "Press any key to boot from CD or DVD", the ISO was not built without the prompt; check `UefiBootPrompt` and `BiosBootPrompt` in the validation result. Use `-KeepWorkspace` and connect to the VM manually to reproduce. |
| `no efi\microsoft\boot\efisys_noprompt.bin` | The source media has UEFI boot files but not the no-prompt boot image, so no ISO without "Press any key" can be built. Use current Microsoft media, which includes it. The tool does not fall back to the prompting `efisys.bin`. |
| `contains boot\bootfix.bin` | `New-IsoImage` was given media that wasn't copied with `Copy-MediaContent`. `Update-WindowsISO` always copies it that way. |
| Setup starts again after the first restart | The machine started from the ISO again, because the ISO no longer waits for a key. Put the disk before the DVD in the BIOS boot order, or let Setup's UEFI boot entry stay first. You can also eject the ISO once Setup has started. |
| `UefiBootPrompt` or `BiosBootPrompt` is `Skipped` | The manifest was written before no-prompt boot was the default, so the check records what it found but does not fail. |

The structural validation result and the boot test result are recorded separately in the manifest. When no boot test
ran, `validation.bootTest.performed` is `false`; the tool never reports an installation test that did not run.
