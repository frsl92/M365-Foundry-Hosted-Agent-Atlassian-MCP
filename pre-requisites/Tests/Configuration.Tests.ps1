$prerequisiteRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $prerequisiteRoot 'Common.ps1')
$registrationScript = Join-Path $prerequisiteRoot '1.Register-Atlassian-Client\Register-AtlassianMcpClient.ps1'

Describe 'Shared prerequisite configuration' {
    BeforeEach {
        $unlockHandle = $null
        $layoutTemplateOverride = $null
        $envPath = Join-Path $TestDrive 'configuration.env'
        if (Test-Path -LiteralPath $envPath) { Remove-Item -LiteralPath $envPath }
    }

    It 'locates the repository env independently of the working directory' {
        Push-Location $TestDrive
        try {
            Get-PrerequisiteEnvPath | Should Be (Join-Path (Split-Path $prerequisiteRoot -Parent) '.env')
        } finally { Pop-Location }
    }

    It 'returns empty configuration for a missing file' {
        (Read-PrerequisiteEnv -Path $envPath).Count | Should Be 0
    }

    It 'resolves explicitly relative file paths against the PowerShell working directory' {
        Push-Location $TestDrive
        try {
            Update-PrerequisiteEnv -Path '.\configuration.env' -Values @{ KEY = 'value' }
            (Read-PrerequisiteEnv -Path '.\configuration.env')['KEY'] | Should BeExactly 'value'
            [System.IO.File]::Exists($envPath) | Should Be $true
        } finally { Pop-Location }
    }

    It 'round-trips special characters without executing or expanding values' {
        $special = 'literal $env:PATH $(throw "executed") # = \ " '' ` ' + "`r`n`t" + [char]0x00E9
        Update-PrerequisiteEnv -Path $envPath -Values ([ordered]@{ SECRET = $special; EMPTY = '' })
        $values = Read-PrerequisiteEnv -Path $envPath
        $values['SECRET'] | Should BeExactly $special
        $values['EMPTY'] | Should BeExactly ''
    }

    It 'reads comments and quoted or unquoted assignments' {
        [System.IO.File]::WriteAllText($envPath, @'
# comment
PLAIN = value # trailing comment
SINGLE='literal \n $value # comment' # trailing comment
DOUBLE="escaped\nline\\n" # trailing comment
EMPTY=
EMPTY_COMMENT= # no value
'@)
        $values = Read-PrerequisiteEnv -Path $envPath
        $values['PLAIN'] | Should BeExactly 'value'
        $values['SINGLE'] | Should BeExactly 'literal \n $value # comment'
        $values['DOUBLE'] | Should BeExactly "escaped`nline\n"
        $values['EMPTY'] | Should BeExactly ''
        $values['EMPTY_COMMENT'] | Should BeExactly ''
    }

    It 'merges only supplied keys and preserves other lines' {
        [System.IO.File]::WriteAllText($envPath, "# keep comment`nOTHER='leave alone' # keep inline`nOWN=old`n")
        Update-PrerequisiteEnv -Path $envPath -Values ([ordered]@{ OWN = 'new'; ADDED = 'value' })
        Update-PrerequisiteEnv -Path $envPath -Values @{ OWN = 'latest' }
        $content = [System.IO.File]::ReadAllText($envPath)
        $content.Contains("# keep comment`n".Replace("`n", [Environment]::NewLine)) | Should Be $true
        $content.Contains("OTHER='leave alone' # keep inline") | Should Be $true
        $values = Read-PrerequisiteEnv -Path $envPath
        $values['OTHER'] | Should BeExactly 'leave alone'
        $values['OWN'] | Should BeExactly 'latest'
        $values['ADDED'] | Should BeExactly 'value'
        $values.Count | Should Be 3
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.env.*.tmp').Count | Should Be 0
    }

    It 'rejects duplicate keys without changing the original file' {
        $original = "KEY=one`nKEY=two"
        [System.IO.File]::WriteAllText($envPath, $original)
        { Update-PrerequisiteEnv -Path $envPath -Values @{ KEY = 'new' } } | Should Throw 'Duplicate .env key'
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'keeps only user inputs in first-use order in the v1 template' {
        $template = Join-Path (Split-Path $prerequisiteRoot -Parent) '.env.v1.example'
        $values = Read-PrerequisiteEnv -Path $template
        $expected = [ordered]@{
            'Inputs first used by 1.Register-Atlassian-Client' = @(
                'AZURE_APIM_NAME', 'AZURE_KEY_VAULT_NAME', 'ATLASSIAN_MCP_ENDPOINT',
                'ATLASSIAN_MCP_CLIENT_NAME', 'ATLASSIAN_MCP_SECRET_PREFIX', 'ATLASSIAN_MCP_SCOPES')
            'Inputs first used by 2.Configure-APIM-Identity' = @('AZURE_RESOURCE_GROUP_NAME', 'AZURE_SUBSCRIPTION_ID')
            'Inputs first used by 3.Configure-APIM-Credential-Provider' = @('AZURE_APIM_CREDENTIAL_PROVIDER_NAME')
            'Inputs first used by 4.Register-Entra-Applications' = @(
                'AZURE_TENANT_ID', 'APIM_API_APP_NAME', 'AUTH_APP_NAME', 'AUTH_REDIRECT_URI', 'AUTH_CLIENT_SECRET')
            'Inputs first used by 5.Configure-APIM-Named-Values' = @(
                'AZURE_APIM_POLICY_ARM_API_VERSION', 'ATLASSIAN_MCP_BASE_URL',
                'ATLASSIAN_MCP_PATH', 'ATLASSIAN_POST_LOGIN_REDIRECT_URL')
            'Inputs first used by 6.Create-APIM-Fragments' = @()
            'Inputs first used by 7.Create-APIM-APIandMCP' = @(
                'AZURE_APIM_CONNECT_API_ID', 'AZURE_APIM_CONNECT_API_PATH',
                'AZURE_APIM_MCP_API_ID', 'AZURE_APIM_MCP_API_PATH')
            'Inputs first used by deployment (agent-deployment/deploy-agent.ps1)' = @(
                'AZURE_ENV_NAME', 'AZURE_LOCATION', 'AZURE_FOUNDRY_PROJECT_RESOURCE_ID',
                'AZURE_FOUNDRY_PROJECT_ENDPOINT', 'AZURE_BOT_SERVICE_RESOURCE_ID',
                'FOUNDRY_MODEL_NAME', 'GATEWAY_MODELS_ENDPOINT', 'GATEWAY_SUBSCRIPTION_KEY',
                'APIM_STATUS_SUBSCRIPTION_KEY', 'APIM_MCP_SUBSCRIPTION_KEY',
                'AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME')
            'Inputs first used by post-requisite 1.Configure-Bot-OAuth' = @()
            'Inputs first used by post-requisite 2.Configure-M365-Endpoint' = @()
            'Inputs first used by post-requisite 3.Prepare-Teams-Package' = @()
        }
        $actual = [ordered]@{}
        $section = ''
        foreach ($line in [System.IO.File]::ReadAllLines($template)) {
            if ($line -match '^# ((Inputs first used by|Generated by) .+)$') {
                $section = $Matches[1]
                $actual[$section] = @()
            } elseif ($line -cmatch '^([A-Za-z_][A-Za-z0-9_]*)=') {
                $section | Should Not BeNullOrEmpty
                $actual[$section] += $Matches[1]
            }
        }
        ($actual.Keys -join '|') | Should BeExactly ($expected.Keys -join '|')
        foreach ($section in $expected.Keys) {
            ($actual[$section] -join '|') | Should BeExactly ($expected[$section] -join '|')
        }
        $defaults = @{
            AUTH_REDIRECT_URI = 'https://token.botframework.com/.auth/web/redirect'
            AZURE_APIM_POLICY_ARM_API_VERSION = '2022-08-01'
            AZURE_ENV_NAME = 'agent-dev'
            FOUNDRY_MODEL_NAME = 'gpt-5.6-luna'
        }
        foreach ($key in $values.Keys) {
            if ($defaults.ContainsKey($key)) { $values[$key] | Should BeExactly $defaults[$key] }
            elseif ($key -ne 'ATLASSIAN_MCP_SCOPES') { $values[$key] | Should BeExactly '' }
        }
        $values['ATLASSIAN_MCP_SCOPES'] | Should Match 'read:account'
        foreach ($section in (Get-PrerequisiteGeneratedSections).Values) {
            foreach ($key in $section) { $values.Contains($key) | Should Be $false }
        }
    }

    It 'orders fresh and newly introduced values by the template rather than write order' {
        Update-PrerequisiteEnv -Path $envPath -Values ([ordered]@{
            AUTH_CLIENT_ID = 'auth-id'
            ATLASSIAN_MCP_CLIENT_SECRET = 'test-secret'
            AUTH_APP_NAME = 'Sign-in'
            AZURE_APIM_NAME = 'test-apim'
        })
        Update-PrerequisiteEnv -Path $envPath -Values ([ordered]@{
            AZURE_APP_REGISTRATIONS_CONFIGURED = 'true'
            AZURE_RESOURCE_GROUP_NAME = 'test-rg'
            AZURE_APIM_IDENTITY_PRINCIPAL_ID = 'principal-id'
            AZURE_APIM_CREDENTIAL_PROVIDER_NAME = 'provider'
        })
        $values = Read-PrerequisiteEnv -Path $envPath
        ($values.Keys -join '|') | Should BeExactly (
            'AZURE_APIM_NAME|AZURE_RESOURCE_GROUP_NAME|AZURE_APIM_CREDENTIAL_PROVIDER_NAME|AUTH_APP_NAME|' +
            'ATLASSIAN_MCP_CLIENT_SECRET|AZURE_APIM_IDENTITY_PRINCIPAL_ID|AUTH_CLIENT_ID|AZURE_APP_REGISTRATIONS_CONFIGURED')
        $values.Count | Should Be 8
        $content = [System.IO.File]::ReadAllText($envPath)
        $content.IndexOf('# Inputs first used by 2.') | Should BeLessThan $content.IndexOf('AZURE_RESOURCE_GROUP_NAME=')
        $content.IndexOf('# Generated by 4.') | Should BeLessThan $content.IndexOf('AUTH_CLIENT_ID=')
    }

    It 'reorganizes legacy configuration without changing values, quoting, or custom comments and remains stable' {
        [System.IO.File]::WriteAllText($envPath, @'
# My configuration
AUTH_CLIENT_ID='auth-id' # keep inline
# A custom note
AZURE_APIM_NAME="test-apim"
ATLASSIAN_MCP_CLIENT_SECRET='literal $value # \secret'
EXTRA='leave alone' # custom input
AUTH_APP_NAME='Sign-in'
'@)
        $before = Read-PrerequisiteEnv -Path $envPath
        Update-PrerequisiteEnv -Path $envPath -Values @{}
        $after = Read-PrerequisiteEnv -Path $envPath
        $after.Count | Should Be $before.Count
        foreach ($key in $before.Keys) { $after[$key] | Should BeExactly $before[$key] }
        $content = [System.IO.File]::ReadAllText($envPath)
        $content.Contains("AUTH_CLIENT_ID='auth-id' # keep inline") | Should Be $true
        $content.Contains('# My configuration') | Should Be $true
        $content.Contains('# A custom note') | Should Be $true
        $content.Contains("EXTRA='leave alone' # custom input") | Should Be $true
        $content.IndexOf('EXTRA=') | Should BeLessThan $content.IndexOf('# Script-generated values')
        $content.IndexOf('AUTH_APP_NAME=') | Should BeLessThan $content.IndexOf('# Script-generated values')
        $content.IndexOf('# Script-generated values') | Should BeLessThan $content.IndexOf('ATLASSIAN_MCP_CLIENT_SECRET=')
        Update-PrerequisiteEnv -Path $envPath -Values @{}
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $content
    }

    It 'stops without replacing configuration when the layout template is missing or malformed' {
        $layoutTemplateOverride = Join-Path $TestDrive 'missing-template.env'
        $original = 'AZURE_APIM_NAME="original"'
        [System.IO.File]::WriteAllText($envPath, $original)
        Mock Join-Path { $layoutTemplateOverride } -ParameterFilter { $ChildPath -eq '..\.env.v1.example' -and $null -ne $layoutTemplateOverride }
        { Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_NAME = 'new' } } | Should Throw 'template .env.v1.example is missing'
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $original
        [System.IO.File]::WriteAllText($layoutTemplateOverride, "DUPLICATE=`"`"`nDUPLICATE=`"`"")
        { Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_NAME = 'new' } } | Should Throw 'Duplicate .env key'
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $original
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.env.*.tmp').Count | Should Be 0
    }

    It 'preserves the original and cleans up temporary files when replacement is blocked' {
        [System.IO.File]::WriteAllText($envPath, 'KEY=original')
        $handle = [System.IO.File]::Open($envPath, 'Open', 'Read', 'Read')
        try {
            { Update-PrerequisiteEnv -Path $envPath -Values @{ KEY = 'replacement' } } | Should Throw 'Replace'
        } finally { $handle.Dispose() }
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly 'KEY=original'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.env.*.tmp').Count | Should Be 0
    }

    It 'rejects malformed input and unsupported escapes without revealing its contents' {
        foreach ($invalid in @('not-an-assignment', 'SECRET="unterminated', 'SECRET="bad\q"')) {
            [System.IO.File]::WriteAllText($envPath, $invalid)
            { Read-PrerequisiteEnv -Path $envPath } | Should Throw 'line 1'
        }
    }

    It 'retries a transient file lock and completes the atomic replacement' {
        [System.IO.File]::WriteAllText($envPath, 'KEY=original')
        $handle = [System.IO.File]::Open($envPath, 'Open', 'Read', 'Read')
        $unlockHandle = $handle
        Mock Start-Sleep { $unlockHandle.Dispose() } -ParameterFilter { $null -ne $unlockHandle }
        try {
            Update-PrerequisiteEnv -Path $envPath -Values @{ KEY = 'replacement' }
        } finally { $handle.Dispose() }
        (Read-PrerequisiteEnv -Path $envPath)['KEY'] | Should BeExactly 'replacement'
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Milliseconds -eq 100 }
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.env.*.tmp').Count | Should Be 0
    }

    It 'rejects invalid keys before writing' {
        { Update-PrerequisiteEnv -Path $envPath -Values @{ 'BAD-KEY' = 'value' } } | Should Throw 'Invalid .env key'
        Test-Path -LiteralPath $envPath | Should Be $false
    }

    It 'resolves explicit parameters before saved values before defaults' {
        $arguments = @{ ParameterName = 'Name'; Key = 'NAME'; DefaultValue = 'default' }
        Resolve-PrerequisiteValue @arguments -Parameters @{ Name = 'explicit' } -Values @{ NAME = 'saved' } | Should Be 'explicit'
        Resolve-PrerequisiteValue @arguments -Parameters @{} -Values @{ NAME = 'saved' } | Should Be 'saved'
        Resolve-PrerequisiteValue @arguments -Parameters @{} -Values @{ NAME = '' } | Should Be 'default'
        Resolve-PrerequisiteValue @arguments -Parameters @{ Name = '' } -Values @{ NAME = 'saved' } | Should BeExactly ''
    }
}

# Provide a mockable command even on machines without the optional Az module.
function Set-AzKeyVaultSecret {
    param($VaultName, $Name, $SecretValue)
    throw 'Unexpected live Key Vault call.'
}

Describe 'Registration shared configuration flow' {
    BeforeEach {
        $envPath = Join-Path $TestDrive 'registration.env'
        if (Test-Path -LiteralPath $envPath) { Remove-Item -LiteralPath $envPath }
        $state = @{ Body = $null; Token = 'test-registration-token'; FailVault = $false; FailRegistration = $false; FailSave = $false }
        Mock Invoke-RestMethod {
            if ($Method -eq 'Post') {
                if ($state.FailRegistration) { throw 'Registration failed for test' }
                if ($state.FailSave) { $null = [System.IO.Directory]::CreateDirectory($envPath) }
                $state.Body = $Body | ConvertFrom-Json
                return [pscustomobject]@{
                    client_id = 'test-client'
                    client_secret = 'test-secret'
                    registration_access_token = $state.Token
                }
            }
            if ($Uri -like '*oauth-protected-resource*') {
                return [pscustomobject]@{
                    authorization_servers = @('https://issuer.example')
                    scopes_supported = @('read:account', 'offline_access', 'read:me')
                    resource = 'https://mcp.example'
                }
            }
            return [pscustomobject]@{
                token_endpoint = 'https://issuer.example/token'
                authorization_endpoint = 'https://issuer.example/authorize'
                registration_endpoint = 'https://issuer.example/register'
                token_endpoint_auth_methods_supported = @('client_secret_post')
            }
        }
        Mock Set-AzKeyVaultSecret {
            if ($state.FailVault) { throw 'Vault unavailable for test' }
            $saved = Read-PrerequisiteEnv -Path $envPath
            $saved['ATLASSIAN_MCP_CLIENT_SECRET'] | Should BeExactly 'test-secret'
        }
        Mock Set-Clipboard { throw 'Clipboard must not be used.' }
    }

    It 'uses saved inputs from another directory and saves and prints registration outputs' {
        Update-PrerequisiteEnv -Path $envPath -Values @{
            AZURE_APIM_NAME = 'saved-apim'
            ATLASSIAN_MCP_SCOPES = 'read:account offline_access'
            OTHER_PREREQUISITE = 'preserved'
        }
        Push-Location $TestDrive
        try {
            $output = & $registrationScript -EnvFile (Split-Path $envPath -Leaf) 6>&1 | Out-String
        } finally { Pop-Location }
        $expected = 'https://authorization-manager.consent.azure-apim.net/redirect/apim/saved-apim'
        $state.Body.redirect_uris[0] | Should BeExactly $expected
        $state.Body.client_name | Should BeExactly 'Atlassian MCP Client'
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['ATLASSIAN_MCP_CLIENT_ID'] | Should BeExactly 'test-client'
        $saved['ATLASSIAN_MCP_CLIENT_SECRET'] | Should BeExactly 'test-secret'
        $saved['ATLASSIAN_MCP_REGISTRATION_ACCESS_TOKEN'] | Should BeExactly 'test-registration-token'
        $saved['ATLASSIAN_MCP_REDIRECT_URI'] | Should BeExactly $expected
        $saved['OTHER_PREREQUISITE'] | Should BeExactly 'preserved'
        $output.Contains('ATLASSIAN_MCP_CLIENT_SECRET="test-secret"') | Should Be $true
        Assert-MockCalled Set-AzKeyVaultSecret -Times 0 -Exactly -Scope It
        Assert-MockCalled Set-Clipboard -Times 0 -Exactly -Scope It
    }

    It 'applies explicit overrides and persists them with normalized scopes' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_NAME = 'old-apim'; ATLASSIAN_MCP_CLIENT_NAME = 'old-name' }
        $null = & $registrationScript -EnvFile $envPath -ApimName 'new-apim' -ClientName 'new-name' -Scopes 'offline_access' 6>&1 3>&1
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['AZURE_APIM_NAME'] | Should BeExactly 'new-apim'
        $saved['ATLASSIAN_MCP_CLIENT_NAME'] | Should BeExactly 'new-name'
        $saved['ATLASSIAN_MCP_SCOPES'] | Should BeExactly 'read:account offline_access'
    }

    It 'fails before network calls when required inputs are missing' {
        { & $registrationScript -EnvFile $envPath } | Should Throw 'APIM instance name is required'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    It 'fails before network calls for malformed configuration' {
        [System.IO.File]::WriteAllText($envPath, 'SECRET="unterminated')
        { & $registrationScript -EnvFile $envPath -ApimName 'test-apim' } | Should Throw 'line 1'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
    }

    It 'blocks accidental re-registration before network calls' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_NAME = 'test-apim'; ATLASSIAN_MCP_CLIENT_ID = 'existing' }
        { & $registrationScript -EnvFile $envPath } | Should Throw '-ForceRegistration'
        Assert-MockCalled Invoke-RestMethod -Times 0 -Exactly -Scope It
        (Read-PrerequisiteEnv -Path $envPath)['ATLASSIAN_MCP_CLIENT_ID'] | Should BeExactly 'existing'
    }

    It 'replaces credentials only when forced and clears a stale registration token' {
        Update-PrerequisiteEnv -Path $envPath -Values @{
            AZURE_APIM_NAME = 'test-apim'
            ATLASSIAN_MCP_CLIENT_ID = 'existing'
            ATLASSIAN_MCP_REGISTRATION_ACCESS_TOKEN = 'stale'
        }
        $state.Token = $null
        $null = & $registrationScript -EnvFile $envPath -ForceRegistration -Scopes 'read:account offline_access' 6>&1 3>&1
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['ATLASSIAN_MCP_CLIENT_ID'] | Should BeExactly 'test-client'
        $saved['ATLASSIAN_MCP_REGISTRATION_ACCESS_TOKEN'] | Should BeExactly ''
    }

    It 'preserves configuration if registration fails' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_NAME = 'test-apim'; ATLASSIAN_MCP_CLIENT_ID = 'existing' }
        $before = [System.IO.File]::ReadAllText($envPath)
        $state.FailRegistration = $true
        { & $registrationScript -EnvFile $envPath -ForceRegistration -Scopes 'read:account offline_access' 6>$null } | Should Throw 'Registration failed for test'
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $before
    }

    It 'saves and prints credentials before also storing them in Key Vault' {
        $output = & $registrationScript -EnvFile $envPath -ApimName 'test-apim' -KeyVaultName 'test-vault' -Scopes 'read:account offline_access' 6>&1 | Out-String
        Assert-MockCalled Set-AzKeyVaultSecret -Times 3 -Exactly -Scope It
        $output.Contains('ATLASSIAN_MCP_CLIENT_SECRET="test-secret"') | Should Be $true
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_KEY_VAULT_NAME'] | Should BeExactly 'test-vault'
    }

    It 'keeps registered credentials locally when Key Vault fails and surfaces the error' {
        $state.FailVault = $true
        { & $registrationScript -EnvFile $envPath -ApimName 'test-apim' -KeyVaultName 'test-vault' -Scopes 'read:account offline_access' 6>$null } | Should Throw 'Vault unavailable for test'
        (Read-PrerequisiteEnv -Path $envPath)['ATLASSIAN_MCP_CLIENT_SECRET'] | Should BeExactly 'test-secret'
    }

    It 'surfaces a local persistence failure and never proceeds to Key Vault' {
        $state.FailSave = $true
        { & $registrationScript -EnvFile $envPath -ApimName 'test-apim' -KeyVaultName 'test-vault' -Scopes 'read:account offline_access' 6>$null } | Should Throw 'ReadAllLines'
        Assert-MockCalled Invoke-RestMethod -Times 1 -Exactly -Scope It -ParameterFilter { $Method -eq 'Post' }
        Assert-MockCalled Set-AzKeyVaultSecret -Times 0 -Exactly -Scope It
    }

    It 'allows an explicit empty vault name to disable a saved vault' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_NAME = 'test-apim'; AZURE_KEY_VAULT_NAME = 'saved-vault' }
        $null = & $registrationScript -EnvFile $envPath -KeyVaultName '' -Scopes 'read:account offline_access' 6>&1
        Assert-MockCalled Set-AzKeyVaultSecret -Times 0 -Exactly -Scope It
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_KEY_VAULT_NAME'] | Should BeExactly ''
    }
}
