$prerequisiteRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $prerequisiteRoot 'Common.ps1')
$providerScript = Join-Path $prerequisiteRoot '3.Configure-APIM-Credential-Provider\Configure-ApimCredentialProvider.ps1'

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live Azure CLI call.'
}
$credentialAzCommand = Get-Command az

Describe 'APIM credential provider prerequisite' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $envPath = Join-Path $TestDrive 'credential.env'
        if (Test-Path -LiteralPath $envPath) { Remove-Item -LiteralPath $envPath }
        $subscriptionId = '11111111-1111-1111-1111-111111111111'
        $resourceId = "/subscriptions/$subscriptionId/resourceGroups/test-rg/providers/Microsoft.ApiManagement/service/test-apim"
        $providerId = "$resourceId/authorizationProviders/atlassian"
        $redirectUrl = 'https://authorization-manager.consent.azure-apim.net/redirect/apim/test-apim'
        $secret = 'test-secret-"quoted"\backslash%percent'
        Update-PrerequisiteEnv -Path $envPath -Values @{
            AZURE_APIM_NAME = 'test-apim'
            AZURE_RESOURCE_GROUP_NAME = 'test-rg'
            AZURE_SUBSCRIPTION_ID = $subscriptionId
            AZURE_APIM_RESOURCE_ID = $resourceId
            AZURE_APIM_IDENTITY_PRINCIPAL_ID = 'preserve-principal'
            AZURE_APIM_CREDENTIAL_PROVIDER_ID = 'stale-provider-id'
            ATLASSIAN_MCP_CLIENT_ID = 'test-client'
            ATLASSIAN_MCP_CLIENT_SECRET = $secret
            ATLASSIAN_MCP_AUTHORIZATION_URL = 'https://auth.atlassian.com/authorize'
            ATLASSIAN_MCP_TOKEN_URL = 'https://auth.atlassian.com/oauth/token'
            ATLASSIAN_MCP_ENDPOINT = 'https://mcp.atlassian.com/v1/mcp/authv2'
            ATLASSIAN_MCP_SERVER_URL = 'https://mcp.atlassian.com'
            ATLASSIAN_MCP_REDIRECT_URI = $redirectUrl
            ATLASSIAN_MCP_SCOPES = 'read:account read:me offline_access'
        }
        $expected = [pscustomobject]@{
            id = $providerId
            properties = [pscustomobject]@{
                displayName = 'atlassian'
                identityProvider = 'oauth2pkcewithdcr'
                oauth2 = [pscustomobject]@{
                    redirectUrl = $redirectUrl
                    grantTypes = [pscustomobject]@{
                        authorizationCode = [pscustomobject]@{
                            authorizationUrl = 'https://auth.atlassian.com/authorize'
                            clientId = 'test-client'
                            refreshUrl = 'https://auth.atlassian.com/oauth/token'
                            scopes = 'read:account read:me offline_access'
                            serverUrl = 'https://mcp.atlassian.com/v1/mcp/authv2'
                            tokenUrl = 'https://auth.atlassian.com/oauth/token'
                        }
                    }
                }
            }
        }
        $state = @{
            Existing = $null
            ResponseProvider = $expected
            Publish = $true
            Written = $false
            DelayedReads = 0
            FailMethod = ''
            FailureOutput = ''
            FailVerification = $false
            RawResponse = $null
            CliMissing = $false
            CliBatch = $false
            Paginate = $false
            NextLink = ''
            Calls = [System.Collections.Generic.List[object]]::new()
            Body = $null
            BodyPath = ''
        }
        Mock Get-Command {
            if (-not $state.CliMissing) {
                if ($state.CliBatch) {
                    [pscustomobject]@{ CommandType = 'Application'; Source = 'C:\test\az.cmd' }
                } else { $credentialAzCommand }
            }
        } -ParameterFilter { $Name -eq 'az' }
        Mock Start-Sleep {} -ParameterFilter { $Seconds -gt 0 }
        Mock az {
            $state.Calls.Add($Arguments)
            $global:LASTEXITCODE = 0
            $method = $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
            $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1].Trim('"')
            if ($method -eq 'put') {
                $bodyArgument = $Arguments[[Array]::IndexOf($Arguments, '--body') + 1]
                if (-not $bodyArgument.StartsWith('@')) { throw 'Expected a request body file, not inline credentials.' }
                $state.BodyPath = $bodyArgument.Substring(1)
                $state.Body = [System.IO.File]::ReadAllText($state.BodyPath) | ConvertFrom-Json
                if ((Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] -cne '') {
                    throw 'Stale provider ID must be cleared before a write.'
                }
            }
            if ($state.FailMethod -eq $method -or ($state.FailVerification -and $state.Written -and $method -eq 'get')) {
                $global:LASTEXITCODE = 1
                if ($state.FailureOutput) { return $state.FailureOutput }
                return "ERROR: (AuthorizationFailed) echo of test credentials: $secret"
            }
            if ($method -eq 'put') {
                $state.Written = $true
                if ($state.Publish) { $state.Existing = $state.ResponseProvider }
                return
            }
            if ($method -ne 'get') { throw "Unexpected method: $method" }
            if ($null -ne $state.RawResponse) { return $state.RawResponse }
            if ($state.Written -and $state.DelayedReads -gt 0) {
                $state.DelayedReads--
                return '{"value":[]}'
            }
            if ($state.NextLink) {
                return (ConvertTo-Json -InputObject @{ value = @(); nextLink = $state.NextLink })
            }
            if ($state.Paginate -and $url -notlike '*skiptoken=*') {
                return (ConvertTo-Json -InputObject @{ value = @(); nextLink = "$url&%24skipToken=page2%3D%3D" })
            }
            $providers = @()
            if ($state.Existing) { $providers = @($state.Existing) }
            return (ConvertTo-Json -InputObject @{ value = $providers } -Depth 10)
        }
    }

    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
    }

    It 'creates the exact PKCE DCR payload using saved inputs and persists only verified outputs' {
        Push-Location $TestDrive
        try { $output = & $providerScript -EnvFile '.\credential.env' 6>&1 }
        finally { Pop-Location }
        $state.Written | Should Be $true
        $state.Body.properties.identityProvider | Should BeExactly 'oauth2pkcewithdcr'
        $state.Body.properties.displayName | Should BeExactly 'atlassian'
        $state.Body.properties.oauth2.redirectUrl | Should BeExactly $redirectUrl
        $code = $state.Body.properties.oauth2.grantTypes.authorizationCode
        @($code.PSObject.Properties).Count | Should Be 7
        $code.clientSecret | Should BeExactly $secret
        foreach ($field in $expected.properties.oauth2.grantTypes.authorizationCode.PSObject.Properties) {
            $code.($field.Name) | Should BeExactly $field.Value
        }
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly $providerId
        $saved['AZURE_APIM_CREDENTIAL_PROVIDER_NAME'] | Should BeExactly 'atlassian'
        $saved['AZURE_APIM_IDENTITY_PRINCIPAL_ID'] | Should BeExactly 'preserve-principal'
        $saved['ATLASSIAN_MCP_CLIENT_SECRET'] | Should BeExactly $secret
        Test-Path -LiteralPath $state.BodyPath | Should Be $false
        ($output -join "`n").Contains($secret) | Should Be $false
        foreach ($call in $state.Calls) {
            $call -contains '--subscription' | Should Be $true
            $call -contains $subscriptionId | Should Be $true
            ($call -join ' ').Contains($secret) | Should Be $false
            $call -contains '--only-show-errors' | Should Be $true
        }
        Assert-MockCalled az -Times 1 -Exactly -Scope It -ParameterFilter {
            $Arguments -contains 'put' -and $Arguments -contains 'none' -and
            $Arguments -contains 'Content-Type=application/json' -and
            $Arguments -notcontains 'If-Match=*'
        }
    }

    It 'uses a saved provider name unless explicitly overridden' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_CREDENTIAL_PROVIDER_NAME = 'saved-provider' }
        $expected.id = "$resourceId/authorizationProviders/saved-provider"
        $expected.properties.displayName = 'saved-provider'
        $state.Existing = $expected
        $null = & $providerScript -EnvFile $envPath 6>&1
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_NAME'] | Should BeExactly 'saved-provider'
        $expected.id = "$resourceId/authorizationProviders/explicit-provider"
        $expected.properties.displayName = 'explicit-provider'
        $null = & $providerScript -EnvFile $envPath -ProviderName 'explicit-provider' 6>&1
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly $expected.id
        $state.Written | Should Be $false
    }

    It 'reuses matching public settings on repeated runs without writing or needing a returned secret' {
        $state.Existing = $expected
        $expected.properties.oauth2.grantTypes.authorizationCode.scopes = "offline_access  read:me`nread:account"
        $null = & $providerScript -EnvFile $envPath 6>&1
        $null = & $providerScript -EnvFile $envPath 6>&1
        Assert-MockCalled az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments -contains 'put' }
        $state.BodyPath | Should BeExactly ''
    }

    It 'requires explicit approval for differences without revealing field values' {
        $state.Existing = $expected
        $expected.properties.oauth2.grantTypes.authorizationCode.clientId = 'different-sensitive-client'
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'rerun with -UpdateExisting'
        $state.Written | Should Be $false
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly ''
    }

    It 'rejects a different identity provider or grant configuration' {
        $state.Existing = $expected
        $expected.properties.identityProvider = 'oauth2'
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'identityProvider'
        $expected.properties.identityProvider = 'oauth2pkcewithdcr'
        $expected.properties.oauth2.grantTypes | Add-Member -NotePropertyName clientCredentials -NotePropertyValue @{ clientId = 'other' }
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'clientCredentials'
        $state.Written | Should Be $false
    }

    It 'writes the secret with If-Match when explicitly updating even if public settings match' {
        $state.Existing = $expected
        $null = & $providerScript -EnvFile $envPath -UpdateExisting 6>&1
        $state.Body.properties.oauth2.grantTypes.authorizationCode.clientSecret | Should BeExactly $secret
        Assert-MockCalled az -Times 1 -Exactly -Scope It -ParameterFilter {
            $Arguments -contains 'put' -and $Arguments -contains 'If-Match=*'
        }
        Test-Path -LiteralPath $state.BodyPath | Should Be $false
    }

    It 'allows deliberate updates of mismatching public settings and verifies the result' {
        $state.Existing = $expected | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $state.Existing.properties.oauth2.grantTypes.authorizationCode.tokenUrl = 'https://example.test/old-token'
        $null = & $providerScript -EnvFile $envPath -UpdateExisting 6>&1
        $state.Written | Should Be $true
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly $providerId
    }

    It 'finds providers on later pages rather than creating duplicates' {
        $state.Paginate = $true
        $state.Existing = $expected
        $null = & $providerScript -EnvFile $envPath 6>&1
        $state.Written | Should Be $false
        $state.Calls.Count | Should Be 2
        foreach ($call in $state.Calls) {
            $call[[Array]::IndexOf($call, '--url') + 1].StartsWith('"') | Should Be $false
        }
    }

    It 'quotes the complete pagination URL for the Windows batch launcher' {
        $state.CliBatch = $true
        $state.Paginate = $true
        $state.Existing = $expected
        $null = & $providerScript -EnvFile $envPath 6>&1
        $state.Written | Should Be $false
        $state.Calls.Count | Should Be 2
        foreach ($call in $state.Calls) {
            $urlArgument = $call[[Array]::IndexOf($call, '--url') + 1]
            $urlArgument.StartsWith('"') | Should Be $true
            $urlArgument.EndsWith('"') | Should Be $true
        }
        $nextCall = $state.Calls[1]
        $nextCall[[Array]::IndexOf($nextCall, '--url') + 1] | Should Match '&%24skipToken=page2%3D%3D"$'
    }

    It 'identifies Windows parsing failures without exposing command output' {
        $state.FailMethod = 'get'
        $state.FailureOutput = "$secret`n'%24skipToken' is not recognized as an internal or external command"
        $errorMessage = ''
        try { $null = & $providerScript -EnvFile $envPath 6>&1 } catch { $errorMessage = $_.Exception.Message }
        $errorMessage | Should Match 'Windows command parsing failed'
        $errorMessage.Contains($secret) | Should Be $false
        $state.Written | Should Be $false
    }

    It 'rejects untrusted and repeated pagination links' {
        $state.NextLink = 'https://example.test/next'
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'unexpected credential provider pagination URL'
        $state.NextLink = "https://management.azure.com$resourceId/authorizationProviders?api-version=2024-05-01"
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'repeated credential provider pagination link'
        $state.Written | Should Be $false
    }

    It 'never treats a failed read as a missing provider and withholds echoed credentials' {
        $state.FailMethod = 'get'
        $errorMessage = ''
        try { $null = & $providerScript -EnvFile $envPath 6>&1 } catch { $errorMessage = $_.Exception.Message }
        $errorMessage | Should Match 'AuthorizationFailed'
        $errorMessage.Contains($secret) | Should Be $false
        $state.Written | Should Be $false
        $state.BodyPath | Should BeExactly ''
    }

    It 'removes the temporary secret file on write failure and does not save a success ID' {
        $state.FailMethod = 'put'
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'credential provider put failed'
        Test-Path -LiteralPath $state.BodyPath | Should Be $false
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.env.*.request.json' -Force).Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly ''
    }

    It 'retries delayed visibility with the bounded backoff' {
        $state.DelayedReads = 3
        $null = & $providerScript -EnvFile $envPath 6>&1
        foreach ($delay in @(2, 4, 8)) {
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Seconds -eq $delay }
        }
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly $providerId
    }

    It 'fails verification when Azure never returns the provider' {
        $state.Publish = $false
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'settings could not be verified'
        $state.Calls.Count | Should Be 6
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly ''
        Test-Path -LiteralPath $state.BodyPath | Should Be $false
    }

    It 'keeps the ID empty and cleans up credentials if verification reads fail' {
        $state.FailVerification = $true
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'credential provider get failed'
        $state.Written | Should Be $true
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly ''
        Test-Path -LiteralPath $state.BodyPath | Should Be $false
    }

    It 'fails verification when Azure returns different settings or a different resource' {
        $expected.properties.oauth2.grantTypes.authorizationCode.serverUrl = 'https://example.test/wrong'
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'settings could not be verified'
        $expected.id = "$resourceId/authorizationProviders/another-provider"
        $state.Existing = $null
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'settings could not be verified'
    }

    It 'rejects malformed, empty and unexpected read responses' {
        foreach ($response in @('', 'invalid JSON', 'null')) {
            $state.RawResponse = $response
            { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'invalid or empty JSON'
        }
        foreach ($response in @('{}', '{"value":null}', '{"value":{}}', '{"value":"invalid"}')) {
            $state.RawResponse = $response
            { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'unexpected credential provider collection'
        }
        $state.Written | Should Be $false
    }

    It 'requires each registration input before any Azure call' {
        foreach ($key in @('ATLASSIAN_MCP_CLIENT_ID', 'ATLASSIAN_MCP_CLIENT_SECRET',
            'ATLASSIAN_MCP_AUTHORIZATION_URL', 'ATLASSIAN_MCP_TOKEN_URL',
            'ATLASSIAN_MCP_ENDPOINT', 'ATLASSIAN_MCP_SCOPES', 'ATLASSIAN_MCP_REDIRECT_URI')) {
            $original = (Read-PrerequisiteEnv -Path $envPath)[$key]
            Update-PrerequisiteEnv -Path $envPath -Values @{ $key = '' }
            { & $providerScript -EnvFile $envPath 6>$null } | Should Throw "Missing $key"
            Update-PrerequisiteEnv -Path $envPath -Values @{ $key = $original }
        }
        $state.Calls.Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] | Should BeExactly 'stale-provider-id'
    }

    It 'rejects missing or unsafe target inputs including an explicit empty override' {
        { & $providerScript -EnvFile $envPath -ApimName '' 6>$null } | Should Throw 'Supply -ApimName'
        { & $providerScript -EnvFile $envPath -ApimName 'https://wrong.test' 6>$null } | Should Throw 'Invalid APIM'
        { & $providerScript -EnvFile $envPath -SubscriptionId 'display-name' 6>$null } | Should Throw 'subscription GUID'
        { & $providerScript -EnvFile $envPath -ResourceGroupName '../other' 6>$null } | Should Throw 'resource group name'
        { & $providerScript -EnvFile $envPath -ProviderName 'bad/name' 6>$null } | Should Throw 'ProviderName must'
        $state.Calls.Count | Should Be 0
    }

    It 'rejects invalid endpoint schemes, embedded credentials and fragments' {
        foreach ($key in @('ATLASSIAN_MCP_AUTHORIZATION_URL', 'ATLASSIAN_MCP_TOKEN_URL', 'ATLASSIAN_MCP_ENDPOINT')) {
            $original = (Read-PrerequisiteEnv -Path $envPath)[$key]
            foreach ($url in @('http://example.test', 'https://user:password@example.test', 'https://example.test/#fragment', 'relative-url')) {
                Update-PrerequisiteEnv -Path $envPath -Values @{ $key = $url }
                { & $providerScript -EnvFile $envPath 6>$null } | Should Throw "$key must be an absolute HTTPS URL"
            }
            Update-PrerequisiteEnv -Path $envPath -Values @{ $key = $original }
        }
        $state.Calls.Count | Should Be 0
    }

    It 'blocks cross-APIM identity and OAuth callback reuse' {
        { & $providerScript -EnvFile $envPath -ResourceGroupName 'other-rg' 6>$null } | Should Throw 'identity details belong to another resource'
        Update-PrerequisiteEnv -Path $envPath -Values @{ ATLASSIAN_MCP_REDIRECT_URI = "$redirectUrl-other" }
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'does not match the selected APIM callback'
        $state.Calls.Count | Should Be 0
    }

    It 'requires Azure CLI without attempting automatic login' {
        $state.CliMissing = $true
        { & $providerScript -EnvFile $envPath 6>$null } | Should Throw 'Azure CLI is required'
        $state.Calls.Count | Should Be 0
    }
}

Describe 'Credential provider Windows native argument handling' {
    It 'preserves ampersands and encoded skip tokens through a real cmd launcher' -Skip:($env:OS -ne 'Windows_NT') {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($providerScript, [ref]$tokens, [ref]$parseErrors)
        $requestFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Invoke-CredentialProviderRequest'
        }, $true)
        . ([scriptblock]::Create($requestFunction.Extent.Text))
        $fixture = Join-Path $PSScriptRoot 'Fixtures\Echo-AzureCliUrl.cmd'
        $azureCliCommand = Get-Command $fixture
        $SubscriptionId = '11111111-1111-1111-1111-111111111111'
        $url = 'https://management.azure.com/test?api-version=2024-05-01&%24skipToken=page2%3d%3d'
        $previousAlias = Get-Alias az -ErrorAction SilentlyContinue
        $previousExitCode = $global:LASTEXITCODE
        try {
            Set-Alias -Name az -Value $fixture -Scope Local
            $result = Invoke-CredentialProviderRequest -Method get -Url $url
            $result.url | Should BeExactly $url
        } finally {
            if ($previousAlias) {
                Set-Alias -Name az -Value $previousAlias.Definition -Scope Local
            } else {
                Remove-Item Alias:\az
            }
            $global:LASTEXITCODE = $previousExitCode
        }
    }
}
