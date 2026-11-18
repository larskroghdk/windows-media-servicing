BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\WindowsIsoServicing\WindowsIsoServicing.psd1') -Force
    . (Join-Path $PSScriptRoot 'TestData.ps1')
}

Describe 'ConvertFrom-CatalogSearchResult' {
    It 'parses update id, title, products, classification, date and size' {
        $html = Get-TestFixture 'catalog-search-kb5126646.html'
        $rows = @(InModuleScope WindowsIsoServicing -Parameters @{ Html = $html } { ConvertFrom-CatalogSearchResult -Html $Html })
        $rows.Count | Should -Be 1
        $rows[0].UpdateId | Should -Be '1abba66b-03c6-467e-9819-96844606cb15'
        $rows[0].Title | Should -Be '2026-10 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5126646) (26100.33650)'
        $rows[0].Products | Should -Be @('Microsoft Server Operating System-24H2')
        $rows[0].Classification | Should -Be 'Security Updates'
        $rows[0].LastUpdated | Should -Be ([datetime]'2026-10-13')
        $rows[0].Size | Should -Be 2675578880
        $rows[0].IsTruncated | Should -BeFalse
    }
    It 'lists every product of a row and flags results with more than one page' {
        $html = Get-TestFixture 'catalog-search-dynamic-update-24h2.html'
        $rows = @(InModuleScope WindowsIsoServicing -Parameters @{ Html = $html } { ConvertFrom-CatalogSearchResult -Html $Html })
        $rows.Count | Should -Be 25
        $rows[0].IsTruncated | Should -BeTrue
        ($rows | Where-Object Title -like '*Safe OS Dynamic Update*' | Select-Object -First 1).Products | Should -Contain 'Windows Safe OS Dynamic Update'
    }
    It 'returns nothing for a search without results' {
        $html = Get-TestFixture 'catalog-search-none.html'
        @(InModuleScope WindowsIsoServicing -Parameters @{ Html = $html } { ConvertFrom-CatalogSearchResult -Html $Html }).Count | Should -Be 0
    }
    It 'fails with CatalogFormatChanged on an unrecognized page instead of returning nothing' {
        { InModuleScope WindowsIsoServicing { ConvertFrom-CatalogSearchResult -Html '<html><body>Service unavailable</body></html>' } } | Should -Throw -ErrorId 'CatalogFormatChanged'
    }
    It 'fails with CatalogFormatChanged when a row lacks its date' {
        $html = (Get-TestFixture 'catalog-search-kb5126646.html') -replace '10/13/2026', 'October 13'
        { InModuleScope WindowsIsoServicing -Parameters @{ Html = $html } { ConvertFrom-CatalogSearchResult -Html $Html } } | Should -Throw -ErrorId 'CatalogFormatChanged'
    }
}

Describe 'ConvertFrom-CatalogUpdateDetail' {
    It 'parses the updates that supersede an update' {
        $html = Get-TestFixture 'catalog-detail-kb5126646.html'
        $detail = InModuleScope WindowsIsoServicing -Parameters @{ Html = $html } { ConvertFrom-CatalogUpdateDetail -Html $Html }
        $detail.Classification | Should -Be 'Security Updates'
        $detail.Products | Should -Be @('Microsoft Server Operating System-24H2')
        $detail.SupersededBy.Count | Should -Be 3
        $detail.SupersededBy.Title | Should -Contain '2026-11 Cumulative Update for Microsoft server operating system version 24H2 for x64-based Systems (KB5131080) (26100.33822)'
        $detail.SupersededBy[0].UpdateId | Should -Match '^[0-9a-f-]{36}$'
    }
    It 'reads the description that distinguishes combined Dynamic Update titles' {
        $html = Get-TestFixture 'catalog-detail-kb5131094.html'
        $detail = InModuleScope WindowsIsoServicing -Parameters @{ Html = $html } { ConvertFrom-CatalogUpdateDetail -Html $Html }
        $detail.Description | Should -Be 'ComponentUpdate:'
        $detail.Products | Should -Be @('Windows 10 and later Dynamic Update', 'Windows Safe OS Dynamic Update')
    }
    It 'fails with CatalogFormatChanged when the superseded-by section is missing' {
        $html = (Get-TestFixture 'catalog-detail-kb5126646.html') -replace 'id="supersededbyInfo"', 'id="other"'
        { InModuleScope WindowsIsoServicing -Parameters @{ Html = $html } { ConvertFrom-CatalogUpdateDetail -Html $Html } } | Should -Throw -ErrorId 'CatalogFormatChanged'
    }
}

Describe 'ConvertFrom-CatalogDownloadDialog' {
    BeforeAll {
        $script:dialog = Get-TestFixture 'catalog-download-kb5126646.html'
        $script:updateId = '1abba66b-03c6-467e-9819-96844606cb15'
    }
    It 'returns the target and checkpoint MSUs with hexadecimal SHA-1 and SHA-256 hashes' {
        $files = @(InModuleScope WindowsIsoServicing -Parameters @{ Html = $dialog; Id = $updateId } { ConvertFrom-CatalogDownloadDialog -Html $Html -UpdateId $Id })
        $files.Count | Should -Be 2
        $files.Name | Should -Contain 'windows11.0-kb5126646-x64_1c4904f50bb65dd132a8f4c024de8d5fd91ff3b1.msu'
        $files.Name | Should -Contain 'windows11.0-kb5043080-x64_953449672073f8fb99badb4cc6d5d7849b9c83e8.msu'
        $target = $files | Where-Object Name -like '*kb5126646*'
        $target.Sha1 | Should -Be ([System.Convert]::ToHexString([System.Convert]::FromBase64String('HEkE9Qu2XdEyqPTAJN6NX9kf87E=')))
        $target.Sha256 | Should -Match '^[0-9A-F]{64}$'
        $target.Uri | Should -BeLike 'https://catalog.sf.dl.delivery.mp.microsoft.com/*'
    }
    It 'refuses download locations outside Microsoft download hosts' {
        $html = $dialog -replace 'https://catalog\.sf\.dl\.delivery\.mp\.microsoft\.com', 'https://downloads.example.com'
        { InModuleScope WindowsIsoServicing -Parameters @{ Html = $html; Id = $updateId } { ConvertFrom-CatalogDownloadDialog -Html $Html -UpdateId $Id } } | Should -Throw '*not a Microsoft download host*'
    }
    It 'refuses a response that describes a different update' {
        { InModuleScope WindowsIsoServicing -Parameters @{ Html = $dialog } { ConvertFrom-CatalogDownloadDialog -Html $Html -UpdateId '00000000-0000-0000-0000-000000000000' } } | Should -Throw -ErrorId 'CatalogFormatChanged'
    }
}

Describe 'Invoke-UpdateSourceRequest' {
    It 'refuses hosts other than the Microsoft Update Catalog and the MSRC API, and plain HTTP' {
        InModuleScope WindowsIsoServicing {
            Mock Invoke-WebRequest { throw 'must not be called' }
            { Invoke-UpdateSourceRequest -Uri 'https://example.com/Search.aspx' } | Should -Throw '*Refusing request*'
            { Invoke-UpdateSourceRequest -Uri 'http://www.catalog.update.microsoft.com/Search.aspx' } | Should -Throw '*Refusing request*'
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }
    It 'retries transport failures and then reports the failure' {
        InModuleScope WindowsIsoServicing {
            Mock Write-ServicingLog {}
            Mock Start-Sleep {}
            Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('No such host is known.') }
            { Invoke-UpdateSourceRequest -Uri 'https://api.msrc.microsoft.com/cvrf/v3.0/updates' -MaximumAttempt 3 -RetryDelaySeconds 0 } | Should -Throw '*after 3 attempt(s)*No such host*'
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        }
    }
}

Describe 'Select-MsrcSecurityUpdate' {
    BeforeAll {
        $script:document = Get-TestFixture 'msrc-cvrf-2026-Oct.json' | ConvertFrom-Json -Depth 20
    }
    It 'returns the cumulative update, not the lower-build hotpatch of the same month' {
        $update = InModuleScope WindowsIsoServicing -Parameters @{ Document = $document } { Select-MsrcSecurityUpdate -Document $Document -ProductName 'Windows Server 2025' }
        $update.Kb | Should -Be 'KB5131080'
        $update.FixedBuild | Should -Be ([version]'10.0.26100.33822')
        $update.Supersedes | Should -Be 'KB5126646'
        $update.DocumentId | Should -Be '2026-Oct'
    }
    It 'matches the product name exactly' {
        $update = InModuleScope WindowsIsoServicing -Parameters @{ Document = $document } { Select-MsrcSecurityUpdate -Document $Document -ProductName 'Windows 11 Version 24H2 for x64-based Systems' }
        $update.Kb | Should -Be 'KB5132061'
        InModuleScope WindowsIsoServicing -Parameters @{ Document = $document } { Select-MsrcSecurityUpdate -Document $Document -ProductName 'Windows Server 2022' } | Should -BeNullOrEmpty
    }
}

Describe 'Get-MsrcProductName' {
    It 'builds the MSRC product name for <Key> <Architecture>' -ForEach @(
        @{ Key = 'WindowsServer2025'; Build = 26100; Type = 'Server'; Architecture = 'x64'; Expected = 'Windows Server 2025' }
        @{ Key = 'Windows11Version24H2'; Build = 26100; Type = 'Client'; Architecture = 'arm64'; Expected = 'Windows 11 Version 24H2 for ARM64-based Systems' }
        @{ Key = 'Windows10Version22H2'; Build = 19045; Type = 'Client'; Architecture = 'x86'; Expected = 'Windows 10 Version 22H2 for 32-bit Systems' }
        @{ Key = 'WindowsServer23H2'; Build = 25398; Type = 'Server'; Architecture = 'x64'; Expected = $null }
    ) {
        InModuleScope WindowsIsoServicing -Parameters @{ Build = $Build; Type = $Type; Architecture = $Architecture; Expected = $Expected } {
            $os = Resolve-WindowsRelease -Build $Build -InstallationType $Type -EditionId 'ServerStandard' -AsOf ([datetime]'2026-11-18')
            Get-MsrcProductName -OperatingSystem $os -Architecture $Architecture | Should -Be $Expected
        }
    }
}
