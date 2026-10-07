$prerequisiteRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $prerequisiteRoot 'Common.ps1')
$fragmentScript = Join-Path $prerequisiteRoot '6.Create-APIM-Fragments\Configure-ApimPolicyFragments.ps1'
$apiScript = Join-Path $prerequisiteRoot '7.Create-APIM-APIandMCP\Configure-ApimApis.ps1'

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live Azure CLI call.'
}
$provisioningAzCommand = Get-Command az

Describe 'APIM fragment and external MCP provisioning' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $envPath = Join-Path $TestDrive 'provisioning.env'
        if (Test-Path -LiteralPath $envPath) { Remove-Item -LiteralPath $envPath }
        $sub = '11111111-1111-1111-1111-111111111111'
        $tenant = '22222222-2222-2222-2222-222222222222'
        $testResourceId = "/subscriptions/$sub/resourceGroups/test-rg/providers/Microsoft.ApiManagement/service/test-apim"
        $configuration = @{
            AZURE_APIM_NAME = 'test-apim'; AZURE_RESOURCE_GROUP_NAME = 'test-rg'; AZURE_SUBSCRIPTION_ID = $sub
            AZURE_TENANT_ID = $tenant; AZURE_APIM_RESOURCE_ID = $testResourceId; AZURE_APIM_NAMED_VALUES_CONFIGURED = 'true'
            AZURE_APIM_IDENTITY_PRINCIPAL_ID = '33333333-3333-3333-3333-333333333333'
            APIM_API_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
            AUTH_CLIENT_ID = '55555555-5555-5555-5555-555555555555'
            AZURE_APIM_CREDENTIAL_PROVIDER_NAME = 'atlassian'; AZURE_APIM_POLICY_ARM_API_VERSION = '2022-08-01'
            ATLASSIAN_MCP_BASE_URL = 'https://mcp.atlassian.com'; ATLASSIAN_MCP_PATH = '/v1/mcp/authv2'
            ATLASSIAN_POST_LOGIN_REDIRECT_URL = 'https://www.atlassian.com/software/jira'
            ATLASSIAN_MCP_ENDPOINT = 'https://registration.example/v1/mcp'
            ATLASSIAN_MCP_CLIENT_SECRET = 'dummy-private-secret'; AUTH_CLIENT_SECRET = 'dummy-private-auth-secret'
            UNRELATED = 'preserve'
        }
        Update-PrerequisiteEnv -Path $envPath -Values $configuration
        $mapping = @{
            'apim-api-client-id' = 'APIM_API_CLIENT_ID'; 'apim-mi-object-id' = 'AZURE_APIM_IDENTITY_PRINCIPAL_ID'
            'apim-name' = 'AZURE_APIM_NAME'; 'arm-api-version' = 'AZURE_APIM_POLICY_ARM_API_VERSION'
            'atlassian-credential-provider' = 'AZURE_APIM_CREDENTIAL_PROVIDER_NAME'
            'atlassian-mcp-base-url' = 'ATLASSIAN_MCP_BASE_URL'; 'atlassian-mcp-path' = 'ATLASSIAN_MCP_PATH'
            'atlassian-post-login-redirect-url' = 'ATLASSIAN_POST_LOGIN_REDIRECT_URL'
            'bot-user-auth-client-id' = 'AUTH_CLIENT_ID'; 'rg' = 'AZURE_RESOURCE_GROUP_NAME'
            'sub-id' = 'AZURE_SUBSCRIPTION_ID'; 'tenant-id' = 'AZURE_TENANT_ID'
        }
        $state = @{
            Resources = @{}; Writes = [Collections.Generic.List[object]]::new()
            Calls = [Collections.Generic.List[object]]::new(); BodyPaths = [Collections.Generic.List[string]]::new()
            ResponsePaths = [Collections.Generic.List[string]]::new()
            Account = @{ id = $sub; tenantId = $tenant; environmentName = 'AzureCloud' }
            NamedValues = @($mapping.GetEnumerator() | ForEach-Object {
                @{ id = "$testResourceId/namedValues/$($_.Key)"; name = $_.Key
                   properties = @{ displayName = $_.Key; secret = $false; value = $configuration[$_.Value] } }
            })
            FailCode = ''; FailSuffix = ''; FailWritesOnly = $false; InvalidJson = $false; Publish = $true; Batch = $false
            DropSubscription = $false; PendingReads = 0; FailedState = $false; NextLink = ''
            OmitHttpType = $false
            OmitMcpTransport = $false
            InvalidPolicyJson = $false; MissingPolicyResponse = $false
        }
        Mock Get-Command {
            if ($state.Batch) { [pscustomobject]@{ CommandType = 'Application'; Source = 'C:\test\az.cmd' } }
            else { $provisioningAzCommand }
        } -ParameterFilter { $Name -eq 'az' }
        Mock Start-Sleep {}
        Mock az {
            $global:LASTEXITCODE = 0
            $state.Calls.Add($Arguments)
            $null = $Arguments[[Array]::IndexOf($Arguments, '--subscription') + 1] | Should BeExactly $sub
            if ($Arguments[0] -eq 'account') { return ConvertTo-Json -InputObject $state.Account }
            $null = $Arguments[0] | Should BeExactly 'rest'
            $method = $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
            $urlArgument = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1]
            if ($state.Batch) { $null = $urlArgument.StartsWith('"') | Should Be $true }
            $uri = [Uri]$urlArgument.Trim('"')
            $id = [Uri]::UnescapeDataString($uri.AbsolutePath)
            if ($uri.AbsolutePath -match 'listSecrets|/listValue|/subscriptions/.*/listKeys') { throw 'Secrets and keys must not be retrieved.' }
            if ($state.FailCode -and $id.EndsWith($state.FailSuffix) -and (-not $state.FailWritesOnly -or $method -eq 'put')) {
                $global:LASTEXITCODE = 1
                return "ERROR: ($($state.FailCode)) dummy-private-secret dummy-private-auth-secret"
            }
            if ($state.InvalidJson) { return 'not JSON dummy-private-secret' }
            if ($id -eq $testResourceId) {
                return ConvertTo-Json -InputObject @{ id = $testResourceId; properties = @{ gatewayUrl = 'https://test-apim.azure-api.net' } }
            }
            if ($id.EndsWith('/namedValues')) {
                return ConvertTo-Json -InputObject @{ value = $state.NamedValues; nextLink = $state.NextLink } -Depth 10
            }
            if ($method -eq 'get' -and $id.EndsWith('/operations')) {
                $operations = @($state.Resources.Values | Where-Object { $_.id.StartsWith("$id/") -and $_.id -notmatch '/policies/' })
                return ConvertTo-Json -InputObject @{ value = $operations } -Depth 10
            }
            if ($method -eq 'get') {
                if (-not $state.Resources.ContainsKey($id)) {
                    $global:LASTEXITCODE = 1
                    return 'ERROR: (ResourceNotFound) Missing child resource'
                }
                $resource = $state.Resources[$id]
                if ($state.PendingReads -gt 0) {
                    $state.PendingReads--
                    $resource = @{ id = $resource.id; properties = $resource.properties.Clone() }
                    $resource.properties.provisioningState = 'InProgress'
                }
                if ($state.FailedState) { $resource.properties.provisioningState = 'Failed' }
                $json = ConvertTo-Json -InputObject $resource -Depth 30
                $responseIndex = [Array]::IndexOf($Arguments, '--output-file')
                if ($responseIndex -ge 0) {
                    $responsePath = $Arguments[$responseIndex + 1].Trim('"')
                    $state.ResponsePaths.Add($responsePath)
                    if (-not $state.MissingPolicyResponse) {
                        if ($state.InvalidPolicyJson) { $json = 'invalid JSON dummy-private-secret' }
                        [IO.File]::WriteAllText($responsePath, $json, [Text.UTF8Encoding]::new($true))
                    }
                    return
                }
                return $json
            }
            $null = $method | Should BeExactly 'put'
            $bodyArgument = $Arguments[[Array]::IndexOf($Arguments, '--body') + 1].Trim('"')
            $null = $bodyArgument.StartsWith('@') | Should Be $true
            $path = $bodyArgument.Substring(1)
            $state.BodyPaths.Add($path)
            $text = [IO.File]::ReadAllText($path)
            $null = $text | Should Not Match 'dummy-private'
            $body = $text | ConvertFrom-Json
            $responseIndex = [Array]::IndexOf($Arguments, '--output-file')
            if ($responseIndex -lt 0) { throw 'Writes must capture their responses even when output is none.' }
            $responsePath = $Arguments[$responseIndex + 1].Trim('"')
            $state.ResponsePaths.Add($responsePath)
            [IO.File]::WriteAllText($responsePath, '{"writeAccepted":true}', [Text.UTF8Encoding]::new($true))
            $flag = if ($id -match '/policyFragments/') { 'AZURE_APIM_POLICY_FRAGMENTS_CONFIGURED' } else { 'AZURE_APIM_APIS_CONFIGURED' }
            $null = (Read-PrerequisiteEnv -Path $envPath)[$flag] | Should BeExactly 'false'
            $state.Writes.Add(@{ Id = $id; Body = $body; Arguments = $Arguments; Url = $uri.AbsoluteUri })
            if ($state.Publish) {
                $properties = @{}
                foreach ($property in $body.properties.PSObject.Properties) {
                    if ($property.Name -notin @('format', 'value') -or $id -match '/(policyFragments|policies)/') {
                        $properties[$property.Name] = $property.Value
                    }
                }
                $properties.provisioningState = 'Succeeded'
                if ($state.OmitHttpType -and $properties.type -ceq 'http') { $properties.Remove('type') }
                if ($state.OmitMcpTransport -and $properties.type -ceq 'mcp') {
                    $properties.mcpProperties.PSObject.Properties.Remove('transportType')
                }
                if ($state.DropSubscription -and $id -match '/apis/[^/]+$') { $properties.subscriptionRequired = $false }
                $state.Resources[$id] = @{ id = $id; name = $id.Split('/')[-1]; properties = $properties }
                if ($body.properties.format -eq 'openapi') {
                    $state.Resources["$id/operations/get-status"] = @{
                        id = "$id/operations/get-status"; name = 'get-status'
                        properties = @{ method = 'GET'; urlTemplate = '/status'; provisioningState = 'Succeeded' }
                    }
                }
            }
        }
    }

    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
        foreach ($path in $state.BodyPaths) { Test-Path -LiteralPath $path | Should Be $false }
        foreach ($path in $state.ResponsePaths) { Test-Path -LiteralPath $path | Should Be $false }
    }

    It 'parses the mock CLI account response' {
        $response = & az account show --subscription $sub --only-show-errors --output json
        ($response -join "`n" | ConvertFrom-Json).id | Should BeExactly $sub
    }

    It 'creates both fragments with rawxml assets and saves verified grouped outputs' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Count | Should Be 2
        foreach ($write in $state.Writes) {
            $write.Body.properties.format | Should BeExactly 'rawxml'
            $write.Url | Should Match 'api-version=2024-05-01'
        }
        $values = Read-PrerequisiteEnv -Path $envPath
        $values['AZURE_APIM_POLICY_FRAGMENTS_CONFIGURED'] | Should BeExactly 'true'
        $values['AZURE_APIM_USER_AUTH_FRAGMENT_ID'] | Should BeExactly "$testResourceId/policyFragments/atlassian-user-auth"
        $values['AZURE_APIM_SAFE_ERRORS_FRAGMENT_ID'] | Should BeExactly "$testResourceId/policyFragments/atlassian-safe-errors"
        $values['UNRELATED'] | Should BeExactly 'preserve'
    }

    It 'reuses matching fragments without ARM writes and updates conflicts only with explicit approval' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Count | Should Be 0
        $state.Resources["$testResourceId/policyFragments/atlassian-safe-errors"].properties.value = '<fragment><return-response /></fragment>'
        $state.Resources["$testResourceId/policyFragments/atlassian-safe-errors"].properties.description = 'Keep this metadata'
        { & $fragmentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'UpdateExisting'
        $state.Writes.Count | Should Be 0
        & $fragmentScript -EnvFile $envPath -UpdateExisting -Confirm:$false
        $state.Writes.Count | Should Be 1
        $state.Writes[0].Body.properties.description | Should BeExactly 'Keep this metadata'
        ($state.Writes[0].Arguments -contains 'If-Match=*') | Should Be $true
    }

    It 'previews fragments without ARM or environment writes' {
        $before = [IO.File]::ReadAllText($envPath)
        & $fragmentScript -EnvFile $envPath -WhatIf
        $state.Writes.Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $before
    }

    It 'requires prerequisite 5 and rejects tenant or resource mismatches' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_NAMED_VALUES_CONFIGURED = 'false' }
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'prerequisite 5'
        $state.Calls.Count | Should Be 0
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_NAMED_VALUES_CONFIGURED = 'true' }
        { & $fragmentScript -EnvFile $envPath -ApimName other-apim } | Should Throw 'prerequisite 5'
        $state.Account.tenantId = '66666666-6666-6666-6666-666666666666'
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'account must match'
        $state.Writes.Count | Should Be 0
    }

    It 'preflights missing and changed public named values without writing' {
        $named = $state.NamedValues | Where-Object { $_.name -eq 'tenant-id' }
        $named.properties.value = 'different'
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'saved public'
        $state.NamedValues = @($state.NamedValues | Where-Object { $_.name -ne 'tenant-id' })
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'Missing or ambiguous'
        $state.Writes.Count | Should Be 0
    }

    It 'accepts a <Kind> secret dependency in prerequisites 6 and 7 without reading or comparing its contents' -TestCases @(
        @{ Kind = 'missing value' },
        @{ Kind = 'null value' },
        @{ Kind = 'different returned value' },
        @{ Kind = 'Key Vault-backed' }
    ) {
        param($Kind)
        $named = $state.NamedValues | Where-Object { $_.name -eq 'tenant-id' }
        $named.properties.secret = $true
        $named.properties.Remove('value')
        if ($Kind -eq 'null value') { $named.properties.value = $null }
        if ($Kind -eq 'different returned value') { $named.properties.value = 'dummy-private-secret' }
        if ($Kind -eq 'Key Vault-backed') {
            $named.properties.keyVault = @{ secretIdentifier = 'https://test-vault.vault.azure.net/secrets/tenant-id' }
        }
        $warnings = @(& $fragmentScript -EnvFile $envPath -Confirm:$false 3>&1)
        $state.Writes.Count | Should Be 2
        ($warnings | Out-String) | Should Match "Named value 'tenant-id'"
        ($warnings | Out-String) | Should Match 'contents were not read or compared'
        ($warnings | Out-String) | Should Not Match 'dummy-private'
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_POLICY_FRAGMENTS_CONFIGURED'] | Should BeExactly 'true'
        $state.Writes.Clear()
        $warnings = @(& $apiScript -EnvFile $envPath -Confirm:$false 3>&1)
        $state.Writes.Count | Should Be 4
        ($warnings | Out-String) | Should Match 'contents were not read or compared'
        ($warnings | Out-String) | Should Not Match 'dummy-private'
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_APIS_CONFIGURED'] | Should BeExactly 'true'
        $named.properties.secret | Should Be $true
        @($state.Calls | Where-Object { ($_ -join ' ') -match 'listValue|listSecrets|listKeys' }).Count | Should Be 0
    }

    It 'still rejects invalid resource identity for a secret dependency before writing' {
        $named = $state.NamedValues | Where-Object { $_.name -eq 'tenant-id' }
        $named.properties.secret = $true
        $named.id = '/subscriptions/other/resourceGroups/other/providers/Microsoft.ApiManagement/service/other/namedValues/tenant-id'
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'invalid resource identity'
        $state.Writes.Count | Should Be 0
    }

    It 'still rejects ambiguous secret dependencies before writing' {
        $named = $state.NamedValues | Where-Object { $_.name -eq 'tenant-id' }
        $named.properties.secret = $true
        $state.NamedValues += $named
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'Missing or ambiguous'
        $state.Writes.Count | Should Be 0
    }

    It 'still rejects <Kind> secrecy metadata before writing' -TestCases @(
        @{ Kind = 'missing' }, @{ Kind = 'non-boolean' }
    ) {
        param($Kind)
        $named = $state.NamedValues | Where-Object { $_.name -eq 'tenant-id' }
        if ($Kind -eq 'missing') { $named.properties.Remove('secret') }
        else { $named.properties.secret = 'true' }
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'secrecy metadata'
        $state.Writes.Count | Should Be 0
    }

    It 'does not mistake permission failures or invalid JSON for absent fragments' {
        $state.FailCode = 'AuthorizationFailed'; $state.FailSuffix = '/policyFragments/atlassian-user-auth'
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'AuthorizationFailed'
        $state.Writes.Count | Should Be 0
        $state.FailCode = ''; $state.InvalidJson = $true
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'invalid or empty'
    }

    It 'handles asynchronous read-back and does not mark invisible fragments configured' {
        $state.PendingReads = 2
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        Assert-MockCalled Start-Sleep -Times 2 -Exactly -Scope It
        $state.Resources.Clear(); $state.Publish = $false
        { & $fragmentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'read-back window'
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_POLICY_FRAGMENTS_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'imports the supplied spec and operation policy and creates a protected external MCP with its policy' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Count | Should Be 4
        $connect = $state.Writes[0]
        $connect.Body.properties.format | Should BeExactly 'openapi'
        $connect.Body.properties.value | Should BeExactly ([IO.File]::ReadAllText((Join-Path $prerequisiteRoot '7.Create-APIM-APIandMCP\assets\Atlassian Connect.openapi.yaml')))
        $connect.Body.properties.serviceUrl | Should BeExactly 'https://mcp.atlassian.com/v1/mcp/authv2'
        $state.Writes[1].Id | Should BeExactly "$testResourceId/apis/atlassian-connect/operations/get-status/policies/policy"
        $state.Writes[1].Body.properties.value | Should Match 'include-fragment fragment-id="atlassian-user-auth"'
        $mcp = $state.Writes[2]
        $mcp.Url | Should Match 'api-version=2025-09-01-preview'
        $mcp.Body.properties.type | Should BeExactly 'mcp'
        $mcp.Body.properties.serviceUrl | Should BeExactly 'https://mcp.atlassian.com'
        $mcp.Body.properties.mcpProperties.transportType | Should BeExactly 'streamable'
        $mcp.Body.properties.mcpProperties.endpoints -is [Array] | Should Be $false
        @($mcp.Body.properties.mcpProperties.endpoints.PSObject.Properties).Count | Should Be 1
        $mcp.Body.properties.mcpProperties.endpoints.message.uriTemplate | Should BeExactly '/v1/mcp/authv2'
        $state.Writes[3].Id | Should BeExactly "$testResourceId/apis/atlassian-mcp/policies/policy"
        $state.Writes[3].Body.properties.value | Should Match 'exists-action="delete"'
        foreach ($write in @($connect, $mcp)) {
            $write.Body.properties.subscriptionRequired | Should Be $true
            $write.Body.properties.subscriptionKeyParameterNames.header | Should BeExactly 'Ocp-Apim-Subscription-Key'
        }
        $values = Read-PrerequisiteEnv -Path $envPath
        $values['AZURE_APIM_APIS_CONFIGURED'] | Should BeExactly 'true'
        $values['AZURE_APIM_CONNECT_STATUS_URL'] | Should BeExactly 'https://test-apim.azure-api.net/atlassian-connect/status'
        $values['AZURE_APIM_MCP_SERVER_URL'] | Should BeExactly 'https://test-apim.azure-api.net/atlassian-mcp/mcp'
        $values['ATLASSIAN_MCP_ENDPOINT'] | Should BeExactly 'https://registration.example/v1/mcp'
        $values['UNRELATED'] | Should BeExactly 'preserve'
    }

    It 'reuses both APIs and policies and protects conflicts from implicit updates' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Count | Should Be 0
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.description = 'Keep this API metadata'
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.subscriptionRequired = $false
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'UpdateExisting'
        $state.Writes.Count | Should Be 0
        & $apiScript -EnvFile $envPath -UpdateExisting -Confirm:$false
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.subscriptionRequired | Should Be $true
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.description | Should BeExactly 'Keep this API metadata'
        $state.Writes.Count | Should Be 2
    }

    It 'honors saved routes and explicit overrides while keeping backend routes separate' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_CONNECT_API_PATH = 'saved/connect'; AZURE_APIM_MCP_API_PATH = 'saved/tools' }
        & $apiScript -EnvFile $envPath -ConnectApiId custom-connect -ConnectApiPath chosen/connect -McpApiId custom-mcp -Confirm:$false
        $values = Read-PrerequisiteEnv -Path $envPath
        $values['AZURE_APIM_CONNECT_STATUS_URL'] | Should BeExactly 'https://test-apim.azure-api.net/chosen/connect/status'
        $values['AZURE_APIM_MCP_SERVER_URL'] | Should BeExactly 'https://test-apim.azure-api.net/saved/tools/mcp'
        $values['ATLASSIAN_MCP_PATH'] | Should BeExactly '/v1/mcp/authv2'
    }

    It 'previews both APIs without changing the environment or ARM resources' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $before = [IO.File]::ReadAllText($envPath); $state.Writes.Clear()
        & $apiScript -EnvFile $envPath -WhatIf
        $state.Writes.Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $before
    }

    It 'requires prerequisite 6 and rejects overlapping gateway prefixes' {
        { & $apiScript -EnvFile $envPath } | Should Throw 'prerequisite 6'
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        { & $apiScript -EnvFile $envPath -ConnectApiPath tools -McpApiPath tools/subroute } | Should Throw 'non-overlapping'
        { & $apiScript -EnvFile $envPath -ConnectApiId same -McpApiId same } | Should Throw 'distinct'
        $state.Writes.Count | Should Be 0
    }

    It 'refuses unrelated API types and unrelated Connect operations even with UpdateExisting' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.type = 'http'
        { & $apiScript -EnvFile $envPath -UpdateExisting } | Should Throw 'another API type'
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.type = 'mcp'
        $state.Resources["$testResourceId/apis/atlassian-connect/operations/unrelated"] = @{
            id = "$testResourceId/apis/atlassian-connect/operations/unrelated"; name = 'unrelated'; properties = @{ method = 'POST' }
        }
        { & $apiScript -EnvFile $envPath -UpdateExisting } | Should Throw 'unrelated operations'
        $state.Writes.Count | Should Be 0
    }

    It 'fails read-back if Azure does not enforce subscription keys and keeps the completion flag false' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.DropSubscription = $true
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'read-back window'
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_APIS_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'surfaces partial write failures without exposing raw CLI output or marking completion' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.FailCode = 'AuthorizationFailed'; $state.FailSuffix = '/apis/atlassian-mcp'
        $state.FailWritesOnly = $true
        $failure = $null
        try { & $apiScript -EnvFile $envPath -Confirm:$false } catch { $failure = $_ }
        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match 'AuthorizationFailed'
        $failure.Exception.Message | Should Not Match 'dummy-private'
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_APIS_CONFIGURED'] | Should BeExactly 'false'
        $state.Resources.ContainsKey("$testResourceId/apis/atlassian-connect/operations/get-status/policies/policy") | Should Be $true
    }

    It 'rejects pagination links outside the APIM collection before any writes' {
        $state.NextLink = 'https://untrusted.example/namedValues?token=private'
        { & $fragmentScript -EnvFile $envPath } | Should Throw 'pagination path'
        $state.Writes.Count | Should Be 0
    }

    It 'quotes URLs and body file paths for the Windows Azure CLI launcher' {
        $state.Batch = $true
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        foreach ($write in $state.Writes) {
            $body = $write.Arguments[[Array]::IndexOf($write.Arguments, '--body') + 1]
            $body.StartsWith('"@') | Should Be $true
        }
    }

    It 'requires explicit reimport when the saved specification fingerprint is missing or changed' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_CONNECT_SPEC_SHA256 = 'stale' }
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'specification is unverified'
        $state.Writes.Count | Should Be 0
        & $apiScript -EnvFile $envPath -UpdateExisting -Confirm:$false
        $state.Writes.Count | Should Be 2
        $state.Writes[0].Body.properties.format | Should BeExactly 'openapi'
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CONNECT_SPEC_SHA256'] | Should Match '^[0-9a-f]{64}$'
    }

    It 'rejects terminal provisioning failures rather than treating them as existing resources' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.FailedState = $true
        $state.Writes.Clear()
        { & $fragmentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'provisioning failed'
        $state.Writes.Count | Should Be 0
    }

    It 'rejects live fragment drift even when its saved completion flag is true' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        $state.Resources["$testResourceId/policyFragments/atlassian-user-auth"].properties.value = '<fragment><set-header name="Authorization" exists-action="delete" /></fragment>'
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'differs from its prerequisite 6 asset'
        $state.Writes.Count | Should Be 0
    }

    It 'verifies and reuses HTTP APIs when ARM omits the default type discriminator' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.OmitHttpType = $true
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Resources["$testResourceId/apis/atlassian-connect"].properties.ContainsKey('type') | Should Be $false
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_APIS_CONFIGURED'] | Should BeExactly 'true'
        $state.Writes.Clear()
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Count | Should Be 0
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APIM_CONNECT_SPEC_SHA256 = '' }
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'specification is unverified'
        & $apiScript -EnvFile $envPath -UpdateExisting -Confirm:$false
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_APIS_CONFIGURED'] | Should BeExactly 'true'
    }

    It 'does not treat a missing MCP discriminator or missing key requirement as a match' {
        Test-ApimApiProperties -Actual ([pscustomobject]@{ subscriptionRequired = $true }) `
            -Expected @{ type = 'mcp'; subscriptionRequired = $true } | Should Be $false
        Test-ApimApiProperties -Actual ([pscustomobject]@{}) `
            -Expected @{ type = 'http'; subscriptionRequired = $true } | Should Be $false
        Test-ApimApiProperties -Actual ([pscustomobject]@{ type = ''; subscriptionRequired = $true }) `
            -Expected @{ type = 'http'; subscriptionRequired = $true } | Should Be $false
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.Remove('type')
        $state.Writes.Clear()
        { & $apiScript -EnvFile $envPath -UpdateExisting -Confirm:$false } | Should Throw 'another API type'
        $state.Writes.Count | Should Be 0
    }

    It 'reads BOM-prefixed policy JSON through response files and cleans them up' {
        $state.Batch = $true
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.ResponsePaths.Count | Should BeGreaterThan 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_APIS_CONFIGURED'] | Should BeExactly 'true'
        foreach ($call in $state.Calls) {
            $index = [Array]::IndexOf($call, '--output-file')
            if ($index -ge 0) {
                $call[$index + 1].StartsWith('"') | Should Be $true
                ($call -contains 'Accept=application/json') | Should Be $true
            }
        }

    }

    It 'captures and discards BOM-prefixed write responses without relying on stdout JSON' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        & $apiScript -EnvFile $envPath -Confirm:$false
        foreach ($write in $state.Writes) {
            ($write.Arguments -contains '--output-file') | Should Be $true
        }
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_APIS_CONFIGURED'] | Should BeExactly 'true'
        foreach ($path in $state.ResponsePaths) { Test-Path -LiteralPath $path | Should Be $false }
    }

    It 'verifies the live message-only MCP topology when transportType is not returned' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        $state.OmitMcpTransport = $true
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Count | Should Be 0
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.mcpProperties |
            Add-Member -NotePropertyName transportType -NotePropertyValue 'sse'
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'UpdateExisting'
        $state.Writes.Count | Should Be 0
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.mcpProperties.PSObject.Properties.Remove('transportType')
        $state.Resources["$testResourceId/apis/atlassian-mcp"].properties.mcpProperties.endpoints |
            Add-Member -NotePropertyName sse -NotePropertyValue @{ uriTemplate = '/sse' }
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'UpdateExisting'
        $state.Writes.Count | Should Be 0
    }

    It 'rejects malformed or absent policy response files without inferring a missing resource' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.Writes.Clear()
        $state.InvalidPolicyJson = $true
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'invalid or empty'
        $state.InvalidPolicyJson = $false; $state.MissingPolicyResponse = $true
        { & $apiScript -EnvFile $envPath -Confirm:$false } | Should Throw 'invalid or empty'
        $state.Writes.Count | Should Be 0
    }

    It 'reports the failed policy request without leaking CLI output or URL query values' {
        & $fragmentScript -EnvFile $envPath -Confirm:$false
        & $apiScript -EnvFile $envPath -Confirm:$false
        $state.FailCode = 'AuthorizationFailed'
        $state.FailSuffix = '/apis/atlassian-connect/operations/get-status/policies/policy'
        $failure = $null
        try { & $apiScript -EnvFile $envPath -Confirm:$false } catch { $failure = $_ }
        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match 'GET /subscriptions/.*/operations/get-status/policies/policy'
        $failure.Exception.Message | Should Not Match 'dummy-private|api-version|format=rawxml'
    }
}

Describe 'APIM rawxml asset validation' {
    It 'preserves authentication status and safe error codes for subscription validation failures' {
        $policy = ConvertTo-ApimPolicyDocument -Value ([IO.File]::ReadAllText(
            (Join-Path $prerequisiteRoot '6.Create-APIM-Fragments\assets\atlassian-safe-errors.xml'))) -Root fragment
        $status = $policy.SelectSingleNode('/fragment/return-response/set-status').GetAttribute('code')
        $status | Should Match 'SubscriptionKeyNotFound'
        $status | Should Match 'SubscriptionKeyInvalid'
        $status | Should Match '\? 401 : 502'
        $body = $policy.SelectSingleNode('/fragment/return-response/set-body').InnerText
        $body | Should Match 'subscription_key_required'
        $body | Should Match 'invalid_subscription_key'
        $body | Should Match 'invalid_user_token'
        $body | Should Match 'gateway_operation_failed'
    }

    It 'enforces a valid subscription before JWT validation or inherited policies on both routes' {
        $fragment = ConvertTo-ApimPolicyDocument -Value ([IO.File]::ReadAllText(
            (Join-Path $prerequisiteRoot '6.Create-APIM-Fragments\assets\atlassian-user-auth.xml'))) -Root fragment
        $fragment.fragment.FirstChild.Name | Should BeExactly 'choose'
        $guard = $fragment.SelectSingleNode('/fragment/choose/when')
        $guard.GetAttribute('condition') | Should BeExactly '@(context.Subscription == null)'
        $guard.SelectSingleNode('return-response/set-status').GetAttribute('code') | Should BeExactly '401'
        $guard.SelectSingleNode('return-response/set-body').InnerText | Should Match 'subscription_key_required'
        foreach ($name in @('get-status', 'atlassian-mcp')) {
            $policy = ConvertTo-ApimPolicyDocument -Value ([IO.File]::ReadAllText(
                (Join-Path $prerequisiteRoot "7.Create-APIM-APIandMCP\assets\$name.xml"))) -Root policies
            $inbound = $policy.SelectSingleNode('/policies/inbound')
            $inbound.FirstChild.GetAttribute('fragment-id') | Should BeExactly 'atlassian-user-auth'
            $inbound.ChildNodes[1].Name | Should BeExactly 'base'
        }

    }

    It 'normalizes raw C# attribute quotes and XML-encoded attributes without changing expressions' {
        $raw = '<fragment><set-variable name="user" value="@((string)context.Variables["userOid"])" /></fragment>'
        $encoded = '<fragment><set-variable name="user" value="@((string)context.Variables[&quot;userOid&quot;])" /></fragment>'
        Test-ApimPolicyMatch -Actual $encoded -Expected $raw -Root fragment | Should Be $true
    }

    It 'rejects malformed policies and document type declarations' {
        { ConvertTo-ApimPolicyDocument -Value '<fragment><invalid></fragment>' -Root fragment } | Should Throw 'Invalid APIM'
        { ConvertTo-ApimPolicyDocument -Value '<policies />' -Root fragment } | Should Throw 'Expected'
        { ConvertTo-ApimPolicyDocument -Value '<!DOCTYPE fragment [<!ENTITY x SYSTEM "file:///private">]><fragment>&x;</fragment>' -Root fragment } | Should Throw 'Invalid APIM'
    }
}

Describe 'APIM provisioning Windows native argument handling' {
    It 'preserves rawxml format and pagination query parameters through a real cmd launcher' -Skip:($env:OS -ne 'Windows_NT') {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\Echo-AzureCliUrl.cmd'
        $context = [pscustomobject]@{
            AzureCli = Get-Command $fixture
            SubscriptionId = '11111111-1111-1111-1111-111111111111'
            ServiceUrl = 'https://management.azure.com/test'
        }
        $url = 'https://management.azure.com/test/policyFragments?api-version=2024-05-01&format=rawxml&%24skipToken=page2%3d%3d'
        $previousAlias = Get-Alias az -ErrorAction SilentlyContinue
        $previousExitCode = $global:LASTEXITCODE
        try {
            Set-Alias -Name az -Value $fixture -Scope Local
            (Invoke-ApimProvisioningRequest -Context $context -Method get -Url $url).url | Should BeExactly $url
        } finally {
            if ($previousAlias) { Set-Alias -Name az -Value $previousAlias.Definition -Scope Local }
            else { Remove-Item Alias:\az }
            $global:LASTEXITCODE = $previousExitCode
        }
    }

    It 'passes temporary JSON bodies in directories with spaces through a real cmd launcher' -Skip:($env:OS -ne 'Windows_NT') {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\Echo-AzureCliBody.cmd'
        $directory = Join-Path $TestDrive 'native folder with spaces'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $context = [pscustomobject]@{
            AzureCli = Get-Command $fixture
            SubscriptionId = '11111111-1111-1111-1111-111111111111'
            ServiceUrl = 'https://management.azure.com/test'
            EnvFile = Join-Path $directory 'custom.env'
        }
        $previousAlias = Get-Alias az -ErrorAction SilentlyContinue
        $previousExitCode = $global:LASTEXITCODE
        try {
            Set-Alias -Name az -Value $fixture -Scope Local
            Invoke-ApimProvisioningRequest -Context $context -Method put `
                -Url 'https://management.azure.com/test/policyFragments/test?api-version=2024-05-01' `
                -Body @{ properties = @{ format = 'rawxml'; value = '<fragment><return-response /></fragment>' } }
            @(Get-ChildItem -LiteralPath $directory -Filter '*.request.json').Count | Should Be 0
        } finally {
            if ($previousAlias) { Set-Alias -Name az -Value $previousAlias.Definition -Scope Local }
            else { Remove-Item Alias:\az }
            $global:LASTEXITCODE = $previousExitCode
        }
    }
}
