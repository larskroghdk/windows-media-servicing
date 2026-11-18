# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `Find-Oscdimg` falls back to an installed Windows ADK (Deployment Tools) when the bundled `Resources\oscdimg.exe` is
  missing or not signed by Microsoft. `-OscdimgPath` also accepts an ADK folder, and the pipeline configuration accepts
  `oscdimgPath`. The run log records which copy was used.
- `scripts/Install-BuildDependency.ps1` installs the pinned PSResourceGet, Pester and PSScriptAnalyzer versions for CI
  and local builds.

### Changed

- Publishing to the PowerShell Gallery requires a `v<version>` tag with a published GitHub release whose prerelease
  setting matches the manifest, and pushes the validated package unchanged after checking its SHA-256.
