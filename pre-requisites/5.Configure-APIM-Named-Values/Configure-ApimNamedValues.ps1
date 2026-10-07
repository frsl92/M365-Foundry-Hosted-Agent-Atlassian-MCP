<#
.SYNOPSIS
    Creates or reuses the twelve non-secret named values used by the APIM policies.
.DESCRIPTION
    Reuses prerequisites 2-4 and the shared .env. Conflicting values require
    -UpdateExisting. Secret, Key Vault and unrelated named values are never changed.
.EXAMPLE
    .\Configure-ApimNamedValues.ps1
.EXAMPLE
    .\Configure-ApimNamedValues.ps1 -UpdateExisting
#>
[CmdletBinding()]
param(
    [string]$ApimName,
    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [string]$McpBaseUrl,
    [string]$McpPath,
    [string]$PostLoginRedirectUrl,
    [string]$ArmApiVersion,
    [string]$EnvFile,
    [switch]$UpdateExisting
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
if (-not $EnvFile) { $EnvFile = Get-PrerequisiteEnvPath }
$EnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
$configuration = Read-PrerequisiteEnv -Path $EnvFile
$inputKeys = [ordered]@{
    ApimName = 'AZURE_APIM_NAME'
    ResourceGroupName = 'AZURE_RESOURCE_GROUP_NAME'
    SubscriptionId = 'AZURE_SUBSCRIPTION_ID'
    McpBaseUrl = 'ATLASSIAN_MCP_BASE_URL'
    McpPath = 'ATLASSIAN_MCP_PATH'
    PostLoginRedirectUrl = 'ATLASSIAN_POST_LOGIN_REDIRECT_URL'
    ArmApiVersion = 'AZURE_APIM_POLICY_ARM_API_VERSION'
}
$defaults = @{
    McpBaseUrl = 'https://mcp.atlassian.com'
    McpPath = '/v2/mcp'
    PostLoginRedirectUrl = 'https://www.atlassian.com/software/jira'
    ArmApiVersion = '2022-08-01'
}
foreach ($entry in $inputKeys.GetEnumerator()) {
    $value = Resolve-PrerequisiteValue -Parameters $PSBoundParameters -ParameterName $entry.Key `
        -Values $configuration -Key $entry.Value -DefaultValue ([string]$defaults[$entry.Key])
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Supply -$($entry.Key) or set $($entry.Value) in '$EnvFile'." }
    Set-Variable -Name $entry.Key -Value $value
}

function Assert-NamedValueGuid {
    param([string]$Value, [string]$Key)
    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [Guid]::Empty) {
        throw "$Key must be a nonempty GUID. Complete the earlier prerequisites for the selected APIM instance."
    }
    return $parsed.ToString()
}

$SubscriptionId = Assert-NamedValueGuid $SubscriptionId 'AZURE_SUBSCRIPTION_ID'
if ($ApimName -notmatch '^[A-Za-z](?:[A-Za-z0-9-]{0,48}[A-Za-z0-9])?$') {
    throw 'ApimName must be a valid APIM service name, not a URL or resource ID.'
}
if ($ResourceGroupName -notmatch '^[\p{L}\p{N}_().-]{1,90}$' -or $ResourceGroupName.EndsWith('.')) {
    throw 'ResourceGroupName must be a valid resource group name, not a resource ID.'
}
$resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName"
if ($configuration['AZURE_APIM_RESOURCE_ID'] -ine $resourceId) {
    throw 'Missing or mismatched saved APIM resource ID. Rerun prerequisite 2 for the selected APIM instance.'
}
$principalId = Assert-NamedValueGuid $configuration['AZURE_APIM_IDENTITY_PRINCIPAL_ID'] 'AZURE_APIM_IDENTITY_PRINCIPAL_ID'
$tenantId = Assert-NamedValueGuid $configuration['AZURE_TENANT_ID'] 'AZURE_TENANT_ID'
if ($configuration['AZURE_APIM_IDENTITY_TENANT_ID'] -ine $tenantId) {
    throw 'The saved APIM identity and app registrations must belong to the same tenant. Rerun prerequisites 2 and 4.'
}
if ($configuration['AZURE_APP_REGISTRATIONS_CONFIGURED'] -cne 'true') {
    throw 'Complete prerequisite 4 successfully before configuring the named values.'
}
$apiClientId = Assert-NamedValueGuid $configuration['APIM_API_CLIENT_ID'] 'APIM_API_CLIENT_ID'
$authClientId = Assert-NamedValueGuid $configuration['AUTH_CLIENT_ID'] 'AUTH_CLIENT_ID'
if ($apiClientId -eq $authClientId -or $principalId -in @($apiClientId, $authClientId)) {
    throw 'The two application/client IDs and the APIM managed identity principal ID must be distinct.'
}
$providerName = $configuration['AZURE_APIM_CREDENTIAL_PROVIDER_NAME']
if ($providerName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$' -or
    $configuration['AZURE_APIM_CREDENTIAL_PROVIDER_ID'] -ine "$resourceId/authorizationProviders/$providerName") {
    throw 'Missing or mismatched saved credential provider. Complete prerequisite 3 for the selected APIM instance.'
}
foreach ($entry in @{ McpBaseUrl = $McpBaseUrl; PostLoginRedirectUrl = $PostLoginRedirectUrl }.GetEnumerator()) {
    $uri = $null
    if (-not [Uri]::TryCreate($entry.Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Fragment -or
        $entry.Value -match '[\s{}"]') {
        throw "$($entry.Key) must be an absolute HTTPS URL without credentials, a fragment, whitespace or policy expressions."
    }
    if ($entry.Key -eq 'McpBaseUrl' -and ($uri.AbsolutePath -ne '/' -or $uri.Query)) {
        throw 'McpBaseUrl must be an HTTPS origin without a path or query; configure McpPath separately.'
    }
}
$McpBaseUrl = $McpBaseUrl.TrimEnd('/')
if ($McpPath -notmatch '^/[A-Za-z0-9._~/-]+$' -or $McpPath -match '//|(^|/)\.\.?(/|$)') {
    throw 'McpPath must be an absolute backend path without a query, fragment, dot segments or policy expressions.'
}
$versionDate = [DateTime]::MinValue
if (-not [DateTime]::TryParseExact($ArmApiVersion, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::None, [ref]$versionDate)) {
    throw 'ArmApiVersion must be a stable API version in yyyy-MM-dd format. The policy examples use 2022-08-01.'
}
$desired = [ordered]@{
    'apim-api-client-id' = $apiClientId
    'apim-mi-object-id' = $principalId
    'apim-name' = $ApimName
    'arm-api-version' = $ArmApiVersion
    'atlassian-credential-provider' = $providerName
    'atlassian-mcp-base-url' = $McpBaseUrl
    'atlassian-mcp-path' = $McpPath
    'atlassian-post-login-redirect-url' = $PostLoginRedirectUrl
    'bot-user-auth-client-id' = $authClientId
    'rg' = $ResourceGroupName
    'sub-id' = $SubscriptionId
    'tenant-id' = $tenantId
}
foreach ($entry in $desired.GetEnumerator()) {
    if ($entry.Value.Length -gt 4096) { throw "The value for '$($entry.Key)' exceeds APIM's 4096-character limit." }
}
$azureCliCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azureCliCommand) { throw 'Azure CLI is required. Install it, run az login, and rerun this script.' }
$serviceUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$([Uri]::EscapeDataString($ResourceGroupName))/providers/Microsoft.ApiManagement/service/$ApimName"
$collectionUrl = "$serviceUrl/namedValues?api-version=2024-05-01"

function Invoke-NamedValueCli {
    param([string[]]$Arguments, [switch]$NoContent)
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $output = & az @Arguments --subscription $SubscriptionId --only-show-errors --output $(if ($NoContent) { 'none' } else { 'json' }) 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) {
        $code = 'Unavailable'
        $text = $output -join "`n"
        if ($text -match '"code"\s*:\s*"([A-Za-z0-9_.-]+)"' -or $text -match 'ERROR:\s*\(([A-Za-z0-9_.-]+)\)') { $code = $Matches[1] }
        $exception = [InvalidOperationException]::new("Azure CLI named value request failed (exit code $exitCode; Azure code: $code). Output withheld. Check login, subscription access and APIM named-value permissions. Fix the error and rerun; completed writes are not rolled back.")
        $exception.Data['AzureCode'] = $code
        throw $exception
    }
    if ($NoContent) { return }
    try {
        $result = ('{"response":' + ($output -join "`n") + '}') | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $result.response) { throw 'Empty response.' }
    } catch { throw 'Azure CLI returned invalid or empty JSON for a named value request. Output withheld; no missing resource is inferred.' }
    return ,$result.response
}

function Invoke-NamedValueRequest {
    param([string]$Method, [string]$Url, [System.Collections.IDictionary]$Body)
    $path = $null
    try {
        $urlArgument = $Url
        $nativeBatch = $azureCliCommand.CommandType -eq 'Application' -and $azureCliCommand.Source -match '\.(cmd|bat)$'
        if ($nativeBatch) { $urlArgument = '"' + ([Uri]$Url).AbsoluteUri + '"' }
        $arguments = @('rest', '--method', $Method, '--url', $urlArgument)
        if ($Body) {
            $path = Join-Path (Split-Path $EnvFile -Parent) ".env.$([Guid]::NewGuid().ToString('N')).request.json"
            [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Body -Depth 6), [System.Text.UTF8Encoding]::new($false))
            $bodyArgument = "@$path"
            if ($nativeBatch) { $bodyArgument = '"' + $bodyArgument + '"' }
            $arguments += @('--body', $bodyArgument, '--headers', 'Content-Type=application/json')
            if ($Method -eq 'patch') { $arguments += 'If-Match=*' }
        }
        Invoke-NamedValueCli -Arguments $arguments -NoContent:([bool]$Body)
    } finally {
        if ($path -and [System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
    }
}

function Get-ApimNamedValues {
    $url = $collectionUrl
    $values = [System.Collections.Generic.List[object]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    do {
        if (-not $visited.Add($url)) { throw 'Azure returned a repeated named value pagination link.' }
        $page = Invoke-NamedValueRequest -Method get -Url $url
        if ($page.value -isnot [Array]) { throw 'Azure returned an unexpected named value collection.' }
        foreach ($item in $page.value) {
            if (-not $item.id -or -not $item.name -or -not $item.properties.displayName) {
                throw 'Azure returned an incomplete named value identity. No writes will be attempted.'
            }
            $values.Add($item)
        }
        $url = [string]$page.nextLink
        if ($url) {
            $next = $null
            if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$next) -or
                $next.Scheme -ne 'https' -or $next.Host -ne 'management.azure.com' -or $next.Port -ne 443 -or
                $next.UserInfo -or $next.Fragment -or $next.AbsolutePath -ine ([Uri]$collectionUrl).AbsolutePath) {
                throw 'Azure returned an unexpected named value pagination URL.'
            }
        }
    } while ($url)
    return ,$values.ToArray()
}

function Assert-ManagedNamedValue {
    param($Item, [string]$DisplayName, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Item.name) -or $Item.name.Length -gt 256 -or
        $Item.name -match '[*#&+:<>?/\\\x00-\x1f]' -or $Item.name -in @('.', '..') -or
        $Item.id -ine "$resourceId/namedValues/$($Item.name)" -or
        $Item.properties.displayName -cne $DisplayName -or ($Name -and $Item.name -cne $Name)) {
        throw "Unexpected or ambiguous resource identity for named value '$DisplayName'. No rename will be attempted."
    }
    if ($Item.properties.secret -isnot [bool] -or $Item.properties.secret -or $Item.properties.keyVault) {
        throw "Named value '$DisplayName' is secret, Key Vault-backed, or has unknown secrecy. It will not be read as plaintext or overwritten, even with -UpdateExisting."
    }
    if ($Item.properties.value -isnot [string] -or [string]::IsNullOrWhiteSpace($Item.properties.value)) {
        throw "The public value for '$DisplayName' was omitted or invalid. It cannot be compared safely. Secret retrieval is intentionally disabled."
    }
}

Write-Host '1. Validating the APIM target, tenant and current managed identity.' -ForegroundColor Cyan
$account = Invoke-NamedValueCli -Arguments @('account', 'show')
if ($account.id -ine $SubscriptionId -or $account.tenantId -ine $tenantId -or $account.environmentName -cne 'AzureCloud') {
    throw 'The selected subscription must belong to the saved tenant in Azure public cloud. No configuration or Azure resources were changed.'
}
$service = Invoke-NamedValueRequest -Method get -Url "${serviceUrl}?api-version=2024-05-01"
if ($service.id -ine $resourceId -or $service.identity.type -notmatch '(^|,\s*)SystemAssigned($|,)' -or
    $service.identity.principalId -ine $principalId -or $service.identity.tenantId -ine $tenantId) {
    throw 'The live APIM system-assigned identity does not match the saved configuration. Complete prerequisite 2 again before proceeding.'
}
$savedInputs = @{ AZURE_APIM_NAMED_VALUES_CONFIGURED = 'false' }
foreach ($entry in $inputKeys.GetEnumerator()) { $savedInputs[$entry.Value] = Get-Variable -Name $entry.Key -ValueOnly }
Update-PrerequisiteEnv -Path $EnvFile -Values $savedInputs

Write-Host '2. Checking all twelve public named values before making changes.' -ForegroundColor Cyan
$existing = Get-ApimNamedValues
$operations = [System.Collections.Generic.List[object]]::new()
$conflicts = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $desired.GetEnumerator()) {
    $matches = @($existing | Where-Object { $_.properties.displayName -ieq $entry.Key })
    if ($matches.Count -gt 1) { throw "Multiple named values match '$($entry.Key)'. Resolve the ambiguity before rerunning." }
    $method = 'put'
    $name = $entry.Key
    if ($matches.Count -eq 1) {
        $item = $matches[0]
        Assert-ManagedNamedValue -Item $item -DisplayName $entry.Key
        $name = $item.name
        $method = if ($item.properties.value -ceq $entry.Value) { '' } else { 'patch' }
        if ($method -and -not $UpdateExisting) { $conflicts.Add($entry.Key) }
    } elseif (@($existing | Where-Object { $_.name -ieq $name }).Count) {
        throw "Resource name '$name' is already used by another display name. It will not be renamed or overwritten."
    }
    $operations.Add(@{ Name = $name; DisplayName = $entry.Key; Value = $entry.Value; Method = $method })
}
if ($conflicts.Count) {
    throw "Existing named values differ: $($conflicts -join ', '). No Azure writes were made. Review the configuration and rerun with -UpdateExisting to approve these changes."
}

Write-Host '3. Creating missing values, applying approved changes, and verifying all values.' -ForegroundColor Cyan
foreach ($operation in $operations) {
    $url = "$serviceUrl/namedValues/$([Uri]::EscapeDataString($operation.Name))?api-version=2024-05-01"
    if ($operation.Method) {
        $properties = @{ value = $operation.Value }
        if ($operation.Method -eq 'put') {
            $properties.displayName = $operation.DisplayName
            $properties.secret = $false
        }
        Invoke-NamedValueRequest -Method $operation.Method -Url $url -Body @{ properties = $properties }
    }
    $verified = $false
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $item = Invoke-NamedValueRequest -Method get -Url $url
            Assert-ManagedNamedValue -Item $item -DisplayName $operation.DisplayName -Name $operation.Name
            if ($item.properties.provisioningState -in @('Failed', 'Canceled')) {
                throw "Provisioning failed for named value '$($operation.DisplayName)'. Inspect it in APIM and rerun."
            }
            if ($item.properties.value -ceq $operation.Value -and
                (-not $item.properties.provisioningState -or $item.properties.provisioningState -eq 'Succeeded')) {
                $verified = $true
                break
            }
        } catch {
            if ($_.Exception.Data['AzureCode'] -notin @('ResourceNotFound', 'NotFound')) { throw }
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt + 1)) }
    }
    if (-not $verified) { throw "Named value '$($operation.DisplayName)' could not be verified after four reads. Completed writes remain; wait and rerun. The configured flag remains false." }
    Write-Host "   Verified $($operation.DisplayName)."
}
Update-PrerequisiteEnv -Path $EnvFile -Values @{ AZURE_APIM_NAMED_VALUES_CONFIGURED = 'true' }
Write-Host "4. Verified all twelve named values and saved configuration to '$EnvFile'." -ForegroundColor Green
Write-Host '   Secret and unrelated named values were left untouched. Policies, connections, consent and backend compatibility are separate steps.'
