<#
.SYNOPSIS
    Restores APIM named values from the repository's .backup.yaml file.
.DESCRIPTION
    Validates the backup and APIM target, preflights every named value, then
    restores only the entries listed under values:. Existing metadata is
    preserved, unrelated named values are untouched, and values are not printed.
.EXAMPLE
    .\Restore-ApimNamedValues.ps1
.EXAMPLE
    .\Restore-ApimNamedValues.ps1 -Confirm:$false
.EXAMPLE
    .\Restore-ApimNamedValues.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$BackupFile = (Join-Path $PSScriptRoot '..\..\.backup.yaml')
)

$ErrorActionPreference = 'Stop'
$BackupFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BackupFile)

function Read-NamedValueBackup {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        throw "Named-value backup '$Path' does not exist."
    }

    $values = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    $foundValues = $false
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $lineNumber++
        if ($line -match '^\s*(#.*)?$') { continue }
        if (-not $foundValues) {
            if ($line -cne 'values:') {
                throw "Invalid named-value backup at '$Path', line $lineNumber. Expected a top-level values mapping."
            }
            $foundValues = $true
            continue
        }
        if ($line -cnotmatch '^  ([A-Za-z0-9][A-Za-z0-9._-]{0,255}):\s*(.*?)\s*$') {
            throw "Invalid named-value entry at '$Path', line $lineNumber. Expected two-space-indented NAME: VALUE."
        }

        $name = $Matches[1]
        $raw = $Matches[2]
        if ($values.Contains($name)) {
            throw "Duplicate named value '$name' at '$Path', line $lineNumber."
        }
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw "Named value '$name' has an empty value at '$Path', line $lineNumber."
        }

        if ($raw.StartsWith("'")) {
            if ($raw -cnotmatch "^'((?:[^']|'')*)'$") {
                throw "Invalid single-quoted value for '$name' at '$Path', line $lineNumber."
            }
            $value = $Matches[1].Replace("''", "'")
        } elseif ($raw.StartsWith('"')) {
            try {
                $value = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
            } catch {
                throw "Invalid double-quoted value for '$name' at '$Path', line $lineNumber."
            }
            if ($value -isnot [string]) {
                throw "The double-quoted value for '$name' must be a string."
            }
        } else {
            if ($raw -match '^(?:[!&*]|---|\.\.\.)' -or $raw -match '\s+#') {
                throw "Unsupported YAML syntax for '$name' at '$Path', line $lineNumber. Use a plain or quoted scalar without comments."
            }
            $value = $raw
        }

        if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 4096 -or $value -match "[`r`n]") {
            throw "Named value '$name' must contain 1 to 4096 characters on one line."
        }
        $values.Add($name, [string]$value)
    }
    if (-not $foundValues -or $values.Count -eq 0) {
        throw "Named-value backup '$Path' does not contain any values."
    }
    return ,$values
}

function Assert-BackupGuid {
    param([string]$Value, [string]$Name)

    $parsed = [Guid]::Empty
    if (-not [Guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [Guid]::Empty) {
        throw "Backup named value '$Name' must be a nonempty GUID."
    }
    return $parsed.ToString()
}

$backup = Read-NamedValueBackup -Path $BackupFile
foreach ($requiredName in @('apim-name', 'rg', 'sub-id', 'tenant-id', 'apim-mi-object-id')) {
    if (-not $backup.Contains($requiredName)) {
        throw "Named-value backup '$BackupFile' is missing required target value '$requiredName'."
    }
}

$ApimName = [string]$backup['apim-name']
$ResourceGroupName = [string]$backup['rg']
$SubscriptionId = Assert-BackupGuid ([string]$backup['sub-id']) 'sub-id'
$TenantId = Assert-BackupGuid ([string]$backup['tenant-id']) 'tenant-id'
$PrincipalId = Assert-BackupGuid ([string]$backup['apim-mi-object-id']) 'apim-mi-object-id'
if ($ApimName -notmatch '^[A-Za-z](?:[A-Za-z0-9-]{0,48}[A-Za-z0-9])?$') {
    throw "Backup named value 'apim-name' is not a valid APIM service name."
}
if ($ResourceGroupName -notmatch '^[\p{L}\p{N}_().-]{1,90}$' -or $ResourceGroupName.EndsWith('.')) {
    throw "Backup named value 'rg' is not a valid resource group name."
}

$azureCliCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azureCliCommand) {
    throw 'Azure CLI is required. Install it, run az login, and rerun this script.'
}

$resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName"
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
        if ($text -match '"code"\s*:\s*"([A-Za-z0-9_.-]+)"' -or $text -match 'ERROR:\s*\(([A-Za-z0-9_.-]+)\)') {
            $code = $Matches[1]
        }
        $exception = [InvalidOperationException]::new("Azure CLI named value request failed (exit code $exitCode; Azure code: $code). Output withheld. Check login, subscription access and APIM named-value permissions. Fix the error and rerun; completed writes are not rolled back.")
        $exception.Data['AzureCode'] = $code
        throw $exception
    }
    if ($NoContent) { return }
    try {
        $result = ('{"response":' + ($output -join "`n") + '}') | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $result.response) { throw 'Empty response.' }
    } catch {
        throw 'Azure CLI returned invalid or empty JSON for a named value request. Output withheld; no missing resource is inferred.'
    }
    return ,$result.response
}

function Invoke-NamedValueRequest {
    param([string]$Method, [string]$Url, $Body)

    $path = $null
    try {
        $urlArgument = $Url
        $nativeBatch = $azureCliCommand.CommandType -eq 'Application' -and $azureCliCommand.Source -match '\.(cmd|bat)$'
        if ($nativeBatch) { $urlArgument = '"' + ([Uri]$Url).AbsoluteUri + '"' }
        $arguments = @('rest', '--method', $Method, '--url', $urlArgument)
        if ($Body) {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) "apim-named-values-$([Guid]::NewGuid().ToString('N')).json"
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
        if (-not $visited.Add($url)) {
            throw 'Azure returned a repeated named value pagination link.'
        }
        $page = Invoke-NamedValueRequest -Method get -Url $url
        if ($page.value -isnot [Array]) {
            throw 'Azure returned an unexpected named value collection.'
        }
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

function Assert-NamedValueIdentity {
    param($Item, [string]$DisplayName, [string]$Name)

    if ([string]::IsNullOrWhiteSpace($Item.name) -or $Item.name.Length -gt 256 -or
        $Item.name -match '[*#&+:<>?/\\\x00-\x1f]' -or $Item.name -in @('.', '..') -or
        $Item.id -ine "$resourceId/namedValues/$($Item.name)" -or
        $Item.properties.displayName -cne $DisplayName -or ($Name -and $Item.name -cne $Name)) {
        throw "Unexpected or ambiguous resource identity for named value '$DisplayName'. No rename will be attempted."
    }
    if ($Item.properties.secret -isnot [bool] -or $Item.properties.keyVault) {
        throw "Named value '$DisplayName' has unknown secrecy or is Key Vault-backed. It cannot be restored from a plaintext values backup."
    }
}

Write-Host '1. Validating the backup target, tenant and current APIM identity.' -ForegroundColor Cyan
$account = Invoke-NamedValueCli -Arguments @('account', 'show')
if ($account.id -ine $SubscriptionId -or $account.tenantId -ine $TenantId -or $account.environmentName -cne 'AzureCloud') {
    throw 'The selected subscription must belong to the tenant recorded in the backup in Azure public cloud. No Azure resources were changed.'
}
$service = Invoke-NamedValueRequest -Method get -Url "${serviceUrl}?api-version=2024-05-01"
if ($service.id -ine $resourceId -or $service.identity.type -notmatch '(^|,\s*)SystemAssigned($|,)' -or
    $service.identity.principalId -ine $PrincipalId -or $service.identity.tenantId -ine $TenantId) {
    throw 'The live APIM system-assigned identity does not match the backup. No named values were changed.'
}

Write-Host "2. Preflighting all $($backup.Count) named values before making changes." -ForegroundColor Cyan
$existing = Get-ApimNamedValues
$operations = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $backup.GetEnumerator()) {
    $matches = @($existing | Where-Object { $_.properties.displayName -ieq $entry.Key })
    if ($matches.Count -gt 1) {
        throw "Multiple named values match '$($entry.Key)'. Resolve the ambiguity before restoring."
    }

    $method = 'put'
    $name = [string]$entry.Key
    $isSecret = $false
    if ($matches.Count -eq 1) {
        $item = $matches[0]
        Assert-NamedValueIdentity -Item $item -DisplayName $entry.Key
        $name = [string]$item.name
        $isSecret = [bool]$item.properties.secret
        if (-not $isSecret -and $item.properties.value -isnot [string]) {
            throw "The public value for '$($entry.Key)' was omitted. It cannot be compared safely."
        }
        $method = if (-not $isSecret -and $item.properties.value -ceq $entry.Value) { '' } else { 'patch' }
    } elseif (@($existing | Where-Object { $_.name -ieq $name }).Count) {
        throw "Resource name '$name' is already used by another display name. It will not be renamed or overwritten."
    }
    $operations.Add([pscustomobject]@{
        Name = $name
        DisplayName = [string]$entry.Key
        Value = [string]$entry.Value
        Method = $method
        Secret = $isSecret
    })
}

$writes = @($operations | Where-Object Method)
$creates = @($writes | Where-Object Method -eq 'put').Count
$updates = @($writes | Where-Object Method -eq 'patch').Count
$unchanged = $operations.Count - $writes.Count
Write-Host "   Planned changes: $creates create, $updates update, $unchanged unchanged. Unrelated named values will not be changed."
if ($writes.Count -eq 0) {
    Write-Host '3. Every backed-up named value already matches APIM. No writes were needed.' -ForegroundColor Green
    return
}
if (-not $PSCmdlet.ShouldProcess(
        "API Management service '$ApimName' in resource group '$ResourceGroupName'",
        "Restore $($writes.Count) named values from '$BackupFile'")) {
    Write-Host '3. Restore canceled. No Azure writes were made.'
    return
}

Write-Host '3. Restoring and verifying the backed-up named values.' -ForegroundColor Cyan
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
            Assert-NamedValueIdentity -Item $item -DisplayName $operation.DisplayName -Name $operation.Name
            if ($item.properties.provisioningState -in @('Failed', 'Canceled')) {
                throw "Provisioning failed for named value '$($operation.DisplayName)'. Inspect it in APIM and rerun."
            }
            $valueMatches = if ($operation.Secret) {
                $item.properties.secret -eq $true
            } else {
                $item.properties.secret -eq $false -and $item.properties.value -is [string] -and
                    $item.properties.value -ceq $operation.Value
            }
            if ($valueMatches -and
                (-not $item.properties.provisioningState -or $item.properties.provisioningState -eq 'Succeeded')) {
                $verified = $true
                break
            }
        } catch {
            if ($_.Exception.Data['AzureCode'] -notin @('ResourceNotFound', 'NotFound')) { throw }
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([int][Math]::Pow(2, $attempt + 1)) }
    }
    if (-not $verified) {
        throw "Named value '$($operation.DisplayName)' could not be verified after four reads. Completed writes remain; wait and rerun."
    }
    Write-Host "   Verified $($operation.DisplayName)."
}

Write-Host "4. Restored all $($backup.Count) named values from '$BackupFile'." -ForegroundColor Green
Write-Host '   Existing metadata and unrelated named values were left untouched. The shared .env file was not changed.'
