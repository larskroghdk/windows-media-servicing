@{
    Releases        = @(
        @{
            Key               = 'WindowsServer2012'
            Name              = 'Windows Server 2012'
            Family            = 'Server'
            Build             = 9200
            Version           = $null
            FileNameStem      = 'Windows_Server_2012'
            UpdateProductText = 'Windows Server 2012'
            MsrcProductName   = 'Windows Server 2012'
            Servicing         = @{ Model = 'MonthlyRollup'; ServicingStackSeparate = $true; ServicingStackCombined = $false; CheckpointUpdates = $false; SafeOsDynamicUpdate = $false; SetupDynamicUpdate = $false }
            Lifecycle         = @(
                @{ EditionPattern = '.*'; Channel = 'Extended Security Updates'; EndOfSupport = '2023-10-10'; EsuEnd = '2026-10-13' }
            )
        }
        @{
            Key               = 'WindowsServer2012R2'
            Name              = 'Windows Server 2012 R2'
            Family            = 'Server'
            Build             = 9600
            Version           = $null
            FileNameStem      = 'Windows_Server_2012_R2'
            UpdateProductText = 'Windows Server 2012 R2'
            MsrcProductName   = 'Windows Server 2012 R2'
            Servicing         = @{ Model = 'MonthlyRollup'; ServicingStackSeparate = $true; ServicingStackCombined = $false; CheckpointUpdates = $false; SafeOsDynamicUpdate = $false; SetupDynamicUpdate = $false }
            Lifecycle         = @(
                @{ EditionPattern = '.*'; Channel = 'Extended Security Updates'; EndOfSupport = '2023-10-10'; EsuEnd = '2026-10-13' }
            )
        }
        @{
            Key                      = 'WindowsServer2016'
            Name                     = 'Windows Server 2016'
            Family                   = 'Server'
            Build                    = 14393
            Version                  = '1607'
            FileNameStem             = 'Windows_Server_2016'
            UpdateProductText        = 'Windows Server 2016'
            DynamicUpdateProductText = 'Windows 10 Version 1607'
            MsrcProductName          = 'Windows Server 2016'
            Servicing                = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $false; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle                = @(
                @{ EditionPattern = '.*'; Channel = 'LTSC'; EndOfSupport = '2027-01-12'; EsuEnd = $null }
            )
        }
        @{
            Key                      = 'WindowsServer2019'
            Name                     = 'Windows Server 2019'
            Family                   = 'Server'
            Build                    = 17763
            Version                  = '1809'
            FileNameStem             = 'Windows_Server_2019'
            UpdateProductText        = 'Windows Server 2019'
            DynamicUpdateProductText = 'Windows 10 Version 1809'
            MsrcProductName          = 'Windows Server 2019'
            Servicing                = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $false; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle                = @(
                @{ EditionPattern = '.*'; Channel = 'LTSC'; EndOfSupport = '2029-01-09'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'WindowsServer2022'
            Name              = 'Windows Server 2022'
            Family            = 'Server'
            Build             = 20348
            Version           = '21H2'
            FileNameStem      = 'Windows_Server_2022'
            UpdateProductText = 'Microsoft server operating system, version 21H2'
            MsrcProductName   = 'Windows Server 2022'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '.*'; Channel = 'LTSC'; EndOfSupport = '2031-10-14'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'WindowsServer23H2'
            Name              = 'Windows Server, version 23H2'
            Family            = 'Server'
            Build             = 25398
            Version           = '23H2'
            FileNameStem      = 'Windows_Server_23H2'
            UpdateProductText = 'Microsoft server operating system version 23H2'
            MsrcProductName   = $null
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '.*'; Channel = 'Annual Channel'; EndOfSupport = '2025-10-24'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'WindowsServer2025'
            Name              = 'Windows Server 2025'
            Family            = 'Server'
            Build             = 26100
            Version           = '24H2'
            FileNameStem      = 'Windows_Server_2025'
            UpdateProductText = 'Microsoft server operating system version 24H2'
            MsrcProductName   = 'Windows Server 2025'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $true; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '.*'; Channel = 'LTSC'; EndOfSupport = '2034-10-10'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'Windows10Version1607'
            Name              = 'Windows 10'
            Family            = 'Client'
            Build             = 14393
            Version           = '1607'
            FileNameStem      = 'Windows_10_1607'
            UpdateProductText = 'Windows 10 Version 1607'
            MsrcProductName   = 'Windows 10 Version 1607 for {0} Systems'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $false; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = 'EnterpriseS'; Channel = 'Enterprise LTSB 2016'; EndOfSupport = '2026-10-13'; EsuEnd = $null; FileNameStem = 'Windows_10_LTSB_2016' }
                @{ EditionPattern = '.*'; Channel = 'General Availability'; EndOfSupport = '2019-04-09'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'Windows10Version1809'
            Name              = 'Windows 10'
            Family            = 'Client'
            Build             = 17763
            Version           = '1809'
            FileNameStem      = 'Windows_10_1809'
            UpdateProductText = 'Windows 10 Version 1809'
            MsrcProductName   = 'Windows 10 Version 1809 for {0} Systems'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $false; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = 'EnterpriseS'; Channel = 'Enterprise LTSC 2019'; EndOfSupport = '2029-01-09'; EsuEnd = $null; FileNameStem = 'Windows_10_LTSC_2019' }
                @{ EditionPattern = '.*'; Channel = 'General Availability'; EndOfSupport = '2021-05-11'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'Windows10Version21H2'
            Name              = 'Windows 10'
            Family            = 'Client'
            Build             = 19044
            Version           = '21H2'
            FileNameStem      = 'Windows_10_21H2'
            UpdateProductText = 'Windows 10 Version 21H2'
            MsrcProductName   = 'Windows 10 Version 21H2 for {0} Systems'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '^IoTEnterpriseS$'; Channel = 'IoT Enterprise LTSC 2021'; EndOfSupport = '2032-01-13'; EsuEnd = $null; FileNameStem = 'Windows_10_IoT_LTSC_2021' }
                @{ EditionPattern = 'EnterpriseS'; Channel = 'Enterprise LTSC 2021'; EndOfSupport = '2027-01-12'; EsuEnd = $null; FileNameStem = 'Windows_10_LTSC_2021' }
                @{ EditionPattern = '.*'; Channel = 'General Availability'; EndOfSupport = '2024-06-11'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'Windows10Version22H2'
            Name              = 'Windows 10'
            Family            = 'Client'
            Build             = 19045
            Version           = '22H2'
            FileNameStem      = 'Windows_10_22H2'
            UpdateProductText = 'Windows 10 Version 22H2'
            MsrcProductName   = 'Windows 10 Version 22H2 for {0} Systems'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '^Core'; Channel = 'Consumer Extended Security Updates'; EndOfSupport = '2025-10-14'; EsuEnd = '2026-10-13' }
                @{ EditionPattern = '.*'; Channel = 'Commercial Extended Security Updates'; EndOfSupport = '2025-10-14'; EsuEnd = '2028-10-10' }
            )
        }
        @{
            Key               = 'Windows11Version22H2'
            Name              = 'Windows 11'
            Family            = 'Client'
            Build             = 22621
            Version           = '22H2'
            FileNameStem      = 'Windows_11_22H2'
            UpdateProductText = 'Windows 11 Version 22H2'
            MsrcProductName   = 'Windows 11 Version 22H2 for {0} Systems'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '^(Enterprise|Education|IoTEnterprise)'; Channel = 'Enterprise and Education'; EndOfSupport = '2025-10-14'; EsuEnd = $null }
                @{ EditionPattern = '.*'; Channel = 'Home and Pro'; EndOfSupport = '2024-10-08'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'Windows11Version23H2'
            Name              = 'Windows 11'
            Family            = 'Client'
            Build             = 22631
            Version           = '23H2'
            FileNameStem      = 'Windows_11_23H2'
            UpdateProductText = 'Windows 11 Version 23H2'
            MsrcProductName   = 'Windows 11 Version 23H2 for {0} Systems'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $false; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '^(Enterprise|Education|IoTEnterprise)'; Channel = 'Enterprise and Education'; EndOfSupport = '2026-11-10'; EsuEnd = $null }
                @{ EditionPattern = '.*'; Channel = 'Home and Pro'; EndOfSupport = '2025-11-11'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'Windows11Version24H2'
            Name              = 'Windows 11'
            Family            = 'Client'
            Build             = 26100
            Version           = '24H2'
            FileNameStem      = 'Windows_11_24H2'
            UpdateProductText = 'Windows 11 Version 24H2'
            MsrcProductName   = 'Windows 11 Version 24H2 for {0} Systems'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $true; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '^IoTEnterpriseS'; Channel = 'IoT Enterprise LTSC 2024'; EndOfSupport = '2034-10-10'; EsuEnd = $null; FileNameStem = 'Windows_11_IoT_LTSC_2024' }
                @{ EditionPattern = 'EnterpriseS'; Channel = 'Enterprise LTSC 2024'; EndOfSupport = '2029-10-09'; EsuEnd = $null; FileNameStem = 'Windows_11_LTSC_2024' }
                @{ EditionPattern = '^(Enterprise|Education|IoTEnterprise)'; Channel = 'Enterprise and Education'; EndOfSupport = '2027-10-12'; EsuEnd = $null }
                @{ EditionPattern = '.*'; Channel = 'Home and Pro'; EndOfSupport = '2026-10-13'; EsuEnd = $null }
            )
        }
        @{
            Key               = 'Windows11Version25H2'
            Name              = 'Windows 11'
            Family            = 'Client'
            Build             = 26200
            Version           = '25H2'
            FileNameStem      = 'Windows_11_25H2'
            UpdateProductText = 'Windows 11 Version 25H2'
            MsrcProductName   = 'Windows 11 Version 25H2 for {0} Systems'
            Servicing         = @{ Model = 'Cumulative'; ServicingStackSeparate = $true; ServicingStackCombined = $true; CheckpointUpdates = $true; SafeOsDynamicUpdate = $true; SetupDynamicUpdate = $true }
            Lifecycle         = @(
                @{ EditionPattern = '^(Enterprise|Education|IoTEnterprise)'; Channel = 'Enterprise and Education'; EndOfSupport = '2028-10-10'; EsuEnd = $null }
                @{ EditionPattern = '.*'; Channel = 'Home and Pro'; EndOfSupport = '2027-10-12'; EsuEnd = $null }
            )
        }
    )

    RetiredReleases = @(
        @{ Family = 'Client'; Build = 9600; Name = 'Windows 8.1' }
        @{ Family = 'Client'; Build = 10240; Name = 'Windows 10 Enterprise LTSB 2015' }
        @{ Family = 'Client'; Build = 19041; Name = 'Windows 10 Version 2004' }
        @{ Family = 'Client'; Build = 19042; Name = 'Windows 10 Version 20H2' }
        @{ Family = 'Client'; Build = 19043; Name = 'Windows 10 Version 21H1' }
        @{ Family = 'Client'; Build = 22000; Name = 'Windows 11 Version 21H2' }
        @{ Family = 'Server'; Build = 7601; Name = 'Windows Server 2008 R2' }
    )
}
