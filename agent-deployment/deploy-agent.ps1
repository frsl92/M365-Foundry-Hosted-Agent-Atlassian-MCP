<#
.SYNOPSIS
    Deploys the agent to an existing Foundry project using the root .env.
.DESCRIPTION
    Creates or reuses a local azd environment, deploys the agent, verifies its
    bot identity and endpoint, then saves the post-requisite inputs atomically.
    Requires azd auth login and az login. Does not provision a Foundry project.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$EnvironmentName,
    [string]$TenantId,
    [string]$Location,
    [string]$ProjectResourceId,
    [string]$ProjectEndpoint,
    [string]$BotServiceArmId,
    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\common-scripts\Common.ps1')
if (-not $EnvFile) { $EnvFile = Get-PrerequisiteEnvPath }
$EnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
$configuration = Read-PrerequisiteEnv -Path $EnvFile
$inputKeys = [ordered]@{
    EnvironmentName = 'AZURE_ENV_NAME'
    TenantId = 'AZURE_TENANT_ID'
    Location = 'AZURE_LOCATION'
    ProjectResourceId = 'AZURE_FOUNDRY_PROJECT_RESOURCE_ID'
    ProjectEndpoint = 'AZURE_FOUNDRY_PROJECT_ENDPOINT'
    BotServiceArmId = 'AZURE_BOT_SERVICE_RESOURCE_ID'
}
foreach ($entry in $inputKeys.GetEnumerator()) {
    $value = Resolve-PrerequisiteValue -Parameters $PSBoundParameters -ParameterName $entry.Key `
        -Values $configuration -Key $entry.Value -DefaultValue (Get-Variable -Name $entry.Key -ValueOnly)
    Set-Variable -Name $entry.Key -Value $value -WhatIf:$false -Confirm:$false
}
foreach ($entry in $inputKeys.GetEnumerator()) {
    if ($entry.Key -ne 'BotServiceArmId' -and [string]::IsNullOrWhiteSpace((Get-Variable -Name $entry.Key -ValueOnly))) {
        throw "Supply -$($entry.Key) or set $($entry.Value) in '$EnvFile'."
    }
}
$agentInputKeys = [ordered]@{
    FOUNDRY_MODEL_NAME = 'FOUNDRY_MODEL_NAME'
    GATEWAY_MODELS_ENDPOINT = 'GATEWAY_MODELS_ENDPOINT'
    GATEWAY_SUBSCRIPTION_KEY = 'GATEWAY_SUBSCRIPTION_KEY'
    APIM_MCP_URL = 'AZURE_APIM_MCP_SERVER_URL'
    ATLASSIAN_STATUS_URL = 'AZURE_APIM_CONNECT_STATUS_URL'
    APIM_STATUS_SUBSCRIPTION_KEY = 'APIM_STATUS_SUBSCRIPTION_KEY'
    APIM_MCP_SUBSCRIPTION_KEY = 'APIM_MCP_SUBSCRIPTION_KEY'
    AGENTAPPLICATION__USERAUTHORIZATION__HANDLERS__APIM__SETTINGS__AZUREBOTOAUTHCONNECTIONNAME = 'AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME'
}
$agentValues = [ordered]@{}
foreach ($entry in $agentInputKeys.GetEnumerator()) {
    $defaultValue = if ($entry.Key -eq 'FOUNDRY_MODEL_NAME') { 'gpt-5.6-luna' } else { '' }
    $value = Resolve-PrerequisiteValue -Parameters @{} -ParameterName $entry.Key `
        -Values $configuration -Key $entry.Value -DefaultValue $defaultValue
    if ($entry.Key -notin @('APIM_STATUS_SUBSCRIPTION_KEY', 'APIM_MCP_SUBSCRIPTION_KEY') -and
        [string]::IsNullOrWhiteSpace($value)) {
        throw "Set $($entry.Value) in '$EnvFile' before deployment."
    }
    $agentValues[$entry.Key] = $value
}
if ($EnvironmentName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,63}$') {
    throw 'EnvironmentName must be 1-64 letters, digits or hyphens, starting with a letter or digit.'
}
if ($Location -cnotmatch '^[a-z0-9]+$') { throw 'Location must be an Azure region name such as swedencentral.' }
$tenantGuid = [Guid]::Empty
if (-not [Guid]::TryParse($TenantId, [ref]$tenantGuid) -or $tenantGuid -eq [Guid]::Empty) {
    throw 'TenantId must be a nonempty GUID.'
}
if ($ProjectResourceId -notmatch '^/subscriptions/(?<Subscription>[0-9a-f-]{36})/resourceGroups/(?<Group>[A-Za-z0-9._()-]+)/providers/Microsoft\.CognitiveServices/accounts/(?<Account>[A-Za-z0-9-]+)/projects/(?<Project>[A-Za-z0-9._-]+)$') {
    throw 'ProjectResourceId must be the full ARM ID of the existing Foundry project.'
}
$subscriptionId = $Matches.Subscription
$resourceGroup = $Matches.Group
$accountName = $Matches.Account
$projectName = $Matches.Project
$subscriptionGuid = [Guid]::Empty
if (-not [Guid]::TryParse($subscriptionId, [ref]$subscriptionGuid) -or $subscriptionGuid -eq [Guid]::Empty) {
    throw 'The project subscription ID must be a nonempty GUID.'
}
$ProjectEndpoint = $ProjectEndpoint.TrimEnd('/')
if ($ProjectEndpoint -cne "https://$accountName.services.ai.azure.com/api/projects/$projectName") {
    throw 'ProjectEndpoint does not match ProjectResourceId. Use the matching Azure public-cloud project endpoint.'
}
foreach ($commandName in @('az', 'azd')) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) { throw "$commandName is required. Install and authenticate it first." }
}
if (-not [IO.File]::Exists((Join-Path $PSScriptRoot 'azure.yaml'))) { throw 'The deployment azure.yaml is missing.' }
if (-not [IO.File]::Exists((Join-Path $PSScriptRoot '..\.env.v1.example'))) { throw 'The root .env.v1.example template is missing.' }
$AgentName = Get-DeploymentAgentName -ManifestPath (Join-Path $PSScriptRoot 'azure.yaml') -ServiceName 'agent'

function Invoke-DeploymentAzd {
    param([string[]]$Arguments, [string]$Operation)

    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $output = & azd @Arguments --cwd $PSScriptRoot --environment $EnvironmentName --no-prompt 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) {
        $diagnostic = $output -join "`n"
        foreach ($values in @($configuration, $existing, [Environment]::GetEnvironmentVariables())) {
            if ($null -eq $values) { continue }
            foreach ($entry in $values.GetEnumerator()) {
                if ([string]$entry.Key -match '(?i)secret|password|token|api.?key|subscription.?key|credential|connection.?string|sas' -and
                    -not [string]::IsNullOrEmpty([string]$entry.Value)) {
                    $secret = [string]$entry.Value
                    $diagnostic = $diagnostic.Replace($secret, '[REDACTED]')
                    $diagnostic = $diagnostic.Replace([Uri]::EscapeDataString($secret), '[REDACTED]')
                    $jsonSecret = ConvertTo-Json -InputObject $secret -Compress
                    $diagnostic = $diagnostic.Replace($jsonSecret.Substring(1, $jsonSecret.Length - 2), '[REDACTED]')
                }
            }
        }
        $diagnostic = [regex]::Replace($diagnostic, '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*', 'Bearer [REDACTED]')
        $diagnostic = [regex]::Replace($diagnostic,
            '(?im)(\b(?:client_secret|clientSecret|password|access_token|accessToken|refresh_token|refreshToken|api_key|apiKey|accountkey)\b["'']?\s*[:=]\s*)(?:"[^"\r\n]*"|''[^''\r\n]*''|[^\s,;]+)',
            '$1[REDACTED]')
        $diagnostic = [regex]::Replace($diagnostic, '(?i)([?&](?:sig|token|access_token|code)=)[^&\s"'']+', '$1[REDACTED]')
        $diagnostic = [regex]::Replace($diagnostic, '\x1B\[[0-?]*[ -/]*[@-~]', '')
        if ([string]::IsNullOrWhiteSpace($diagnostic)) { $diagnostic = 'azd returned no diagnostic output.' }
        # Redact before truncating so a secret cannot be exposed as a partial value.
        if ($diagnostic.Length -gt 12000) { $diagnostic = '[Earlier output truncated]' + "`n" + $diagnostic.Substring($diagnostic.Length - 12000) }
        throw "$Operation failed (azd exit code $exitCode). The root environment file has not been updated.`nRedacted azd output (review before sharing):`n$diagnostic"
    }
}

$azdEnvFile = Join-Path $PSScriptRoot ".azure\$EnvironmentName\.env"
$existingEnvironment = Test-Path -LiteralPath $azdEnvFile -PathType Leaf
if ($existingEnvironment) {
    $existing = Read-PrerequisiteEnv -Path $azdEnvFile
    foreach ($binding in @(
        @{ Key = 'AZURE_AI_PROJECT_ID'; Value = $ProjectResourceId },
        @{ Key = 'FOUNDRY_PROJECT_ENDPOINT'; Value = $ProjectEndpoint },
        @{ Key = 'AZURE_SUBSCRIPTION_ID'; Value = $subscriptionId },
        @{ Key = 'AZURE_TENANT_ID'; Value = $TenantId }
    )) {
        if ($existing[$binding.Key] -and $existing[$binding.Key] -ine $binding.Value) {
            throw "The existing azd environment '$EnvironmentName' has a different $($binding.Key). Choose a new AZURE_ENV_NAME instead of repointing it."
        }
    }
}
if ($BotServiceArmId) {
    $null = Get-PublishingContext -Parameters @{
        ProjectEndpoint = $ProjectEndpoint; AgentName = $AgentName; BotServiceArmId = $BotServiceArmId
    } -EnvFile $EnvFile
}

if (-not $PSCmdlet.ShouldProcess(
    "$ProjectResourceId / $AgentName",
    "Configure azd environment '$EnvironmentName', deploy the agent and save verified post-requisite values to '$EnvFile'")) {
    return
}

Write-Host '1. Checking the Azure CLI tenant used for deployment verification.'
$account = Invoke-PublishingCli -Arguments @('account', 'show', '--subscription', $subscriptionId) -Operation 'Read deployment account'
if ($account.environmentName -cne 'AzureCloud' -or $account.tenantId -ine $TenantId) {
    throw 'Azure CLI is not authenticated to the configured public-cloud tenant. Run az login with the configured tenant.'
}

Write-Host "2. Configuring azd environment '$EnvironmentName'."
if (-not $existingEnvironment) {
    Invoke-DeploymentAzd -Arguments @('env', 'new', $EnvironmentName, '--subscription', $subscriptionId, '--location', $Location) `
        -Operation 'Create azd environment'
}
$azdValues = [ordered]@{
    AZURE_SUBSCRIPTION_ID = $subscriptionId
    AZURE_LOCATION = $Location
    AZURE_TENANT_ID = $TenantId
    AZURE_RESOURCE_GROUP = $resourceGroup
    AZURE_AI_PROJECT_ID = $ProjectResourceId
    FOUNDRY_PROJECT_ENDPOINT = $ProjectEndpoint
}
foreach ($entry in $agentValues.GetEnumerator()) {
    $azdValues[$entry.Key] = $entry.Value
}
foreach ($entry in $azdValues.GetEnumerator()) {
    Invoke-DeploymentAzd -Arguments @('env', 'set', $entry.Key, $entry.Value) -Operation "Set azd $($entry.Key)"
}
Write-Host '3. Validating the local agent definition before deployment.'
Invoke-DeploymentAzd -Arguments @('ai', 'agent', 'doctor', '--local-only') -Operation 'Validate local agent definition'
Write-Host '4. Deploying the agent service. This can take several minutes.'
Invoke-DeploymentAzd -Arguments @('deploy', 'agent') -Operation 'Deploy agent'

Write-Host '5. Discovering and validating the deployed agent and Azure Bot Service.'
$requestContext = [pscustomobject]@{ SubscriptionId = $subscriptionId }
$agent = Invoke-PublishingRequest -Context $requestContext -Method GET `
    -Url "$ProjectEndpoint/agents/${AgentName}?api-version=v1" -Operation 'Read deployed agent'
$clientId = [Guid]::Empty
if ($agent.name -cne $AgentName -or
    -not [Guid]::TryParse([string]$agent.instance_identity.client_id, [ref]$clientId) -or $clientId -eq [Guid]::Empty) {
    throw 'Deployment finished, but the expected agent identity could not be verified. The root environment file has not been updated.'
}
if (-not $BotServiceArmId) {
    $bots = Invoke-PublishingCli -Arguments @('resource', 'list', '--subscription', $subscriptionId,
        '--resource-group', $resourceGroup, '--resource-type', 'Microsoft.BotService/botServices',
        '--query', '{value: @}') -Operation 'Discover deployed bots'
    if ($null -eq $bots.value) { throw 'Bot discovery returned no value array. The root environment file has not been updated.' }
    $botDetails = foreach ($botResource in $bots.value) {
        $candidateContext = Get-PublishingContext -Parameters @{
            ProjectEndpoint = $ProjectEndpoint; AgentName = $AgentName; BotServiceArmId = [string]$botResource.id
        } -EnvFile $EnvFile
        Invoke-PublishingRequest -Context $candidateContext -Method GET -Url $candidateContext.BotUrl -Arm `
            -Operation 'Read discovered bot'
    }
    $matchingBots = @($botDetails | Where-Object {
        $_.properties.msaAppId -ieq [string]$agent.instance_identity.client_id -and
        $_.properties.msaAppTenantId -ieq $TenantId
    })
    if ($matchingBots.Count -ne 1) {
        throw "Found $($matchingBots.Count) bots matching the deployed agent identity in '$resourceGroup'. Supply -BotServiceArmId for an existing matching bot (including one in another resource group). No post-requisite values were saved."
    }
    $BotServiceArmId = [string]$matchingBots[0].id
}
$context = Get-PublishingContext -Parameters @{
    ProjectEndpoint = $ProjectEndpoint; AgentName = $AgentName; BotServiceArmId = $BotServiceArmId
} -EnvFile $EnvFile
$null = Get-PublishingState -Context $context

Write-Host '6. Saving verified post-requisite inputs.'
Update-PrerequisiteEnv -Path $EnvFile -Values @{
    AZURE_ENV_NAME = $EnvironmentName
    AZURE_TENANT_ID = $TenantId
    AZURE_LOCATION = $Location
    AZURE_FOUNDRY_PROJECT_RESOURCE_ID = $ProjectResourceId
    AZURE_FOUNDRY_PROJECT_ENDPOINT = $ProjectEndpoint
    AZURE_FOUNDRY_AGENT_NAME = $AgentName
    AZURE_BOT_SERVICE_RESOURCE_ID = $BotServiceArmId
}
Write-Host 'Deployment and agent/bot verification succeeded. Run post-requisite 1 next; publishing settings and catalog approval are separate.'
