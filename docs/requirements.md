# 📋 Requirements

## 🖥️ Servicing host

| Requirement | Details |
| --- | --- |
| Operating system | Windows 11 or Windows Server 2022/2025. The host's DISM must be the same version as the media being serviced, or newer. Service Windows Server 2025 / Windows 11 24H2+ media from a 26100+ host. |
| PowerShell | PowerShell 7.4 or later. |
| Elevation | Every command except `Get-WindowsISOManifest` and `Publish-WindowsISO` must run elevated. |
| OSCDIMG | Ships with the module (`Resources\oscdimg.exe`, from the Windows ADK Deployment Tools), so the Windows ADK does not need to be installed. An installed ADK is the fallback. See [OSCDIMG](#-oscdimg). |
| DISM PowerShell module | Built into Windows (`Dism`). |
| Storage | A local NTFS volume for the workspace. The path must contain no whitespace (OSCDIMG boot arguments cannot be quoted). Plan on twice the ISO size, plus twice the update size, plus the largest image size, plus 20 GB. `Update-WindowsISO` checks this before it starts. |
| Antivirus | Exclude the workspace from real-time scanning. Scanning mounted images slows DISM a lot and can cause dismount failures. |
| Hyper-V (optional) | Needed for `-BootTest` and `tests/live/Test-WindowsIsoInstallation.ps1`: the Hyper-V role and its PowerShell module, on an x64 host. The installation test also needs PowerShell Direct, so a Windows 10 or Windows Server 2016 or later host. |

## 💿 OSCDIMG

`oscdimg.exe` is the only file the module needs from the Windows ADK. The boot files (`etfsboot.com`,
`efisys_noprompt.bin`) come from the source media, so they always match its boot manager. The copy is chosen in this
order, and the first one with a valid Microsoft Authenticode signature is used:

1. `-OscdimgPath` (or `oscdimgPath` in the pipeline configuration): a file, or a folder that holds `oscdimg.exe` or a
   Windows ADK installation (for example `D:\Windows Kits\10`). When this file is refused, no other copy is tried.
2. The bundled `Resources\oscdimg.exe`.
3. The Windows ADK Deployment Tools: the folder in `KitsRoot10` under
   `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots`, then `%ProgramFiles(x86)%\Windows Kits\10`.
   Within an installation the host architecture comes first (`amd64` on x64, `arm64` on Arm64), then `x86`.

The run log records the path, file version and source of the copy used. The module never downloads or installs the
ADK. If the bundled copy is gone and no ADK is installed, install the
[Windows ADK](https://learn.microsoft.com/windows-hardware/get-started/adk-install) with only the Deployment Tools
feature (`adksetup.exe /quiet /norestart /features OptionId.DeploymentTools`); the Windows PE add-on is not needed.

## 🌐 Update source

By default, updates come from the Microsoft Update Catalog, checked against the MSRC Security Updates API (see
[update-discovery.md](update-discovery.md)). The servicing host's own Windows Update, WSUS or Group Policy settings are
not used and need no change. The host needs outbound HTTPS, through any proxy configured for PowerShell, to:

| Host | Purpose |
| --- | --- |
| `www.catalog.update.microsoft.com` | Search, update details and download file lists |
| `api.msrc.microsoft.com` | Monthly security update data (CVRF) |
| `catalog.sf.dl.delivery.mp.microsoft.com` and other `*.delivery.mp.microsoft.com` hosts | Package downloads |
| `download.windowsupdate.com` | Package downloads for some older files (HTTP or HTTPS) |

TLS inspection is possible, as long as it doesn't change the content: every package is checked against its published
hash and its Microsoft signature.

For disconnected hosts, pass `-RepositoryPath`: a folder containing `updates.json` and the package files. An update
cache filled by an earlier online run can be used as a repository. With a repository, no online source is contacted.

## 🔐 Permissions

- The account running servicing needs read access to the source ISO, write access to the workspace, cache, output and log folders, and write access to the artifact store when it publishes.
- No credentials are stored in configuration. The update sources need no authentication, and file share access uses the identity of the process.
