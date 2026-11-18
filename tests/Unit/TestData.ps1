function New-TestManifest {
    <#
    .SYNOPSIS
        Creates a manifest object that passes the manifest schema, for unit tests.

    .DESCRIPTION
        Returns a Windows Server 2025 x64 manifest with one update and one serviced install index. The parameters change
        the values the publishing tests vary.

    .PARAMETER FileName
        Output ISO file name.

    .PARAMETER Sha256
        Output ISO SHA-256.

    .PARAMETER CreatedAt
        Creation time in ISO 8601 format.

    .PARAMETER Passed
        Value of validation.passed.

    .EXAMPLE
        New-TestManifest -Passed $false

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    param(
        [string]$FileName = 'Windows_Server_2025_x64_26100_2026-11.iso',
        [string]$Sha256 = ('b' * 64),
        [string]$CreatedAt = '2026-11-12T08:00:00+00:00',
        [bool]$Passed = $true
    )
    [pscustomobject]@{
        schemaVersion   = 1
        toolName        = 'windows-iso-servicing'
        toolVersion     = '1.0.0'
        runId           = '20261112-080000-abcdef12'
        createdAt       = $CreatedAt
        source          = [pscustomobject]@{ fileName = 'source.iso'; sha256 = ('a' * 64); sizeBytes = 1 }
        operatingSystem = [pscustomobject]@{ key = 'WindowsServer2025'; name = 'Windows Server 2025'; build = 26100; architecture = 'x64'; language = 'en-US' }
        output          = [pscustomobject]@{ fileName = $FileName; sha256 = $Sha256; servicingMonth = '2026-11'; bootModes = [pscustomobject]@{ bios = $true; uefi = $true } }
        updates         = @([pscustomobject]@{ kb = 'KB5070000'; category = 'CumulativeUpdate' })
        images          = [pscustomobject]@{ install = @([pscustomobject]@{ index = 1; editionId = 'ServerDatacenter'; serviced = $true; versionAfter = '10.0.26100.7171' }) }
        validation      = [pscustomobject]@{ passed = $Passed }
    }
}

function New-BuiltIso {
    <#
    .SYNOPSIS
        Creates a fake serviced ISO with a matching manifest file, for unit tests.

    .DESCRIPTION
        Writes Content to Windows_Server_2025_x64_26100_<Month>.iso in Directory and a manifest with its SHA-256 next to
        it, and returns the manifest path.

    .PARAMETER Directory
        Folder for the files.

    .PARAMETER Month
        Servicing month in yyyy-MM format.

    .PARAMETER Content
        Content of the fake ISO.

    .PARAMETER Passed
        Value of validation.passed in the manifest.

    .EXAMPLE
        New-BuiltIso -Directory (Join-Path $TestDrive 'out') -Month '2026-11' -Content 'november'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    param(
        [string]$Directory,
        [string]$Month,
        [string]$Content,
        [bool]$Passed = $true
    )
    $null = New-Item -Path $Directory -ItemType Directory -Force
    $name = "Windows_Server_2025_x64_26100_$Month.iso"
    $iso = Join-Path $Directory $name
    Set-Content -LiteralPath $iso -Value $Content -NoNewline
    $hash = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash.ToLowerInvariant()
    New-TestManifest -FileName $name -Sha256 $hash -CreatedAt "$Month-12T08:00:00+00:00" -Passed $Passed | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$iso.json"
    "$iso.json"
}

function New-TestUpdate {
    <#
    .SYNOPSIS
        Creates an update object for selection tests.

    .DESCRIPTION
        Returns an update of the category, KB and release month, created on the 10th of that month, without files.

    .PARAMETER Category
        Update category, for example 'CumulativeUpdate'.

    .PARAMETER Kb
        KB number.

    .PARAMETER Month
        Release month in yyyy-MM format.

    .PARAMETER Preview
        Marks the update as a preview.

    .PARAMETER Superseded
        Marks the update as superseded.

    .EXAMPLE
        New-TestUpdate -Category 'CumulativeUpdate' -Kb 'KB5070001' -Month '2026-11' -Preview

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    param(
        [string]$Category,
        [string]$Kb,
        [string]$Month,
        [switch]$Preview,
        [switch]$Superseded
    )
    [pscustomobject]@{
        Category = $Category; Kb = $Kb; ReleaseMonth = $Month; IsPreview = [bool]$Preview; IsSuperseded = [bool]$Superseded
        CreationDate = [datetime]"$Month-10"; Title = "$Category $Kb"; Files = @()
    }
}

function New-TestFile {
    <#
    .SYNOPSIS
        Creates a package file object for selection tests.

    .DESCRIPTION
        Returns a file object with the name and an example.invalid URI, which can never resolve.

    .PARAMETER Name
        File name.

    .EXAMPLE
        New-TestFile -Name 'windows11.0-kb5070001-x64.msu'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    param([string]$Name)
    [pscustomobject]@{ Name = $Name; Uri = "https://example.invalid/$Name"; Path = $null; Sha1 = $null; Sha256 = $null; Size = 1; Role = $null }
}

function New-TestCatalogRow {
    <#
    .SYNOPSIS
        Creates a Catalog search row for discovery tests.

    .DESCRIPTION
        Returns an object shaped like the output of ConvertFrom-CatalogSearchResult, with an update ID built from Id.

    .PARAMETER Id
        Number used for the update ID.

    .PARAMETER Title
        Update title.

    .PARAMETER Classification
        Catalog classification, for example 'Security Updates'.

    .PARAMETER Date
        Last updated date.

    .PARAMETER Products
        Catalog products.

    .EXAMPLE
        New-TestCatalogRow -Id 1 -Title '2026-11 Cumulative Update for Windows Server 2019 for x64-based Systems (KB5131085)' -Classification 'Security Updates' -Date '2026-11-10' -Products 'Windows Server 2019'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    param(
        [int]$Id,
        [string]$Title,
        [string]$Classification,
        [string]$Date,
        [string[]]$Products
    )
    [pscustomobject]@{
        UpdateId = '00000000-0000-0000-0000-{0:d12}' -f $Id; Title = $Title; Products = $Products; Classification = $Classification
        LastUpdated = [datetime]$Date; Size = 1; IsTruncated = $false
    }
}

function Get-TestFixture {
    <#
    .SYNOPSIS
        Returns the content of a captured test fixture.

    .DESCRIPTION
        Reads a file from tests\Unit\Fixtures. The fixtures are real responses of the Microsoft Update Catalog and the
        MSRC Security Updates API, captured on 2026-11-18. When Microsoft changes a page, capture a new response; never
        edit a fixture to make a parser pass.

    .PARAMETER Name
        File name of the fixture.

    .EXAMPLE
        Get-TestFixture -Name 'catalog-search-kb5126646.html'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    param([string]$Name)
    [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "Fixtures\$Name"))
}
