$script:UpdateCategories = @('ServicingStack', 'CumulativeUpdate', 'DotNetCumulativeUpdate', 'SafeOsDynamicUpdate', 'SetupDynamicUpdate')

function Get-ProductTitlePattern {
    <#
    .SYNOPSIS
        Converts the product text of a release into a regular expression for update titles.

    .DESCRIPTION
        Escapes the product text. When it contains 'version', the pattern also accepts the comma Microsoft uses in some
        titles before 'version', for example 'Microsoft server operating system, version 23H2'.

    .PARAMETER ProductText
        UpdateProductText or DynamicUpdateProductText of the release in OperatingSystems.psd1.

    .EXAMPLE
        Get-ProductTitlePattern -ProductText 'Microsoft server operating system version 24H2'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ProductText
    )
    $parts = [regex]::Split($ProductText, ',?\s+version\s+', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($parts.Count -eq 2) {
        return [regex]::Escape($parts[0]) + ',?\s+version\s+' + [regex]::Escape($parts[1])
    }
    [regex]::Escape($ProductText)
}

function Get-CatalogSearchQuery {
    <#
    .SYNOPSIS
        Returns the Microsoft Update Catalog searches for a release and architecture.

    .DESCRIPTION
        Returns one search per update type the release's servicing model uses: the cumulative update or, for
        rollup-serviced releases, the Security Monthly Quality Rollup; the standalone servicing stack update; the .NET
        Framework cumulative update; and the Dynamic Update.

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .EXAMPLE
        Get-CatalogSearchQuery -OperatingSystem $release -Architecture 'x64'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$OperatingSystem,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture
    )
    $product = $OperatingSystem.UpdateProductText
    $systems = "for $Architecture-based Systems"
    $servicing = $OperatingSystem.Servicing
    if ($servicing.Model -eq 'MonthlyRollup') { "Security Monthly Quality Rollup for $product $systems" }
    else { "Cumulative Update for $product $systems" }
    if ($servicing.ServicingStackSeparate) { "Servicing Stack Update for $product $systems" }
    if ($servicing.Model -eq 'Cumulative') { "Cumulative Update for .NET Framework for $product for $Architecture" }
    if ($servicing.SafeOsDynamicUpdate -or $servicing.SetupDynamicUpdate) { "Dynamic Update for $($OperatingSystem.DynamicUpdateProductText) $systems" }
}

function Get-CatalogUpdateClassification {
    <#
    .SYNOPSIS
        Classifies a Catalog update title for a release.

    .DESCRIPTION
        Classifies the title with the release's UpdateProductText. When that gives no match and the release has a
        different DynamicUpdateProductText, the title is classified with that text too, and only Safe OS and Setup
        Dynamic Updates are accepted from it. Windows Server 2019, for example, receives its Dynamic Updates under the
        Windows 10 Version 1809 product.

    .PARAMETER Title
        Update title from the Catalog.

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .PARAMETER ProductTitles
        Products of the update from the Catalog, used to tell Safe OS and Setup Dynamic Updates apart.

    .PARAMETER Description
        Description of the update from its details page, used for the same purpose.

    .EXAMPLE
        Get-CatalogUpdateClassification -Title '2026-10 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5126646) (26100.33650)' -OperatingSystem $release -Architecture 'x64'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Category, Kb, ReleaseMonth, IsPreview and OsBuild.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [pscustomobject]$OperatingSystem,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture,
        [string[]]$ProductTitles = @(),
        [string]$Description = ''
    )
    $parameters = @{ Title = $Title; Architecture = $Architecture; ProductTitles = $ProductTitles; Description = $Description }
    $classification = Get-UpdateClassification @parameters -ProductText $OperatingSystem.UpdateProductText
    if ($classification -or $OperatingSystem.DynamicUpdateProductText -eq $OperatingSystem.UpdateProductText) { return $classification }
    $classification = Get-UpdateClassification @parameters -ProductText $OperatingSystem.DynamicUpdateProductText
    if ($classification -and $classification.Category -in 'SafeOsDynamicUpdate', 'SetupDynamicUpdate') { $classification }
}

function Get-UpdateClassification {
    <#
    .SYNOPSIS
        Classifies an update title by matching it against the known title formats.

    .DESCRIPTION
        Matches the title against the formats of cumulative updates, Security Monthly Quality Rollups, servicing stack
        updates, .NET Framework cumulative updates and Dynamic Updates for the product and architecture, and returns the
        category, KB number, release month, preview flag and OS build. A title that only says 'Dynamic Update' is
        classified from its description (ComponentUpdate or SetupUpdate) or its products (Windows Safe OS Dynamic Update
        or Windows 10 and later Dynamic Update); without either, and for unknown titles, nothing is returned.
        The preview flag is set only when the title says 'Preview'. Recent previews do not, so Find-CatalogUpdate also
        treats a cumulative update not classified Security Updates as a preview (docs/update-discovery.md).

    .PARAMETER Title
        Update title.

    .PARAMETER ProductText
        Product text from OperatingSystems.psd1.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .PARAMETER ProductTitles
        Products of the update from the Catalog.

    .PARAMETER Description
        Description of the update from its Catalog details page.

    .EXAMPLE
        Get-UpdateClassification -Title '2026-11 Dynamic Update for Windows 10 Version 1809 for x64-based Systems (KB5131094)' -ProductText 'Windows 10 Version 1809' -Architecture 'x64' -Description 'ComponentUpdate:'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Category, Kb, ReleaseMonth, IsPreview and OsBuild.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [string]$ProductText,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture,
        [string[]]$ProductTitles = @(),
        [string]$Description = ''
    )
    $product = Get-ProductTitlePattern -ProductText $ProductText
    $arch = [regex]::Escape($Architecture)
    $kbSuffix = '\((?<kb>KB\d+)\)(\s+\((?<build>\d+\.\d+)\))?\s*$'
    $systems = "for\s+$arch-based\s+Systems\s+$kbSuffix"
    $rules = @(
        @{ Category = 'CumulativeUpdate'; Pattern = "^(?<month>\d{4}-\d{2})\s+Cumulative\s+Update(?<preview>\s+Preview)?\s+for\s+$product\s+$systems" }
        @{ Category = 'CumulativeUpdate'; Pattern = "^(?<month>\d{4}-\d{2})\s+Security\s+Monthly\s+Quality\s+Rollup\s+for\s+$product\s+$systems" }
        @{ Category = 'ServicingStack'; Pattern = "^((?<month>\d{4}-\d{2})\s+)?Servicing\s+Stack\s+Update\s+for\s+$product\s+$systems" }
        @{ Category = 'DotNetCumulativeUpdate'; Pattern = "^(?<month>\d{4}-\d{2})\s+Cumulative\s+Update(?<preview>\s+Preview)?\s+for\s+\.NET\s+Framework\s+.+?\s+for\s+$product\s+for\s+$arch\b.*?$kbSuffix" }
        @{ Category = 'SafeOsDynamicUpdate'; Pattern = "^(?<month>\d{4}-\d{2})\s+Safe\s+OS\s+Dynamic\s+Update\s+for\s+$product\s+$systems" }
        @{ Category = 'SetupDynamicUpdate'; Pattern = "^(?<month>\d{4}-\d{2})\s+Setup\s+Dynamic\s+Update\s+for\s+$product\s+$systems" }
        @{ Category = 'DynamicUpdate'; Pattern = "^(?<month>\d{4}-\d{2})\s+Dynamic\s+Update\s+for\s+$product\s+$systems" }
    )
    foreach ($rule in $rules) {
        $match = [regex]::Match($Title, $rule.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) { continue }
        $category = $rule.Category
        if ($category -eq 'DynamicUpdate') {
            $category = if ($Description -match '\bComponentUpdate\b') {
                'SafeOsDynamicUpdate'
            }
            elseif ($Description -match '\bSetupUpdate\b') {
                'SetupDynamicUpdate'
            }
            elseif ($ProductTitles -contains 'Windows Safe OS Dynamic Update') {
                'SafeOsDynamicUpdate'
            }
            elseif ($ProductTitles -contains 'Windows 10 and later Dynamic Update') {
                'SetupDynamicUpdate'
            }
            else {
                return $null
            }
        }
        return [pscustomobject]@{
            Category     = $category
            Kb           = $match.Groups['kb'].Value.ToUpperInvariant()
            ReleaseMonth = if ($match.Groups['month'].Success) { $match.Groups['month'].Value }
            IsPreview    = $match.Groups['preview'].Success
            OsBuild      = if ($match.Groups['build'].Success) { $match.Groups['build'].Value }
        }
    }
    $null
}

function New-UpdateRecord {
    <#
    .SYNOPSIS
        Creates the update object used in update plans.

    .DESCRIPTION
        Combines a classification with the title, source, files and Catalog metadata into a WindowsIsoServicing.Update
        object.

    .PARAMETER Classification
        Classification returned by Get-CatalogUpdateClassification or built from a repository entry.

    .PARAMETER Title
        Update title.

    .PARAMETER Source
        MicrosoftUpdateCatalog or Repository.

    .PARAMETER Files
        Package files of the update. Catalog updates get their files after selection.

    .PARAMETER CreationDate
        Last updated date from the Catalog.

    .PARAMETER UpdateId
        Catalog update ID.

    .PARAMETER CatalogClassification
        Catalog classification, for example 'Security Updates'.

    .PARAMETER IsSuperseded
        Marks the update as superseded.

    .EXAMPLE
        New-UpdateRecord -Classification $classification -Title $row.Title -Source 'MicrosoftUpdateCatalog' -Files @() -CreationDate $row.LastUpdated -UpdateId $row.UpdateId -CatalogClassification $row.Classification

    .OUTPUTS
        WindowsIsoServicing.Update

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Classification,
        [Parameter(Mandatory)]
        [string]$Title,
        [Parameter(Mandatory)]
        [ValidateSet('MicrosoftUpdateCatalog', 'Repository')]
        [string]$Source,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Files,
        [Nullable[datetime]]$CreationDate,
        [string]$UpdateId,
        [string]$CatalogClassification,
        [bool]$IsSuperseded = $false
    )
    [pscustomobject]@{
        PSTypeName            = 'WindowsIsoServicing.Update'
        Category              = $Classification.Category
        Kb                    = $Classification.Kb
        Title                 = $Title
        ReleaseMonth          = $Classification.ReleaseMonth
        IsPreview             = $Classification.IsPreview
        OsBuild               = $Classification.OsBuild
        CreationDate          = $CreationDate
        UpdateId              = $UpdateId
        CatalogClassification = $CatalogClassification
        IsSuperseded          = $IsSuperseded
        Source                = $Source
        Files                 = @($Files)
    }
}

function Select-UpdatePackageFile {
    <#
    .SYNOPSIS
        Selects the files to install from an update and assigns their roles.

    .DESCRIPTION
        Dynamic Updates install their CAB files, without express files. A cumulative update on a release with checkpoint
        updates needs exactly one target MSU, whose name contains the update's KB, and every other MSU must be a
        checkpoint MSU; no other file is accepted (INVARIANTS.md, Update discovery #4). A .NET Framework rollup that
        publishes one MSU per framework version keeps them all. Any other update must have exactly one installable MSU
        or CAB, preferring the file named after its KB.

    .PARAMETER Update
        Update with its Catalog or repository files.

    .PARAMETER CheckpointUpdates
        The release uses checkpoint cumulative updates.

    .EXAMPLE
        Select-UpdatePackageFile -Update $cumulative -CheckpointUpdates

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Update,
        [switch]$CheckpointUpdates
    )
    $kbPattern = '(?i)[-_]' + [regex]::Escape($Update.Kb) + '[-_.]'
    $msu = @($Update.Files | Where-Object { $_.Name -like '*.msu' })
    $cab = @($Update.Files | Where-Object { $_.Name -like '*.cab' -and $_.Name -notmatch '(?i)express' })
    if ($Update.Category -in 'SafeOsDynamicUpdate', 'SetupDynamicUpdate') {
        if ($cab.Count -eq 0) { throw "$($Update.Kb) ($($Update.Title)) contains no CAB package." }
        foreach ($file in $cab) { Copy-PackageFileWithRole -File $file -Role 'Package' }
        return
    }
    if ($Update.Category -eq 'CumulativeUpdate' -and $CheckpointUpdates) {
        if ($msu.Count -eq 0) {
            throw "$($Update.Kb) provides no MSU file. Checkpoint cumulative updates must be serviced from the MSU files Microsoft publishes in the Microsoft Update Catalog."
        }
        $targets = @($msu | Where-Object { $_.Name -match $kbPattern })
        if ($targets.Count -ne 1) {
            throw "Expected exactly one target MSU for $($Update.Kb), found $($targets.Count): $($msu.Name -join ', ')."
        }
        foreach ($file in $msu) {
            $role = if ($file.Name -match $kbPattern) { 'Target' }
            elseif ($file.Name -match '(?i)[-_]kb\d+[-_.]') { 'Checkpoint' }
            else { throw "Unexpected file '$($file.Name)' in cumulative update $($Update.Kb)." }
            Copy-PackageFileWithRole -File $file -Role $role
        }
        return
    }
    if ($Update.Category -eq 'DotNetCumulativeUpdate' -and $msu.Count -gt 1 -and -not @($msu | Where-Object { $_.Name -match $kbPattern })) {
        foreach ($file in $msu) {
            if ($file.Name -notmatch '(?i)[-_]kb\d+[-_.]') { throw "Unexpected file '$($file.Name)' in .NET Framework update $($Update.Kb)." }
            Copy-PackageFileWithRole -File $file -Role 'Package'
        }
        return
    }
    $candidates = if ($msu.Count -gt 0) { $msu } else { $cab }
    if ($candidates.Count -gt 1) {
        $candidates = @($candidates | Where-Object { $_.Name -match $kbPattern })
    }
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one installable package for $($Update.Kb) ($($Update.Title)), found $($candidates.Count): $($Update.Files.Name -join ', ')."
    }
    Copy-PackageFileWithRole -File $candidates[0] -Role 'Package'
}

function Copy-PackageFileWithRole {
    <#
    .SYNOPSIS
        Returns a copy of a package file object with its role set.

    .DESCRIPTION
        Copies the file object, so the update's original file list is not changed, and sets Role.

    .PARAMETER File
        Package file object.

    .PARAMETER Role
        Package, Target or Checkpoint.

    .EXAMPLE
        Copy-PackageFileWithRole -File $file -Role 'Checkpoint'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$File,
        [Parameter(Mandatory)]
        [ValidateSet('Package', 'Target', 'Checkpoint')]
        [string]$Role
    )
    $copy = $File.PSObject.Copy()
    $copy.Role = $Role
    $copy
}

function Select-NewestUpdate {
    <#
    .SYNOPSIS
        Returns the newest of a set of updates.

    .DESCRIPTION
        Orders the updates by release month, then by Catalog date, then by KB number, and returns the first.

    .PARAMETER Update
        Updates of one category.

    .EXAMPLE
        Select-NewestUpdate -Update @($candidates | Where-Object Category -eq 'SafeOsDynamicUpdate')

    .OUTPUTS
        WindowsIsoServicing.Update

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Update
    )
    $Update | Sort-Object -Property @{ Expression = { [string]$_.ReleaseMonth } }, @{ Expression = { $_.CreationDate } }, @{ Expression = { $_.Kb } } -Descending | Select-Object -First 1
}

function Select-ApplicableUpdate {
    <#
    .SYNOPSIS
        Selects the updates to apply from the discovered candidates.

    .DESCRIPTION
        Leaves out superseded updates and, without IncludePreview, previews. Selects the newest cumulative update, the
        newest standalone servicing stack update (on releases with a combined servicing stack only one from the same
        month as the cumulative update), every .NET Framework update of the newest month, and the newest Safe OS and
        Setup Dynamic Update when the release uses them.

    .PARAMETER Candidate
        Updates returned by Find-CatalogUpdate or Find-RepositoryUpdate.

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER IncludePreview
        Also considers optional preview updates.

    .EXAMPLE
        Select-ApplicableUpdate -Candidate $candidates -OperatingSystem $release

    .OUTPUTS
        WindowsIsoServicing.Update

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Candidate,
        [Parameter(Mandatory)]
        [pscustomobject]$OperatingSystem,
        [switch]$IncludePreview
    )
    $servicing = $OperatingSystem.Servicing
    $eligible = @($Candidate | Where-Object { -not $_.IsSuperseded -and ($IncludePreview -or -not $_.IsPreview) })
    $cumulative = Select-NewestUpdate -Update @($eligible | Where-Object Category -EQ 'CumulativeUpdate')
    if ($servicing.ServicingStackSeparate) {
        $stacks = @($eligible | Where-Object Category -EQ 'ServicingStack')
        if ($servicing.ServicingStackCombined) {
            $stacks = @($stacks | Where-Object { $cumulative -and $_.ReleaseMonth -eq $cumulative.ReleaseMonth })
        }
        Select-NewestUpdate -Update $stacks
    }
    if ($cumulative) { $cumulative }
    $dotNet = @($eligible | Where-Object Category -EQ 'DotNetCumulativeUpdate')
    if ($dotNet) {
        $newestMonth = ($dotNet | Sort-Object { [string]$_.ReleaseMonth } -Descending | Select-Object -First 1).ReleaseMonth
        $dotNet | Where-Object ReleaseMonth -EQ $newestMonth | Sort-Object Kb
    }
    if ($servicing.SafeOsDynamicUpdate) {
        Select-NewestUpdate -Update @($eligible | Where-Object Category -EQ 'SafeOsDynamicUpdate')
    }
    if ($servicing.SetupDynamicUpdate) {
        Select-NewestUpdate -Update @($eligible | Where-Object Category -EQ 'SetupDynamicUpdate')
    }
}

function Select-DistinctPackageUpdate {
    <#
    .SYNOPSIS
        Removes .NET Framework updates whose files another selected update already contains.

    .DESCRIPTION
        The Catalog lists some .NET Framework rollups both as one update with several MSUs and as separate updates per
        framework version. Starting with the update with the most files, a .NET update whose file names are all covered
        by an earlier one is dropped, so no package is added twice. Other categories are returned unchanged.

    .PARAMETER Update
        Updates with their selected files.

    .EXAMPLE
        Select-DistinctPackageUpdate -Update $updates

    .OUTPUTS
        WindowsIsoServicing.Update

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Update
    )
    $covered = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $redundant = foreach ($dotNet in $Update | Where-Object Category -EQ 'DotNetCumulativeUpdate' | Sort-Object { @($_.Files).Count } -Descending) {
        $names = @($dotNet.Files | ForEach-Object Name)
        if ($names.Count -and -not @($names | Where-Object { -not $covered.Contains($_) })) { $dotNet.Kb; continue }
        foreach ($name in $names) { $null = $covered.Add($name) }
    }
    $Update | Where-Object { $_.Kb -notin @($redundant) }
}

function Find-CatalogUpdate {
    <#
    .SYNOPSIS
        Finds the candidate updates for a release in the Microsoft Update Catalog.

    .DESCRIPTION
        Runs the searches from Get-CatalogSearchQuery, skips rows older than MaximumAgeDays and repeated rows, and
        classifies each title. Titles that only say 'Dynamic Update' are classified again from their details page. A
        cumulative update not classified Security Updates is marked as a preview, because recent previews have no
        'Preview' in the title (docs/update-discovery.md).

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .PARAMETER MaximumAgeDays
        Oldest Catalog date to consider, in days before AsOf, 30 to 3650. Defaults to 400.

    .PARAMETER AsOf
        Reference date. Defaults to now (UTC).

    .EXAMPLE
        Find-CatalogUpdate -OperatingSystem $release -Architecture 'x64'

    .OUTPUTS
        WindowsIsoServicing.Update

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$OperatingSystem,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture,
        [ValidateRange(30, 3650)]
        [int]$MaximumAgeDays = 400,
        [datetime]$AsOf = [datetime]::UtcNow
    )
    $oldest = $AsOf.Date.AddDays(-$MaximumAgeDays)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($query in Get-CatalogSearchQuery -OperatingSystem $OperatingSystem -Architecture $Architecture) {
        foreach ($row in Search-CatalogUpdate -Query $query) {
            if ($row.LastUpdated -lt $oldest -or -not $seen.Add($row.UpdateId)) { continue }
            $classificationParameters = @{ Title = $row.Title; OperatingSystem = $OperatingSystem; Architecture = $Architecture; ProductTitles = $row.Products }
            $classification = Get-CatalogUpdateClassification @classificationParameters
            if (-not $classification) { continue }
            if ($row.Title -match '^\d{4}-\d{2}\s+Dynamic\s+Update\s+for\s') {
                $detail = Get-CatalogUpdateDetail -UpdateId $row.UpdateId
                $classificationParameters.ProductTitles = $detail.Products
                $classification = Get-CatalogUpdateClassification @classificationParameters -Description $detail.Description
                if (-not $classification) { continue }
            }
            if ($classification.Category -eq 'CumulativeUpdate' -and $row.Classification -ne 'Security Updates') {
                $classification.IsPreview = $true
            }
            New-UpdateRecord -Classification $classification -Title $row.Title -Source 'MicrosoftUpdateCatalog' -Files @() -CreationDate $row.LastUpdated -UpdateId $row.UpdateId -CatalogClassification $row.Classification
        }
    }
}

function Assert-CatalogUpdatePlan {
    <#
    .SYNOPSIS
        Checks a Catalog update plan against MSRC and the supersedence data, and returns plan notes.

    .DESCRIPTION
        Implements INVARIANTS.md, Update discovery #2. Throws when the security update MSRC lists for the product is not
        among the Catalog candidates, when no cumulative update was selected, or when the selected one is older than the
        MSRC security update. Throws when a selected update is superseded by an update of the same category that the
        search did not return, or by an eligible candidate. Returns a note when MSRC cannot confirm the baseline and for
        each newer preview or non-security cumulative update left out.

    .PARAMETER Selected
        Updates returned by Select-ApplicableUpdate.

    .PARAMETER Candidate
        Updates returned by Find-CatalogUpdate.

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .PARAMETER IncludePreview
        Previews were included in the selection.

    .PARAMETER AsOf
        Reference date for the MSRC release. Defaults to now (UTC).

    .EXAMPLE
        Assert-CatalogUpdatePlan -Selected $selected -Candidate $candidates -OperatingSystem $release -Architecture 'x64'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://github.com/microsoft/MSRC-Microsoft-Security-Updates-API
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Selected,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Candidate,
        [Parameter(Mandatory)]
        [pscustomobject]$OperatingSystem,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture,
        [switch]$IncludePreview,
        [datetime]$AsOf = [datetime]::UtcNow
    )
    $cumulative = $Selected | Where-Object Category -EQ 'CumulativeUpdate' | Select-Object -First 1
    $productName = Get-MsrcProductName -OperatingSystem $OperatingSystem -Architecture $Architecture
    if (-not $productName) {
        "The MSRC Security Updates API does not list $($OperatingSystem.Name); the cumulative update could not be checked against Microsoft's security release data."
    }
    else {
        $security = Get-MsrcSecurityUpdate -ProductName $productName -AsOf $AsOf
        if (-not $security) {
            "The MSRC Security Updates API lists no security update for '$productName' in its latest monthly release; Microsoft may no longer publish public updates for this release."
        }
        else {
            $baseline = $Candidate | Where-Object { $_.Category -eq 'CumulativeUpdate' -and $_.Kb -eq $security.Kb } | Select-Object -First 1
            if (-not $baseline) {
                throw "The MSRC Security Updates API lists $($security.Kb) (build $($security.FixedBuild), $($security.DocumentId)) as the latest security update for '$productName', but the Microsoft Update Catalog search returned no such $Architecture cumulative update. Discovery stopped so that the security update is not skipped."
            }
            if (-not $cumulative) {
                throw "No cumulative update was selected, but the MSRC Security Updates API lists $($security.Kb) for '$productName'."
            }
            if ($cumulative.CreationDate -lt $baseline.CreationDate) {
                throw "The selected cumulative update $($cumulative.Kb) is older than $($security.Kb), the latest security update the MSRC Security Updates API lists for '$productName'."
            }
            Write-ServicingLog -Operation 'Discover' -Target $productName -Message "Security baseline $($security.Kb) confirmed by MSRC $($security.DocumentId); selected $($cumulative.Kb)"
        }
    }
    if ($cumulative -and -not $IncludePreview) {
        foreach ($newer in $Candidate | Where-Object { $_.Category -eq 'CumulativeUpdate' -and $_.IsPreview -and $_.CreationDate -gt $cumulative.CreationDate } | Sort-Object CreationDate) {
            "$($newer.Kb) ($($newer.CreationDate.ToString('yyyy-MM-dd')), Catalog classification '$($newer.CatalogClassification)') is newer than the selected security update $($cumulative.Kb). It is an optional preview or a non-security out-of-band release, which the Catalog does not distinguish; pass -IncludePreview to include it."
        }
    }
    foreach ($update in $Selected) {
        foreach ($superseding in (Get-CatalogUpdateDetail -UpdateId $update.UpdateId).SupersededBy) {
            $classification = Get-CatalogUpdateClassification -Title $superseding.Title -OperatingSystem $OperatingSystem -Architecture $Architecture
            if (-not $classification -or $classification.Category -ne $update.Category) { continue }
            $known = $Candidate | Where-Object UpdateId -EQ $superseding.UpdateId | Select-Object -First 1
            if (-not $known) {
                throw "$($superseding.Title) supersedes the selected $($update.Kb), but the Microsoft Update Catalog search did not return it. Discovery stopped so that the newer update is not skipped."
            }
            if (-not $known.IsPreview -or $IncludePreview) {
                throw "The selected $($update.Kb) is superseded by $($known.Kb), which is also eligible; the Catalog results are inconsistent."
            }
        }
    }
}

function Find-RepositoryUpdate {
    <#
    .SYNOPSIS
        Reads the candidate updates for a release from a local repository.

    .DESCRIPTION
        Returns the entries of the repository's updates.json for the release key and architecture. Unknown categories
        and file paths outside the repository folder are refused. The repository format is described in
        docs/update-discovery.md.

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .PARAMETER RepositoryPath
        Full path of the repository folder.

    .EXAMPLE
        Find-RepositoryUpdate -OperatingSystem $release -Architecture 'x64' -RepositoryPath 'E:\UpdateCache'

    .OUTPUTS
        WindowsIsoServicing.Update

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$OperatingSystem,
        [Parameter(Mandatory)]
        [string]$Architecture,
        [Parameter(Mandatory)]
        [string]$RepositoryPath
    )
    $index = Read-RepositoryIndex -RepositoryPath $RepositoryPath
    $rootPrefix = [System.IO.Path]::GetFullPath($RepositoryPath).TrimEnd('\') + '\'
    foreach ($entry in $index.updates) {
        if ($entry.releaseKey -ne $OperatingSystem.Key -or $entry.architecture -ne $Architecture) { continue }
        if ($entry.category -notin $script:UpdateCategories) {
            throw "Repository entry $($entry.kb) has unknown category '$($entry.category)'."
        }
        $classification = [pscustomobject]@{
            Category     = $entry.category
            Kb           = ([string]$entry.kb).ToUpperInvariant()
            ReleaseMonth = $entry.releaseMonth
            IsPreview    = [bool]$entry.PSObject.Properties['isPreview']?.Value
            OsBuild      = $entry.PSObject.Properties['osBuild']?.Value
        }
        $files = foreach ($file in $entry.files) {
            $path = [System.IO.Path]::GetFullPath((Join-Path $RepositoryPath $file.path))
            if (-not $path.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Repository entry $($entry.kb) references '$($file.path)' outside the repository."
            }
            [pscustomobject]@{
                Name   = $file.name
                Uri    = $null
                Path   = $path
                Sha1   = $file.PSObject.Properties['sha1']?.Value
                Sha256 = $file.PSObject.Properties['sha256']?.Value
                Size   = [long]$file.PSObject.Properties['size']?.Value
                Role   = $file.PSObject.Properties['role']?.Value
            }
        }
        New-UpdateRecord -Classification $classification -Title $entry.title -Source 'Repository' -Files @($files) -UpdateId $entry.PSObject.Properties['updateId']?.Value
    }
}

function Read-RepositoryIndex {
    <#
    .SYNOPSIS
        Reads the updates.json index of a repository or package cache.

    .DESCRIPTION
        Returns the index, or an empty index with schema version 1 when the file does not exist. Other schema versions
        are refused.

    .PARAMETER RepositoryPath
        Repository or cache folder.

    .EXAMPLE
        Read-RepositoryIndex -RepositoryPath 'E:\UpdateCache'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with schemaVersion and updates.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryPath
    )
    $indexPath = Join-Path $RepositoryPath 'updates.json'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        return [pscustomobject]@{ schemaVersion = 1; updates = @() }
    }
    $index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json -Depth 8
    if ($index.schemaVersion -ne 1) {
        throw "Unsupported repository index schema version '$($index.schemaVersion)' in $indexPath."
    }
    $index.updates = @($index.updates)
    $index
}

function Get-UpdatePlan {
    <#
    .SYNOPSIS
        Builds the update plan for a release and architecture.

    .DESCRIPTION
        Finds the candidates in the repository, when RepositoryPath is given, or in the Microsoft Update Catalog, selects
        the applicable updates and their package files, and removes duplicate .NET packages. Catalog plans are checked
        with Assert-CatalogUpdatePlan and get their download file lists. The notes record updates left out on purpose and
        components that will not be serviced.

    .PARAMETER OperatingSystem
        Release returned by Resolve-WindowsRelease.

    .PARAMETER Architecture
        x86, x64 or arm64.

    .PARAMETER RepositoryPath
        Full path of a local repository to use instead of the Catalog.

    .PARAMETER MaximumAgeDays
        Oldest Catalog date to consider, in days, 30 to 3650. Defaults to 400.

    .PARAMETER IncludePreview
        Includes optional preview updates.

    .PARAMETER AsOf
        Reference date. Defaults to now (UTC).

    .EXAMPLE
        Get-UpdatePlan -OperatingSystem $release -Architecture 'x64'

    .OUTPUTS
        WindowsIsoServicing.UpdatePlan

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$OperatingSystem,
        [Parameter(Mandatory)]
        [ValidateSet('x86', 'x64', 'arm64')]
        [string]$Architecture,
        [string]$RepositoryPath,
        [ValidateRange(30, 3650)]
        [int]$MaximumAgeDays = 400,
        [switch]$IncludePreview,
        [datetime]$AsOf = [datetime]::UtcNow
    )
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($RepositoryPath) {
        $candidates = @(Find-RepositoryUpdate -OperatingSystem $OperatingSystem -Architecture $Architecture -RepositoryPath $RepositoryPath)
        $selected = @(Select-ApplicableUpdate -Candidate $candidates -OperatingSystem $OperatingSystem -IncludePreview:$IncludePreview)
    }
    else {
        $candidates = @(Find-CatalogUpdate -OperatingSystem $OperatingSystem -Architecture $Architecture -MaximumAgeDays $MaximumAgeDays -AsOf $AsOf)
        $selected = @(Select-ApplicableUpdate -Candidate $candidates -OperatingSystem $OperatingSystem -IncludePreview:$IncludePreview)
        foreach ($note in Assert-CatalogUpdatePlan -Selected $selected -Candidate $candidates -OperatingSystem $OperatingSystem -Architecture $Architecture -IncludePreview:$IncludePreview -AsOf $AsOf) {
            $notes.Add($note)
        }
        foreach ($update in $selected) { $update.Files = @(Get-CatalogUpdateFile -UpdateId $update.UpdateId) }
    }
    $updates = foreach ($update in $selected) {
        $files = @(Select-UpdatePackageFile -Update $update -CheckpointUpdates:($OperatingSystem.Servicing.CheckpointUpdates))
        $update.Files = $files
        $update
    }
    $updates = @(Select-DistinctPackageUpdate -Update @($updates))
    $categories = @($updates | ForEach-Object Category)
    if ('CumulativeUpdate' -notin $categories) {
        $notes.Add('No applicable cumulative update was found.')
    }
    if ($OperatingSystem.Servicing.SafeOsDynamicUpdate -and 'SafeOsDynamicUpdate' -notin $categories) {
        $notes.Add('No Safe OS Dynamic Update was found; WinRE will not be serviced.')
    }
    if (-not $OperatingSystem.Servicing.SafeOsDynamicUpdate) {
        $notes.Add("Microsoft publishes no Safe OS Dynamic Update for $($OperatingSystem.Name); WinRE will not be serviced.")
    }
    if ($OperatingSystem.Servicing.SetupDynamicUpdate -and 'SetupDynamicUpdate' -notin $categories) {
        $notes.Add('No Setup Dynamic Update was found; media setup files will not be updated.')
    }
    if ($OperatingSystem.Servicing.Model -eq 'MonthlyRollup') {
        $notes.Add('Rollup-serviced releases are serviced in install.wim only; boot.wim and WinRE are left unchanged, and .NET Framework rollups are not applied.')
    }
    [pscustomobject]@{
        PSTypeName      = 'WindowsIsoServicing.UpdatePlan'
        OperatingSystem = $OperatingSystem
        Architecture    = $Architecture
        Source          = if ($RepositoryPath) { "Repository:$RepositoryPath" } else { 'MicrosoftUpdateCatalog' }
        Updates         = @($updates)
        Notes           = @($notes)
        GeneratedAt     = [DateTimeOffset]::Now
    }
}
