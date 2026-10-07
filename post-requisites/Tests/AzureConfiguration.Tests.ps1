. (Join-Path $PSScriptRoot 'TestHelpers.ps1')
$oauthScript = Join-Path $postRoot '1.Configure-Bot-OAuth\Configure-BotOAuth.ps1'
$configureScript = Join-Path $postRoot '2.Configure-M365-Endpoint\Enable-M365Publishing.ps1'

Describe 'Bot OAuth and M365 endpoint configuration' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $state = New-TestDeployment -Root $TestDrive
        $envPath = $state.EnvPath
        Mock Get-Command { $testAzCommand } -ParameterFilter { $Name -eq 'az' }
        Mock Start-Sleep {}
        Mock az {
            $global:LASTEXITCODE = 0
            if ($Arguments[0] -eq 'account') {
                return ConvertTo-Json @{ tenantId = $state.AccountTenant; environmentName = 'AzureCloud' }
            }
            if ($Arguments[0] -eq 'bot') { return ConvertTo-Json $state.Provider -Depth 30 }
            if ($Arguments[0] -ne 'rest') { throw 'Unexpected CLI command.' }
            $method = $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
            $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1].Trim('"')
            $body = $null
            if ($Arguments -contains '--body') {
                $path = $Arguments[[Array]::IndexOf($Arguments, '--body') + 1].Trim('"').Substring(1)
                $state.BodyPaths.Add($path)
                $body = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
            }
            $state.Calls.Add([pscustomobject]@{ Method = $method; Url = $url; Body = $body; Arguments = $Arguments })
            if ($state.ErrorMethod -eq $method) {
                $global:LASTEXITCODE = 1
                return 'ERROR: (Forbidden) must-not-be-printed'
            }
            if ($state.InvalidJson) { return 'invalid-json must-not-be-printed' }
            if ($method -eq 'GET') {
                if ($url -like '*/channels[?]*') {
                    return ConvertTo-Json @{ value = @($state.Channels); nextLink = $state.NextLink } -Depth 30
                }
                if ($url -like '*/connections[?]*') {
                    $state.ListingCount++
                    if ($state.ListingCount -gt 1 -and $state.Appearance) { $state.Connections = @($state.Appearance) }
                    $summaries = @(foreach ($connection in $state.Connections) {
                        @{ id = $connection.id; name = $connection.name; properties = @{
                            serviceProviderId = $connection.properties.serviceProviderId
                            provisioningState = 'Succeeded'
                        } }
                    })
                    return ConvertTo-Json @{ value = $summaries; nextLink = $state.ConnectionNextLink } -Depth 30
                }
                if ($url -like '*/connections/*') {
                    if ($state.ReadBackDelay -gt 0) {
                        $state.ReadBackDelay--
                        return '{"id":"not-yet-visible","properties":{}}'
                    }
                    return ConvertTo-Json $state.Connections[0] -Depth 30
                }
                if ($url -like '*management.azure.com*') { return ConvertTo-Json $state.Bot -Depth 30 }
                return ConvertTo-Json $state.Agent -Depth 30
            }
            if ($method -eq 'PATCH') {
                if (-not $state.IgnoreWrites) {
                    $state.Agent.agent_endpoint | Add-Member -NotePropertyName protocol_configuration -NotePropertyValue $body.agent_endpoint.protocol_configuration -Force
                    $state.Agent.agent_endpoint | Add-Member -NotePropertyName authorization_schemes -NotePropertyValue $body.agent_endpoint.authorization_schemes -Force
                }
                return 'Updated.'
            }
            if ($method -eq 'PUT') {
                if (-not $state.IgnoreWrites) {
                    if ($url -like '*/connections/*') {
                        $properties = ConvertFrom-Json -InputObject (ConvertTo-Json $body.properties -Depth 30)
                        $properties.PSObject.Properties.Remove('clientSecret')
                        foreach ($parameter in $properties.parameters) { $parameter.key = $parameter.key.ToLowerInvariant() }
                        $properties.parameters += @(
                            [pscustomobject]@{ key = 'clientId'; value = $properties.clientId },
                            [pscustomobject]@{ key = 'clientSecret'; value = $null },
                            [pscustomobject]@{ key = 'scopes'; value = $properties.scopes }
                        )
                        $state.Connections = @([pscustomobject]@{
                            id = "$($state.BotId)/connections/apim-user"; name = 'apim-user'; properties = $properties })
                    } else { $state.Channels = @([pscustomobject]@{ properties = $body.properties }) }
                }
                return 'Updated.'
            }
            throw 'Unexpected REST operation.'
        }
    }
    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
        foreach ($path in $state.BodyPaths) { [IO.File]::Exists($path) | Should Be $false }
    }

    It 'creates Azure AD v2 OAuth with our sign-in app, tenant, scope and empty exchange URL' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $writes = @($state.Calls | Where-Object { $_.Method -ne 'GET' })
        $writes.Count | Should Be 1
        $write = $writes[0]
        $write.Method | Should BeExactly 'PUT'
        $write.Url | Should BeExactly "https://management.azure.com$($state.BotId)/connections/apim-user?api-version=2022-09-15"
        $write.Body.location | Should BeExactly 'global'
        $write.Body.properties.clientId | Should BeExactly '55555555-5555-5555-5555-555555555555'
        $write.Body.properties.clientSecret | Should BeExactly 'must-not-be-printed'
        ($write.Arguments -join ' ') | Should Not Match 'must-not-be-printed'
        $write.Body.properties.serviceProviderId | Should BeExactly '30dd229c-58e3-4a48-bdfd-91ec48eb906c'
        $write.Body.properties.scopes | Should BeExactly 'openid profile offline_access api://66666666-6666-6666-6666-666666666666/Mcp.Invoke'
        @($write.Body.properties.parameters | Where-Object { $_.key -eq 'TenantId' })[0].value | Should BeExactly $state.Tenant
        @($write.Body.properties.parameters | Where-Object { $_.key -eq 'TokenExchangeUrl' })[0].value | Should BeExactly ''
        [IO.File]::ReadAllText($envPath) | Should BeExactly $state.OriginalEnv
    }

    It 'reuses matching public OAuth settings without writing or claiming secret verification' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $state.Calls.Clear()
        & $oauthScript -EnvFile $envPath -Confirm:$false
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
        @($state.Calls | Where-Object { $_.Url -like '*/connections/*' -and $_.Method -eq 'GET' }).Count | Should Be 1
    }

    It 'accepts reordered scopes and an omitted empty token exchange parameter' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $connection = $state.Connections[0]
        $connection.properties.scopes = 'profile api://66666666-6666-6666-6666-666666666666/Mcp.Invoke openid offline_access'
        $connection.properties.parameters = @($connection.properties.parameters | Where-Object { $_.key -ne 'TokenExchangeUrl' })
        $state.Calls.Clear()
        & $oauthScript -EnvFile $envPath -Confirm:$false
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'accepts original provider-key casing without Azure-added mirrors' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $state.Connections[0].properties.parameters = @(
            [pscustomobject]@{ key = 'TenantId'; value = $state.Tenant },
            [pscustomobject]@{ key = 'TokenExchangeUrl'; value = '' }
        )
        $state.Calls.Clear()
        & $oauthScript -EnvFile $envPath -Confirm:$false
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'ignores unreadable secret mirrors without claiming secret verification' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $secret = @($state.Connections[0].properties.parameters | Where-Object { $_.key -eq 'clientSecret' })[0]
        $secret.value = '********'
        $state.Calls.Clear()
        & $oauthScript -EnvFile $envPath -Confirm:$false
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'rejects a conflicting Azure-added public parameter <Key>' -TestCases @(
        @{ Key = 'clientId'; Value = '77777777-7777-7777-7777-777777777777' },
        @{ Key = 'scopes'; Value = 'openid profile offline_access api://wrong/Mcp.Invoke' },
        @{ Key = 'tenantid'; Value = '77777777-7777-7777-7777-777777777777' }
    ) {
        param($Key, $Value)
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $parameter = @($state.Connections[0].properties.parameters | Where-Object { $_.key -eq $Key })[0]
        $parameter.value = $Value
        $state.Calls.Clear()
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw '-UpdateExisting'
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'rejects duplicate provider keys regardless of casing' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $state.Connections[0].properties.parameters += [pscustomobject]@{ key = 'TenantId'; value = $state.Tenant }
        $state.Calls.Clear()
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw '-UpdateExisting'
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'rejects unexpected provider parameters rather than ignoring conflicting settings' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $state.Connections[0].properties.parameters += [pscustomobject]@{ key = 'unexpected'; value = 'value' }
        $state.Calls.Clear()
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw '-UpdateExisting'
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'requires UpdateExisting before clearing a configured token exchange URL' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $exchange = @($state.Connections[0].properties.parameters | Where-Object { $_.key -eq 'TokenExchangeUrl' })[0]
        $exchange.value = 'api://previous'
        $state.Calls.Clear()
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw '-UpdateExisting'
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'requires UpdateExisting for conflicting OAuth settings' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $state.Connections[0].properties.clientId = '77777777-7777-7777-7777-777777777777'
        $state.Calls.Clear()
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw '-UpdateExisting'
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
        & $oauthScript -EnvFile $envPath -UpdateExisting -Confirm:$false
        $state.Connections[0].properties.clientId | Should BeExactly '55555555-5555-5555-5555-555555555555'
    }

    It 'reapplies the secret only when UpdateExisting is supplied' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $state.Calls.Clear()
        & $oauthScript -EnvFile $envPath -UpdateExisting -Confirm:$false
        @($state.Calls | Where-Object { $_.Method -eq 'PUT' }).Count | Should Be 1
    }

    It 'supports OAuth WhatIf without a write or secret body file' {
        & $oauthScript -EnvFile $envPath -WhatIf
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
        $state.BodyPaths.Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $state.OriginalEnv
    }

    It 'requires OAuth input <Key> before calling Azure' -TestCases @(
        @{ Key = 'AUTH_CLIENT_ID' }, @{ Key = 'AUTH_CLIENT_SECRET' },
        @{ Key = 'AZURE_TENANT_ID' }, @{ Key = 'APIM_SCOPE' },
        @{ Key = 'AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME' }
    ) {
        param($Key)
        Update-PrerequisiteEnv -Path $envPath -Values @{ $Key = '' }
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw $Key
        $state.Calls.Count | Should Be 0
    }

    It 'rejects invalid OAuth value <Key>' -TestCases @(
        @{ Key = 'AUTH_CLIENT_ID'; Value = 'not-a-guid' },
        @{ Key = 'AZURE_TENANT_ID'; Value = 'common' },
        @{ Key = 'APIM_SCOPE'; Value = 'openid api://other/Mcp.Invoke' },
        @{ Key = 'AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME'; Value = 'bad/name' }
    ) {
        param($Key, $Value)
        Update-PrerequisiteEnv -Path $envPath -Values @{ $Key = $Value }
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw $Key
        $state.Calls.Count | Should Be 0
    }

    It 'rejects a configured tenant different from the verified bot tenant' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_TENANT_ID = '77777777-7777-7777-7777-777777777777' }
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw 'does not match the deployed bot tenant'
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'does not overwrite an OAuth connection that appeared during confirmation' {
        $state.Appearance = [pscustomobject]@{ id = "$($state.BotId)/connections/apim-user"; name = 'apim-user'; properties = @{} }
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw 'appeared after confirmation'
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'refuses duplicate matching OAuth connections' {
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $state.Connections += $state.Connections[0]
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw 'multiple matching OAuth'
    }

    It 'polls public OAuth read-back without repeating the write' {
        $state.ReadBackDelay = 2
        & $oauthScript -EnvFile $envPath -Confirm:$false
        @($state.Calls | Where-Object { $_.Method -eq 'PUT' }).Count | Should Be 1
        @($state.Calls | Where-Object { $_.Method -eq 'GET' -and $_.Url -like '*/connections/*' }).Count | Should Be 3
    }

    It 'fails explicitly when OAuth read-back never matches' {
        $state.ReadBackDelay = 10
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw 'could not be verified'
        @($state.Calls | Where-Object { $_.Method -eq 'PUT' }).Count | Should Be 1
        [IO.File]::ReadAllText($envPath) | Should BeExactly $state.OriginalEnv
    }

    It 'withholds secrets and cleans the body file after a failed OAuth PUT' {
        $state.ErrorMethod = 'PUT'
        $message = ''
        try { & $oauthScript -EnvFile $envPath -Confirm:$false } catch { $message = $_.Exception.Message }
        $message | Should Match 'Configure bot OAuth connection failed'
        $message | Should Match 'Forbidden'
        $message | Should Not Match 'must-not-be-printed'
    }

    It 'quotes OAuth URLs and file bodies for Windows az.cmd without putting the secret in arguments' {
        Mock Get-Command {
            [pscustomobject]@{ CommandType = 'Application'; Source = 'C:\Program Files\Azure CLI\az.cmd' }
        } -ParameterFilter { $Name -eq 'az' }
        & $oauthScript -EnvFile $envPath -Confirm:$false
        $put = @($state.Calls | Where-Object { $_.Method -eq 'PUT' })[0]
        $put.Arguments[[Array]::IndexOf($put.Arguments, '--url') + 1] | Should Match '^".*"$'
        $put.Arguments[[Array]::IndexOf($put.Arguments, '--body') + 1] | Should Match '^"@.*"$'
        ($put.Arguments -join ' ') | Should Not Match 'must-not-be-printed'
    }

    It 'rejects an invalid provider response' {
        $state.Provider.properties.id = 'invalid'
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw 'invalid Azure Active Directory v2'
        $state.BodyPaths.Count | Should Be 0
    }

    It 'refuses untrusted or looping OAuth pagination' -TestCases @(
        @{ Url = 'https://example.com/connections' },
        @{ Url = 'https://management.azure.com/subscriptions/wrong/connections' }
    ) {
        param($Url)
        $state.ConnectionNextLink = $Url
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw 'unexpected or repeated pagination'
        @($state.Calls | Where-Object { $_.Url -eq $Url }).Count | Should Be 0
    }

    It 'stops repeated same-bot OAuth pagination without another request' {
        $state.ConnectionNextLink = "https://management.azure.com$($state.BotId)/connections?api-version=2022-09-15"
        { & $oauthScript -EnvFile $envPath -Confirm:$false } | Should Throw 'unexpected or repeated pagination'
        @($state.Calls | Where-Object { $_.Url -eq $state.ConnectionNextLink }).Count | Should Be 1
    }

    It 'merges endpoint settings and creates only the Teams channel' {
        & $configureScript -EnvFile $envPath -Confirm:$false
        $writes = @($state.Calls | Where-Object { $_.Method -ne 'GET' })
        $writes.Count | Should Be 2
        $writes[0].Method | Should BeExactly 'PATCH'
        ($writes[0].Arguments -contains 'Content-Type=application/merge-patch+json') | Should Be $true
        $writes[0].Body.agent_endpoint.protocol_configuration.responses | Should Not Be $null
        $writes[0].Body.agent_endpoint.protocol_configuration.activity.existing | Should BeExactly 'keep'
        $writes[0].Body.agent_endpoint.authorization_schemes[0].type | Should BeExactly 'Entra'
        $writes[0].Body.agent_endpoint.authorization_schemes[1].type | Should BeExactly 'BotServiceTenant'
        $state.Agent.agent_endpoint.version_selector.marker | Should BeExactly 'keep-routing'
        $writes[1].Url | Should BeExactly "https://management.azure.com$($state.BotId)/channels/MsTeamsChannel?api-version=2022-09-15"
        $state.Bot.properties.publicNetworkAccess | Should BeExactly 'Disabled'
        Assert-PublishingReady -State (Get-PublishingState -Context (Get-PublishingContext -Parameters @{} -EnvFile $envPath))
    }

    It 'preserves existing Teams channel properties' {
        $state.Channels = @([pscustomobject]@{
            properties = @{ channelName = 'MsTeamsChannel'; properties = @{ isEnabled = $false; enableCalling = $true; callingWebhook = 'https://example.com/calls' } } })
        & $configureScript -EnvFile $envPath -Confirm:$false
        $put = @($state.Calls | Where-Object { $_.Method -eq 'PUT' })[0]
        $put.Body.properties.properties.enableCalling | Should Be $true
        $put.Body.properties.properties.callingWebhook | Should BeExactly 'https://example.com/calls'
    }

    It 'is a no-op when endpoint and channel settings already match' {
        & $configureScript -EnvFile $envPath -Confirm:$false
        $state.Calls.Clear()
        & $configureScript -EnvFile $envPath -Confirm:$false
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $state.OriginalEnv
    }

    It 'supports endpoint WhatIf without body files or writes' {
        & $configureScript -EnvFile $envPath -WhatIf
        $state.BodyPaths.Count | Should Be 0
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'refuses a bot with mismatched <Field>' -TestCases @(
        @{ Field = 'msaAppId'; Message = 'does not match' },
        @{ Field = 'msaAppTenantId'; Message = 'does not match' },
        @{ Field = 'endpoint'; Message = 'does not point' }
    ) {
        param($Field, $Message)
        $state.Bot.properties.$Field = 'mismatch'
        { & $configureScript -EnvFile $envPath -Confirm:$false } | Should Throw $Message
        @($state.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
    }

    It 'adds missing endpoint collections without changing version routing' {
        $state.Agent.agent_endpoint.PSObject.Properties.Remove('protocol_configuration')
        $state.Agent.agent_endpoint.authorization_schemes = @()
        & $configureScript -EnvFile $envPath -Confirm:$false
        $state.Agent.agent_endpoint.protocol_configuration.activity.enable_m365_public_endpoint | Should Be $true
        @($state.Agent.agent_endpoint.authorization_schemes).Count | Should Be 1
        $state.Agent.agent_endpoint.version_selector.marker | Should BeExactly 'keep-routing'
    }

    It 'accepts the activity endpoint spelling with v1' {
        $state.Bot.properties.endpoint = "$($state.Endpoint)/agents/atlassian-agent/endpoint/protocols/activity?api-version=v1"
        & $configureScript -EnvFile $envPath -Confirm:$false
    }

    It 'does not report readiness when writes were not reflected in read-back' {
        $state.IgnoreWrites = $true
        { & $configureScript -EnvFile $envPath -Confirm:$false } | Should Throw 'Publishing prerequisites are not ready'
    }

    It 'stops before Teams channel changes when the endpoint PATCH fails' {
        $state.ErrorMethod = 'PATCH'
        { & $configureScript -EnvFile $envPath -Confirm:$false } | Should Throw 'Configure Activity endpoint failed'
        @($state.Calls | Where-Object { $_.Method -eq 'PUT' }).Count | Should Be 0
    }

    It 'rejects malformed CLI JSON without dumping its contents' {
        $state.InvalidJson = $true
        { & $configureScript -EnvFile $envPath -Confirm:$false } | Should Throw 'invalid JSON'
    }

    It 'refuses untrusted channel pagination' {
        $state.NextLink = 'https://example.com/channels'
        { & $configureScript -EnvFile $envPath -Confirm:$false } | Should Throw 'unexpected pagination URL'
        @($state.Calls | Where-Object { $_.Url -like '*example.com*' }).Count | Should Be 0
    }
}
