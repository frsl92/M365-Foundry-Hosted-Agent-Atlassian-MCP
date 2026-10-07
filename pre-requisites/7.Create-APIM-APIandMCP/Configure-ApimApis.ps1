<#
.SYNOPSIS
    Imports Atlassian Connect and exposes the external Atlassian MCP in APIM using Azure CLI.
.DESCRIPTION
    Requires prerequisites 5 and 6. Applies the get-status operation policy and
    the external MCP API policy. Both APIs require APIM subscription keys and
    retain the supplied delegated user authentication. Does not create or print keys.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$ApimName,
    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [string]$ConnectApiId,
    [string]$ConnectApiPath,
    [string]$McpApiId,
    [string]$McpApiPath,
    [string]$EnvFile,
    [string]$AssetDirectory = (Join-Path $PSScriptRoot 'assets'),
    [string]$FragmentAssetDirectory = (Join-Path $PSScriptRoot '..\6.Create-APIM-Fragments\assets'),
    [switch]$UpdateExisting
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
$specPath = Join-Path $AssetDirectory 'Atlassian Connect.openapi.yaml'
$spec = [IO.File]::ReadAllText($specPath)
$sha = [Security.Cryptography.SHA256]::Create()
try { $specHash = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($specPath))).Replace('-', '').ToLowerInvariant() }
finally { $sha.Dispose() }
$statusPolicy = Read-ApimPolicyAsset -Path (Join-Path $AssetDirectory 'get-status.xml') -Root policies
$mcpPolicy = Read-ApimPolicyAsset -Path (Join-Path $AssetDirectory 'atlassian-mcp.xml') -Root policies
$fragmentAssets = @{}
foreach ($name in @('atlassian-user-auth', 'atlassian-safe-errors')) {
    $fragmentAssets[$name] = Read-ApimPolicyAsset -Path (Join-Path $FragmentAssetDirectory "$name.xml") -Root fragment
}
$context = Get-ApimProvisioningContext -Parameters $PSBoundParameters -EnvFile $EnvFile
if ($context.Values['AZURE_APIM_POLICY_FRAGMENTS_CONFIGURED'] -cne 'true') { throw 'Complete prerequisite 6 before creating the APIs.' }
$inputKeys = [ordered]@{
    ConnectApiId = 'AZURE_APIM_CONNECT_API_ID'; ConnectApiPath = 'AZURE_APIM_CONNECT_API_PATH'
    McpApiId = 'AZURE_APIM_MCP_API_ID'; McpApiPath = 'AZURE_APIM_MCP_API_PATH'
}
$defaults = @{ ConnectApiId = 'atlassian-connect'; ConnectApiPath = 'atlassian-connect'; McpApiId = 'atlassian-mcp'; McpApiPath = 'atlassian-mcp' }
foreach ($entry in $inputKeys.GetEnumerator()) {
    $value = Resolve-PrerequisiteValue -Parameters $PSBoundParameters -ParameterName $entry.Key `
        -Values $context.Values -Key $entry.Value -DefaultValue $defaults[$entry.Key]
    if ($entry.Key.EndsWith('Id')) {
        if ($value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw "$($entry.Key) must be an unrevisioned API identifier (1-80 letters, digits, underscores or hyphens)." }
    } elseif ($value.Length -gt 400 -or $value -notmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$') {
        throw "$($entry.Key) must be a nonempty gateway route prefix without leading/trailing slashes or URL expressions."
    }
    Set-Variable -Name $entry.Key -Value $value -WhatIf:$false -Confirm:$false
}
if ($ConnectApiId -ieq $McpApiId -or $ConnectApiPath -ieq $McpApiPath -or
    $ConnectApiPath.StartsWith("$McpApiPath/", [StringComparison]::OrdinalIgnoreCase) -or
    $McpApiPath.StartsWith("$ConnectApiPath/", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The Connect and MCP API identifiers and route prefixes must be distinct and non-overlapping.'
}
$backendOrigin = [string]$context.Values['ATLASSIAN_MCP_BASE_URL']
$backendPath = [string]$context.Values['ATLASSIAN_MCP_PATH']
$uri = $null
if (-not [Uri]::TryCreate($backendOrigin, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or
    $backendOrigin -match '[\s{}"]' -or $backendPath -notmatch '^/[A-Za-z0-9._~/-]+$' -or $backendPath -match '//|(^|/)\.\.?(/|$)') {
    throw 'Set a valid HTTPS ATLASSIAN_MCP_BASE_URL origin and ATLASSIAN_MCP_PATH through prerequisite 5.'
}
$backendUrl = $backendOrigin.TrimEnd('/') + $backendPath
Assert-ApimPolicyDependencies -Context $context -Policies @($statusPolicy, $mcpPolicy)
foreach ($name in @('atlassian-user-auth', 'atlassian-safe-errors')) {
    $key = if ($name -eq 'atlassian-user-auth') { 'AZURE_APIM_USER_AUTH_FRAGMENT_ID' } else { 'AZURE_APIM_SAFE_ERRORS_FRAGMENT_ID' }
    $id = "$($context.ResourceId)/policyFragments/$name"
    if ($context.Values[$key] -ine $id) { throw "Saved fragment '$name' belongs to another resource. Rerun prerequisite 6." }
    $fragment = Get-ApimProvisioningResource -Context $context -Url "$($context.ServiceUrl)/policyFragments/${name}?api-version=2024-05-01&format=rawxml" -ResourceId $id
    if (-not (Test-ApimPolicyMatch -Actual $fragment.properties.value -Expected $fragmentAssets[$name] -Root fragment)) {
        throw "Fragment '$name' differs from its prerequisite 6 asset. Rerun prerequisite 6 before creating the APIs."
    }
}
$keyNames = @{ header = 'Ocp-Apim-Subscription-Key'; query = 'subscription-key' }
$apis = @(
    @{
        Name = $ConnectApiId; Version = '2024-05-01'; Policy = $statusPolicy
        PolicyPath = 'operations/get-status/policies/policy'
        Properties = @{
            type = 'http'; displayName = 'Atlassian Connect'; path = $ConnectApiPath; protocols = @('https')
            serviceUrl = $backendUrl; subscriptionRequired = $true; subscriptionKeyParameterNames = $keyNames
        }
    },
    @{
        Name = $McpApiId; Version = '2025-09-01-preview'; Policy = $mcpPolicy
        PolicyPath = 'policies/policy'
        Properties = @{
            type = 'mcp'; displayName = 'Atlassian MCP'; path = $McpApiPath; protocols = @('https')
            serviceUrl = $backendOrigin.TrimEnd('/'); subscriptionRequired = $true; subscriptionKeyParameterNames = $keyNames
            mcpProperties = @{ transportType = 'streamable'; endpoints = @{ message = @{ uriTemplate = $backendPath } } }
        }
    }
)
foreach ($api in $apis) {
    $api.Id = "$($context.ResourceId)/apis/$($api.Name)"
    $api.Url = "$($context.ServiceUrl)/apis/$($api.Name)?api-version=$($api.Version)"
    $api.Existing = Get-ApimProvisioningResource -Context $context -Url $api.Url -ResourceId $api.Id -AllowMissing
    if ($api.Existing -and (Get-ApimApiType -Properties $api.Existing.properties) -cne $api.Properties.type) {
        throw "API '$($api.Name)' has another API type. Select another identifier; it will not be replaced."
    }
    $api.Change = -not $api.Existing -or -not (Test-ApimApiProperties -Actual $api.Existing.properties -Expected $api.Properties)
    if ($api.Name -ceq $ConnectApiId -and $api.Existing) {
        $operations = Get-ApimProvisioningCollection -Context $context -Url "$($context.ServiceUrl)/apis/$ConnectApiId/operations?api-version=2024-05-01"
        if (@($operations | Where-Object { $_.name -cne 'get-status' }).Count) {
            throw 'The Connect API contains unrelated operations. Select another identifier; importing will not delete them.'
        }
        $api.Change = $api.Change -or $context.Values['AZURE_APIM_CONNECT_SPEC_SHA256'] -cne $specHash -or
            $operations.Count -ne 1 -or $operations[0].properties.method -cne 'GET' -or $operations[0].properties.urlTemplate -cne '/status'
    }
    $api.PolicyId = "$($api.Id)/$($api.PolicyPath)"
    $api.PolicyUrl = "$($context.ServiceUrl)/apis/$($api.Name)/$($api.PolicyPath)?api-version=$($api.Version)&format=rawxml"
    $api.ExistingPolicy = if ($api.Existing) {
        Get-ApimProvisioningResource -Context $context -Url $api.PolicyUrl -ResourceId $api.PolicyId -AllowMissing
    } else { $null }
    $api.PolicyChange = -not $api.ExistingPolicy -or -not (Test-ApimPolicyMatch -Actual $api.ExistingPolicy.properties.value -Expected $api.Policy -Root policies)
    if ($api.Existing -and ($api.Change -or ($api.ExistingPolicy -and $api.PolicyChange)) -and -not $UpdateExisting) {
        throw "API '$($api.Name)' or its policy differs (or the imported specification is unverified). Review and rerun with -UpdateExisting; no writes were made."
    }
}
if (-not $PSCmdlet.ShouldProcess($context.ResourceId, 'Import Atlassian Connect, expose the external MCP, apply policies and save verified outputs')) { return }
$saved = [ordered]@{ AZURE_APIM_APIS_CONFIGURED = 'false' }
foreach ($entry in $inputKeys.GetEnumerator()) { $saved[$entry.Value] = Get-Variable -Name $entry.Key -ValueOnly }
Update-PrerequisiteEnv -Path $context.EnvFile -Values $saved
foreach ($api in $apis) {
    if ($api.Change) {
        $properties = $api.Properties.Clone()
        if ($api.Existing) {
            foreach ($name in @(
                'description', 'authenticationSettings', 'apiRevision', 'apiVersion', 'apiVersionSetId',
                'apiRevisionDescription', 'apiVersionDescription', 'contact', 'license', 'termsOfServiceUrl'
            )) {
                $property = $api.Existing.properties.PSObject.Properties[$name]
                if ($null -ne $property) { $properties[$name] = $property.Value }
            }
        }
        if ($api.Name -ceq $ConnectApiId) { $properties['format'] = 'openapi'; $properties['value'] = $spec }
        Invoke-ApimProvisioningRequest -Context $context -Method put -Url $api.Url `
            -Body @{ properties = $properties } -Existing:([bool]$api.Existing)
    }
    $null = Wait-ApimProvisioningResource -Context $context -Url $api.Url -ResourceId $api.Id -Matches {
        param($resource)
        Test-ApimApiProperties -Actual $resource.properties -Expected $api.Properties
    }
    if ($api.Name -ceq $ConnectApiId) {
        $operationId = "$($api.Id)/operations/get-status"
        $null = Wait-ApimProvisioningResource -Context $context -Url "$($context.ServiceUrl)/apis/$ConnectApiId/operations/get-status?api-version=2024-05-01" -ResourceId $operationId -Matches {
            param($resource)
            $resource.properties.method -ceq 'GET' -and $resource.properties.urlTemplate -ceq '/status'
        }
    }
    if ($api.PolicyChange -or $api.Change) {
        Invoke-ApimProvisioningRequest -Context $context -Method put `
            -Url "$($context.ServiceUrl)/apis/$($api.Name)/$($api.PolicyPath)?api-version=$($api.Version)" `
            -Body @{ properties = @{ format = 'rawxml'; value = $api.Policy } } -Existing:([bool]$api.ExistingPolicy)
    }
    $null = Wait-ApimProvisioningResource -Context $context -Url $api.PolicyUrl -ResourceId $api.PolicyId -Matches {
        param($resource)
        Test-ApimPolicyMatch -Actual $resource.properties.value -Expected $api.Policy -Root policies
    }
}
Update-PrerequisiteEnv -Path $context.EnvFile -Values @{
    AZURE_APIM_CONNECT_API_RESOURCE_ID = $apis[0].Id
    AZURE_APIM_CONNECT_SPEC_SHA256 = $specHash
    AZURE_APIM_CONNECT_STATUS_URL = "$($context.GatewayUrl)/$ConnectApiPath/status"
    AZURE_APIM_MCP_API_RESOURCE_ID = $apis[1].Id
    AZURE_APIM_MCP_SERVER_URL = "$($context.GatewayUrl)/$McpApiPath/mcp"
    AZURE_APIM_APIS_CONFIGURED = 'true'
}
Write-Host 'Verified both APIs, get-status and MCP policies, and Ocp-Apim-Subscription-Key requirements. Keys were not created or printed; functional user consent and client tests remain separate.'
