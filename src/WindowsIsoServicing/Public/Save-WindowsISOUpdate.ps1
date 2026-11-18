function Save-WindowsISOUpdate {

    <#
    .SYNOPSIS
        Downloads and validates the packages of an update plan into the local update cache.

    .DESCRIPTION
        Downloads every package file of the plan, verifies the hash published in the update metadata and the Microsoft
        Authenticode signature, and records the packages in the cache index (updates.json). Valid cached files are not
        downloaded again. The cache can be copied to a disconnected host and used with -RepositoryPath. Requires
        elevation: the cache is restricted to SYSTEM and Administrators and locked against concurrent runs, because its
        packages go into serviced media.

    .PARAMETER Plan
        Update plan returned by Get-WindowsISOUpdates.

    .PARAMETER CachePath
        Update cache folder.

    .EXAMPLE
        Get-WindowsISOUpdates -SourceISO 'D:\ISO\Windows_Server_2022.iso' | Save-WindowsISOUpdate -CachePath 'E:\UpdateCache'

    .OUTPUTS
        WindowsIsoServicing.UpdatePlan

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        Get-WindowsISOUpdates

    .LINK
        Update-WindowsISO
    #>

    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('WindowsIsoServicing.UpdatePlan')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSTypeName('WindowsIsoServicing.UpdatePlan')]
        [pscustomobject]$Plan,
        [ValidateNotNullOrEmpty()]
        [string]$CachePath = (Get-DefaultServicingPath -Kind Cache)
    )

    process {
        if (-not $PSCmdlet.ShouldProcess($CachePath, "Download $(@($Plan.Updates).Count) updates")) { return }
        Assert-Administrator
        $cache = Resolve-DirectoryPath -Path $CachePath -Create
        Protect-ServicingDirectory -Path $cache -Check All -Confirm:$false
        $cacheLock = Lock-Directory -Directory $cache
        try {
            $saved = @(Save-UpdatePackage -Update $Plan.Updates -OperatingSystem $Plan.OperatingSystem -Architecture $Plan.Architecture -CachePath $cache)
        }
        finally {
            Unlock-Directory -Lock $cacheLock
        }
        $result = $Plan.PSObject.Copy()
        $result.Updates = $saved
        $result
    }
}
