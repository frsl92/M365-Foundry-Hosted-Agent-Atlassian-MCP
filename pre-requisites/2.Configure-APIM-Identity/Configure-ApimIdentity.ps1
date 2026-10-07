<#
.SYNOPSIS
    Validates APIM's system-assigned managed identity and grants it API Management
    Service Contributor on the APIM resource itself.
.DESCRIPTION
    Inputs resolve from explicit parameters, then the shared repository-root .env.
    Saves identity details before configuring RBAC. Never enables the identity.
    Existing matching resource-scoped assignments are reused on reruns.
.EXAMPLE
    .\Configure-ApimIdentity.ps1 -ApimName "my-apim" -ResourceGroupName "my-rg" -SubscriptionId "00000000-0000-0000-0000-000000000000"
.EXAMPLE
    .\Configure-ApimIdentity.ps1
#>
param(
    [string]$ApimName,
    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [string]$EnvFile
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
}
foreach ($entry in $inputKeys.GetEnumerator()) {
    $value = Resolve-PrerequisiteValue -Parameters $PSBoundParameters -ParameterName $entry.Key `
        -Values $configuration -Key $entry.Value
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Supply -$($entry.Key) or set $($entry.Value) in '$EnvFile'."
    }
    Set-Variable -Name $entry.Key -Value $value
}
if ($ApimName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') {
    throw 'Invalid APIM instance name. Supply a name, not a URL or resource ID.'
}
$subscriptionGuid = [Guid]::Empty
if (-not [Guid]::TryParse($SubscriptionId, [ref]$subscriptionGuid) -or $subscriptionGuid -eq [Guid]::Empty) {
    throw 'SubscriptionId must be a nonempty subscription GUID, not a subscription display name.'
}
$SubscriptionId = $subscriptionGuid.ToString()
if ($ResourceGroupName -match '[/\\]' -or $ResourceGroupName.StartsWith('-')) {
    throw 'ResourceGroupName must be a resource group name, not a resource ID.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required. Install it, run az login, and rerun this script.'
}

function Invoke-ApimAzureCliJson {
    param([string[]]$Arguments)

    $PSNativeCommandUseErrorActionPreference = $false
    $output = & az @Arguments --subscription $SubscriptionId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI '$($Arguments[0..1] -join ' ')' failed (exit code $LASTEXITCODE). Review the CLI error above; check az login, subscription access, and RBAC permissions, then rerun."
    }
    if ([string]::IsNullOrWhiteSpace(($output -join "`n"))) {
        throw "Azure CLI '$($Arguments[0..1] -join ' ')' returned no JSON."
    }
    $output -join "`n" | ConvertFrom-Json -ErrorAction Stop
}

$roleDefinitionGuid = '312a565d-c81f-4fd8-895a-4e21e48d571c'
$roleName = 'API Management Service Contributor'
$expectedResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName"

Write-Host "1. Checking the system-assigned identity of APIM '$ApimName'." -ForegroundColor Cyan
$apim = Invoke-ApimAzureCliJson -Arguments @(
    'apim', 'show', '--name', $ApimName, '--resource-group', $ResourceGroupName,
    '--query', '{id:id,identity:identity}'
)
if (-not $apim.id -or $apim.id -ine $expectedResourceId) {
    throw 'Azure returned an unexpected APIM resource ID. No identity values or role assignments were changed.'
}
$resourceId = [string]$apim.id
$identityEnabled = @([string]$apim.identity.type -split '\s*,\s*') -contains 'SystemAssigned'
$principalGuid = [Guid]::Empty
$tenantGuid = [Guid]::Empty
$identityReady = $identityEnabled -and
    [Guid]::TryParse([string]$apim.identity.principalId, [ref]$principalGuid) -and
    $principalGuid -ne [Guid]::Empty -and
    [Guid]::TryParse([string]$apim.identity.tenantId, [ref]$tenantGuid) -and
    $tenantGuid -ne [Guid]::Empty

$savedValues = [ordered]@{
    AZURE_APIM_NAME                 = $ApimName
    AZURE_RESOURCE_GROUP_NAME       = $ResourceGroupName
    AZURE_SUBSCRIPTION_ID           = $SubscriptionId
    AZURE_APIM_RESOURCE_ID          = $resourceId
    AZURE_APIM_IDENTITY_ENABLED     = $identityEnabled.ToString().ToLowerInvariant()
    AZURE_APIM_IDENTITY_PRINCIPAL_ID = if ($identityReady) { $principalGuid.ToString() } else { '' }
    AZURE_APIM_IDENTITY_TENANT_ID    = if ($identityReady) { $tenantGuid.ToString() } else { '' }
    AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID = ''
}
Update-PrerequisiteEnv -Path $EnvFile -Values $savedValues

if (-not $identityEnabled) {
    throw "System-assigned managed identity is not enabled for '$ApimName'. In Azure portal, open this APIM instance > Security > Managed identities > System assigned, set Status to On, and select Save. Wait for the update to finish, then rerun this script. No role was granted."
}
if (-not $identityReady) {
    throw 'The system-assigned identity is enabled but its principal ID or tenant ID is not ready. Wait for APIM provisioning to complete and rerun this script. No role was granted.'
}
$principalId = $principalGuid.ToString()
Write-Host "   Saved managed identity principal ID: $principalId"

function Get-ApimContributorAssignment {
    $assignments = @(Invoke-ApimAzureCliJson -Arguments @(
        'role', 'assignment', 'list', '--scope', $resourceId,
        '--assignee-object-id', $principalId,
        '--fill-principal-name', 'false', '--fill-role-definition-name', 'false'
    ))
    $assignments | Where-Object {
        $_.principalId -ieq $principalId -and
        $_.scope -ieq $resourceId -and
        $_.roleDefinitionId -imatch "/$roleDefinitionGuid$" -and
        -not $_.condition -and
        $_.id
    } | Select-Object -First 1
}

Write-Host "2. Checking '$roleName' at scope '$resourceId'." -ForegroundColor Cyan
$assignment = Get-ApimContributorAssignment
if ($assignment) {
    Write-Host '   An exact resource-scoped assignment already exists; reusing it.'
} else {
    Write-Host "   Granting '$roleName' to the APIM managed identity."
    $null = Invoke-ApimAzureCliJson -Arguments @(
        'role', 'assignment', 'create', '--assignee-object-id', $principalId,
        '--assignee-principal-type', 'ServicePrincipal',
        '--role', $roleDefinitionGuid, '--scope', $resourceId
    )
    # ARM reads may briefly lag behind the successful role assignment write.
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $assignment = Get-ApimContributorAssignment
        if ($assignment) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt + 1)) }
    }
    if (-not $assignment) {
        throw 'Role creation returned successfully, but the assignment could not yet be verified. Identity details remain saved. Wait for RBAC propagation and rerun; an existing matching assignment will be reused.'
    }
}

Update-PrerequisiteEnv -Path $EnvFile -Values @{
    AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID = [string]$assignment.id
}
Write-Host "3. Verified role assignment and saved its ID to '$EnvFile'." -ForegroundColor Green
Write-Host '   Azure permission propagation can take several minutes before the identity can use this role.'
