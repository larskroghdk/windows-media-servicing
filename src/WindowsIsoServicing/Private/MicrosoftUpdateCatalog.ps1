$script:CatalogBaseUri = 'https://www.catalog.update.microsoft.com'
$script:UpdateSourceHosts = @('www.catalog.update.microsoft.com', 'api.msrc.microsoft.com')
$script:CatalogDownloadHostPattern = '(^|\.)(download\.windowsupdate\.com|delivery\.mp\.microsoft\.com)$'
$script:CatalogGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Invoke-UpdateSourceRequest {
    <#
    .SYNOPSIS
        Sends a request to the Microsoft Update Catalog or the MSRC Security Updates API.

    .DESCRIPTION
        Refuses any URI that is not HTTPS to www.catalog.update.microsoft.com or api.msrc.microsoft.com (INVARIANTS.md,
        Update discovery #1). Sends a GET, or a POST when Body is given, and returns the response content. Network
        failures, HTTP 429 and HTTP 5xx are retried with exponential back-off; other HTTP errors fail at once.

    .PARAMETER Uri
        Request URI.

    .PARAMETER Body
        Form fields to post. Without it a GET is sent.

    .PARAMETER Headers
        Request headers, for example @{ Accept = 'application/json' }.

    .PARAMETER MaximumAttempt
        Maximum number of attempts, 1 to 10. Defaults to 4.

    .PARAMETER RetryDelaySeconds
        Delay before the first retry, doubled for each further retry, 0 to 300. Defaults to 10.

    .EXAMPLE
        Invoke-UpdateSourceRequest -Uri 'https://api.msrc.microsoft.com/cvrf/v3.0/updates' -Headers @{ Accept = 'application/json' }

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
        [uri]$Uri,
        [hashtable]$Body,
        [hashtable]$Headers = @{},
        [ValidateRange(1, 10)]
        [int]$MaximumAttempt = 4,
        [ValidateRange(0, 300)]
        [int]$RetryDelaySeconds = 10
    )
    if ($Uri.Scheme -ne 'https' -or $Uri.Host -notin $script:UpdateSourceHosts) {
        throw "Refusing request to '$Uri': update metadata is read only over HTTPS from $($script:UpdateSourceHosts -join ', ')."
    }
    $request = @{
        Uri        = $Uri
        Headers    = $Headers
        UserAgent  = "WindowsIsoServicing/$script:ToolVersion"
        TimeoutSec = 300
    }
    if ($Body) {
        $request.Method = 'Post'
        $request.Body = $Body
    }
    for ($attempt = 1; ; $attempt++) {
        try {
            return (Invoke-WebRequest @request -ErrorAction Stop).Content
        }
        catch {
            $status = $_.Exception.PSObject.Properties['Response']?.Value?.StatusCode
            $transient = $null -eq $status -or [int]$status -eq 429 -or [int]$status -ge 500
            if (-not $transient -or $attempt -ge $MaximumAttempt) {
                throw "Request to $($Uri.Host)$($Uri.AbsolutePath) failed after $attempt attempt(s): $($_.Exception.Message)"
            }
            $delay = $RetryDelaySeconds * [math]::Pow(2, $attempt - 1)
            Write-ServicingLog -Operation 'Discover' -Level Warning -Target $Uri.Host -Message "Attempt $attempt failed ($($_.Exception.Message)); retrying in $delay s"
            Start-Sleep -Seconds $delay
        }
    }
}

function New-CatalogFormatError {
    <#
    .SYNOPSIS
        Creates the error record for a Microsoft Update Catalog page in an unexpected format.

    .DESCRIPTION
        Returns an ErrorRecord with error ID CatalogFormatChanged and category InvalidData. The Catalog has no documented
        API, so its parsers throw this error instead of returning an empty result when a page has changed (INVARIANTS.md,
        Update discovery #1). The message names the remedy: update the parser and its fixtures, or service from a
        repository with -RepositoryPath.

    .PARAMETER Page
        Name of the page, for example 'search', 'details' or 'download'.

    .PARAMETER Detail
        What was missing or unexpected.

    .EXAMPLE
        throw (New-CatalogFormatError -Page 'search' -Detail 'the result table contains no update rows')

    .OUTPUTS
        System.Management.Automation.ErrorRecord

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory error record only.')]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param(
        [Parameter(Mandatory)]
        [string]$Page,
        [Parameter(Mandatory)]
        [string]$Detail
    )
    $exception = [System.FormatException]::new("The Microsoft Update Catalog $Page page has an unrecognized format ($Detail). The Catalog has no documented API and its pages may have changed; update Private\MicrosoftUpdateCatalog.ps1 and its test fixtures, or service from a repository with -RepositoryPath.")
    [System.Management.Automation.ErrorRecord]::new($exception, 'CatalogFormatChanged', 'InvalidData', $Page)
}

function ConvertFrom-CatalogHtmlText {
    <#
    .SYNOPSIS
        Converts an HTML fragment from a Catalog page to plain text.

    .DESCRIPTION
        Replaces tags with spaces, decodes HTML entities, collapses whitespace and trims the result.

    .PARAMETER Html
        HTML fragment.

    .EXAMPLE
        ConvertFrom-CatalogHtmlText -Html '<a href="#">2026-11 Cumulative Update&nbsp;for Microsoft server operating system version 24H2</a>'

    .OUTPUTS
        System.String

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string]$Html
    )
    ([System.Net.WebUtility]::HtmlDecode(($Html -replace '<[^>]+>', ' ')) -replace '\s+', ' ').Trim()
}

function ConvertFrom-CatalogSearchResult {
    <#
    .SYNOPSIS
        Parses the result rows of a Microsoft Update Catalog search page.

    .DESCRIPTION
        Returns one object per result row with update ID, title, products, classification, last updated date and size.
        A page with the no-results message returns nothing. A page without the result table, with no rows, or with a row
        lacking a title, an M/d/yyyy date or a size throws CatalogFormatChanged. IsTruncated is $true when the page says it
        is page 1 of more than one, because only the first page is read.

    .PARAMETER Html
        Content of Search.aspx.

    .EXAMPLE
        ConvertFrom-CatalogSearchResult -Html (Get-Content -LiteralPath '.\tests\Unit\Fixtures\catalog-search-kb5126646.html' -Raw)

    .OUTPUTS
        System.Management.Automation.PSCustomObject with UpdateId, Title, Products, Classification, LastUpdated, Size and
        IsTruncated.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Html
    )
    if ($Html -match 'id="ctl00_catalogBody_noResultText"') { return }
    if ($Html -notmatch 'id="ctl00_catalogBody_updateMatches"') {
        throw (New-CatalogFormatError -Page 'search' -Detail 'neither a result table nor a no-results message was found')
    }
    $truncated = $Html -match 'id="ctl00_catalogBody_searchDuration">[^<]*\(page 1 of (?!1\))\d+\)'
    $rows = [regex]::Matches($Html, "(?s)<tr id=`"(?<id>$script:CatalogGuidPattern)_R\d+`">(?<row>.*?)</tr>")
    if ($rows.Count -eq 0) {
        throw (New-CatalogFormatError -Page 'search' -Detail 'the result table contains no update rows')
    }
    foreach ($row in $rows) {
        $id = $row.Groups['id'].Value
        $cells = @{}
        foreach ($cell in [regex]::Matches($row.Groups['row'].Value, "(?s)id=`"$id`_C(?<n>\d)_R\d+`"[^>]*>(?<value>.*?)</td>")) {
            $cells[[int]$cell.Groups['n'].Value] = $cell.Groups['value'].Value
        }
        $title = ConvertFrom-CatalogHtmlText -Html $cells[1]
        $date = [datetime]::MinValue
        $dateText = ConvertFrom-CatalogHtmlText -Html $cells[4]
        $size = [regex]::Match($row.Groups['row'].Value, "id=`"$id`_originalSize`">(\d+)<")
        if (-not $title -or -not $size.Success -or -not [datetime]::TryParseExact($dateText, 'M/d/yyyy', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$date)) {
            throw (New-CatalogFormatError -Page 'search' -Detail "row $id lacks a title, a M/d/yyyy date or a size")
        }
        [pscustomobject]@{
            UpdateId       = $id.ToLowerInvariant()
            Title          = $title
            Products       = @((ConvertFrom-CatalogHtmlText -Html $cells[2]) -split '\s*,\s*' | Where-Object { $_ })
            Classification = ConvertFrom-CatalogHtmlText -Html $cells[3]
            LastUpdated    = $date
            Size           = [long]$size.Groups[1].Value
            IsTruncated    = $truncated
        }
    }
}

function Search-CatalogUpdate {
    <#
    .SYNOPSIS
        Searches the Microsoft Update Catalog.

    .DESCRIPTION
        Requests Search.aspx with the query and returns the parsed rows of the first result page. The Catalog has no
        documented API; this is the page its web interface uses.

    .PARAMETER Query
        Search text, for example a KB number or a title prefix.

    .EXAMPLE
        Search-CatalogUpdate -Query '2026-11 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems'

    .OUTPUTS
        System.Management.Automation.PSCustomObject

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0

    .LINK
        https://www.catalog.update.microsoft.com
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Query
    )
    $html = Invoke-UpdateSourceRequest -Uri "$script:CatalogBaseUri/Search.aspx?q=$([uri]::EscapeDataString($Query))"
    $rows = @(ConvertFrom-CatalogSearchResult -Html $html)
    $truncatedText = if ($rows.Count -and $rows[0].IsTruncated) { ' (first page only)' } else { '' }
    Write-ServicingLog -Operation 'Discover' -Target 'Microsoft Update Catalog' -Message "Search '$Query' returned $($rows.Count) rows$truncatedText"
    foreach ($row in $rows) { $row }
}

function ConvertFrom-CatalogUpdateDetail {
    <#
    .SYNOPSIS
        Parses the details page of a Microsoft Update Catalog update.

    .DESCRIPTION
        Returns title, description, products, classification and the updates that supersede it. Every one of these
        sections must be present, or CatalogFormatChanged is thrown; an empty superseded-by list means the update is not
        superseded.

    .PARAMETER Html
        Content of ScopedViewInline.aspx.

    .EXAMPLE
        ConvertFrom-CatalogUpdateDetail -Html (Get-Content -LiteralPath '.\tests\Unit\Fixtures\catalog-detail-kb5126646.html' -Raw)

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Title, Description, Products, Classification and SupersededBy.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Html
    )
    $title = [regex]::Match($Html, '(?s)<span id="ScopedViewHandler_titleText">(.*?)</span>')
    $description = [regex]::Match($Html, '(?s)<span id="ScopedViewHandler_desc">(.*?)</span>')
    $products = [regex]::Match($Html, '(?s)<div id="productsDiv">\s*<span[^>]*>[^<]*</span>(.*?)</div>')
    $classification = [regex]::Match($Html, '(?s)<div id="classificationDiv">\s*<span[^>]*>[^<]*</span>(.*?)</div>')
    $supersededBy = [regex]::Match($Html, '(?s)<div id="supersededbyInfo">(.*?)<span id="ScopedViewHandler_labelSupersededUpdates_Separator"')
    foreach ($part in @(@{ Name = 'title'; Match = $title }, @{ Name = 'description'; Match = $description }, @{ Name = 'products'; Match = $products }, @{ Name = 'classification'; Match = $classification }, @{ Name = 'superseded-by list'; Match = $supersededBy })) {
        if (-not $part.Match.Success) { throw (New-CatalogFormatError -Page 'details' -Detail "missing $($part.Name)") }
    }
    [pscustomobject]@{
        Title          = ConvertFrom-CatalogHtmlText -Html $title.Groups[1].Value
        Description    = ConvertFrom-CatalogHtmlText -Html $description.Groups[1].Value
        Products       = @((ConvertFrom-CatalogHtmlText -Html $products.Groups[1].Value) -split '\s*,\s*' | Where-Object { $_ })
        Classification = ConvertFrom-CatalogHtmlText -Html $classification.Groups[1].Value
        SupersededBy   = @(foreach ($link in [regex]::Matches($supersededBy.Groups[1].Value, "(?s)updateid=(?<id>$script:CatalogGuidPattern)'>(?<title>.*?)</a>")) {
                [pscustomobject]@{ UpdateId = $link.Groups['id'].Value.ToLowerInvariant(); Title = ConvertFrom-CatalogHtmlText -Html $link.Groups['title'].Value }
            })
    }
}

function Get-CatalogUpdateDetail {
    <#
    .SYNOPSIS
        Reads the details of a Microsoft Update Catalog update.

    .DESCRIPTION
        Requests ScopedViewInline.aspx for the update ID and returns the parsed details.

    .PARAMETER UpdateId
        Catalog update ID (a GUID).

    .EXAMPLE
        Get-CatalogUpdateDetail -UpdateId '1abba66b-03c6-467e-9819-96844606cb15'

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
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$UpdateId
    )
    ConvertFrom-CatalogUpdateDetail -Html (Invoke-UpdateSourceRequest -Uri "$script:CatalogBaseUri/ScopedViewInline.aspx?updateid=$UpdateId")
}

function ConvertTo-HexHash {
    <#
    .SYNOPSIS
        Converts a Base64 hash from the Catalog download dialog to hexadecimal.

    .DESCRIPTION
        Decodes the Base64 value and throws unless it has the expected length: 20 bytes for SHA-1, 32 for SHA-256.

    .PARAMETER Base64
        Base64-encoded hash.

    .PARAMETER Length
        Expected length in bytes: 20 or 32.

    .EXAMPLE
        ConvertTo-HexHash -Base64 'qUqP5cyxm6YcTAhz05Hph5gvu9M=' -Length 20

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
        [string]$Base64,
        [Parameter(Mandatory)]
        [ValidateSet(20, 32)]
        [int]$Length
    )
    $bytes = [System.Convert]::FromBase64String($Base64)
    if ($bytes.Length -ne $Length) { throw "Hash '$Base64' is $($bytes.Length) bytes; expected $Length." }
    [System.Convert]::ToHexString($bytes)
}

function ConvertFrom-CatalogDownloadDialog {
    <#
    .SYNOPSIS
        Parses the file list of a Microsoft Update Catalog download dialog.

    .DESCRIPTION
        Returns one file object per downloadInformation entry with name, URI, SHA-1 and, when published, SHA-256. Throws
        CatalogFormatChanged when there are no entries, when the response describes another update, or when an entry
        lacks url, fileName or digest. A URI that is not on download.windowsupdate.com or delivery.mp.microsoft.com, or
        whose last segment is not the declared file name, is refused.

    .PARAMETER Html
        Content of DownloadDialog.aspx.

    .PARAMETER UpdateId
        Catalog update ID that was requested.

    .EXAMPLE
        ConvertFrom-CatalogDownloadDialog -Html (Get-Content -LiteralPath '.\tests\Unit\Fixtures\catalog-download-kb5126646.html' -Raw) -UpdateId '1abba66b-03c6-467e-9819-96844606cb15'

    .OUTPUTS
        System.Management.Automation.PSCustomObject with Name, Uri, Path, Sha1, Sha256, Size and Role.

    .NOTES
        Author:  Lars Krogh Paulsen
        Version: 1.0.0
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Html,
        [Parameter(Mandatory)]
        [string]$UpdateId
    )
    $properties = [regex]::Matches($Html, "downloadInformation\[0\]\.files\[(?<n>\d+)\]\.(?<name>url|fileName|digest|sha256)\s*=\s*'(?<value>[^']*)';")
    if ($properties.Count -eq 0) {
        throw (New-CatalogFormatError -Page 'download' -Detail "no file entries for update $UpdateId")
    }
    $declaredId = [regex]::Match($Html, "downloadInformation\[0\]\.updateID\s*=\s*'([^']*)'").Groups[1].Value
    if ($declaredId -ne $UpdateId) {
        throw (New-CatalogFormatError -Page 'download' -Detail "the response describes update '$declaredId' instead of $UpdateId")
    }
    $files = [ordered]@{}
    foreach ($property in $properties) {
        $index = $property.Groups['n'].Value
        if (-not $files.Contains($index)) { $files[$index] = @{} }
        $files[$index][$property.Groups['name'].Value] = $property.Groups['value'].Value
    }
    foreach ($file in $files.Values) {
        if (-not $file['url'] -or -not $file['fileName'] -or -not $file['digest']) {
            throw (New-CatalogFormatError -Page 'download' -Detail "a file entry of update $UpdateId lacks url, fileName or digest")
        }
        $uri = [uri]$file['url']
        if ($uri.Scheme -notin 'https', 'http' -or $uri.Host -notmatch $script:CatalogDownloadHostPattern) {
            throw "Refusing download location '$uri' for update ${UpdateId}: not a Microsoft download host."
        }
        if ($uri.Segments[-1] -ne $file['fileName']) {
            throw "Download location '$uri' does not end in the declared file name '$($file['fileName'])'."
        }
        [pscustomobject]@{
            Name   = $file['fileName']
            Uri    = $uri.AbsoluteUri
            Path   = $null
            Sha1   = ConvertTo-HexHash -Base64 $file['digest'] -Length 20
            Sha256 = if ($file['sha256']) { ConvertTo-HexHash -Base64 $file['sha256'] -Length 32 }
            Size   = 0
            Role   = $null
        }
    }
}

function Get-CatalogUpdateFile {
    <#
    .SYNOPSIS
        Lists the download files of a Microsoft Update Catalog update.

    .DESCRIPTION
        Posts the update ID to DownloadDialog.aspx and returns the parsed file list.

    .PARAMETER UpdateId
        Catalog update ID (a GUID).

    .EXAMPLE
        Get-CatalogUpdateFile -UpdateId '1abba66b-03c6-467e-9819-96844606cb15'

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
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string]$UpdateId
    )
    $updateIds = ConvertTo-Json -Compress -InputObject @([ordered]@{ size = 0; languages = ''; uidInfo = $UpdateId; updateID = $UpdateId })
    $html = Invoke-UpdateSourceRequest -Uri "$script:CatalogBaseUri/DownloadDialog.aspx" -Body @{ updateIDs = $updateIds }
    ConvertFrom-CatalogDownloadDialog -Html $html -UpdateId $UpdateId
}
