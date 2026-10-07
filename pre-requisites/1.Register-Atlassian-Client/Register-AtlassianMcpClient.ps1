<#
.SYNOPSIS
    Registers an OAuth client (via Dynamic Client Registration) with Atlassian's Rovo MCP
    authorization server.

.DESCRIPTION
    1. Reads the MCP server's Protected Resource Metadata to find the authorization server.
    2. Reads the authorization server metadata (endpoints, supported auth methods).
    3. Registers a confidential client (client_secret_post) with the redirect URI derived
       from the API Management instance name.
    4. Saves inputs and registration values to the repository-root .env and prints values.
    5. Optionally stores the client ID / secret in Key Vault.

    Inputs resolve from explicit parameters, then .env, then defaults.
    An existing saved registration requires -ForceRegistration to create a NEW client.

.EXAMPLE
    ./Register-AtlassianMcpClient.ps1 -ApimName "my-apim"

.EXAMPLE
    ./Register-AtlassianMcpClient.ps1 -ApimName "my-apim" -KeyVaultName my-vault
#>
param(
    [string]$ApimName,

    [string]$McpServerUrl = "https://mcp.atlassian.com/v1/mcp/authv2",

    [string]$Scopes = "read:account read:me offline_access read:jira-work write:jira-work search:confluence read:page:confluence write:page:confluence read:space:confluence read:comment:confluence write:comment:confluence",

    [string]$ClientName = "Atlassian MCP Client",

    # Optional: store credentials in Key Vault (requires Az.KeyVault and Connect-AzAccount)
    [string]$KeyVaultName,

    [string]$SecretPrefix = "atlassian-mcp",

    [string]$EnvFile,

    [switch]$ForceRegistration
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot '..\Common.ps1')
if (-not $EnvFile) { $EnvFile = Get-PrerequisiteEnvPath }
$EnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
$configuration = Read-PrerequisiteEnv -Path $EnvFile
$inputKeys = [ordered]@{
    ApimName     = 'AZURE_APIM_NAME'
    McpServerUrl = 'ATLASSIAN_MCP_ENDPOINT'
    Scopes       = 'ATLASSIAN_MCP_SCOPES'
    ClientName   = 'ATLASSIAN_MCP_CLIENT_NAME'
    KeyVaultName = 'AZURE_KEY_VAULT_NAME'
    SecretPrefix = 'ATLASSIAN_MCP_SECRET_PREFIX'
}
foreach ($entry in $inputKeys.GetEnumerator()) {
    $value = Resolve-PrerequisiteValue -Parameters $PSBoundParameters -ParameterName $entry.Key `
        -Values $configuration -Key $entry.Value -DefaultValue (Get-Variable -Name $entry.Key -ValueOnly)
    Set-Variable -Name $entry.Key -Value $value
}
if ([string]::IsNullOrWhiteSpace($ApimName)) {
    throw "APIM instance name is required. Supply -ApimName or set AZURE_APIM_NAME in '$EnvFile'."
}
if ($ApimName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') {
    throw "Invalid APIM instance name. Supply a name, not a URL or resource ID."
}
if (-not $ForceRegistration -and (
    $configuration['ATLASSIAN_MCP_CLIENT_ID'] -or $configuration['ATLASSIAN_MCP_CLIENT_SECRET']
)) {
    throw "A registration is already saved in '$EnvFile'. Use it in later prerequisites, or specify -ForceRegistration to create a NEW client and replace its saved credentials."
}

function Get-ErrorBody($err) {
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) { return $err.ErrorDetails.Message }
    return $err.Exception.Message
}

# ---------------------------------------------------------------------------
# 1. Protected Resource Metadata -> authorization server
# ---------------------------------------------------------------------------
$mcpUri = [Uri]$McpServerUrl
$prmUrl = "$($mcpUri.Scheme)://$($mcpUri.Authority)/.well-known/oauth-protected-resource$($mcpUri.AbsolutePath.TrimEnd('/'))"

Write-Host "1. Reading protected resource metadata: $prmUrl" -ForegroundColor Cyan
$prm = Invoke-RestMethod -Uri $prmUrl
$issuer = $prm.authorization_servers[0]
if (-not $issuer) { throw "No authorization_servers found in protected resource metadata." }
Write-Host "   Authorization server: $issuer"

# Scope sanity checks
$scopeList = $Scopes -split '\s+' | Where-Object { $_ }
if ($scopeList -notcontains "read:account") {
    Write-Warning "read:account is required by Atlassian (fails after consent without it). Adding it."
    $scopeList = @("read:account") + $scopeList
}
if ($scopeList -notcontains "offline_access") {
    Write-Warning "offline_access not requested: no refresh tokens, users will need to re-consent often."
}
$unknown = $scopeList | Where-Object { $prm.scopes_supported -notcontains $_ }
if ($unknown) { Write-Warning "Scopes not listed in scopes_supported: $($unknown -join ', ')" }
$Scopes = $scopeList -join ' '

# ---------------------------------------------------------------------------
# 2. Authorization server metadata (try RFC 8414 form first, then fallbacks)
# ---------------------------------------------------------------------------
$issUri = [Uri]$issuer
$issPath = $issUri.AbsolutePath.TrimEnd('/')
$candidates = @(
    "$($issUri.Scheme)://$($issUri.Authority)/.well-known/oauth-authorization-server$issPath",
    "$($issuer.TrimEnd('/'))/.well-known/oauth-authorization-server",
    "$($issuer.TrimEnd('/'))/.well-known/openid-configuration"
)

$asMeta = $null
foreach ($url in $candidates) {
    try {
        Write-Host "2. Trying authorization server metadata: $url" -ForegroundColor Cyan
        $asMeta = Invoke-RestMethod -Uri $url
        if ($asMeta.token_endpoint) { break }
    } catch { $asMeta = $null }
}
if (-not $asMeta) { throw "Could not read authorization server metadata from any known location." }
if (-not $asMeta.registration_endpoint) { throw "Authorization server does not advertise a registration_endpoint (no DCR)." }
if ($asMeta.token_endpoint_auth_methods_supported -notcontains "client_secret_post") {
    throw "client_secret_post not supported (supported: $($asMeta.token_endpoint_auth_methods_supported -join ', '))."
}

# ---------------------------------------------------------------------------
# 3. Dynamic Client Registration
# ---------------------------------------------------------------------------
[Uri]$RedirectUri = "https://authorization-manager.consent.azure-apim.net/redirect/apim/$ApimName"

$regBody = @{
    client_name                = $ClientName
    redirect_uris              = @($RedirectUri.AbsoluteUri)
    grant_types                = @("authorization_code", "refresh_token")
    response_types             = @("code")
    token_endpoint_auth_method = "client_secret_post"
    scope                      = $Scopes
} | ConvertTo-Json

Write-Host "3. Registering client at $($asMeta.registration_endpoint)" -ForegroundColor Cyan
try {
    $reg = Invoke-RestMethod -Method Post -Uri $asMeta.registration_endpoint `
        -ContentType "application/json" -Body $regBody
} catch {
    $msg = Get-ErrorBody $_
    Write-Host "   Registration failed: $msg" -ForegroundColor Red
    if ($msg -match "redirect") {
        Write-Host "   Hint: allowlist $($RedirectUri.Host) in Atlassian Admin (Rovo MCP server > Allowed domains)." -ForegroundColor Yellow
    }
    throw
}

if (-not $reg.client_id -or -not $reg.client_secret) {
    throw "Registration returned no client_id or client_secret (auth method: $($reg.token_endpoint_auth_method))."
}
if ($reg.client_secret_expires_at -and $reg.client_secret_expires_at -ne 0) {
    $exp = [DateTimeOffset]::FromUnixTimeSeconds($reg.client_secret_expires_at).LocalDateTime
    Write-Warning "Client secret EXPIRES on $exp. Plan to re-register before then."
}
if (-not $reg.registration_access_token) {
    Write-Warning "No registration_access_token returned: this client cannot be updated later. Changing scopes means re-registering and users re-consenting."
}

# ---------------------------------------------------------------------------
# 4. Save shared configuration and print environment variables
# ---------------------------------------------------------------------------
$environmentVariables = [ordered]@{
    "ATLASSIAN_MCP_CLIENT_ID"         = $reg.client_id
    "ATLASSIAN_MCP_CLIENT_SECRET"     = $reg.client_secret
    "ATLASSIAN_MCP_AUTHORIZATION_URL" = $asMeta.authorization_endpoint
    "ATLASSIAN_MCP_TOKEN_URL"         = $asMeta.token_endpoint
    "ATLASSIAN_MCP_SERVER_URL"        = $prm.resource
    "ATLASSIAN_MCP_REDIRECT_URI"      = $RedirectUri.AbsoluteUri
    "ATLASSIAN_MCP_SCOPES"            = $Scopes
}
$savedValues = [ordered]@{}
foreach ($entry in $inputKeys.GetEnumerator()) {
    $savedValues[$entry.Value] = Get-Variable -Name $entry.Key -ValueOnly
}
foreach ($entry in $environmentVariables.GetEnumerator()) {
    $savedValues[$entry.Key] = $entry.Value
}
$savedValues['ATLASSIAN_MCP_REGISTRATION_ACCESS_TOKEN'] = [string]$reg.registration_access_token

Write-Host ""
Write-Host "4. Registration environment variables (contain secrets)" -ForegroundColor Green
foreach ($entry in $environmentVariables.GetEnumerator()) {
    Write-Host "$($entry.Key)=$(Format-DotEnvValue ([string]$entry.Value))"
}
try {
    Update-PrerequisiteEnv -Path $EnvFile -Values $savedValues
} catch {
    Write-Host "   Client registered, but saving '$EnvFile' failed. Preserve the printed values before retrying; another run may create another client." -ForegroundColor Red
    throw
}
Write-Host "   Saved shared configuration to '$EnvFile'." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5. Optionally store credentials
# ---------------------------------------------------------------------------
if ($KeyVaultName) {
    Write-Host "5. Storing credentials in Key Vault '$KeyVaultName'" -ForegroundColor Cyan
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$SecretPrefix-client-id" `
        -SecretValue (ConvertTo-SecureString $reg.client_id -AsPlainText -Force) | Out-Null
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$SecretPrefix-client-secret" `
        -SecretValue (ConvertTo-SecureString $reg.client_secret -AsPlainText -Force) | Out-Null
    if ($reg.registration_access_token) {
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "$SecretPrefix-registration-token" `
            -SecretValue (ConvertTo-SecureString $reg.registration_access_token -AsPlainText -Force) | Out-Null
    }
    Write-Host "   Stored: $SecretPrefix-client-id, $SecretPrefix-client-secret"
} else {
    Write-Host "5. No Key Vault given; credentials are saved locally only." -ForegroundColor Yellow
}