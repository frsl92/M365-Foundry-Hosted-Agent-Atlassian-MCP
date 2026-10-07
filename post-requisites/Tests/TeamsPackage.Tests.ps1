. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$prepareTemplate = Join-Path $postRoot '3.Prepare-Teams-Package\Prepare-TeamsPackage.ps1'

Describe 'Offline Teams package preparation' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $workspace = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + ' workspace')
        $history = Join-Path $workspace 'post-requisites\3.Prepare-Teams-Package'
        $common = Join-Path $workspace 'common-scripts'
        $null = New-Item -ItemType Directory -Path $history, $common -Force
        Copy-Item -LiteralPath $prepareTemplate -Destination $history
        Copy-Item -LiteralPath (Join-Path $postRoot '..\common-scripts\Common.ps1') -Destination $common
        $prepare = Join-Path $history 'Prepare-TeamsPackage.ps1'
        $request = Join-Path $workspace 'metadata.json'
        $source = Join-Path $workspace 'original package.zip'
        $output = Join-Path $workspace 'customized package.zip'
        $client = '33333333-3333-3333-3333-333333333333'
        $metadata = @{
            agentDisplayName = 'Test agent'; appVersion = '1.2.3'
            shortDescription = 'Test'; fullDescription = 'Test agent description'
            developerName = 'Test organization'; developerWebsiteUrl = 'https://example.com'
            privacyUrl = 'https://example.com/privacy'; termsOfUseUrl = 'https://example.com/terms'
        }
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        $manifest = @{
            '$schema' = 'https://developer.microsoft.com/json-schemas/teams/v1.29/MicrosoftTeams.schema.json'
            manifestVersion = '1.29'; version = '1.0.0'; id = '44444444-4444-4444-4444-444444444444'
            name = @{ short = 'Original'; full = 'Original full name' }
            description = @{ short = 'Original short'; full = 'Original description' }
            developer = @{ name = 'Original'; websiteUrl = 'https://original.example.com'; privacyUrl = 'https://original.example.com'; termsOfUseUrl = 'https://original.example.com'; extra = 'preserve' }
            icons = @{ color = 'default-color-icon.png'; outline = 'default-outline-icon.png' }
            accentColor = '#4464ee'
            webApplicationInfo = @{ id = $client; resource = 'api://example.com' }
            bots = @(@{ botId = $client; scopes = @('personal', 'team', 'groupChat', 'copilot'); supportsFiles = $true })
            copilotAgents = @{ customEngineAgents = @(@{ id = $client; type = 'bot'; disclaimer = @{ text = 'Preserve me' } }) }
            supportsChannelFeatures = 'tier1'; validDomains = @('example.com')
            unknownFutureField = @{ nested = @('keep', 'unchanged') }
        }
        Write-TestPackage -Path $source -Manifest $manifest
        $packageState = @{ SourceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source)) }
        $parameters = @{ MetadataFile = $request; PackagePath = $source; OutputPackagePath = $output }
        Mock Get-PublishingContext { throw 'Offline packaging must not load Azure context or root env.' }
        Mock Invoke-PublishingCli { throw 'Offline packaging must not call Azure.' }
        Mock atk { throw 'Offline packaging must not call Toolkit.' }
        Mock Invoke-MgGraphRequest { throw 'Offline packaging must not call Graph.' }
    }
    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($source)) | Should BeExactly $packageState.SourceBytes
        Assert-MockCalled Get-PublishingContext -Times 0 -Exactly
        Assert-MockCalled Invoke-PublishingCli -Times 0 -Exactly
        Assert-MockCalled atk -Times 0 -Exactly
        Assert-MockCalled Invoke-MgGraphRequest -Times 0 -Exactly
        @(Get-ChildItem -LiteralPath $history -Filter '*.lock').Count | Should Be 0
    }

    It 'prepares a new ZIP offline and preserves every deployment identity and noneditable field' {
        $result = & $prepare @parameters
        $result.Published | Should Be $false
        $result.NextAction | Should BeExactly 'ManualTeamsAdminCenterUpload'
        $result.AppId | Should BeExactly $manifest.id
        $result.AppVersion | Should BeExactly '1.2.3'
        $result.PackagePath | Should BeExactly $output
        [IO.File]::Exists($result.ArchivePath) | Should Be $true
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($output)) |
            Should BeExactly ([Convert]::ToBase64String([IO.File]::ReadAllBytes($result.ArchivePath)))
        $actual = Read-TestPackageEntry -Path $output
        $actual.version | Should BeExactly '1.2.3'
        $actual.name.short | Should BeExactly 'Test agent'
        $actual.name.full | Should BeExactly 'Test agent'
        $actual.description.short | Should BeExactly 'Test'
        $actual.description.full | Should BeExactly $metadata.fullDescription
        $actual.developer.name | Should BeExactly $metadata.developerName
        $actual.developer.extra | Should BeExactly 'preserve'
        foreach ($field in @('id', 'manifestVersion', 'bots', 'webApplicationInfo', 'copilotAgents',
            'supportsChannelFeatures', 'unknownFutureField', 'icons', 'accentColor')) {
            (ConvertTo-Json $actual.$field -Depth 100 -Compress) |
                Should BeExactly (ConvertTo-Json $manifest.$field -Depth 100 -Compress)
        }
        ($actual.validDomains -join '|') | Should BeExactly 'example.com|token.botframework.com'
        ($actual.validDomains -is [array]) | Should Be $true
        foreach ($name in @('default-color-icon.png', 'default-outline-icon.png', 'resources/extra.txt')) {
            Read-TestPackageEntry -Path $output -Name $name -Base64 |
                Should BeExactly (Read-TestPackageEntry -Path $source -Name $name -Base64)
        }
        [IO.Directory]::Exists((Join-Path $history 'toolkit')) | Should Be $false
    }

    It 'does not write any ZIP under WhatIf' {
        & $prepare @parameters -WhatIf
        [IO.File]::Exists($output) | Should Be $false
        @(Get-ChildItem -LiteralPath $history -Filter 'appPackage.*.zip').Count | Should Be 0
    }

    It 'adds the OAuth domain when source validDomains is <State>' -TestCases @(
        @{ State = 'missing' }, @{ State = 'empty' }
    ) {
        param($State)
        if ($State -eq 'missing') { $manifest.Remove('validDomains') }
        else { $manifest.validDomains = @() }
        Write-TestPackage -Path $source -Manifest $manifest
        $packageState.SourceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
        $null = & $prepare @parameters
        $actual = Read-TestPackageEntry -Path $output
        ($actual.validDomains -is [array]) | Should Be $true
        $actual.validDomains.Count | Should Be 1
        $actual.validDomains[0] | Should BeExactly 'token.botframework.com'
    }

    It 'preserves existing domains without adding a duplicate OAuth domain for <Domain>' -TestCases @(
        @{ Domain = 'token.botframework.com' }, @{ Domain = 'TOKEN.BOTFRAMEWORK.COM' }
    ) {
        param($Domain)
        $manifest.validDomains = @($Domain, 'example.com', 'another.example.com')
        Write-TestPackage -Path $source -Manifest $manifest
        $packageState.SourceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
        $null = & $prepare @parameters
        $actual = Read-TestPackageEntry -Path $output
        ($actual.validDomains -join '|') | Should BeExactly ($manifest.validDomains -join '|')
        @($actual.validDomains | Where-Object { $_ -ieq 'token.botframework.com' }).Count | Should Be 1
    }

    It 'rejects malformed validDomains <Case> instead of silently replacing it' -TestCases @(
        @{ Case = 'null'; Domains = $null },
        @{ Case = 'scalar'; Domains = 'example.com' },
        @{ Case = 'non-string entry'; Domains = @(123) },
        @{ Case = 'empty entry'; Domains = @('') }
    ) {
        param($Case, $Domains)
        $manifest.validDomains = $Domains
        Write-TestPackage -Path $source -Manifest $manifest
        $packageState.SourceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
        { & $prepare @parameters } | Should Throw 'validDomains must be an array of nonempty domain strings'
        [IO.File]::Exists($output) | Should Be $false
        @(Get-ChildItem -LiteralPath $history -Filter 'appPackage.*.zip').Count | Should Be 0
    }

    It 'keeps the original icon bytes for <State> icon paths' -TestCases @(
        @{ State = 'omitted' }, @{ State = 'empty' }, @{ State = 'whitespace' }
    ) {
        param($State)
        if ($State -ne 'omitted') {
            $metadata.colorIconPath = if ($State -eq 'empty') { '' } else { ' ' }
            $metadata.outlineIconPath = $metadata.colorIconPath
        }
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        $null = & $prepare @parameters
        foreach ($name in @('default-color-icon.png', 'default-outline-icon.png')) {
            Read-TestPackageEntry -Path $output -Name $name -Base64 |
                Should BeExactly (Read-TestPackageEntry -Path $source -Name $name -Base64)
        }
    }

    It 'resolves replacement icons relative to JSON and keeps the original ZIP paths' {
        $color = Join-Path $workspace 'color.png'
        $outline = Join-Path $workspace 'outline.png'
        New-TestPng -Path $color -Width 192 -Height 192
        New-TestPng -Path $outline -Width 32 -Height 32
        $metadata.colorIconPath = 'color.png'
        $metadata.outlineIconPath = 'outline.png'
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        $null = & $prepare @parameters
        Read-TestPackageEntry -Path $output -Name 'default-color-icon.png' -Base64 |
            Should BeExactly ([Convert]::ToBase64String([IO.File]::ReadAllBytes($color)))
        Read-TestPackageEntry -Path $output -Name 'default-outline-icon.png' -Base64 |
            Should BeExactly ([Convert]::ToBase64String([IO.File]::ReadAllBytes($outline)))
    }

    It 'supports absolute icon paths and metadata file paths with spaces' {
        $metadata.colorIconPath = Join-Path $workspace 'color icon.png'
        $metadata.outlineIconPath = Join-Path $workspace 'outline icon.png'
        New-TestPng -Path $metadata.colorIconPath -Width 192 -Height 192
        New-TestPng -Path $metadata.outlineIconPath -Width 32 -Height 32
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        $null = & $prepare @parameters
        [IO.File]::Exists($output) | Should Be $true
    }

    It 'rejects a single populated <Field> icon path' -TestCases @(
        @{ Field = 'colorIconPath' }, @{ Field = 'outlineIconPath' }
    ) {
        param($Field)
        $metadata[$Field] = 'only-one.png'
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        { & $prepare @parameters } | Should Throw 'Provide both'
        [IO.File]::Exists($output) | Should Be $false
    }

    It 'rejects invalid icon input <Case>' -TestCases @(
        @{ Case = 'missing'; Size = 192; Corrupt = $false; Missing = $true },
        @{ Case = 'incorrect dimensions'; Size = 100; Corrupt = $false; Missing = $false },
        @{ Case = 'corrupt'; Size = 192; Corrupt = $true; Missing = $false }
    ) {
        param($Case, $Size, $Corrupt, $Missing)
        $metadata.colorIconPath = Join-Path $workspace 'bad.png'
        $metadata.outlineIconPath = Join-Path $workspace 'outline.png'
        New-TestPng -Path $metadata.outlineIconPath -Width 32 -Height 32
        if ($Corrupt) { [IO.File]::WriteAllText($metadata.colorIconPath, 'not a png') }
        elseif (-not $Missing) { New-TestPng -Path $metadata.colorIconPath -Width $Size -Height $Size }
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        { & $prepare @parameters } | Should Throw 'colorIconPath'
        [IO.File]::Exists($output) | Should Be $false
    }

    It 'rejects invalid metadata <Field>' -TestCases @(
        @{ Field = 'agentDisplayName'; Value = '' },
        @{ Field = 'agentDisplayName'; Value = ('a' * 31) },
        @{ Field = 'agentFullName'; Value = ('a' * 101) },
        @{ Field = 'shortDescription'; Value = ('a' * 81) },
        @{ Field = 'fullDescription'; Value = ('a' * 4001) },
        @{ Field = 'developerName'; Value = ('a' * 33) },
        @{ Field = 'appVersion'; Value = '1.2' },
        @{ Field = 'appVersion'; Value = '01.2.3' },
        @{ Field = 'privacyUrl'; Value = 'http://example.com' },
        @{ Field = 'termsOfUseUrl'; Value = 'https://user:pass@example.com' },
        @{ Field = 'developerWebsiteUrl'; Value = 'https://example.com/bad path' },
        @{ Field = 'accentColor'; Value = 'blue' },
        @{ Field = 'colorIconPath'; Value = 123 },
        @{ Field = 'colorIconBase64'; Value = 'YWJj' },
        @{ Field = 'id'; Value = 'new-id' }
    ) {
        param($Field, $Value)
        $metadata[$Field] = $Value
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        { & $prepare @parameters } | Should Throw $Field
        [IO.File]::Exists($output) | Should Be $false
    }

    It 'sets the optional full name and accent color without changing bot identity' {
        $metadata.agentFullName = 'Full agent name'
        $metadata.accentColor = '#112233'
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        $null = & $prepare @parameters
        $actual = Read-TestPackageEntry -Path $output
        $actual.name.full | Should BeExactly 'Full agent name'
        $actual.accentColor | Should BeExactly '#112233'
        $actual.bots[0].botId | Should BeExactly $client
    }

    It 'rejects invalid source identity <Case>' -TestCases @(
        @{ Case = 'missing app id' }, @{ Case = 'invalid bot id' }, @{ Case = 'mismatched web app' }
    ) {
        param($Case)
        if ($Case -eq 'missing app id') { $manifest.id = '' }
        elseif ($Case -eq 'invalid bot id') { $manifest.bots[0].botId = 'not-a-guid' }
        else { $manifest.webApplicationInfo.id = '77777777-7777-7777-7777-777777777777' }
        Write-TestPackage -Path $source -Manifest $manifest
        $packageState.SourceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
        $message = if ($Case -eq 'missing app id') { 'nonempty application id' } else { 'one valid bot identity' }
        { & $prepare @parameters } | Should Throw $message
        [IO.File]::Exists($output) | Should Be $false
    }

    It 'rejects unsafe or duplicate ZIP entry <Entry>' -TestCases @(
        @{ Entry = '../escape.txt' }, @{ Entry = 'nested\escape.txt' },
        @{ Entry = '/absolute.txt' }, @{ Entry = 'MANIFEST.JSON' }
    ) {
        param($Entry)
        Write-TestPackage -Path $source -Manifest $manifest -ExtraEntries @($Entry)
        $packageState.SourceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
        { & $prepare @parameters } | Should Throw 'unsafe or duplicate'
    }

    It 'rejects missing icon references in the source ZIP' {
        $manifest.icons.color = 'missing.png'
        Write-TestPackage -Path $source -Manifest $manifest
        $packageState.SourceBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source))
        { & $prepare @parameters } | Should Throw 'two distinct icon'
    }

    It 'does not overwrite the source ZIP or an existing destination' {
        $parameters.OutputPackagePath = $source
        { & $prepare @parameters } | Should Throw 'no files will be overwritten'
        $parameters.OutputPackagePath = $output
        [IO.File]::WriteAllText($output, 'keep')
        { & $prepare @parameters } | Should Throw 'no files will be overwritten'
        [IO.File]::ReadAllText($output) | Should BeExactly 'keep'
    }

    It 'resolves default package and archive paths independently of current directory' {
        $agent = Join-Path $workspace 'agent-deployment\agent'
        $null = New-Item -ItemType Directory -Path $agent -Force
        Copy-Item -LiteralPath $source -Destination (Join-Path $agent 'appPackage.zip')
        Push-Location $TestDrive
        try { $result = & $prepare -MetadataFile $request } finally { Pop-Location }
        Split-Path $result.PackagePath -Leaf | Should BeExactly 'appPackage.1.2.3.zip'
        $result.PackagePath | Should BeExactly $result.ArchivePath
        [IO.File]::Exists((Join-Path $history 'appPackage.1.2.3.zip')) | Should Be $true
    }

    It 'allows the first customized package to use the source version' {
        $metadata.appVersion = '1.0.0'
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        $result = & $prepare @parameters
        $result.AppVersion | Should BeExactly '1.0.0'
    }

    It 'refuses a downgrade below the source version' {
        $metadata.appVersion = '0.9.0'
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        { & $prepare @parameters } | Should Throw 'must not be lower'
    }

    It 'requires requested <Requested> to exceed historical <Previous> even with an unused output path' -TestCases @(
        @{ Requested = '1.2.3'; Previous = '1.2.3' },
        @{ Requested = '1.2.3'; Previous = '1.3.0' },
        @{ Requested = '1.9.0'; Previous = '1.10.0' }
    ) {
        param($Requested, $Previous)
        $old = @{} + $manifest
        $old.version = $Previous
        Write-TestPackage -Path (Join-Path $history "appPackage.$Previous.zip") -Manifest $old
        $metadata.appVersion = $Requested
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        { & $prepare @parameters } | Should Throw 'higher'
        [IO.File]::Exists($output) | Should Be $false
    }

    It 'compares versions numerically and preserves previous archives' {
        $first = & $prepare @parameters
        $firstBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($first.ArchivePath))
        $metadata.appVersion = '1.10.0'
        [IO.File]::WriteAllText($request, (ConvertTo-Json $metadata))
        $parameters.OutputPackagePath = Join-Path $workspace 'next.zip'
        $second = & $prepare @parameters
        $second.AppVersion | Should BeExactly '1.10.0'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($first.ArchivePath)) | Should BeExactly $firstBytes
    }

    It 'keeps version history separate for different manifest app identities' {
        $old = @{} + $manifest
        $old.id = '77777777-7777-7777-7777-777777777777'
        $old.version = '9.0.0'
        Write-TestPackage -Path (Join-Path $history 'appPackage.9.0.0.zip') -Manifest $old
        $result = & $prepare @parameters
        $result.AppVersion | Should BeExactly '1.2.3'
    }

    It 'fails explicitly on unreadable history rather than ignoring it' {
        [IO.File]::WriteAllText((Join-Path $history 'appPackage.9.0.0.zip'), 'not a zip')
        { & $prepare @parameters } | Should Throw 'Cannot read package history'
    }

    It 'refuses concurrent preparation while package history is locked' {
        $lockPath = Join-Path $history '.appPackage.lock'
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { { & $prepare @parameters } | Should Throw 'Cannot lock package history' } finally {
            $lock.Dispose()
            [IO.File]::Delete($lockPath)
        }
        [IO.File]::Exists($output) | Should Be $false
    }

    It 'does not consult or write a root .env or retained legacy Toolkit state' {
        $rootEnv = Join-Path $workspace '.env'
        [IO.File]::WriteAllText($rootEnv, 'intentionally invalid environment contents')
        $legacy = Join-Path $history 'toolkit\env'
        $null = New-Item -ItemType Directory -Path $legacy -Force
        $legacyEnv = Join-Path $legacy '.env.catalog'
        [IO.File]::WriteAllText($legacyEnv, 'preserve legacy state')
        $null = & $prepare @parameters
        [IO.File]::ReadAllText($rootEnv) | Should BeExactly 'intentionally invalid environment contents'
        [IO.File]::ReadAllText($legacyEnv) | Should BeExactly 'preserve legacy state'
    }
}
