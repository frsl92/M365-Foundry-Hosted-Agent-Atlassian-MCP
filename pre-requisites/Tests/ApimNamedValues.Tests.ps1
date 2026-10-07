$prerequisiteRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $prerequisiteRoot 'Common.ps1')
$namedValueScript = Join-Path $prerequisiteRoot '5.Configure-APIM-Named-Values\Configure-ApimNamedValues.ps1'

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live Azure CLI call.'
}
$namedValueAzCommand = Get-Command az

function New-TestNamedValue {
    param([string]$Name, [string]$DisplayName, [string]$Value)
    return [pscustomobject]@{
        id = "$testResourceId/namedValues/$Name"
        name = $Name
        properties = [pscustomobject]@{
            displayName = $DisplayName
            value = $Value
            secret = $false
            tags = @('preserve-tag')
            provisioningState = 'Succeeded'
        }
    }
}

Describe 'APIM public named values prerequisite' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $envPath = Join-Path $TestDrive 'named-values.env'
        if (Test-Path -LiteralPath $envPath) { Remove-Item -LiteralPath $envPath }
        $testSub = '11111111-1111-1111-1111-111111111111'
        $testTenant = '22222222-2222-2222-2222-222222222222'
        $testPrincipal = '33333333-3333-3333-3333-333333333333'
        $testResourceId = "/subscriptions/$testSub/resourceGroups/test-rg/providers/Microsoft.ApiManagement/service/test-apim"
        $expectedValues = [ordered]@{
            'apim-api-client-id' = '44444444-4444-4444-4444-444444444444'
            'apim-mi-object-id' = $testPrincipal
            'apim-name' = 'test-apim'
            'arm-api-version' = '2022-08-01'
            'atlassian-credential-provider' = 'Atlassian'
            'atlassian-mcp-base-url' = 'https://mcp.atlassian.com'
            'atlassian-mcp-path' = '/v2/mcp'
            'atlassian-post-login-redirect-url' = 'https://www.atlassian.com/software/jira'
            'bot-user-auth-client-id' = '55555555-5555-5555-5555-555555555555'
            'rg' = 'test-rg'
            'sub-id' = $testSub
            'tenant-id' = $testTenant
        }
        Update-PrerequisiteEnv -Path $envPath -Values @{
            AZURE_APIM_NAME = 'test-apim'
            AZURE_RESOURCE_GROUP_NAME = 'test-rg'
            AZURE_SUBSCRIPTION_ID = $testSub
            AZURE_APIM_RESOURCE_ID = $testResourceId
            AZURE_APIM_IDENTITY_PRINCIPAL_ID = $testPrincipal
            AZURE_APIM_IDENTITY_TENANT_ID = $testTenant
            AZURE_TENANT_ID = $testTenant
            APIM_API_CLIENT_ID = $expectedValues['apim-api-client-id']
            AUTH_CLIENT_ID = $expectedValues['bot-user-auth-client-id']
            APIM_API_SERVICE_PRINCIPAL_ID = '66666666-6666-6666-6666-666666666666'
            AUTH_SERVICE_PRINCIPAL_ID = '77777777-7777-7777-7777-777777777777'
            AZURE_APP_REGISTRATIONS_CONFIGURED = 'true'
            AZURE_APIM_CREDENTIAL_PROVIDER_NAME = 'Atlassian'
            AZURE_APIM_CREDENTIAL_PROVIDER_ID = "$testResourceId/authorizationProviders/Atlassian"
            AUTH_CLIENT_SECRET = 'dummy-auth-secret'
            ATLASSIAN_MCP_CLIENT_SECRET = 'dummy-atlassian-secret'
            ATLASSIAN_MCP_ENDPOINT = 'https://mcp.atlassian.com/v1/mcp'
            UNRELATED = 'preserve-value'
        }
        $state = @{
            Entries = [System.Collections.Generic.List[object]]::new()
            Calls = [System.Collections.Generic.List[object]]::new()
            Writes = [System.Collections.Generic.List[object]]::new()
            BodyPaths = [System.Collections.Generic.List[string]]::new()
            Account = @{ id = $testSub; tenantId = $testTenant; environmentName = 'AzureCloud' }
            Service = @{ id = $testResourceId; identity = @{ type = 'SystemAssigned, UserAssigned'; principalId = $testPrincipal; tenantId = $testTenant } }
            NextLink = ''
            SecondPage = @()
            RawList = $null
            FailMethod = ''
            FailName = ''
            FailRead = $false
            Publish = $true
            DelayedReads = 0
            ReadState = 'Succeeded'
            Batch = $false
            MissingCli = $false
        }
        Mock Get-Command {
            if (-not $state.MissingCli) {
                if ($state.Batch) { [pscustomobject]@{ CommandType = 'Application'; Source = 'C:\test\az.cmd' } }
                else { $namedValueAzCommand }
            }
        } -ParameterFilter { $Name -eq 'az' }
        Mock Start-Sleep {} -ParameterFilter { $Seconds -gt 0 }
        Mock az {
            $state.Calls.Add($Arguments)
            $global:LASTEXITCODE = 0
            if ($Arguments[0] -eq 'account' -and $Arguments[1] -eq 'show') {
                return ConvertTo-Json -InputObject $state.Account -Depth 5
            }
            if ($Arguments[0] -ne 'rest') { throw 'Only account show and ARM REST are allowed.' }
            $method = $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
            $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1].Trim('"')
            if ($url -match 'listSecrets|/authorizations|/servicePrincipals') { throw 'Forbidden API call.' }
            $uri = [Uri]$url
            $name = [Uri]::UnescapeDataString($uri.Segments[-1])
            if ($method -in @('put', 'patch')) {
                $bodyArgument = $Arguments[[Array]::IndexOf($Arguments, '--body') + 1].Trim('"')
                if (-not $bodyArgument.StartsWith('@')) { throw 'Expected a file-backed JSON request.' }
                $path = $bodyArgument.Substring(1)
                $state.BodyPaths.Add($path)
                $body = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ((Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_NAMED_VALUES_CONFIGURED'] -cne 'false') {
                    throw 'The configured flag must be false before writes.'
                }
                if ($body.properties.value -like '*dummy-*-secret*') { throw 'A secret leaked into a request.' }
                $state.Writes.Add(@{ Method = $method; Name = $name; Body = $body })
            }
            if ($method -eq $state.FailMethod -or ($state.FailName -and $name -eq $state.FailName -and $method -ne 'get') -or
                ($state.FailRead -and $method -eq 'get' -and $uri.AbsolutePath -match '/namedValues/')) {
                $global:LASTEXITCODE = 1
                return 'ERROR: (AuthorizationFailed) dummy-auth-secret dummy-atlassian-secret'
            }
            if ($uri.AbsolutePath -ieq $testResourceId) { return ConvertTo-Json -InputObject $state.Service -Depth 5 }
            if ($name -eq 'namedValues') {
                if ($null -ne $state.RawList) { return $state.RawList }
                if ($uri.Query -match 'skipToken') {
                    return ConvertTo-Json -InputObject @{ value = @($state.SecondPage); nextLink = '' } -Depth 8
                }
                return ConvertTo-Json -InputObject @{ value = $state.Entries.ToArray(); nextLink = $state.NextLink } -Depth 8
            }
            if ($method -eq 'get') {
                if ($state.DelayedReads -gt 0) {
                    $state.DelayedReads--
                    $global:LASTEXITCODE = 1
                    return 'ERROR: (ResourceNotFound) not visible yet'
                }
                $found = @(@($state.Entries.ToArray()) + @($state.SecondPage) | Where-Object { $_.name -ceq $name })
                if ($found.Count -eq 0) {
                    $global:LASTEXITCODE = 1
                    return 'ERROR: (ResourceNotFound) not found'
                }
                $found[0].properties.provisioningState = $state.ReadState
                return ConvertTo-Json -InputObject $found[0] -Depth 8
            }
            if ($method -eq 'put') {
                if ($state.Publish) {
                    $state.Entries.Add((New-TestNamedValue -Name $name -DisplayName $body.properties.displayName -Value $body.properties.value))
                }
                return
            }
            if ($method -eq 'patch') {
                if ($Arguments -notcontains 'If-Match=*') { throw 'Missing explicit update condition.' }
                $found = @(@($state.Entries.ToArray()) + @($state.SecondPage) | Where-Object { $_.name -ceq $name })
                if ($found.Count -ne 1) { throw 'Cannot patch an unknown or ambiguous resource.' }
                if ($state.Publish) { $found[0].properties.value = $body.properties.value }
                return
            }
            throw 'Unexpected REST method.'
        }
    }
    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
        foreach ($path in $state.BodyPaths) { Test-Path -LiteralPath $path | Should Be $false }
    }

    It 'creates exactly the twelve public values from prior outputs and saves grouped defaults' {
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        $state.Writes.Count | Should Be 12
        ($state.Writes.Name -join '|') | Should BeExactly ($expectedValues.Keys -join '|')
        foreach ($write in $state.Writes) {
            $write.Method | Should BeExactly 'put'
            $write.Body.properties.displayName | Should BeExactly $write.Name
            $write.Body.properties.value | Should BeExactly $expectedValues[$write.Name]
            $write.Body.properties.secret | Should Be $false
        }
        $values = Read-PrerequisiteEnv -Path $envPath
        $values['AZURE_APIM_NAMED_VALUES_CONFIGURED'] | Should BeExactly 'true'
        $values['ATLASSIAN_MCP_PATH'] | Should BeExactly '/v2/mcp'
        $values['AZURE_APIM_POLICY_ARM_API_VERSION'] | Should BeExactly '2022-08-01'
        $values['AUTH_CLIENT_SECRET'] | Should BeExactly 'dummy-auth-secret'
        $values['ATLASSIAN_MCP_ENDPOINT'] | Should BeExactly 'https://mcp.atlassian.com/v1/mcp'
        $values['UNRELATED'] | Should BeExactly 'preserve-value'
        foreach ($call in $state.Calls) {
            $call[[Array]::IndexOf($call, '--subscription') + 1] | Should BeExactly $testSub
        }
    }

    It 'reuses a completed run without additional writes' {
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        $state.Writes.Clear()
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        $state.Writes.Count | Should Be 0
    }

    It 'matches existing generated resource names by display name and preserves tags when updating' {
        $item = New-TestNamedValue '88888888-8888-8888-8888-888888888888' 'apim-name' 'old-name'
        $state.Entries.Add($item)
        $null = & $namedValueScript -EnvFile $envPath -UpdateExisting 6>&1
        $write = @($state.Writes | Where-Object Method -eq 'patch')
        $write.Count | Should Be 1
        $write[0].Name | Should BeExactly $item.name
        @($write[0].Body.properties.PSObject.Properties).Count | Should Be 1
        $item.properties.tags[0] | Should BeExactly 'preserve-tag'
    }

    It 'preflights late conflicts before creating any earlier missing entries' {
        $state.Entries.Add((New-TestNamedValue 'tenant-id' 'tenant-id' 'wrong-tenant'))
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'No Azure writes were made'
        $state.Writes.Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_NAMED_VALUES_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'leaves unrelated public and secret entries untouched and never reads their values individually' {
        $secretItem = New-TestNamedValue 'secret-entry' 'unrelated-secret' ''
        $secretItem.properties.secret = $true
        $state.Entries.Add($secretItem)
        $state.Entries.Add((New-TestNamedValue 'unrelated-public' 'unrelated-public' 'keep'))
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        $state.Writes.Count | Should Be 12
        $secretItem.properties.secret | Should Be $true
        ($state.Calls | ConvertTo-Json -Depth 4) | Should Not Match 'listSecrets|/secret-entry|/unrelated-public'
    }

    It 'rejects secret and Key Vault collisions even with update approval' {
        $item = New-TestNamedValue 'tenant-id' 'tenant-id' $testTenant
        $state.Entries.Add($item)
        $item.properties.secret = $true
        { & $namedValueScript -EnvFile $envPath -UpdateExisting 6>$null } | Should Throw 'will not be read as plaintext'
        $item.properties.secret = $false
        $item.properties | Add-Member -NotePropertyName keyVault -NotePropertyValue @{ secretIdentifier = 'https://example.vault.azure.net/secrets/test' }
        { & $namedValueScript -EnvFile $envPath -UpdateExisting 6>$null } | Should Throw 'will not be read as plaintext'
        $state.Writes.Count | Should Be 0
    }

    It 'rejects a missing plaintext value without falling back to secret retrieval' {
        $state.Entries.Add((New-TestNamedValue 'tenant-id' 'tenant-id' ''))
        { & $namedValueScript -EnvFile $envPath -UpdateExisting 6>$null } | Should Throw 'Secret retrieval is intentionally disabled'
        $state.Writes.Count | Should Be 0
    }

    It 'rejects resource-name collisions belonging to a different display name' {
        $state.Entries.Add((New-TestNamedValue 'tenant-id' 'another-display-name' 'keep'))
        { & $namedValueScript -EnvFile $envPath -UpdateExisting 6>$null } | Should Throw 'already used by another display name'
        $state.Writes.Count | Should Be 0
    }

    It 'reads later pages and reuses their matching values' {
        $state.NextLink = "https://management.azure.com$testResourceId/namedValues?api-version=2024-05-01&skipToken=next"
        $state.SecondPage = @((New-TestNamedValue 'generated' 'tenant-id' $testTenant))
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        $state.Writes.Count | Should Be 11
        ($state.Writes.Name -contains 'tenant-id') | Should Be $false
    }

    It 'detects duplicate display names across pages before writes' {
        $state.Entries.Add((New-TestNamedValue 'one' 'tenant-id' $testTenant))
        $state.SecondPage = @((New-TestNamedValue 'two' 'tenant-id' $testTenant))
        $state.NextLink = "https://management.azure.com$testResourceId/namedValues?api-version=2024-05-01&skipToken=next"
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'Multiple named values'
        $state.Writes.Count | Should Be 0
    }

    It 'rejects hostile and repeated pagination links' {
        $state.NextLink = "https://example.test$testResourceId/namedValues?skipToken=next"
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'unexpected named value pagination URL'
        $state.NextLink = "https://management.azure.com$testResourceId/namedValues?api-version=2024-05-01"
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'repeated named value pagination link'
        $state.Writes.Count | Should Be 0
    }

    It 'rejects malformed discovery rather than assuming resources are missing' {
        $state.RawList = '{"value":{}}'
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'unexpected named value collection'
        $state.RawList = 'not JSON'
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'invalid or empty JSON'
        $state.Writes.Count | Should Be 0
    }

    It 'rejects managed resource identities outside the selected APIM service' {
        $item = New-TestNamedValue 'tenant-id' 'tenant-id' $testTenant
        $item.id = '/other-service/namedValues/tenant-id'
        $state.Entries.Add($item)
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'Unexpected or ambiguous resource identity'
        $state.Writes.Count | Should Be 0
    }

    It 'preserves and URL-encodes an existing resource name containing spaces' {
        $state.Entries.Add((New-TestNamedValue 'legacy value' 'tenant-id' $testTenant))
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        $state.Writes.Count | Should Be 11
        ($state.Calls | ConvertTo-Json -Depth 4) | Should Match 'legacy%20value'
    }

    It 'rejects unknown secrecy instead of treating it as a public named value' {
        $item = New-TestNamedValue 'tenant-id' 'tenant-id' $testTenant
        $item.properties.secret = $null
        $state.Entries.Add($item)
        { & $namedValueScript -EnvFile $envPath -UpdateExisting 6>$null } | Should Throw 'unknown secrecy'
        $state.Writes.Count | Should Be 0
    }

    It 'uses saved settings and explicit overrides without changing the registration endpoint' {
        Update-PrerequisiteEnv -Path $envPath -Values @{
            ATLASSIAN_MCP_BASE_URL = 'https://saved.example.test'
            ATLASSIAN_MCP_PATH = '/saved/path'
            AZURE_APIM_POLICY_ARM_API_VERSION = '2024-05-01'
            ATLASSIAN_POST_LOGIN_REDIRECT_URL = 'https://saved.example.test/jira'
        }
        $null = & $namedValueScript -EnvFile $envPath -McpPath '/override/path' -PostLoginRedirectUrl 'https://example.test/jira?a=1&b=2' 6>&1
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['ATLASSIAN_MCP_BASE_URL'] | Should BeExactly 'https://saved.example.test'
        $saved['ATLASSIAN_MCP_PATH'] | Should BeExactly '/override/path'
        $saved['ATLASSIAN_POST_LOGIN_REDIRECT_URL'] | Should BeExactly 'https://example.test/jira?a=1&b=2'
        $saved['AZURE_APIM_POLICY_ARM_API_VERSION'] | Should BeExactly '2024-05-01'
        @($state.Writes | Where-Object Name -eq 'atlassian-mcp-path')[0].Body.properties.value | Should BeExactly '/override/path'
    }

    It 'rejects explicit empty overrides and unsafe URLs before contacting Azure' {
        { & $namedValueScript -EnvFile $envPath -McpPath '' 6>$null } | Should Throw 'Supply -McpPath'
        { & $namedValueScript -EnvFile $envPath -McpBaseUrl 'http://example.test' 6>$null } | Should Throw 'absolute HTTPS'
        { & $namedValueScript -EnvFile $envPath -McpBaseUrl 'https://example.test/path' 6>$null } | Should Throw 'HTTPS origin'
        { & $namedValueScript -EnvFile $envPath -McpPath '/../unsafe' 6>$null } | Should Throw 'absolute backend path'
        { & $namedValueScript -EnvFile $envPath -ArmApiVersion '2024-99-01' 6>$null } | Should Throw 'stable API version'
        $state.Calls.Count | Should Be 0
    }

    It 'rejects missing earlier outputs and mismatched saved targets before any Azure calls' {
        { & $namedValueScript -EnvFile $envPath -ApimName 'different-apim' 6>$null } | Should Throw 'mismatched saved APIM resource ID'
        Update-PrerequisiteEnv -Path $envPath -Values @{ APIM_API_CLIENT_ID = '' }
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'APIM_API_CLIENT_ID must be a nonempty GUID'
        $state.Calls.Count | Should Be 0
    }

    It 'requires verified registrations and a provider belonging to the selected APIM' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APP_REGISTRATIONS_CONFIGURED = 'false' }
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'Complete prerequisite 4'
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_APP_REGISTRATIONS_CONFIGURED = 'true'; AZURE_APIM_CREDENTIAL_PROVIDER_ID = '/wrong' }
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'mismatched saved credential provider'
        $state.Calls.Count | Should Be 0
    }

    It 'rejects mismatched live tenant and managed identity without writes' {
        $state.Account.tenantId = 'wrong'
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'saved tenant in Azure public cloud'
        $state.Account.tenantId = $testTenant
        $state.Service.identity.principalId = 'wrong'
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'live APIM system-assigned identity'
        $state.Writes.Count | Should Be 0
    }

    It 'recovers partial creations on rerun and withholds raw CLI errors' {
        $state.FailName = 'apim-name'
        $message = ''
        try { $null = & $namedValueScript -EnvFile $envPath 6>&1 } catch { $message = $_.Exception.Message }
        $message | Should Match 'AuthorizationFailed'
        $message | Should Not Match 'dummy-auth-secret|dummy-atlassian-secret'
        $state.Entries.Count | Should Be 2
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_NAMED_VALUES_CONFIGURED'] | Should BeExactly 'false'
        $state.FailName = ''
        $state.Writes.Clear()
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        $state.Writes.Count | Should Be 10
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_NAMED_VALUES_CONFIGURED'] | Should BeExactly 'true'
    }

    It 'retries delayed visibility with bounded backoff' {
        $state.DelayedReads = 3
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        foreach ($delay in @(2, 4, 8)) {
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Seconds -eq $delay }
        }
    }

    It 'does not mark success when accepted writes never become visible' {
        $state.Publish = $false
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'could not be verified after four reads'
        $state.Writes.Count | Should Be 1
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_NAMED_VALUES_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'does not mark success for pending provisioning even when the desired value is visible' {
        $state.ReadState = 'Updating'
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'could not be verified after four reads'
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_NAMED_VALUES_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'fails explicitly when Azure CLI is unavailable' {
        $state.MissingCli = $true
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'Azure CLI is required'
        $state.Calls.Count | Should Be 0
    }

    It 'rejects failed provisioning and denied verification without retrying them' {
        $state.ReadState = 'Failed'
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'Provisioning failed'
        $state.ReadState = 'Succeeded'
        $state.FailRead = $true
        { & $namedValueScript -EnvFile $envPath 6>$null } | Should Throw 'AuthorizationFailed'
        Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It -ParameterFilter { $Seconds -gt 0 }
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_NAMED_VALUES_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'quotes native batch URLs and body paths including pagination ampersands' {
        $state.Batch = $true
        $state.NextLink = "https://management.azure.com$testResourceId/namedValues?api-version=2024-05-01&skipToken=next"
        $null = & $namedValueScript -EnvFile $envPath 6>&1
        foreach ($call in $state.Calls) {
            if ($call[0] -eq 'rest') {
                $call[[Array]::IndexOf($call, '--url') + 1] | Should Match '^"https://.+?"$'
                if ($call -contains '--body') { $call[[Array]::IndexOf($call, '--body') + 1] | Should Match '^"@.+?"$' }
            }
        }

    }
}

Describe 'APIM named values Windows native argument handling' {
    It 'passes complete pagination URLs and request paths through actual cmd launchers' -Skip:($env:OS -ne 'Windows_NT') {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($namedValueScript, [ref]$tokens, [ref]$parseErrors)
        @($parseErrors).Count | Should Be 0
        foreach ($name in @('Invoke-NamedValueCli', 'Invoke-NamedValueRequest')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $directory = Join-Path $TestDrive 'named value requests & more'
        $null = New-Item -ItemType Directory -Path $directory
        $EnvFile = Join-Path $directory '.env'
        $SubscriptionId = '11111111-1111-1111-1111-111111111111'
        $previousAlias = Get-Alias az -ErrorAction SilentlyContinue
        $previousExitCode = $global:LASTEXITCODE
        try {
            $fixture = Join-Path $PSScriptRoot 'Fixtures\Echo-AzureCliUrl.cmd'
            $azureCliCommand = Get-Command $fixture
            Set-Alias -Name az -Value $fixture -Scope Local
            $url = 'https://management.azure.com/example/namedValues?api-version=2024-05-01&$skipToken=next'
            $result = Invoke-NamedValueRequest -Method get -Url $url
            $result.url | Should BeExactly $url
            $fixture = Join-Path $PSScriptRoot 'Fixtures\Echo-AzureCliBody.cmd'
            $azureCliCommand = Get-Command $fixture
            Set-Alias -Name az -Value $fixture -Scope Local
            Invoke-NamedValueRequest -Method put -Url $url -Body @{
                properties = @{ displayName = 'native-probe'; value = 'https://example.test/?a=1&b=2'; secret = $false }
            }
            @(Get-ChildItem -LiteralPath $directory -Force).Count | Should Be 0
        } finally {
            if ($previousAlias) { Set-Alias -Name az -Value $previousAlias.Definition -Scope Local }
            else { Remove-Item Alias:\az }
            $global:LASTEXITCODE = $previousExitCode
        }
    }
}
