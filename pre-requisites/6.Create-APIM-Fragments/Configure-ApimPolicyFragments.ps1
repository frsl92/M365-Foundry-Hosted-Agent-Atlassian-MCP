<#
.SYNOPSIS
    Creates or reuses the two shared Atlassian APIM policy fragments using Azure CLI.
.DESCRIPTION
    Requires prerequisite 5. Validates both assets and dependencies before writes.
    Conflicting fragment contents require -UpdateExisting. Reads back all outputs.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$ApimName,
    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [string]$EnvFile,
    [string]$AssetDirectory = (Join-Path $PSScriptRoot 'assets'),
    [switch]$UpdateExisting
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
$fragments = @(
    @{ Name = 'atlassian-user-auth'; Key = 'AZURE_APIM_USER_AUTH_FRAGMENT_ID' },
    @{ Name = 'atlassian-safe-errors'; Key = 'AZURE_APIM_SAFE_ERRORS_FRAGMENT_ID' }
)
foreach ($fragment in $fragments) {
    $fragment.Value = Read-ApimPolicyAsset -Path (Join-Path $AssetDirectory "$($fragment.Name).xml") -Root fragment
}
$context = Get-ApimProvisioningContext -Parameters $PSBoundParameters -EnvFile $EnvFile
Assert-ApimPolicyDependencies -Context $context -Policies @($fragments | ForEach-Object { $_.Value })
foreach ($fragment in $fragments) {
    $fragment.Id = "$($context.ResourceId)/policyFragments/$($fragment.Name)"
    $fragment.Url = "$($context.ServiceUrl)/policyFragments/$($fragment.Name)?api-version=2024-05-01&format=rawxml"
    $fragment.Existing = Get-ApimProvisioningResource -Context $context -Url $fragment.Url -ResourceId $fragment.Id -AllowMissing
    $fragment.Change = -not $fragment.Existing -or -not (Test-ApimPolicyMatch -Actual $fragment.Existing.properties.value -Expected $fragment.Value -Root fragment)
    if ($fragment.Existing -and $fragment.Change -and -not $UpdateExisting) {
        throw "Fragment '$($fragment.Name)' differs from its asset. Review it and rerun with -UpdateExisting; no writes were made."
    }
}
if (-not $PSCmdlet.ShouldProcess($context.ResourceId, 'Create/update the two policy fragments and save verified environment outputs')) { return }
Update-PrerequisiteEnv -Path $context.EnvFile -Values @{ AZURE_APIM_POLICY_FRAGMENTS_CONFIGURED = 'false' }
$outputs = [ordered]@{}
foreach ($fragment in $fragments) {
    if ($fragment.Change) {
        $properties = @{ format = 'rawxml'; value = $fragment.Value }
        if ($fragment.Existing -and $null -ne $fragment.Existing.properties.description) {
            $properties.description = $fragment.Existing.properties.description
        }
        Invoke-ApimProvisioningRequest -Context $context -Method put `
            -Url "$($context.ServiceUrl)/policyFragments/$($fragment.Name)?api-version=2024-05-01" `
            -Body @{ properties = $properties } -Existing:([bool]$fragment.Existing)
    }
    $verified = Wait-ApimProvisioningResource -Context $context -Url $fragment.Url -ResourceId $fragment.Id -Matches {
        param($resource)
        Test-ApimPolicyMatch -Actual $resource.properties.value -Expected $fragment.Value -Root fragment
    }
    $outputs[$fragment.Key] = $verified.id
}
$outputs['AZURE_APIM_POLICY_FRAGMENTS_CONFIGURED'] = 'true'
Update-PrerequisiteEnv -Path $context.EnvFile -Values $outputs
Write-Host 'Verified atlassian-user-auth and atlassian-safe-errors. No API policies or subscription keys were changed.'
