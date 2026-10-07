$sourceRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $sourceRoot '..\common-scripts\Common.ps1')

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live Azure CLI call.'
}
function azd {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live azd call.'
}
$testAzCommand = Get-Command az
$testAzdCommand = Get-Command azd

Describe 'Environment-driven deployment and post-requisite handoff' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $deploymentRoot = Join-Path $TestDrive 'agent-deployment'
        $helperRoot = Join-Path $TestDrive 'common-scripts'
        $null = New-Item -ItemType Directory -Path $deploymentRoot, $helperRoot -Force
        Copy-Item -LiteralPath (Join-Path $sourceRoot 'deploy-agent.ps1'), (Join-Path $sourceRoot 'azure.yaml') -Destination $deploymentRoot -Force
        Copy-Item -LiteralPath (Join-Path $sourceRoot '..\common-scripts\Common.ps1') -Destination $helperRoot -Force
        Copy-Item -LiteralPath (Join-Path $sourceRoot '..\.env.v1.example') -Destination $TestDrive -Force
        [IO.File]::WriteAllText((Join-Path $deploymentRoot 'azure.yaml'),
            "services:`n  agent:`n    host: azure.ai.agent`n    name: atlassian-agent`n")
        $deploymentScript = Join-Path $deploymentRoot 'deploy-agent.ps1'
        $envPath = Join-Path $TestDrive '.env'
        $environmentName = 'deployment-test-no-live-env'
        $existingEnvFolder = Join-Path $deploymentRoot ".azure\$environmentName"
        $existingEnvPath = Join-Path $existingEnvFolder '.env'
        if (Test-Path -LiteralPath $existingEnvPath) { Remove-Item -LiteralPath $existingEnvPath }
        $subscription = '11111111-1111-1111-1111-111111111111'
        $tenant = '22222222-2222-2222-2222-222222222222'
        $client = '33333333-3333-3333-3333-333333333333'
        $projectId = "/subscriptions/$subscription/resourceGroups/test-rg/providers/Microsoft.CognitiveServices/accounts/test-account/projects/test-project"
        $endpoint = 'https://test-account.services.ai.azure.com/api/projects/test-project'
        $botId = "/subscriptions/$subscription/resourceGroups/test-rg/providers/Microsoft.BotService/botServices/test-bot"
        [IO.File]::WriteAllLines($envPath, @(
            "AZURE_ENV_NAME=$environmentName",
            "AZURE_TENANT_ID=$tenant",
            'AZURE_LOCATION=swedencentral',
            "AZURE_FOUNDRY_PROJECT_RESOURCE_ID=$projectId",
            "AZURE_FOUNDRY_PROJECT_ENDPOINT=$endpoint",
            'AZURE_FOUNDRY_AGENT_NAME=atlassian-agent',
            'AZURE_BOT_SERVICE_RESOURCE_ID=',
            'FOUNDRY_MODEL_NAME=test-model',
            'GATEWAY_MODELS_ENDPOINT=https://models.example.test',
            'GATEWAY_SUBSCRIPTION_KEY=gateway-test-key',
            'AZURE_APIM_MCP_SERVER_URL=https://gateway.example.test/atlassian-mcp/mcp',
            'AZURE_APIM_CONNECT_STATUS_URL=https://gateway.example.test/atlassian-connect/status',
            'APIM_STATUS_SUBSCRIPTION_KEY=status-test-key',
            'APIM_MCP_SUBSCRIPTION_KEY=mcp-test-key',
            'AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME=apim-user-oauth',
            'ATLASSIAN_MCP_CLIENT_SECRET=do-not-print',
            '# unrelated configuration',
            'CUSTOM_SETTING=keep'
        ))
        $original = [IO.File]::ReadAllText($envPath)
        $fixture = @{
            AzCalls = [Collections.Generic.List[object]]::new()
            AzdCalls = [Collections.Generic.List[object]]::new()
            FailAzd = ''
            AzdError = 'Failed do-not-print'
            FailAz = $false
            AgentName = 'atlassian-agent'
            AgentClient = $client
            BotClient = $client
            BotTenant = $tenant
            AccountTenant = $tenant
            BotEndpoint = "$endpoint/agents/atlassian-agent/endpoint/protocols/activityProtocol?api-version=2025-05-15-preview"
            BotIds = @($botId)
        }
        Mock Get-Command { $testAzCommand } -ParameterFilter { $Name -eq 'az' }
        Mock Get-Command { $testAzdCommand } -ParameterFilter { $Name -eq 'azd' }
        Mock azd {
            $fixture.AzdCalls.Add($Arguments)
            $global:LASTEXITCODE = 0
            if (($Arguments[0..1] -join ' ') -eq $fixture.FailAzd -or $Arguments[0] -eq $fixture.FailAzd) {
                $global:LASTEXITCODE = 1
                return $fixture.AzdError
            }
            return 'Operation completed (non-JSON output).'
        }
        Mock az {
            $fixture.AzCalls.Add($Arguments)
            $global:LASTEXITCODE = 0
            if ($fixture.FailAz) {
                $global:LASTEXITCODE = 1
                return 'ERROR: (Forbidden) do-not-print'
            }
            if ($Arguments[0] -eq 'account') {
                return ConvertTo-Json @{ environmentName = 'AzureCloud'; tenantId = $fixture.AccountTenant }
            }
            if ($Arguments[0] -eq 'resource') {
                return ConvertTo-Json -InputObject @{ value = @($fixture.BotIds | ForEach-Object { @{ id = $_ } }) } -Depth 10
            }
            if ($Arguments[0] -ne 'rest') { throw 'Unexpected az command.' }
            $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1].Trim('"')
            if ($url -like '*management.azure.com*/channels?*') { return '{"value":[]}' }
            if ($url -like '*management.azure.com*') {
                return ConvertTo-Json @{
                    id = ($url -replace '^https://management.azure.com', '' -replace '\?.*$', '')
                    location = 'global'
                    properties = @{
                        msaAppId = $fixture.BotClient
                        msaAppTenantId = $fixture.BotTenant
                        endpoint = $fixture.BotEndpoint
                    }
                } -Depth 10
            }
            return ConvertTo-Json @{
                name = $fixture.AgentName
                instance_identity = @{ client_id = $fixture.AgentClient }
                agent_endpoint = @{ protocol_configuration = @{ activity = @{} }; authorization_schemes = @() }
            } -Depth 10
        }
    }

    AfterEach { $global:LASTEXITCODE = $previousExitCode }

    It 'reads root config regardless of working directory and writes the exact post-requisite inputs' {
        Push-Location $TestDrive
        try { & $deploymentScript -Confirm:$false } finally { Pop-Location }
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['AZURE_FOUNDRY_PROJECT_ENDPOINT'] | Should BeExactly $endpoint
        $saved['AZURE_FOUNDRY_AGENT_NAME'] | Should BeExactly 'atlassian-agent'
        $saved['AZURE_BOT_SERVICE_RESOURCE_ID'] | Should BeExactly $botId
        $saved['ATLASSIAN_MCP_CLIENT_SECRET'] | Should BeExactly 'do-not-print'
        $saved['CUSTOM_SETTING'] | Should BeExactly 'keep'
        [IO.File]::ReadAllText($envPath) | Should Match '# unrelated configuration'
        @($fixture.AzdCalls | Where-Object { $_[0] -eq 'deploy' }).Count | Should Be 1
        @($fixture.AzdCalls | Where-Object { $_[0] -eq 'provision' -or $_[0] -eq 'up' }).Count | Should Be 0
        foreach ($call in $fixture.AzdCalls) {
            $cwd = $call[[Array]::IndexOf($call, '--cwd') + 1]
            Split-Path $cwd -Leaf | Should BeExactly 'agent-deployment'
            Split-Path (Split-Path $cwd -Parent) -Leaf | Should BeExactly (Split-Path $TestDrive -Leaf)
            $call[[Array]::IndexOf($call, '--environment') + 1] | Should BeExactly $environmentName
        }
        $deploy = @($fixture.AzdCalls | Where-Object { $_[0] -eq 'deploy' })[0]
        $deploy[1] | Should BeExactly 'agent'
        $checks = @($fixture.AzdCalls | Where-Object { $_[0] -eq 'ai' })
        $checks.Count | Should Be 1
        ($checks[0][0..3] -join ' ') | Should BeExactly 'ai agent doctor --local-only'
        $sets = @($fixture.AzdCalls | Where-Object { $_[0] -eq 'env' -and $_[1] -eq 'set' })
        @($sets | Where-Object { $_[2] -eq 'FOUNDRY_PROJECT_ENDPOINT' })[0][3] | Should BeExactly $endpoint
        @($sets | Where-Object { $_[2] -eq 'AZURE_AI_PROJECT_ID' })[0][3] | Should BeExactly $projectId
        ($sets | ForEach-Object { $_[2] }) -join '|' | Should BeExactly (
            'AZURE_SUBSCRIPTION_ID|AZURE_LOCATION|AZURE_TENANT_ID|AZURE_RESOURCE_GROUP|AZURE_AI_PROJECT_ID|FOUNDRY_PROJECT_ENDPOINT|' +
            'FOUNDRY_MODEL_NAME|GATEWAY_MODELS_ENDPOINT|GATEWAY_SUBSCRIPTION_KEY|APIM_MCP_URL|ATLASSIAN_STATUS_URL|' +
            'APIM_STATUS_SUBSCRIPTION_KEY|APIM_MCP_SUBSCRIPTION_KEY|' +
            'AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__APIM__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME')
        @($sets | Where-Object { $_[2] -eq 'AZURE_SUBSCRIPTION_ID' })[0][3] | Should BeExactly $subscription
        @($sets | Where-Object { $_[2] -eq 'AZURE_RESOURCE_GROUP' })[0][3] | Should BeExactly 'test-rg'
        @($sets | Where-Object { $_[2] -eq 'AZURE_TENANT_ID' })[0][3] | Should BeExactly $tenant
        @($sets | Where-Object { $_[2] -eq 'AZURE_LOCATION' })[0][3] | Should BeExactly 'swedencentral'
        ($sets | ForEach-Object { $_ -join ' ' }) -join "`n" | Should Not Match 'do-not-print'
    }

    It 'honors explicit environment overrides and persists them only after verification' {
        & $deploymentScript -EnvFile $envPath -EnvironmentName 'override-env' -Confirm:$false
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['AZURE_ENV_NAME'] | Should BeExactly 'override-env'
        $saved['AZURE_FOUNDRY_AGENT_NAME'] | Should BeExactly 'atlassian-agent'
    }

    It 'injects the agent settings using canonical APIM URLs rather than duplicate root aliases' {
        [IO.File]::AppendAllText($envPath, "`nAPIM_MCP_URL=https://wrong.example.test/mcp`nATLASSIAN_STATUS_URL=https://wrong.example.test/status`n")
        & $deploymentScript -EnvFile $envPath -Confirm:$false
        $expected = [ordered]@{
            FOUNDRY_MODEL_NAME = 'test-model'
            GATEWAY_MODELS_ENDPOINT = 'https://models.example.test'
            GATEWAY_SUBSCRIPTION_KEY = 'gateway-test-key'
            APIM_MCP_URL = 'https://gateway.example.test/atlassian-mcp/mcp'
            ATLASSIAN_STATUS_URL = 'https://gateway.example.test/atlassian-connect/status'
            APIM_STATUS_SUBSCRIPTION_KEY = 'status-test-key'
            APIM_MCP_SUBSCRIPTION_KEY = 'mcp-test-key'
            AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__APIM__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME = 'apim-user-oauth'
        }
        $sets = @($fixture.AzdCalls | Where-Object { $_[0] -eq 'env' -and $_[1] -eq 'set' })
        foreach ($entry in $expected.GetEnumerator()) {
            $setting = @($sets | Where-Object { $_[2] -ceq $entry.Key })
            $setting.Count | Should Be 1
            $setting[0][3] | Should BeExactly $entry.Value
        }
        @($sets | Where-Object { $_[2] -eq 'AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME' }).Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME'] | Should BeExactly 'apim-user-oauth'
    }

    It 'defaults the model when the root input is <State>' -TestCases @(
        @{ State = 'missing' }, @{ State = 'empty' }
    ) {
        param($State)
        $text = if ($State -eq 'missing') {
            $original -replace '(?m)^FOUNDRY_MODEL_NAME=.*\r?\n', ''
        } else {
            $original.Replace('FOUNDRY_MODEL_NAME=test-model', 'FOUNDRY_MODEL_NAME=')
        }
        [IO.File]::WriteAllText($envPath, $text)
        & $deploymentScript -EnvFile $envPath -Confirm:$false
        $setting = @($fixture.AzdCalls | Where-Object { $_[0] -eq 'env' -and $_[1] -eq 'set' -and $_[2] -eq 'FOUNDRY_MODEL_NAME' })
        $setting[0][3] | Should BeExactly 'gpt-5.6-luna'
    }

    It 'clears optional APIM keys in a reused environment when root keys are <State>' -TestCases @(
        @{ State = 'missing' }, @{ State = 'empty' }
    ) {
        param($State)
        $null = New-Item -ItemType Directory -Path $existingEnvFolder -Force
        [IO.File]::WriteAllLines($existingEnvPath, @(
            "AZURE_AI_PROJECT_ID=$projectId", 'APIM_STATUS_SUBSCRIPTION_KEY=stale-status-key',
            'APIM_MCP_SUBSCRIPTION_KEY=stale-mcp-key'))
        $text = if ($State -eq 'missing') {
            $original -replace '(?m)^APIM_(STATUS|MCP)_SUBSCRIPTION_KEY=.*\r?\n', ''
        } else {
            $original.Replace('APIM_STATUS_SUBSCRIPTION_KEY=status-test-key', 'APIM_STATUS_SUBSCRIPTION_KEY=').
                Replace('APIM_MCP_SUBSCRIPTION_KEY=mcp-test-key', 'APIM_MCP_SUBSCRIPTION_KEY=')
        }
        [IO.File]::WriteAllText($envPath, $text)
        & $deploymentScript -EnvFile $envPath -Confirm:$false
        foreach ($key in @('APIM_STATUS_SUBSCRIPTION_KEY', 'APIM_MCP_SUBSCRIPTION_KEY')) {
            $setting = @($fixture.AzdCalls | Where-Object { $_[0] -eq 'env' -and $_[1] -eq 'set' -and $_[2] -eq $key })
            $setting.Count | Should Be 1
            $setting[0][3] | Should BeExactly ''
            $setting[0][4] | Should BeExactly '--cwd'
        }
    }

    It 'requires agent input <Key> before any CLI changes' -TestCases @(
        @{ Key = 'GATEWAY_MODELS_ENDPOINT' }, @{ Key = 'GATEWAY_SUBSCRIPTION_KEY' },
        @{ Key = 'AZURE_APIM_MCP_SERVER_URL' }, @{ Key = 'AZURE_APIM_CONNECT_STATUS_URL' },
        @{ Key = 'AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME' }
    ) {
        param($Key)
        Update-PrerequisiteEnv -Path $envPath -Values @{ $Key = '' }
        $before = [IO.File]::ReadAllText($envPath)
        { & $deploymentScript -EnvFile $envPath -Confirm:$false } | Should Throw $Key
        $fixture.AzCalls.Count | Should Be 0
        $fixture.AzdCalls.Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $before
    }

    It 'redacts every new subscription key from failed azd diagnostics' {
        $fixture.FailAzd = 'deploy'
        $fixture.AzdError = 'ERROR: deployment failed; gateway-test-key status-test-key mcp-test-key'
        $message = ''
        try { & $deploymentScript -EnvFile $envPath -Confirm:$false } catch { $message = $_.Exception.Message }
        $message | Should Match 'deployment failed'
        $message | Should Match '\[REDACTED\]'
        $message | Should Not Match 'gateway-test-key|status-test-key|mcp-test-key'
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'binds every injected agent setting under the actual manifest agent service' {
        $manifestPath = Join-Path $sourceRoot 'azure.yaml'
        $python = @'
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as f:
    manifest = yaml.safe_load(f)
if "env" in manifest["services"]:
    raise ValueError("env must be under services.agent, not a separate service")
env = manifest["services"]["agent"]["env"]
for key, value in env.items():
    if value != "${" + key + "}":
        raise ValueError("Agent setting is not bound to its azd variable: " + key)
print("|".join(env))
'@
        $keys = & python -c $python $manifestPath
        if ($LASTEXITCODE -ne 0) { throw 'Validating agent environment bindings failed.' }
        $keys | Should BeExactly (
            'FOUNDRY_MODEL_NAME|GATEWAY_MODELS_ENDPOINT|GATEWAY_SUBSCRIPTION_KEY|APIM_MCP_URL|ATLASSIAN_STATUS_URL|' +
            'APIM_STATUS_SUBSCRIPTION_KEY|APIM_MCP_SUBSCRIPTION_KEY|' +
            'AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__APIM__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME')
    }

    It 'uses the manifest name instead of a stale environment value and saves it after verification' {
        $manifestPath = Join-Path $deploymentRoot 'azure.yaml'
        $manifest = [IO.File]::ReadAllText($manifestPath).Replace('name: atlassian-agent', 'name: "renamed-agent" # literal name')
        [IO.File]::WriteAllText($manifestPath, $manifest)
        $fixture.AgentName = 'renamed-agent'
        $fixture.BotEndpoint = "$endpoint/agents/renamed-agent/endpoint/protocols/activity?api-version=v1"
        & $deploymentScript -EnvFile $envPath -Confirm:$false
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_FOUNDRY_AGENT_NAME'] | Should BeExactly 'renamed-agent'
        @($fixture.AzdCalls | Where-Object { $_[0] -eq 'deploy' })[0][1] | Should BeExactly 'agent'
        $agentReads = @($fixture.AzCalls | Where-Object {
            $_[0] -eq 'rest' -and ($_ -join ' ') -like '*services.ai.azure.com*'
        })
        foreach ($call in $agentReads) { ($call -join ' ') | Should Match '/agents/renamed-agent\?api-version=v1' }
    }

    It 'does not require a saved agent name before deployment' {
        [IO.File]::WriteAllText($envPath, $original.Replace('AZURE_FOUNDRY_AGENT_NAME=atlassian-agent', ''))
        & $deploymentScript -EnvFile $envPath -Confirm:$false
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_FOUNDRY_AGENT_NAME'] | Should BeExactly 'atlassian-agent'
    }

    It 'rejects an ambiguous or invalid manifest before Azure calls: <Label>' -TestCases @(
        @{ Label = 'missing name'; Yaml = 'services: {agent: {host: azure.ai.agent}}' },
        @{ Label = 'empty name'; Yaml = 'services: {agent: {host: azure.ai.agent, name: ""}}' },
        @{ Label = 'non-string name'; Yaml = 'services: {agent: {host: azure.ai.agent, name: 123}}' },
        @{ Label = 'substitution'; Yaml = 'services: {agent: {host: azure.ai.agent, name: "${AZURE_FOUNDRY_AGENT_NAME}"}}' },
        @{ Label = 'duplicate name'; Yaml = 'services: {agent: {host: azure.ai.agent, name: first, name: second}}' },
        @{ Label = 'wrong host'; Yaml = 'services: {agent: {host: azure.ai.project, name: wrong}}' },
        @{ Label = 'missing service'; Yaml = 'name: project-name' },
        @{ Label = 'malformed YAML'; Yaml = 'services: [bad' }
    ) {
        param($Label, $Yaml)
        [IO.File]::WriteAllText((Join-Path $deploymentRoot 'azure.yaml'), $Yaml)
        { & $deploymentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'Reading the agent name from azure.yaml failed'
        $fixture.AzCalls.Count | Should Be 0
        $fixture.AzdCalls.Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'defaults to the shared repository-root environment path' {
        Push-Location $TestDrive
        try {
            Get-PrerequisiteEnvPath | Should BeExactly ([IO.Path]::GetFullPath((Join-Path $sourceRoot '..\.env')))
        } finally { Pop-Location }
    }

    It 'reuses a matching local environment without recreating it' {
        $null = New-Item -ItemType Directory -Path $existingEnvFolder -Force
        [IO.File]::WriteAllLines($existingEnvPath, @("AZURE_AI_PROJECT_ID=$projectId", "FOUNDRY_PROJECT_ENDPOINT=$endpoint"))
        & $deploymentScript -EnvFile $envPath -Confirm:$false
        @($fixture.AzdCalls | Where-Object { $_[0] -eq 'env' -and $_[1] -eq 'new' }).Count | Should Be 0
        @($fixture.AzdCalls | Where-Object { $_[0] -eq 'deploy' }).Count | Should Be 1
    }

    It 'refuses to repoint an existing environment before any CLI changes' {
        $null = New-Item -ItemType Directory -Path $existingEnvFolder -Force
        [IO.File]::WriteAllText($existingEnvPath, 'AZURE_AI_PROJECT_ID=a-different-project')
        { & $deploymentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'Choose a new AZURE_ENV_NAME'
        $fixture.AzdCalls.Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'supports WhatIf without any CLI calls or environment writes' {
        & $deploymentScript -EnvFile $envPath -WhatIf
        $fixture.AzCalls.Count | Should Be 0
        $fixture.AzdCalls.Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'stops on <Operation> failure and leaves root configuration unchanged' -TestCases @(
        @{ Operation = 'env new' }, @{ Operation = 'env set' }, @{ Operation = 'ai agent' }, @{ Operation = 'deploy' }
    ) {
        param($Operation)
        $fixture.FailAzd = $Operation
        { & $deploymentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'azd exit code 1'
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
        @($fixture.AzCalls | Where-Object { $_[0] -eq 'resource' }).Count | Should Be 0
        if ($Operation -eq 'ai agent') {
            @($fixture.AzdCalls | Where-Object { $_[0] -eq 'deploy' }).Count | Should Be 0
        }
    }

    It 'includes the real azd error while redacting root and azd secrets and token fields' {
        $null = New-Item -ItemType Directory -Path $existingEnvFolder -Force
        [IO.File]::WriteAllLines($existingEnvPath, @("AZURE_AI_PROJECT_ID=$projectId", 'SERVICE_SECRET=azd-only-secret'))
        $fixture.FailAzd = 'deploy'
        $fixture.AzdError = @(
            'ERROR: agent service definition is not valid: invalid agent name'
            'Known root value: do-not-print; known azd value: azd-only-secret'
            'Authorization: Bearer abc.def.ghi'
            '{"client_secret":"new-unlisted-secret","accessToken":"new-access-token"}'
            'https://example.com/file?sv=1&sig=sas-signature&other=value'
        ) -join "`n"
        $message = ''
        try { & $deploymentScript -EnvFile $envPath -Confirm:$false } catch { $message = $_.Exception.Message }
        $message | Should Match 'invalid agent name'
        $message | Should Match '\[REDACTED\]'
        $message | Should Not Match 'do-not-print|azd-only-secret|abc.def.ghi|new-unlisted-secret|new-access-token|sas-signature'
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'redacts encoded and JSON-escaped known secrets' {
        $secret = 'secret with "quotes" & symbols'
        [IO.File]::AppendAllText($envPath, "`nCUSTOM_SECRET=$(Format-DotEnvValue $secret)`n")
        $jsonSecret = ConvertTo-Json -InputObject $secret -Compress
        $fixture.FailAzd = 'deploy'
        $fixture.AzdError = "ERROR: validation failed`nEncoded: $([Uri]::EscapeDataString($secret))`nJSON: $jsonSecret"
        $message = ''
        try { & $deploymentScript -EnvFile $envPath -Confirm:$false } catch { $message = $_.Exception.Message }
        $message | Should Match 'validation failed'
        $message | Should Not Match 'quotes|symbols'
    }

    It 'keeps the final azd error when diagnostic output must be truncated' {
        $fixture.FailAzd = 'deploy'
        $fixture.AzdError = ('x' * 13000) + "`nERROR: final deployment error do-not-print"
        $message = ''
        try { & $deploymentScript -EnvFile $envPath -Confirm:$false } catch { $message = $_.Exception.Message }
        $message | Should Match 'Earlier output truncated'
        $message | Should Match 'final deployment error'
        $message | Should Not Match 'do-not-print'
    }

    It 'rejects a mismatched project endpoint before deployment' {
        { & $deploymentScript -EnvFile $envPath -ProjectEndpoint 'https://wrong.services.ai.azure.com/api/projects/wrong' -Confirm:$false } |
            Should Throw 'does not match'
        $fixture.AzdCalls.Count | Should Be 0
    }

    It 'rejects an incorrect CLI tenant before azd changes' {
        $fixture.AccountTenant = '44444444-4444-4444-4444-444444444444'
        { & $deploymentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'configured public-cloud tenant'
        $fixture.AzdCalls.Count | Should Be 0
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'requires all mandatory configuration before deployment' {
        { & $deploymentScript -EnvFile $envPath -EnvironmentName '' -Confirm:$false } | Should Throw 'AZURE_ENV_NAME'
        $fixture.AzdCalls.Count | Should Be 0
    }

    It 'does not guess a bot when discovery returns <Count> matching bots' -TestCases @(
        @{ Count = 0 }, @{ Count = 2 }
    ) {
        param($Count)
        $fixture.BotIds = if ($Count -eq 0) { @() } else { @($botId, ($botId + '-second')) }
        { & $deploymentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'Supply -BotServiceArmId'
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'validates an explicitly selected bot without listing unrelated bots' {
        & $deploymentScript -EnvFile $envPath -BotServiceArmId $botId -Confirm:$false
        @($fixture.AzCalls | Where-Object { $_[0] -eq 'resource' }).Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_BOT_SERVICE_RESOURCE_ID'] | Should BeExactly $botId
    }

    It 'refuses saving a bot whose messaging endpoint targets another agent' {
        $fixture.BotEndpoint = "$endpoint/agents/other/endpoint/protocols/activity?api-version=v1"
        { & $deploymentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'messaging endpoint'
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'refuses saving an explicitly selected bot with a different identity' {
        $fixture.BotClient = '44444444-4444-4444-4444-444444444444'
        { & $deploymentScript -EnvFile $envPath -BotServiceArmId $botId -Confirm:$false } | Should Throw 'does not match'
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }

    It 'refuses saving when agent read-back is invalid' {
        $fixture.AgentClient = ''
        { & $deploymentScript -EnvFile $envPath -Confirm:$false } | Should Throw 'identity could not be verified'
        [IO.File]::ReadAllText($envPath) | Should BeExactly $original
    }
}
