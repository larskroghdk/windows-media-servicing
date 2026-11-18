function Get-WindowsISOManifest {

    <#
    .SYNOPSIS
        Reads and validates a servicing manifest.

    .DESCRIPTION
        Reads the JSON manifest written by Update-WindowsISO, either from a manifest file, from the '<iso>.json' file
        next to an ISO, or the latest published manifest for a media key in an artifact store. The manifest structure
        is validated; an invalid manifest causes a terminating error.

    .PARAMETER Path
        Path to a manifest (.json) or to an ISO with a manifest next to it.

    .PARAMETER StorePath
        Artifact store root used by Publish-WindowsISO.

    .PARAMETER MediaKey
        Media key in the artifact store, for example 'WindowsServer2025_x64_en-us'. Omit to list all keys.

    .EXAMPLE
        Get-WindowsISOManifest -Path 'D:\ISO\Updated\Windows_Server_2025_x64_26100_2026-11.iso'

    .EXAMPLE
        Get-WindowsISOManifest -StorePath '\\fs01\iso' -MediaKey 'WindowsServer2025_x64_en-us'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        Test-WindowsISO

    .LINK
        Publish-WindowsISO
    #>

    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', ValueFromPipelineByPropertyName)]
        [Alias('ManifestPath', 'IsoPath', 'FullName')]
        [ValidateNotNullOrEmpty()]
        [string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Store')]
        [ValidateNotNullOrEmpty()]
        [string]$StorePath,
        [Parameter(ParameterSetName = 'Store')]
        [ValidatePattern('^[A-Za-z0-9_.-]+$')]
        [string]$MediaKey
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $file = if ($Path -like '*.iso') { "$Path.json" } else { $Path }
            return Read-ServicingManifest -Path (Resolve-TrustedFilePath -Path $file -AllowedExtension '.json')
        }
        $store = Resolve-DirectoryPath -Path $StorePath
        $keys = if ($MediaKey) { @($MediaKey) } else { @(Get-ChildItem -LiteralPath $store -Directory | Select-Object -ExpandProperty Name) }
        foreach ($key in $keys) {
            $latest = Join-Path $store "$key\latest.json"
            if (Test-Path -LiteralPath $latest -PathType Leaf) {
                Read-ServicingManifest -Path $latest
            }
            elseif ($MediaKey) {
                throw "No published media found for '$MediaKey' in '$store'."
            }
        }
    }
}
