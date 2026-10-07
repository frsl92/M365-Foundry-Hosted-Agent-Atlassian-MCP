<#
.SYNOPSIS
    Registers the APIM API and its dedicated Bot OAuth sign-in client.
.DESCRIPTION
    Uses the shared .env, exposes the admin-only Mcp.Invoke delegated scope,
    and declares that permission on a single-tenant Web client. Ensures both
    service principals exist. Creates no credentials, consent grants, or bot resources.
.EXAMPLE
    .\Register-EntraApplications.ps1
.EXAMPLE
    .\Register-EntraApplications.ps1 -ApimApiAppName "Atlassian MCP Gateway API" -AuthAppName "Teams Atlassian User Sign-in"
#>
[CmdletBinding()]
param(
    [string]$ApimName,
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ApimApiAppName,
    [string]$AuthAppName,
    [string]$ApimApiClientId,
    [string]$AuthClientId,
    [string]$AuthRedirectUri,
    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
if (-not $EnvFile) { $EnvFile = Get-PrerequisiteEnvPath }
$EnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
$configuration = Read-PrerequisiteEnv -Path $EnvFile
$ApimName = Resolve-PrerequisiteValue -Parameters $PSBoundParameters -ParameterName ApimName `
    -Values $configuration -Key AZURE_APIM_NAME
$inputs = @{
    SubscriptionId  = @('AZURE_SUBSCRIPTION_ID', '')
    TenantId        = @('AZURE_TENANT_ID', $configuration['AZURE_APIM_IDENTITY_TENANT_ID'])
    ApimApiAppName  = @('APIM_API_APP_NAME', $(if ($ApimName) { "$ApimName-gateway-api" } else { '' }))
    AuthAppName     = @('AUTH_APP_NAME', $(if ($ApimName) { "$ApimName-user-sign-in" } else { '' }))
    ApimApiClientId = @('APIM_API_CLIENT_ID', '')
    AuthClientId    = @('AUTH_CLIENT_ID', '')
    AuthRedirectUri = @('AUTH_REDIRECT_URI', 'https://token.botframework.com/.auth/web/redirect')
}
foreach ($entry in $inputs.GetEnumerator()) {
    Set-Variable -Name $entry.Key -Value (Resolve-PrerequisiteValue -Parameters $PSBoundParameters `
        -ParameterName $entry.Key -Values $configuration -Key $entry.Value[0] -DefaultValue $entry.Value[1])
}

function Assert-RegistrationGuid {
    param([string]$Value, [string]$Label)
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$guid) -or $guid -eq [Guid]::Empty) {
        throw "$Label must be a nonempty GUID."
    }
    $guid.ToString()
}

$SubscriptionId = Assert-RegistrationGuid $SubscriptionId 'SubscriptionId / AZURE_SUBSCRIPTION_ID'
if (-not $TenantId) {
    throw 'Supply -TenantId or set AZURE_TENANT_ID; alternatively run prerequisite 2 to save the APIM identity tenant.'
}
$TenantId = Assert-RegistrationGuid $TenantId 'TenantId'
foreach ($key in @('AZURE_APIM_IDENTITY_TENANT_ID', 'AZURE_TENANT_ID')) {
    if ($configuration[$key] -and $configuration[$key] -ine $TenantId) {
        throw "Selected tenant differs from saved $key. Use a separate -EnvFile for another tenant."
    }
}
foreach ($name in @($ApimApiAppName, $AuthAppName)) {
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,119}$' -or $name -ne $name.Trim()) {
        throw 'Supply distinct app names (or AZURE_APIM_NAME for defaults): 1-120 letters, digits, spaces, dots, underscores or hyphens, starting with a letter or digit and without trailing spaces.'
    }
}
if ($ApimApiAppName -ieq $AuthAppName) { throw 'The API and sign-in app names must be different.' }
if ($ApimApiClientId) { $ApimApiClientId = Assert-RegistrationGuid $ApimApiClientId 'ApimApiClientId' }
if ($AuthClientId) { $AuthClientId = Assert-RegistrationGuid $AuthClientId 'AuthClientId' }
if ($ApimApiClientId -and $ApimApiClientId -eq $AuthClientId) {
    throw 'The API and sign-in client IDs must be different.'
}
$redirect = $null
if (-not [Uri]::TryCreate($AuthRedirectUri, [UriKind]::Absolute, [ref]$redirect) -or
    $redirect.Scheme -ne 'https' -or -not $redirect.Host -or $redirect.UserInfo -or $redirect.Fragment) {
    throw 'AuthRedirectUri must be an absolute HTTPS URL without embedded credentials or a fragment.'
}
$azureCliCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azureCliCommand) { throw 'Azure CLI is required. Install it, run az login for the intended tenant, and rerun.' }

function Invoke-RegistrationCli {
    param([string[]]$Arguments, [switch]$NoContent)
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $output = & az @Arguments --only-show-errors --output json 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) {
        $code = 'Unavailable'
        $text = $output -join "`n"
        $operation = switch ($Arguments[0]) {
            'ad' { $Arguments[0..2] -join ' ' }
            'account' { 'account show' }
            'rest' { "rest --method $($Arguments[[Array]::IndexOf($Arguments, '--method') + 1])" }
        }
        if ($exitCode -eq 2 -and $text -match 'unrecognized arguments:|arguments are required:|usage:') {
            throw "Azure CLI usage error for 'az $operation' (exit code 2). Output withheld. Check the command's supported arguments with --help; this is not an Entra permission response."
        }
        if ($text -match '"code"\s*:\s*"([A-Za-z0-9_.-]+)"' -or $text -match 'ERROR:\s*\(([A-Za-z0-9_.-]+)\)') {
            $code = $Matches[1]
        }
        $exception = [InvalidOperationException]::new("Azure CLI app registration request 'az $operation' failed (exit code $exitCode; Azure code: $code). Output withheld. Check tenant login and Microsoft Entra application permissions; subscription Contributor alone is insufficient. Fix the error and rerun; do not blindly repeat a create operation.")
        $exception.Data['AzureCode'] = $code
        throw $exception
    }
    if ($NoContent) { return }
    try {
        # Preserve empty and singleton arrays across PowerShell versions.
        $result = ('{"response":' + ($output -join "`n") + '}') | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $result.response) { throw 'Empty response.' }
    } catch {
        throw 'Azure CLI returned invalid or empty JSON for an app registration request. Output withheld; check Entra before retrying a create.'
    }
    return ,$result.response
}

function Invoke-RegistrationWrite {
    param([string]$Method, [System.Collections.IDictionary]$Body, [string]$ObjectId)
    $url = 'https://graph.microsoft.com/v1.0/applications'
    if ($ObjectId) { $url += "/$(Assert-RegistrationGuid $ObjectId 'Application object ID')" }
    $path = Join-Path (Split-Path $EnvFile -Parent) ".env.$([Guid]::NewGuid().ToString('N')).request.json"
    try {
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Body -Depth 10), [System.Text.UTF8Encoding]::new($false))
        $bodyArgument = "@$path"
        if ($azureCliCommand.CommandType -eq 'Application' -and $azureCliCommand.Source -match '\.(cmd|bat)$') {
            $bodyArgument = '"' + $bodyArgument + '"'
        }
        Invoke-RegistrationCli -Arguments @('rest', '--method', $Method, '--url', $url,
            '--resource', 'https://graph.microsoft.com', '--headers', 'Content-Type=application/json',
            '--body', $bodyArgument, '--subscription', $SubscriptionId) -NoContent:($Method -eq 'patch')
    } finally {
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }
    }
}

function Assert-ApplicationIdentity {
    param($App, [string]$ClientId)
    $null = Assert-RegistrationGuid ([string]$App.id) 'Returned application object ID'
    $null = Assert-RegistrationGuid ([string]$App.appId) 'Returned application client ID'
    if ($ClientId -and $App.appId -ine $ClientId) { throw 'Azure returned a different application client ID.' }
}

function Find-Registration {
    param([string]$Name, [string]$ClientId)
    if ($ClientId) {
        $app = Invoke-RegistrationCli -Arguments @('ad', 'app', 'show', '--id', $ClientId)
        Assert-ApplicationIdentity $app $ClientId
        return $app
    }
    $apps = Invoke-RegistrationCli -Arguments @('ad', 'app', 'list', '--display-name', $Name, '--all')
    if ($apps -isnot [Array]) { throw 'Azure returned an unexpected application list; no application will be created.' }
    foreach ($app in $apps) {
        Assert-ApplicationIdentity $app
        if ([string]::IsNullOrWhiteSpace($app.displayName)) { throw 'Azure returned an application without a display name.' }
    }
    $matches = @($apps | Where-Object { $_.displayName -ieq $Name })
    if ($matches.Count -gt 1) {
        throw "Multiple registrations match '$Name'. Select one explicitly with -ApimApiClientId or -AuthClientId; no duplicate will be created."
    }
    if ($matches.Count -eq 1) {
        Assert-ApplicationIdentity $matches[0]
        return $matches[0]
    }
}

function Get-RegistrationDifferences {
    param($App, [string]$Kind, [string]$Name, [string]$ApiClientId, [string]$ScopeId, [switch]$AllowMissingIdentifier)
    if ($App.displayName -cne $Name) { 'displayName' }
    if ($App.signInAudience -cne 'AzureADMyOrg') { 'signInAudience' }
    if ($App.isFallbackPublicClient -eq $true -or $App.publicClient.redirectUris -or $App.spa.redirectUris) { 'public client / SPA settings' }
    if ($App.web.implicitGrantSettings.enableAccessTokenIssuance -eq $true -or
        $App.web.implicitGrantSettings.enableIdTokenIssuance -eq $true) { 'implicit grant settings' }
    if ($App.appRoles) { 'appRoles' }
    if ($Kind -eq 'api') {
        if ($App.web.redirectUris) { 'web.redirectUris' }
        if ($App.requiredResourceAccess) { 'requiredResourceAccess' }
        if ($App.api.requestedAccessTokenVersion -ne 2) { 'api.requestedAccessTokenVersion' }
        $scopes = @($App.api.oauth2PermissionScopes | Where-Object { $null -ne $_ })
        if ($scopes.Count -ne 1 -or $scopes[0].value -cne 'Mcp.Invoke' -or
            $scopes[0].type -cne 'Admin' -or $scopes[0].isEnabled -ne $true) { 'api.oauth2PermissionScopes' }
        if ($scopes.Count -eq 1) {
            $null = Assert-RegistrationGuid ([string]$scopes[0].id) 'API scope ID'
            if ($ScopeId -and $scopes[0].id -ine $ScopeId) { 'API scope ID' }
        }
        if ($App.api.preAuthorizedApplications -or $App.api.knownClientApplications) { 'API preauthorization / bundled consent' }
        $uris = @($App.identifierUris | Where-Object { $null -ne $_ })
        if (-not ($AllowMissingIdentifier -and $uris.Count -eq 0)) {
            if ($uris.Count -ne 1 -or $uris[0] -cne "api://$($App.appId)") { 'identifierUris' }
        }
    } else {
        $uris = @($App.web.redirectUris | Where-Object { $null -ne $_ })
        if ($uris.Count -ne 1 -or $uris[0] -cne $AuthRedirectUri) { 'web.redirectUris' }
        $resources = @($App.requiredResourceAccess | Where-Object { $null -ne $_ })
        if ($resources.Count -ne 1 -or $resources[0].resourceAppId -ine $ApiClientId -or
            @($resources[0].resourceAccess).Count -ne 1 -or
            $resources[0].resourceAccess[0].id -ine $ScopeId -or
            $resources[0].resourceAccess[0].type -cne 'Scope') { 'requiredResourceAccess' }
    }
}

function Assert-RegistrationSettings {
    param($App, [string]$Kind, [string]$Name, [string]$ApiClientId, [string]$ScopeId, [switch]$AllowMissingIdentifier)
    $differences = @(Get-RegistrationDifferences @PSBoundParameters)
    if ($differences.Count) {
        throw "Registration '$Name' differs in: $($differences -join ', '). Existing settings were not overwritten. Review the app or choose a different name/client ID and rerun."
    }
}

function Wait-Registration {
    param([string]$ClientId, [string]$ObjectId, [string]$Kind, [string]$Name, [string]$ApiClientId, [string]$ScopeId)
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $app = Invoke-RegistrationCli -Arguments @('ad', 'app', 'show', '--id', $ObjectId)
            Assert-ApplicationIdentity $app $ClientId
            if ($app.id -ine $ObjectId) { throw 'Azure returned a different application object ID.' }
            if (@(Get-RegistrationDifferences -App $app -Kind $Kind -Name $Name -ApiClientId $ApiClientId -ScopeId $ScopeId).Count -eq 0) {
                return $app
            }
        } catch {
            if ($_.Exception.Data['AzureCode'] -notin @('Request_ResourceNotFound', 'ResourceNotFound')) { throw }
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt + 1)) }
    }
    throw "Registration '$Name' could not be verified after four reads. IDs remain saved. Wait for directory propagation and rerun; do not create a replacement."
}

function Assert-RegistrationServicePrincipal {
    param($Principal, [string]$ClientId)
    Assert-ApplicationIdentity -App $Principal -ClientId $ClientId
    if ($Principal.servicePrincipalType -cne 'Application' -or
        $Principal.appOwnerOrganizationId -ine $TenantId -or $Principal.accountEnabled -ne $true) {
        throw 'The service principal must be an enabled Application in the selected home tenant. Existing settings were not changed; ask a tenant administrator to review the enterprise application.'
    }
}

function Ensure-RegistrationServicePrincipal {
    param([string]$ClientId, [string]$OutputKey)
    $ClientId = Assert-RegistrationGuid $ClientId 'Service principal application/client ID'
    $principals = Invoke-RegistrationCli -Arguments @('ad', 'sp', 'list', '--filter', "appId eq '$ClientId'", '--all')
    if ($principals -isnot [Array] -or $principals.Count -gt 1) {
        throw 'Azure returned an unexpected service principal list; no service principal will be created.'
    }
    if ($principals.Count -eq 1) {
        $principal = $principals[0]
    } else {
        $principal = Invoke-RegistrationCli -Arguments @('ad', 'sp', 'create', '--id', $ClientId)
    }
    Assert-RegistrationServicePrincipal -Principal $principal -ClientId $ClientId
    Update-PrerequisiteEnv -Path $EnvFile -Values @{ $OutputKey = [string]$principal.id }
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $verified = Invoke-RegistrationCli -Arguments @('ad', 'sp', 'show', '--id', $principal.id)
            Assert-RegistrationServicePrincipal -Principal $verified -ClientId $ClientId
            if ($verified.id -ine $principal.id) { throw 'Azure returned a different service principal object ID.' }
            return
        } catch {
            if ($_.Exception.Data['AzureCode'] -notin @('Request_ResourceNotFound', 'ResourceNotFound')) { throw }
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt + 1)) }
    }
    throw "Service principal could not be verified after four reads. Its ID remains saved in $OutputKey. Wait for directory propagation and rerun; do not create a replacement."
}

Write-Host '1. Validating the subscription tenant and looking for existing registrations.' -ForegroundColor Cyan
$account = Invoke-RegistrationCli -Arguments @('account', 'show', '--subscription', $SubscriptionId)
if ($account.id -ine $SubscriptionId -or $account.tenantId -ine $TenantId) {
    throw 'Azure CLI account does not match the selected subscription and tenant. Run az login for the intended tenant; no registrations were changed.'
}
if ($account.environmentName -ne 'AzureCloud') { throw 'This prerequisite currently supports Azure public cloud only.' }
# Entra CLI commands use the active tenant and do not accept --subscription.
$activeAccount = Invoke-RegistrationCli -Arguments @('account', 'show')
if ($activeAccount.tenantId -ine $TenantId) {
    throw 'The active Azure CLI tenant does not match the selected tenant. Run az account set --subscription <AZURE_SUBSCRIPTION_ID> for the intended subscription, then rerun. No registrations or configuration values were changed.'
}
if ($activeAccount.environmentName -ne 'AzureCloud') { throw 'This prerequisite currently supports Azure public cloud only.' }
Update-PrerequisiteEnv -Path $EnvFile -Values @{
    AZURE_APP_REGISTRATIONS_CONFIGURED = 'false'
    AZURE_SUBSCRIPTION_ID = $SubscriptionId
    AZURE_TENANT_ID = $TenantId
    APIM_API_APP_NAME = $ApimApiAppName
    AUTH_APP_NAME = $AuthAppName
    AUTH_REDIRECT_URI = $AuthRedirectUri
}
$apiApp = Find-Registration -Name $ApimApiAppName -ClientId $ApimApiClientId
$authApp = Find-Registration -Name $AuthAppName -ClientId $AuthClientId
if ($apiApp) {
    Assert-RegistrationSettings -App $apiApp -Kind api -Name $ApimApiAppName -AllowMissingIdentifier
}
if ($authApp) {
    if (-not $apiApp) { throw 'The sign-in app already exists but the intended API app was not found. Select the matching API app before proceeding.' }
    if ($apiApp.appId -ieq $authApp.appId) { throw 'The API and sign-in client IDs must be different.' }
    Assert-RegistrationSettings -App $authApp -Kind auth -Name $AuthAppName `
        -ApiClientId $apiApp.appId -ScopeId $apiApp.api.oauth2PermissionScopes[0].id
}

Write-Host "2. Creating or reusing APIM API registration '$ApimApiAppName'." -ForegroundColor Cyan
if (-not $apiApp) {
    $apiApp = Invoke-RegistrationWrite -Method post -Body @{
        displayName = $ApimApiAppName
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $false
        api = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes = @(@{
                id = [Guid]::NewGuid().ToString()
                value = 'Mcp.Invoke'
                type = 'Admin'
                isEnabled = $true
                adminConsentDisplayName = 'Use the Atlassian MCP gateway as the signed-in user'
                adminConsentDescription = "Access the caller's own connection status and permitted Atlassian MCP operations."
            })
        }
    }
}
Assert-ApplicationIdentity $apiApp
# Save recovery IDs before the dependent URI update or second registration.
Update-PrerequisiteEnv -Path $EnvFile -Values @{
    APIM_API_CLIENT_ID = [string]$apiApp.appId
    APIM_API_OBJECT_ID = [string]$apiApp.id
}
Assert-RegistrationSettings -App $apiApp -Kind api -Name $ApimApiAppName -AllowMissingIdentifier
$scopeId = [string]$apiApp.api.oauth2PermissionScopes[0].id
$apiUri = "api://$($apiApp.appId)"
if (-not $apiApp.identifierUris) {
    Invoke-RegistrationWrite -Method patch -ObjectId $apiApp.id -Body @{ identifierUris = @($apiUri) }
}
$apiApp = Wait-Registration -ClientId $apiApp.appId -ObjectId $apiApp.id -Kind api -Name $ApimApiAppName -ScopeId $scopeId
Update-PrerequisiteEnv -Path $EnvFile -Values @{
    APIM_API_IDENTIFIER_URI = $apiUri
    APIM_API_SCOPE_ID = $scopeId
    APIM_SCOPE = "$apiUri/Mcp.Invoke"
}

Write-Host "3. Creating or reusing OAuth sign-in registration '$AuthAppName'." -ForegroundColor Cyan
if (-not $authApp) {
    $authApp = Invoke-RegistrationWrite -Method post -Body @{
        displayName = $AuthAppName
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $false
        web = @{
            redirectUris = @($AuthRedirectUri)
            implicitGrantSettings = @{ enableAccessTokenIssuance = $false; enableIdTokenIssuance = $false }
        }
        requiredResourceAccess = @(@{
            resourceAppId = [string]$apiApp.appId
            resourceAccess = @(@{ id = $scopeId; type = 'Scope' })
        })
    }
}
Assert-ApplicationIdentity $authApp
if ($apiApp.appId -ieq $authApp.appId) { throw 'Azure returned the API registration as the sign-in client.' }
Update-PrerequisiteEnv -Path $EnvFile -Values @{
    AUTH_CLIENT_ID = [string]$authApp.appId
    AUTH_OBJECT_ID = [string]$authApp.id
}
$null = Wait-Registration -ClientId $authApp.appId -ObjectId $authApp.id -Kind auth -Name $AuthAppName `
    -ApiClientId $apiApp.appId -ScopeId $scopeId
Write-Host '4. Creating or reusing the enterprise applications required for admin consent.' -ForegroundColor Cyan
Ensure-RegistrationServicePrincipal -ClientId $apiApp.appId -OutputKey APIM_API_SERVICE_PRINCIPAL_ID
Ensure-RegistrationServicePrincipal -ClientId $authApp.appId -OutputKey AUTH_SERVICE_PRINCIPAL_ID
$completionValues = @{ AZURE_APP_REGISTRATIONS_CONFIGURED = 'true' }
if (-not (Read-PrerequisiteEnv -Path $EnvFile).Contains('AUTH_CLIENT_SECRET')) {
    $completionValues['AUTH_CLIENT_SECRET'] = ''
}
Update-PrerequisiteEnv -Path $EnvFile -Values $completionValues
Write-Host "5. Verified both registrations and service principals; saved their IDs and scope to '$EnvFile'." -ForegroundColor Green
Write-Host '   No bot resource, Teams SSO, APIM policy, credential or consent grant was created.'
Write-Host ''
Write-Host '6. Complete these manual steps in the Azure portal (https://portal.azure.com):' -ForegroundColor Cyan
Write-Host "   Switch to directory '$TenantId', then open Microsoft Entra ID > App registrations > All applications."
Write-Host "   A. Open API app '$ApimApiAppName' (Application/client ID: $($apiApp.appId))."
Write-Host "      Expose an API: verify Application ID URI '$apiUri' and enabled scope 'Mcp.Invoke' with Admins only consent."
Write-Host '      These settings are already configured. Do not create a client secret for this API app.'
Write-Host "   B. Open OAuth sign-in app '$AuthAppName' (Application/client ID: $($authApp.appId))."
Write-Host "      Authentication > Web: verify redirect URI '$AuthRedirectUri'. Leave implicit grants and public client flows disabled."
Write-Host "      API permissions: verify '$ApimApiAppName' > 'Mcp.Invoke' is listed as Delegated."
Write-Host '      An authorized tenant administrator must select Grant admin consent for <tenant> > Yes.'
Write-Host '      Refresh and confirm the permission status is Granted for <tenant>. If already granted, no new grant is needed.'
Write-Host '      Both enterprise applications now exist. If the portal still reports a missing service principal, wait for propagation, refresh, and retry.'
Write-Host '      If consent remains unavailable or fails, ask the tenant administrator to check the selected directory, API permission target, and consent permissions.'
Write-Host '   C. In the same OAuth sign-in app: Certificates & secrets > Client secrets > New client secret.'
Write-Host '      Enter a description (for example, Bot OAuth), choose an expiration per your organization policy, and select Add.'
Write-Host '      Copy the secret Value immediately, NOT the Secret ID; the Value is shown only once. Record the expiration for rotation.'
Write-Host "      Edit '$EnvFile' and populate AUTH_CLIENT_SECRET in the step 4 input section:"
Write-Host '      AUTH_CLIENT_SECRET="<paste the client secret Value here>"'
Write-Host '      Keep an existing valid secret unless intentionally rotating it; do not create another secret on every rerun.'
Write-Host '      Existing AUTH_CLIENT_SECRET values are preserved and never printed. Keep the file private and out of source control.'
Write-Host '   AZURE_APP_REGISTRATIONS_CONFIGURED=true verifies registration settings and service principals only; it does not verify consent or the secret.'
Write-Host '   The saved secret is reserved for future Bot OAuth configuration; this script does not use or validate it.'
