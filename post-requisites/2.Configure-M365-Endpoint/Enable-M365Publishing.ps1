<#
.SYNOPSIS
    Configures tenant-authorized Activity access and enables the existing bot's Teams channel.
.DESCRIPTION
    Preserves other protocols and non-Bot authorization schemes. Replaces
    BotServiceRbac with BotServiceTenant. Does not recreate the agent or bot,
    change Foundry/bot public network access, or submit to the Microsoft 365 catalog.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ProjectEndpoint,
    [string]$AgentName,
    [string]$BotServiceArmId,
    [string]$EnvFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\common-scripts\Common.ps1')
$context = Get-PublishingContext -Parameters $PSBoundParameters -EnvFile $EnvFile
$deploymentState = Get-PublishingState -Context $context
$update = Get-TenantEndpointUpdate -Agent $deploymentState.Agent
if ($deploymentState.PublicActivityEnabled -and $deploymentState.TenantAuthorization -and $deploymentState.TeamsChannelEnabled) {
    Write-Host 'Activity access and Teams channel already configured. No Azure writes were needed.'
    return
}
if (-not $PSCmdlet.ShouldProcess(
    "$($context.AgentName) and $($context.BotServiceArmId)",
    'Enable the restricted public Activity route, authorize tenant-wide use (replacing BotServiceRbac), and enable the Teams channel if needed')) {
    Write-Host 'No Azure writes were made.'
    return
}

if (-not $deploymentState.PublicActivityEnabled -or -not $deploymentState.TenantAuthorization) {
    Invoke-PublishingRequest -Context $context -Method PATCH -Url $context.AgentUrl `
        -Operation 'Configure Activity endpoint' -Body $update -NoContent
}
if (-not $deploymentState.TeamsChannelEnabled) {
    $properties = if ($deploymentState.TeamsChannel) {
        $deploymentState.TeamsChannel.properties.properties
    } else { [pscustomobject]@{} }
    if ($null -eq $properties) { $properties = [pscustomobject]@{} }
    $properties | Add-Member -NotePropertyName isEnabled -NotePropertyValue $true -Force
    $body = @{
        location = $deploymentState.Bot.location
        properties = @{ channelName = 'MsTeamsChannel'; properties = $properties }
    }
    $channelUrl = "https://management.azure.com$($context.BotServiceArmId)/channels/MsTeamsChannel?api-version=2022-09-15"
    Invoke-PublishingRequest -Context $context -Method PUT -Url $channelUrl -Arm `
        -Operation 'Enable Teams channel on existing bot' -Body $body -NoContent
}
$verified = Get-PublishingState -Context $context
Assert-PublishingReady -State $verified
Write-Host 'Verified Activity exception, BotServiceTenant authorization and Teams channel. No catalog submission has been made.'
