<#
.SYNOPSIS
    Creates an Atlassian OAuth 2.1 with PKCE with DCR credential provider in APIM.
.DESCRIPTION
    Reuses the shared .env from prerequisites 1 and 2. Uses Azure CLI az rest.
    Matching providers are reused; changing an existing provider requires
    -UpdateExisting. Connections, access policies and consent are separate steps.
.EXAMPLE
    .\Configure-ApimCredentialProvider.ps1
.EXAMPLE
    .\Configure-ApimCredentialProvider.ps1 -ProviderName 'atlassian' -UpdateExisting
#>
[CmdletBinding()]
param(
    [string]$ApimName,
    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [string]$ProviderName,
    [string]$EnvFile,
    [switch]$UpdateExisting
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
if (-not $EnvFile) { $EnvFile = Get-PrerequisiteEnvPath }
$EnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
$configuration = Read-PrerequisiteEnv -Path $EnvFile
$inputKeys = [ordered]@{
    ApimName          = 'AZURE_APIM_NAME'
    ResourceGroupName = 'AZURE_RESOURCE_GROUP_NAME'
    SubscriptionId   = 'AZURE_SUBSCRIPTION_ID'
    ProviderName     = 'AZURE_APIM_CREDENTIAL_PROVIDER_NAME'
}
foreach ($entry in $inputKeys.GetEnumerator()) {
    $default = if ($entry.Key -eq 'ProviderName') { 'atlassian' } else { '' }
    $value = Resolve-PrerequisiteValue -Parameters $PSBoundParameters -ParameterName $entry.Key `
        -Values $configuration -Key $entry.Value -DefaultValue $default
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Supply -$($entry.Key) or set $($entry.Value) in '$EnvFile'."
    }
    Set-Variable -Name $entry.Key -Value $value
}
if ($ApimName -notmatch '^[A-Za-z][A-Za-z0-9-]{0,49}$') {
    throw 'Invalid APIM instance name. Supply a name, not a URL or resource ID.'
}
if ($ResourceGroupName.Length -gt 90 -or $ResourceGroupName -match '[/\\]' -or $ResourceGroupName.StartsWith('-')) {
    throw 'ResourceGroupName must be a resource group name, not a resource ID.'
}
if ($ProviderName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$') {
    throw 'ProviderName must contain only letters, digits, dots, underscores or hyphens, start with a letter or digit, and be at most 256 characters.'
}
$subscriptionGuid = [Guid]::Empty
if (-not [Guid]::TryParse($SubscriptionId, [ref]$subscriptionGuid) -or $subscriptionGuid -eq [Guid]::Empty) {
    throw 'SubscriptionId must be a nonempty subscription GUID, not a subscription display name.'
}
$SubscriptionId = $subscriptionGuid.ToString()
$resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName"
if ($configuration['AZURE_APIM_RESOURCE_ID'] -and $configuration['AZURE_APIM_RESOURCE_ID'] -ine $resourceId) {
    throw 'Saved APIM identity details belong to another resource. Rerun prerequisite 2 for the selected APIM instance first.'
}

$requiredKeys = @(
    'ATLASSIAN_MCP_CLIENT_ID', 'ATLASSIAN_MCP_CLIENT_SECRET',
    'ATLASSIAN_MCP_AUTHORIZATION_URL', 'ATLASSIAN_MCP_TOKEN_URL',
    'ATLASSIAN_MCP_ENDPOINT', 'ATLASSIAN_MCP_SCOPES', 'ATLASSIAN_MCP_REDIRECT_URI'
)
foreach ($key in $requiredKeys) {
    if ([string]::IsNullOrWhiteSpace($configuration[$key])) {
        throw "Missing $key in '$EnvFile'. Complete prerequisite 1 before configuring the credential provider."
    }
}
foreach ($key in @('ATLASSIAN_MCP_AUTHORIZATION_URL', 'ATLASSIAN_MCP_TOKEN_URL', 'ATLASSIAN_MCP_ENDPOINT')) {
    $uri = $null
    if (-not [Uri]::TryCreate($configuration[$key], [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or -not $uri.Host -or $uri.UserInfo -or $uri.Fragment) {
        throw "$key must be an absolute HTTPS URL without embedded credentials or a fragment."
    }
}
$redirectUrl = "https://authorization-manager.consent.azure-apim.net/redirect/apim/$ApimName"
if ($configuration['ATLASSIAN_MCP_REDIRECT_URI'] -cne $redirectUrl) {
    throw 'The registered ATLASSIAN_MCP_REDIRECT_URI does not match the selected APIM callback URL. Register a client for this APIM instance before proceeding.'
}
$azureCliCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azureCliCommand) {
    throw 'Azure CLI is required. Install it, run az login, and rerun this script.'
}

$authorizationCode = [ordered]@{
    authorizationUrl = $configuration['ATLASSIAN_MCP_AUTHORIZATION_URL']
    clientId         = $configuration['ATLASSIAN_MCP_CLIENT_ID']
    clientSecret     = $configuration['ATLASSIAN_MCP_CLIENT_SECRET']
    refreshUrl       = $configuration['ATLASSIAN_MCP_TOKEN_URL']
    scopes           = $configuration['ATLASSIAN_MCP_SCOPES']
    serverUrl        = $configuration['ATLASSIAN_MCP_ENDPOINT']
    tokenUrl         = $configuration['ATLASSIAN_MCP_TOKEN_URL']
}
$body = @{
    properties = @{
        displayName = $ProviderName
        identityProvider = 'oauth2pkcewithdcr'
        oauth2 = @{
            redirectUrl = $redirectUrl
            grantTypes = @{ authorizationCode = $authorizationCode }
        }
    }
}
$providerId = "$resourceId/authorizationProviders/$ProviderName"
$encodedResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$([Uri]::EscapeDataString($ResourceGroupName))/providers/Microsoft.ApiManagement/service/$ApimName"
$collectionUrl = "https://management.azure.com$encodedResourceId/authorizationProviders?api-version=2024-05-01"
$providerUrl = "https://management.azure.com$encodedResourceId/authorizationProviders/${ProviderName}?api-version=2024-05-01"

function Invoke-CredentialProviderRequest {
    param([string]$Method, [string]$Url, [string]$BodyPath, [switch]$Existing)

    $urlArgument = $Url
    if ($azureCliCommand.CommandType -eq 'Application' -and $azureCliCommand.Source -match '\.(cmd|bat)$') {
        # az.cmd needs literal quotes so cmd.exe does not split nextLink at '&'.
        $urlArgument = '"' + ([Uri]$Url).AbsoluteUri + '"'
    }
    $arguments = @('rest', '--method', $Method, '--url', $urlArgument,
        '--subscription', $SubscriptionId, '--only-show-errors')
    if ($BodyPath) {
        $arguments += @('--body', "@$BodyPath", '--headers', 'Content-Type=application/json')
        if ($Existing) { $arguments += 'If-Match=*' }
        $arguments += @('--output', 'none')
    } else {
        $arguments += @('--output', 'json')
    }
    # Capture stderr too: an ARM validation error can echo request credentials.
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $output = & az @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) {
        $errorText = $output -join "`n"
        if ($errorText -match 'is not recognized as an internal or external command') {
            throw "Azure CLI credential provider $Method failed (exit code $exitCode): Windows command parsing failed. Use the updated script that quotes request URLs for az.cmd. Raw output was withheld to protect credentials."
        }
        $errorCode = 'Unavailable'
        if ($errorText -match '"code"\s*:\s*"([A-Za-z0-9_.-]+)"' -or
            $errorText -match 'ERROR:\s*\(([A-Za-z0-9_.-]+)\)') {
            $errorCode = $Matches[1]
        }
        throw "Azure CLI credential provider $Method failed (exit code $exitCode; Azure code: $errorCode). Raw output was withheld to protect credentials. Check az login, subscription access, APIM permissions and provider settings; rerun after correcting the error."
    }
    if ($BodyPath) { return }
    try {
        if ([string]::IsNullOrWhiteSpace(($output -join "`n"))) { throw 'Empty response.' }
        $result = $output -join "`n" | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $result) { throw 'Null response.' }
    } catch {
        throw 'Azure CLI returned invalid or empty JSON for the credential provider read. Response withheld to protect credentials.'
    }
    return $result
}

function Get-ExistingCredentialProvider {
    $url = $collectionUrl
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    do {
        if (-not $visited.Add($url)) { throw 'Azure returned a repeated credential provider pagination link.' }
        $page = Invoke-CredentialProviderRequest -Method get -Url $url
        if ($page.PSObject.Properties.Name -notcontains 'value' -or $page.value -isnot [Array]) {
            throw 'Azure returned an unexpected credential provider collection.'
        }
        foreach ($provider in $page.value) {
            if ($provider.id -ieq $providerId) { return $provider }
        }
        $url = [string]$page.nextLink
        if ($url) {
            $next = $null
            if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$next) -or
                $next.Scheme -ne 'https' -or $next.Host -ne 'management.azure.com' -or
                $next.Port -ne 443 -or $next.UserInfo -or $next.Fragment -or
                $next.AbsolutePath -ine ([Uri]$collectionUrl).AbsolutePath) {
                throw 'Azure returned an unexpected credential provider pagination URL.'
            }
        }
    } while ($url)
}

function Get-CredentialProviderDifferences {
    param($Provider)

    if ($Provider.id -ine $providerId) { 'resource ID' }
    if ($Provider.properties.displayName -cne $ProviderName) { 'displayName' }
    if ($Provider.properties.identityProvider -cne 'oauth2pkcewithdcr') { 'identityProvider' }
    if ($Provider.properties.oauth2.redirectUrl -cne $redirectUrl) { 'redirectUrl' }
    $grants = $Provider.properties.oauth2.grantTypes
    if (-not $grants.authorizationCode) { 'authorizationCode grant' }
    if ($grants.clientCredentials) { 'unexpected clientCredentials grant' }
    foreach ($key in $authorizationCode.Keys) {
        # ARM omits secrets on reads; -UpdateExisting explicitly sends the saved secret.
        if ($key -eq 'clientSecret') { continue }
        $actual = [string]$grants.authorizationCode.$key
        $expected = [string]$authorizationCode[$key]
        if ($key -eq 'scopes') {
            $actual = (@($actual -split '\s+' | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive) -join ' ')
            $expected = (@($expected -split '\s+' | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive) -join ' ')
        }
        if ($actual -cne $expected) { $key }
    }
}

Update-PrerequisiteEnv -Path $EnvFile -Values @{
    AZURE_APIM_CREDENTIAL_PROVIDER_NAME = $ProviderName
    AZURE_APIM_CREDENTIAL_PROVIDER_ID = ''
}
Write-Host "1. Checking credential provider '$ProviderName' in APIM '$ApimName'." -ForegroundColor Cyan
$existing = Get-ExistingCredentialProvider
if ($existing -and -not $UpdateExisting) {
    $differences = @(Get-CredentialProviderDifferences -Provider $existing)
    if ($differences.Count -gt 0) {
        throw "Existing provider differs in: $($differences -join ', '). No Azure settings were changed. Review the saved configuration and rerun with -UpdateExisting to intentionally update it."
    }
    Write-Host '   Public settings match; reusing the provider without changing its secret.'
    Write-Host '   Secrets cannot be compared on reads. Use -UpdateExisting after rotating client credentials.'
} else {
    Write-Host '2. Saving the OAuth 2.1 with PKCE with DCR provider.' -ForegroundColor Cyan
    $bodyPath = Join-Path (Split-Path $EnvFile -Parent) ".env.$([Guid]::NewGuid().ToString('N')).request.json"
    try {
        [System.IO.File]::WriteAllText($bodyPath, ($body | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
        Invoke-CredentialProviderRequest -Method put -Url $providerUrl -BodyPath $bodyPath -Existing:([bool]$existing)
    } finally {
        if ([System.IO.File]::Exists($bodyPath)) { [System.IO.File]::Delete($bodyPath) }
    }
    $verified = $false
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $provider = Get-ExistingCredentialProvider
        if ($provider -and @(Get-CredentialProviderDifferences -Provider $provider).Count -eq 0) {
            $verified = $true
            break
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt + 1)) }
    }
    if (-not $verified) {
        throw 'Azure accepted the write, but the credential provider settings could not be verified. Its saved ID remains empty. Wait and rerun; review the provider in Azure if the mismatch persists.'
    }
}

$savedValues = [ordered]@{ AZURE_APIM_CREDENTIAL_PROVIDER_ID = $providerId }
foreach ($entry in $inputKeys.GetEnumerator()) {
    $savedValues[$entry.Value] = Get-Variable -Name $entry.Key -ValueOnly
}
try {
    Update-PrerequisiteEnv -Path $EnvFile -Values $savedValues
} catch {
    Write-Warning 'The provider was verified, but saving configuration failed. Fix local file access and rerun to reuse the provider.'
    throw
}
Write-Host "3. Verified credential provider and saved its name and ID to '$EnvFile'." -ForegroundColor Green
Write-Host '   Provider setup only: a connection, access policy and interactive Atlassian consent are still required.'
