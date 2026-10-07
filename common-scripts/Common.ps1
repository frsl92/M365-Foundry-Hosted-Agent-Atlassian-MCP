function Get-PrerequisiteEnvPath {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\.env'))
}

function Format-DotEnvValue([AllowEmptyString()][string]$Value) {
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return "`"$escaped`""
}

function Read-PrerequisiteEnv {
    [CmdletBinding()]
    param([string]$Path = (Get-PrerequisiteEnvPath))

    $ErrorActionPreference = 'Stop'
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $values = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return ,$values }

    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $lineNumber++
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -cnotmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            throw "Invalid .env assignment at '$Path', line $lineNumber. Expected KEY=value."
        }

        $key = $Matches[1]
        $raw = $Matches[2]
        if ($values.Contains($key)) {
            throw "Duplicate .env key '$key' at '$Path', line $lineNumber."
        }

        if ($raw.StartsWith('"')) {
            if ($raw -cnotmatch '^"((?:[^"\\]|\\[\\"nrt])*)"\s*(?:#.*)?$') {
                throw "Invalid double-quoted .env value at '$Path', line $lineNumber."
            }
            $value = [regex]::Replace($Matches[1], '\\([\\"nrt])', {
                param($match)
                switch -CaseSensitive ($match.Groups[1].Value) {
                    '\' { '\' }
                    '"' { '"' }
                    'n' { "`n" }
                    'r' { "`r" }
                    't' { "`t" }
                }
            })
        } elseif ($raw.StartsWith("'")) {
            if ($raw -cnotmatch "^'([^']*)'\s*(?:#.*)?$") {
                throw "Invalid single-quoted .env value at '$Path', line $lineNumber."
            }
            $value = $Matches[1]
        } else {
            $value = ($raw -replace '(^|\s+)#.*$', '').TrimEnd()
        }
        $values.Add($key, $value)
    }
    return ,$values
}

function Resolve-PrerequisiteValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory)][string]$ParameterName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$DefaultValue = ''
    )

    if ($Parameters.Keys -contains $ParameterName) { return [string]$Parameters[$ParameterName] }
    if ($Values.Keys -ccontains $Key -and -not [string]::IsNullOrWhiteSpace($Values[$Key])) {
        return [string]$Values[$Key]
    }
    return $DefaultValue
}

function Assert-FoundryRedirectUri {
    param([string]$Value)

    $uri = $null
    $identifier = [Guid]::Empty
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $Value -match '\s' -or $uri.Scheme -ne 'https' -or
        $uri.Host -ine 'global.consent.azure-apim.net' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -cnotmatch '^/redirect/(?<Identifier>[0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$' -or
        -not [Guid]::TryParse($Matches.Identifier, [ref]$identifier) -or $identifier -eq [Guid]::Empty) {
        throw 'Expected a generated Foundry OAuth redirect URL: HTTPS global.consent.azure-apim.net/redirect/<GUID>, with a compact or hyphenated GUID and no credentials, query or fragment.'
    }
    return $Value
}

function Get-PrerequisiteGeneratedSections {
    [ordered]@{
        '1.Register-Atlassian-Client' = @(
            'ATLASSIAN_MCP_CLIENT_ID', 'ATLASSIAN_MCP_CLIENT_SECRET', 'ATLASSIAN_MCP_AUTHORIZATION_URL',
            'ATLASSIAN_MCP_TOKEN_URL', 'ATLASSIAN_MCP_SERVER_URL', 'ATLASSIAN_MCP_REDIRECT_URI',
            'ATLASSIAN_MCP_REGISTRATION_ACCESS_TOKEN')
        '2.Configure-APIM-Identity' = @(
            'AZURE_APIM_RESOURCE_ID', 'AZURE_APIM_IDENTITY_ENABLED', 'AZURE_APIM_IDENTITY_PRINCIPAL_ID',
            'AZURE_APIM_IDENTITY_TENANT_ID', 'AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID')
        '3.Configure-APIM-Credential-Provider' = @('AZURE_APIM_CREDENTIAL_PROVIDER_ID')
        '4.Register-Entra-Applications' = @(
            'APIM_API_CLIENT_ID', 'APIM_API_OBJECT_ID', 'APIM_API_SERVICE_PRINCIPAL_ID',
            'APIM_API_IDENTIFIER_URI', 'APIM_API_SCOPE_ID', 'APIM_SCOPE', 'AUTH_CLIENT_ID',
            'AUTH_OBJECT_ID', 'AUTH_SERVICE_PRINCIPAL_ID', 'AZURE_APP_REGISTRATIONS_CONFIGURED')
        '5.Configure-APIM-Named-Values' = @('AZURE_APIM_NAMED_VALUES_CONFIGURED')
        '6.Create-APIM-Fragments' = @(
            'AZURE_APIM_USER_AUTH_FRAGMENT_ID', 'AZURE_APIM_SAFE_ERRORS_FRAGMENT_ID',
            'AZURE_APIM_POLICY_FRAGMENTS_CONFIGURED')
        '7.Create-APIM-APIandMCP' = @(
            'AZURE_APIM_CONNECT_API_RESOURCE_ID', 'AZURE_APIM_CONNECT_SPEC_SHA256',
            'AZURE_APIM_CONNECT_STATUS_URL', 'AZURE_APIM_MCP_API_RESOURCE_ID',
            'AZURE_APIM_MCP_SERVER_URL', 'AZURE_APIM_APIS_CONFIGURED')
        'deployment (agent-deployment/deploy-agent.ps1)' = @('AZURE_FOUNDRY_AGENT_NAME')
    }
}

function Format-PrerequisiteEnv {
    param([string[]]$Lines)

    $templatePath = Join-Path $PSScriptRoot '..\.env.v1.example'
    if (-not [System.IO.File]::Exists($templatePath)) {
        throw 'The root configuration template .env.v1.example is missing. Restore it before saving configuration.'
    }
    $templateKeys = Read-PrerequisiteEnv -Path $templatePath
    $templateLines = [System.IO.File]::ReadAllLines($templatePath)
    $generatedSections = Get-PrerequisiteGeneratedSections
    $generatedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($section in $generatedSections.GetEnumerator()) {
        foreach ($key in $section.Value) {
            if ($templateKeys.Contains($key)) {
                throw "Generated key '$key' must not appear in .env.v1.example."
            }
            $null = $generatedKeys.Add($key)
        }
    }
    $templateComments = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($line in $templateLines) {
        if ($line -match '^\s*#') { $null = $templateComments.Add($line) }
    }

    $assignments = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    $otherLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        if ($line -cmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=' -and
            ($templateKeys.Contains($Matches[1]) -or $generatedKeys.Contains($Matches[1]))) {
            $assignments.Add($Matches[1], $line)
        } elseif (-not [string]::IsNullOrWhiteSpace($line) -and -not $templateComments.Contains($line) -and
            $line -notmatch '^# Script-generated values(?: \(all prerequisites\))?$' -and
            $line -notmatch '^# Keep every output below the input sections, even when a later script reuses it\.$' -and
            -not ($line.StartsWith('# Generated by ') -and $generatedSections.Contains($line.Substring(15)))) {
            $otherLines.Add($line)
        }
    }
    if ($assignments.Count -eq 0) { return ,$Lines }

    $formatted = [System.Collections.Generic.List[string]]::new()
    $formatted.AddRange($otherLines)
    if ($otherLines.Count) { $formatted.Add('') }
    foreach ($line in $templateLines) {
        if ($line -cmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $key = $Matches[1]
            if ($assignments.ContainsKey($key)) { $formatted.Add($assignments[$key]) }
        } else {
            $formatted.Add($line)
        }
    }
    $hasOutputs = @($assignments.Keys | Where-Object { $generatedKeys.Contains($_) }).Count -gt 0
    if ($hasOutputs) {
        $formatted.Add('')
        $formatted.Add('# Script-generated values')
        foreach ($section in $generatedSections.GetEnumerator()) {
            $keys = @($section.Value | Where-Object { $assignments.ContainsKey($_) })
            if ($keys.Count -eq 0) { continue }
            $formatted.Add('')
            $formatted.Add("# Generated by $($section.Key)")
            foreach ($key in $keys) { $formatted.Add($assignments[$key]) }
        }
    }
    return ,$formatted
}

function Update-PrerequisiteEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values,
        [string]$Path = (Get-PrerequisiteEnvPath),
        [switch]$PreserveLayout
    )

    $ErrorActionPreference = 'Stop'
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    # Validate the existing file before replacing anything; never silently repair bad input.
    $null = Read-PrerequisiteEnv -Path $Path
    $updates = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    foreach ($entry in $Values.GetEnumerator()) {
        if ([string]$entry.Key -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw 'Invalid .env key supplied for update.'
        }
        $updates.Add([string]$entry.Key, (Format-DotEnvValue ([string]$entry.Value)))
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ([System.IO.File]::Exists($Path)) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            if ($line -cmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=' -and $updates.Contains($Matches[1])) {
                $key = $Matches[1]
                $lines.Add("$key=$($updates[$key])")
                $updates.Remove($key)
            } else {
                $lines.Add($line)
            }
        }
    }
    foreach ($entry in $updates.GetEnumerator()) {
        $lines.Add("$($entry.Key)=$($entry.Value)")
    }
    if (-not $PreserveLayout) { $lines = Format-PrerequisiteEnv -Lines $lines }

    $temporaryPath = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) ".env.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllLines($temporaryPath, $lines, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($Path)) {
            for ($attempt = 0; $attempt -lt 4; $attempt++) {
                try {
                    [System.IO.File]::Replace($temporaryPath, $Path, [System.Management.Automation.Language.NullString]::Value)
                    break
                } catch [System.IO.IOException] {
                    # Windows file scanners can briefly block an otherwise valid atomic replacement.
                    $nativeError = $_.Exception.GetBaseException().HResult -band 0xffff
                    if ($attempt -eq 3 -or $nativeError -notin @(32, 33, 1175)) { throw }
                    Write-Verbose "Configuration replacement is temporarily blocked (Windows error $nativeError); retrying."
                    Start-Sleep -Milliseconds ([int](100 * [Math]::Pow(2, $attempt)))
                }
            }
        } else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Invoke-ApimProvisioningCli {
    param($Context, [string[]]$Arguments, [switch]$NoContent, [string]$ResponseFile)

    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $output = & az @Arguments --subscription $Context.SubscriptionId --only-show-errors --output $(if ($NoContent -or $ResponseFile) { 'none' } else { 'json' }) 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) {
        $code = 'Unavailable'
        $text = $output -join "`n"
        if ($text -match '"code"\s*:\s*"([A-Za-z0-9_.-]+)"' -or $text -match 'ERROR:\s*\(([A-Za-z0-9_.-]+)\)') { $code = $Matches[1] }
        elseif ($text -match 'UnicodeEncodeError|Unexpected UTF-8 BOM') { $code = 'AzureCliResponseEncodingError' }
        $operation = $Arguments[0]
        if ($operation -eq 'rest') {
            $methodIndex = [Array]::IndexOf($Arguments, '--method')
            $urlIndex = [Array]::IndexOf($Arguments, '--url')
            if ($methodIndex -ge 0 -and $urlIndex -ge 0) {
                $operation = "$($Arguments[$methodIndex + 1].ToUpperInvariant()) $(([Uri]$Arguments[$urlIndex + 1].Trim('"')).AbsolutePath)"
            }
        }
        $exception = [InvalidOperationException]::new("Azure CLI APIM request '$operation' failed (exit code $exitCode; Azure code: $code). Output withheld. Check login, subscription access and APIM permissions, or CLI response encoding when indicated. Completed writes are not rolled back; fix the error and rerun.")
        $exception.Data['AzureCode'] = $code
        throw $exception
    }
    if ($NoContent) { return }
    try {
        $json = if ($ResponseFile) { [IO.File]::ReadAllText($ResponseFile) } else { $output -join "`n" }
        $result = ('{"response":' + $json.TrimStart([char]0xFEFF) + '}') | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $result.response) { throw 'Empty response.' }
    } catch { throw 'Azure CLI returned invalid or empty APIM JSON. Output withheld; no missing resource is inferred.' }
    return ,$result.response
}

function Invoke-ApimProvisioningRequest {
    param(
        $Context, [string]$Method, [string]$Url,
        [System.Collections.IDictionary]$Body, [switch]$Existing
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or $uri.Port -ne 443 -or
        $uri.UserInfo -or $uri.Fragment -or
        ($uri.AbsolutePath -ine ([Uri]$Context.ServiceUrl).AbsolutePath -and
         -not $uri.AbsolutePath.StartsWith(([Uri]$Context.ServiceUrl).AbsolutePath + '/', [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Refusing an APIM request outside the selected management resource.'
    }
    $path = $null
    $responsePath = $null
    try {
        $nativeBatch = $Context.AzureCli.CommandType -eq 'Application' -and $Context.AzureCli.Source -match '\.(cmd|bat)$'
        $urlArgument = if ($nativeBatch) { '"' + $uri.AbsoluteUri + '"' } else { $Url }
        $arguments = @('rest', '--method', $Method, '--url', $urlArgument)
        $headers = @()
        if ($Body -or ($Method -ieq 'get' -and $uri.AbsolutePath -match '/policies/policy$')) {
            # az rest decodes write responses even with output none; capture them to avoid BOM/console failures.
            $responsePath = Join-Path (Split-Path $Context.EnvFile -Parent) ".env.$([Guid]::NewGuid().ToString('N')).response.json"
            $responseArgument = if ($nativeBatch) { '"' + $responsePath + '"' } else { $responsePath }
            $arguments += @('--output-file', $responseArgument)
            $headers += 'Accept=application/json'
        }
        if ($Body) {
            $path = Join-Path (Split-Path $Context.EnvFile -Parent) ".env.$([Guid]::NewGuid().ToString('N')).request.json"
            [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Body -Depth 30), [Text.UTF8Encoding]::new($false))
            $bodyArgument = "@$path"
            if ($nativeBatch) { $bodyArgument = '"' + $bodyArgument + '"' }
            $arguments += @('--body', $bodyArgument)
            $headers += 'Content-Type=application/json'
            if ($Existing) { $headers += 'If-Match=*' }
        }
        if ($headers.Count) { $arguments += @('--headers') + $headers }
        Invoke-ApimProvisioningCli -Context $Context -Arguments $arguments -NoContent:([bool]$Body) -ResponseFile $responsePath
    } finally {
        if ($path -and [IO.File]::Exists($path)) { [IO.File]::Delete($path) }
        if ($responsePath -and [IO.File]::Exists($responsePath)) { [IO.File]::Delete($responsePath) }
    }
}

function Get-ApimProvisioningContext {
    param([System.Collections.IDictionary]$Parameters, [string]$EnvFile)

    if (-not $EnvFile) { $EnvFile = Get-PrerequisiteEnvPath }
    $EnvFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EnvFile)
    $values = Read-PrerequisiteEnv -Path $EnvFile
    $resolved = @{}
    foreach ($entry in @{
        ApimName = 'AZURE_APIM_NAME'; ResourceGroupName = 'AZURE_RESOURCE_GROUP_NAME'; SubscriptionId = 'AZURE_SUBSCRIPTION_ID'
    }.GetEnumerator()) {
        $resolved[$entry.Key] = Resolve-PrerequisiteValue -Parameters $Parameters -ParameterName $entry.Key -Values $values -Key $entry.Value
        if ([string]::IsNullOrWhiteSpace($resolved[$entry.Key])) { throw "Supply -$($entry.Key) or set $($entry.Value)." }
    }
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($resolved.SubscriptionId, [ref]$guid) -or $guid -eq [Guid]::Empty) { throw 'SubscriptionId must be a nonempty GUID.' }
    $resolved.SubscriptionId = $guid.ToString()
    if ($resolved.ApimName -notmatch '^[A-Za-z](?:[A-Za-z0-9-]{0,48}[A-Za-z0-9])?$' -or
        $resolved.ResourceGroupName -notmatch '^[\p{L}\p{N}_().-]{1,90}$' -or $resolved.ResourceGroupName.EndsWith('.')) {
        throw 'Supply valid APIM and resource group names, not URLs or resource IDs.'
    }
    $resourceId = "/subscriptions/$($resolved.SubscriptionId)/resourceGroups/$($resolved.ResourceGroupName)/providers/Microsoft.ApiManagement/service/$($resolved.ApimName)"
    if ($values['AZURE_APIM_RESOURCE_ID'] -ine $resourceId -or $values['AZURE_APIM_NAMED_VALUES_CONFIGURED'] -cne 'true') {
        throw 'Complete prerequisite 5 for this APIM resource before deploying fragments or APIs.'
    }
    $cli = Get-Command az -ErrorAction SilentlyContinue
    if (-not $cli) { throw 'Azure CLI is required. Install it and run az login.' }
    $context = [pscustomobject]@{
        ApimName = $resolved.ApimName; ResourceGroupName = $resolved.ResourceGroupName
        SubscriptionId = $resolved.SubscriptionId; ResourceId = $resourceId
        ServiceUrl = "https://management.azure.com/subscriptions/$($resolved.SubscriptionId)/resourceGroups/$([Uri]::EscapeDataString($resolved.ResourceGroupName))/providers/Microsoft.ApiManagement/service/$($resolved.ApimName)"
        EnvFile = $EnvFile; Values = $values; AzureCli = $cli; GatewayUrl = ''
    }
    $account = Invoke-ApimProvisioningCli -Context $context -Arguments @('account', 'show')
    if ($account.id -ine $context.SubscriptionId -or $account.environmentName -cne 'AzureCloud' -or
        -not $values['AZURE_TENANT_ID'] -or $account.tenantId -ine $values['AZURE_TENANT_ID']) {
        throw 'Azure CLI account must match the saved subscription and tenant in Azure public cloud.'
    }
    $service = Invoke-ApimProvisioningRequest -Context $context -Method get -Url "$($context.ServiceUrl)?api-version=2024-05-01"
    if ($service.id -ine $resourceId) { throw 'Azure returned an unexpected APIM resource identity.' }
    $gateway = $null
    if (-not [Uri]::TryCreate([string]$service.properties.gatewayUrl, [UriKind]::Absolute, [ref]$gateway) -or
        $gateway.Scheme -ne 'https' -or $gateway.UserInfo -or $gateway.Query -or $gateway.Fragment -or $gateway.AbsolutePath -ne '/') {
        throw 'Azure returned an invalid APIM HTTPS gateway URL.'
    }
    $context.GatewayUrl = ([string]$service.properties.gatewayUrl).TrimEnd('/')
    return $context
}

function Get-ApimProvisioningResource {
    param($Context, [string]$Url, [string]$ResourceId, [switch]$AllowMissing)

    try {
        $resource = Invoke-ApimProvisioningRequest -Context $Context -Method get -Url $Url
    } catch {
        if ($AllowMissing -and $_.Exception.Data['AzureCode'] -in @('ResourceNotFound', 'NotFound')) { return $null }
        throw
    }
    if ($resource.id -ine $ResourceId -or -not $resource.properties) { throw "Unexpected APIM resource identity or properties for '$ResourceId'." }
    if ($resource.properties.provisioningState -in @('Failed', 'Canceled')) { throw "APIM provisioning failed for '$ResourceId'." }
    return $resource
}

function Get-ApimProvisioningCollection {
    param($Context, [string]$Url)

    $collectionPath = ([Uri]$Url).AbsolutePath
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = [Collections.Generic.List[object]]::new()
    do {
        if (-not $visited.Add($Url)) { throw 'Azure returned a repeated APIM pagination link.' }
        $page = Invoke-ApimProvisioningRequest -Context $Context -Method get -Url $Url
        if ($page.value -isnot [Array]) { throw 'Azure returned an invalid APIM collection.' }
        foreach ($item in $page.value) {
            if (-not $item.id -or -not $item.name -or -not $item.properties) { throw 'Azure returned an incomplete APIM collection item.' }
            $items.Add($item)
        }
        $Url = [string]$page.nextLink
        if ($Url) {
            $next = $null
            if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$next) -or $next.AbsolutePath -ine $collectionPath) {
                throw 'Azure returned an unexpected APIM pagination path.'
            }
        }
    } while ($Url)
    return ,$items.ToArray()
}

function ConvertTo-ApimPolicyDocument {
    param([string]$Value, [ValidateSet('fragment', 'policies')][string]$Root)

    # rawxml allows C# quotes inside expression attributes; encode only those quotes for local XML validation.
    $encoded = [regex]::Replace($Value, '(?s)(?<prefix>\b[\w-]+\s*=\s*")(?<expression>@[({].*?)(?<suffix>"(?=\s+[\w-]+\s*=|\s*/?>))', {
        param($match)
        $match.Groups['prefix'].Value + $match.Groups['expression'].Value.Replace('"', '&quot;') + $match.Groups['suffix'].Value
    })
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($encoded), $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
    } catch [Xml.XmlException] {
        throw "Invalid APIM $Root policy XML. Check expression attributes and XML escaping."
    } finally { $reader.Dispose() }
    if ($document.DocumentElement.Name -cne $Root) { throw "Expected an APIM <$Root> policy root." }
    return $document
}

function Read-ApimPolicyAsset {
    param([string]$Path, [ValidateSet('fragment', 'policies')][string]$Root)

    $value = [IO.File]::ReadAllText($Path)
    $null = ConvertTo-ApimPolicyDocument -Value $value -Root $Root
    return $value
}

function Test-ApimPolicyMatch {
    param([string]$Actual, [string]$Expected, [ValidateSet('fragment', 'policies')][string]$Root)

    return (ConvertTo-ApimPolicyDocument -Value $Actual -Root $Root).OuterXml -ceq
        (ConvertTo-ApimPolicyDocument -Value $Expected -Root $Root).OuterXml
}

function Test-ApimManagedProperties {
    param($Actual, $Expected)

    if ($Expected -is [Collections.IDictionary]) {
        foreach ($entry in $Expected.GetEnumerator()) {
            if ($null -eq $Actual -or -not (Test-ApimManagedProperties -Actual $Actual.($entry.Key) -Expected $entry.Value)) { return $false }
        }
        return $true
    }
    if ($Expected -is [Array]) {
        if ($Actual -isnot [Array] -or $Actual.Count -ne $Expected.Count) { return $false }
        for ($i = 0; $i -lt $Expected.Count; $i++) {
            if (-not (Test-ApimManagedProperties -Actual $Actual[$i] -Expected $Expected[$i])) { return $false }
        }
        return $true
    }
    if ($Expected -is [bool]) { return $Actual -is [bool] -and $Actual -eq $Expected }
    return $Actual -is [string] -and $Actual -ceq $Expected
}

function Get-ApimApiType {
    param($Properties)

    # ARM can omit the discriminator for its default HTTP API type.
    if ($null -eq $Properties.type) { return 'http' }
    return $Properties.type
}

function Test-ApimApiProperties {
    param($Actual, [System.Collections.IDictionary]$Expected)

    if ($null -eq $Actual -or (Get-ApimApiType -Properties $Actual) -cne $Expected['type']) { return $false }
    $managed = [ordered]@{}
    foreach ($entry in $Expected.GetEnumerator()) {
        if ($entry.Key -cne 'type') { $managed[$entry.Key] = $entry.Value }
    }
    if ($Expected['type'] -ceq 'mcp') {
        $endpoints = $Actual.mcpProperties.endpoints
        if ($null -eq $endpoints -or $endpoints -is [Array]) { return $false }
        $keys = @(if ($endpoints -is [Collections.IDictionary]) { $endpoints.Keys } else { $endpoints.PSObject.Properties.Name })
        if ($keys.Count -ne 1 -or $keys[0] -cne 'message') { return $false }
        # The live ARM contract can infer Streamable HTTP from a message-only endpoint map,
        # omitting transportType on read-back. An explicit conflicting transport is still rejected.
        if ($null -eq $Actual.mcpProperties.transportType) {
            $mcp = $Expected['mcpProperties'].Clone()
            $mcp.Remove('transportType')
            $managed['mcpProperties'] = $mcp
        }
    }
    return Test-ApimManagedProperties -Actual $Actual -Expected $managed
}

function Assert-ApimPolicyDependencies {
    param($Context, [string[]]$Policies)

    $references = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($policy in $Policies) {
        foreach ($match in [regex]::Matches($policy, '\{\{([A-Za-z0-9._-]+)\}\}')) { $null = $references.Add($match.Groups[1].Value) }
    }
    $mapping = @{
        'apim-api-client-id' = 'APIM_API_CLIENT_ID'; 'apim-mi-object-id' = 'AZURE_APIM_IDENTITY_PRINCIPAL_ID'
        'apim-name' = 'AZURE_APIM_NAME'; 'arm-api-version' = 'AZURE_APIM_POLICY_ARM_API_VERSION'
        'atlassian-credential-provider' = 'AZURE_APIM_CREDENTIAL_PROVIDER_NAME'
        'atlassian-mcp-base-url' = 'ATLASSIAN_MCP_BASE_URL'; 'atlassian-mcp-path' = 'ATLASSIAN_MCP_PATH'
        'atlassian-post-login-redirect-url' = 'ATLASSIAN_POST_LOGIN_REDIRECT_URL'
        'bot-user-auth-client-id' = 'AUTH_CLIENT_ID'; 'rg' = 'AZURE_RESOURCE_GROUP_NAME'
        'sub-id' = 'AZURE_SUBSCRIPTION_ID'; 'tenant-id' = 'AZURE_TENANT_ID'
    }
    $items = Get-ApimProvisioningCollection -Context $Context -Url "$($Context.ServiceUrl)/namedValues?api-version=2024-05-01"
    foreach ($reference in $references) {
        $matches = @($items | Where-Object { $_.properties.displayName -ceq $reference })
        if ($matches.Count -ne 1) { throw "Missing or ambiguous named value '$reference'. Rerun prerequisite 5." }
        $item = $matches[0]
        if ($item.id -ine "$($Context.ResourceId)/namedValues/$($item.name)" -or
            $item.properties.secret -isnot [bool] -or -not $mapping.ContainsKey($reference)) {
            throw "Named value '$reference' has invalid resource identity, secrecy metadata or prerequisite mapping. Inspect APIM and rerun."
        }
        if ($item.properties.secret -or $item.properties.keyVault) {
            Write-Warning "Named value '$reference' is secret or Key Vault-backed. Its existence and resource identity were verified; its contents were not read or compared with the saved configuration."
            continue
        }
        if ([string]::IsNullOrWhiteSpace($item.properties.value) -or
            $item.properties.value -cne $Context.Values[$mapping[$reference]]) {
            throw "Named value '$reference' does not match the saved public prerequisite configuration. Rerun prerequisite 5."
        }
    }
}

function Wait-ApimProvisioningResource {
    param($Context, [string]$Url, [string]$ResourceId, [scriptblock]$Matches)

    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $resource = Get-ApimProvisioningResource -Context $Context -Url $Url -ResourceId $ResourceId -AllowMissing
        if ($resource -and $resource.properties.provisioningState -notin @('InProgress', 'Creating', 'Updating', 'Accepted') -and
            (& $Matches $resource)) { return $resource }
        if ($attempt -lt 11) { Start-Sleep -Seconds 5 }
    }
    throw "APIM resource '$ResourceId' could not be verified within the read-back window. Completed writes remain; wait and rerun."
}

function Get-DeploymentAgentName {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$ServiceName
    )

    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw 'Python is required to read azure.yaml. Install Python and the packages in agent-deployment\requirements-deploy.txt.'
    }
    $reader = @'
import sys
try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required. Run: python -m pip install -r agent-deployment\\requirements-deploy.txt")

class UniqueKeyLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        mapping = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in mapping:
                raise ValueError("Duplicate YAML keys are not supported.")
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping

try:
    with open(sys.argv[1], encoding="utf-8-sig") as source:
        manifest = yaml.load(source, Loader=UniqueKeyLoader)
except (OSError, UnicodeError, yaml.YAMLError, ValueError, TypeError):
    sys.exit("Cannot read azure.yaml: expected valid YAML with unique mapping keys.")

services = manifest.get("services") if isinstance(manifest, dict) else None
service = services.get(sys.argv[2]) if isinstance(services, dict) else None
if not isinstance(service, dict) or service.get("host") != "azure.ai.agent":
    sys.exit("The selected service must exist in azure.yaml and use host: azure.ai.agent.")
name = service.get("name")
if not isinstance(name, str) or not name.strip():
    sys.exit("The selected agent service must have an explicit, nonempty string name in azure.yaml.")
import re
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
    sys.exit("The agent name in azure.yaml must be literal: use letters, digits, dots, underscores or hyphens, not environment substitutions.")
print(name)
'@
    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $output = & python -c $reader $ManifestPath $ServiceName 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) {
        throw "Reading the agent name from azure.yaml failed (Python exit code $exitCode). $($output -join "`n")"
    }
    $name = ($output -join "`n").Trim()
    if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'The YAML reader returned an invalid agent name.'
    }
    return $name
}

function Get-PublishingContext {
    param(
        [System.Collections.IDictionary]$Parameters,
        [string]$EnvFile
    )

    if (-not $EnvFile) { $EnvFile = Get-PrerequisiteEnvPath }
    $values = Read-PrerequisiteEnv -Path $EnvFile
    $endpoint = Resolve-PrerequisiteValue -Parameters $Parameters -ParameterName ProjectEndpoint `
        -Values $values -Key AZURE_FOUNDRY_PROJECT_ENDPOINT
    $agentName = Resolve-PrerequisiteValue -Parameters $Parameters -ParameterName AgentName `
        -Values $values -Key AZURE_FOUNDRY_AGENT_NAME -DefaultValue 'atlassian-agent'
    $botId = Resolve-PrerequisiteValue -Parameters $Parameters -ParameterName BotServiceArmId `
        -Values $values -Key AZURE_BOT_SERVICE_RESOURCE_ID

    $uri = $null
    if (-not [Uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or
        $endpoint -match '\s' -or $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or
        $uri.Host -notmatch '^[a-z0-9-]+\.services\.ai\.azure\.com$' -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.AbsolutePath -cnotmatch '^/api/projects/[A-Za-z0-9._-]+/?$') {
        throw 'Supply -ProjectEndpoint or AZURE_FOUNDRY_PROJECT_ENDPOINT as https://<account>.services.ai.azure.com/api/projects/<project>.'
    }
    if ($agentName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw 'AgentName must contain only letters, digits, dots, underscores and hyphens, starting with a letter or digit.'
    }
    if ($botId -notmatch '^/subscriptions/(?<Subscription>[0-9a-f-]{36})/resourceGroups/[^/\\?#\s]+/providers/Microsoft\.BotService/botServices/[^/\\?#\s]+$') {
        throw 'Supply -BotServiceArmId or AZURE_BOT_SERVICE_RESOURCE_ID as the ARM ID of the existing Azure Bot Service.'
    }
    $subscription = $Matches.Subscription
    $guid = [Guid]::Empty
    if (-not [Guid]::TryParse($subscription, [ref]$guid) -or $guid -eq [Guid]::Empty) {
        throw 'The bot subscription ID must be a nonempty GUID.'
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required. Install it and run az login before using these scripts.'
    }
    $endpoint = $endpoint.TrimEnd('/')
    return [pscustomobject]@{
        ProjectEndpoint = $endpoint
        AgentName = $agentName
        AgentUrl = "$endpoint/agents/${agentName}?api-version=v1"
        BotServiceArmId = $botId
        BotUrl = "https://management.azure.com${botId}?api-version=2022-09-15"
        ChannelsUrl = "https://management.azure.com${botId}/channels?api-version=2022-09-15"
        SubscriptionId = $subscription
    }
}

function Invoke-PublishingCli {
    param([string[]]$Arguments, [string]$Operation, [switch]$NoContent)

    $PSNativeCommandUseErrorActionPreference = $false
    $ErrorActionPreference = 'Continue'
    $output = & az @Arguments --only-show-errors --output $(if ($NoContent) { 'none' } else { 'json' }) 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) {
        $text = $output -join "`n"
        $code = 'Unavailable'
        if ($text -match '"code"\s*:\s*"([A-Za-z0-9_.-]+)"' -or $text -match 'ERROR:\s*\(([A-Za-z0-9_.-]+)\)') {
            $code = $Matches[1]
        }
        throw "$Operation failed (Azure CLI exit code $exitCode; Azure code: $code). Response withheld to protect credentials and metadata. Check az login, permissions, private DNS/connectivity and request inputs. Completed Azure changes are not rolled back; inspect the resource before retrying."
    }
    if ($NoContent) { return }
    try {
        $response = ConvertFrom-Json -InputObject ($output -join "`n") -ErrorAction Stop
    } catch {
        throw "$Operation returned invalid JSON. Response withheld."
    }
    if ($null -eq $response -or $response -isnot [pscustomobject]) {
        throw "$Operation returned an empty or unexpected response; expected a JSON object."
    }
    return $response
}

function Invoke-PublishingRequest {
    param(
        $Context,
        [ValidateSet('GET', 'PATCH', 'PUT', 'POST')][string]$Method,
        [string]$Url,
        [string]$Operation,
        $Body,
        [switch]$Arm,
        [switch]$NoContent
    )

    $path = $null
    try {
        $command = Get-Command az
        $nativeBatch = $command.CommandType -eq 'Application' -and $command.Source -match '\.(cmd|bat)$'
        $urlArgument = if ($nativeBatch) { '"' + $Url + '"' } else { $Url }
        $resource = if ($Arm) { 'https://management.azure.com/' } else { 'https://ai.azure.com' }
        $arguments = @('rest', '--method', $Method, '--url', $urlArgument,
            '--resource', $resource, '--subscription', $Context.SubscriptionId)
        if ($null -ne $Body) {
            $path = Join-Path ([IO.Path]::GetTempPath()) "foundry-publish-$([Guid]::NewGuid().ToString('N')).json"
            [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Body -Depth 100), [Text.UTF8Encoding]::new($false))
            $bodyArgument = "@$path"
            if ($nativeBatch) { $bodyArgument = '"' + $bodyArgument + '"' }
            $contentType = if ($Method -eq 'PATCH' -and -not $Arm) { 'application/merge-patch+json' } else { 'application/json' }
            $arguments += @('--body', $bodyArgument, '--headers', "Content-Type=$contentType")
        }
        Invoke-PublishingCli -Arguments $arguments -Operation $Operation -NoContent:$NoContent
    } finally {
        if ($path -and [IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
}

function Get-BotOAuthConnections {
    param($Context)

    $path = "$($Context.BotServiceArmId)/connections"
    $url = "https://management.azure.com${path}?api-version=2022-09-15"
    $visited = [Collections.Generic.HashSet[string]]::new()
    $items = [Collections.Generic.List[object]]::new()
    while ($url) {
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com' -or $uri.Port -ne 443 -or
            $uri.UserInfo -or $uri.Fragment -or $uri.AbsolutePath -ine $path -or -not $visited.Add($url)) {
            throw 'Bot OAuth connection listing returned an unexpected or repeated pagination URL.'
        }
        $page = Invoke-PublishingRequest -Context $Context -Method GET -Url $url -Arm -Operation 'Read bot OAuth connections'
        if ($null -eq $page.value) { throw 'Bot OAuth connection listing returned no value array.' }
        foreach ($item in $page.value) { $items.Add($item) }
        $url = [string]$page.nextLink
    }
    return $items.ToArray()
}

function Test-BotOAuthConnection {
    param($Connection, [string]$ResourceId, [string]$ClientId, [string]$TenantId,
        [string]$Scopes, [string]$ProviderId)

    if ($Connection.id -ine $ResourceId -or $Connection.properties.clientId -ine $ClientId -or
        $Connection.properties.serviceProviderId -ine $ProviderId) { return $false }
    if ($Connection.properties.provisioningState -and
        $Connection.properties.provisioningState -ine 'Succeeded') { return $false }
    $parameters = @{}
    foreach ($parameter in @($Connection.properties.parameters)) {
        if ($parameter.key -isnot [string] -or
            $parameter.key -notin @('TenantId', 'TokenExchangeUrl', 'ClientId', 'ClientSecret', 'Scopes') -or
            $parameters.ContainsKey($parameter.key)) { return $false }
        $parameters[$parameter.key] = $parameter.value
    }
    if (-not $parameters.ContainsKey('TenantId') -or $parameters['TenantId'] -ine $TenantId -or
        -not [string]::IsNullOrEmpty([string]$parameters['TokenExchangeUrl'])) { return $false }
    if ($parameters.ContainsKey('ClientId') -and $parameters['ClientId'] -ine $ClientId) { return $false }
    # Azure lowercases provider keys and mirrors public fields plus a redacted secret.
    $scopeValues = @([string]$Connection.properties.scopes)
    if ($parameters.ContainsKey('Scopes')) { $scopeValues += [string]$parameters['Scopes'] }
    $expectedScopes = @($Scopes -split '\s+' | Where-Object { $_ } | Sort-Object -CaseSensitive)
    foreach ($scopeValue in $scopeValues) {
        $actualScopes = @($scopeValue -split '\s+' | Where-Object { $_ } | Sort-Object -CaseSensitive)
        if (($expectedScopes -join '|') -cne ($actualScopes -join '|')) { return $false }
    }
    return $true
}

function Get-PublishingState {
    param($Context)

    $account = Invoke-PublishingCli -Arguments @('account', 'show', '--subscription', $Context.SubscriptionId) `
        -Operation 'Read Azure account'
    if ($account.environmentName -cne 'AzureCloud' -or -not $account.tenantId) {
        throw 'These scripts require an authenticated Azure public-cloud account with a tenant ID.'
    }
    $agent = Invoke-PublishingRequest -Context $Context -Method GET -Url $Context.AgentUrl -Operation 'Read existing agent'
    $clientId = [Guid]::Empty
    if ($agent.name -cne $Context.AgentName -or
        -not [Guid]::TryParse([string]$agent.instance_identity.client_id, [ref]$clientId) -or $clientId -eq [Guid]::Empty) {
        throw 'The agent response does not contain the expected name and a nonempty instance_identity.client_id.'
    }
    $bot = Invoke-PublishingRequest -Context $Context -Method GET -Url $Context.BotUrl -Arm -Operation 'Read existing bot'
    if ($bot.id -ine $Context.BotServiceArmId -or
        $bot.properties.msaAppId -ine [string]$agent.instance_identity.client_id -or
        $bot.properties.msaAppTenantId -ine [string]$account.tenantId) {
        throw 'The existing bot ARM ID, application ID or tenant does not match the selected agent/account. No automatic bot identity replacement is permitted.'
    }
    $botEndpoint = $null
    $expected = "$($Context.ProjectEndpoint)/agents/$($Context.AgentName)/endpoint/protocols/"
    if (-not [Uri]::TryCreate([string]$bot.properties.endpoint, [UriKind]::Absolute, [ref]$botEndpoint) -or
        $botEndpoint.UserInfo -or $botEndpoint.Fragment -or
        ($botEndpoint.GetLeftPart([UriPartial]::Path) -cne "${expected}activityProtocol" -and
         $botEndpoint.GetLeftPart([UriPartial]::Path) -cne "${expected}activity") -or
        $botEndpoint.Query -notmatch '^\?api-version=(v1|2025-05-15-preview)$') {
        throw 'The bot messaging endpoint does not point to this agent Activity endpoint with a supported API version. Review it manually before continuing.'
    }

    $channels = [Collections.Generic.List[object]]::new()
    $nextUrl = $Context.ChannelsUrl
    $visited = [Collections.Generic.HashSet[string]]::new()
    while ($nextUrl) {
        if (-not $visited.Add($nextUrl)) { throw 'Bot channel listing returned a repeated pagination URL.' }
        $page = Invoke-PublishingRequest -Context $Context -Method GET -Url $nextUrl -Arm -Operation 'Read bot channels'
        if ($null -eq $page.value) { throw 'Bot channel listing did not return a value array.' }
        foreach ($channel in $page.value) { $channels.Add($channel) }
        $nextUrl = [string]$page.nextLink
        if ($nextUrl) {
            $nextUri = $null
            if (-not [Uri]::TryCreate($nextUrl, [UriKind]::Absolute, [ref]$nextUri) -or
                $nextUri.Scheme -ne 'https' -or $nextUri.Host -ne 'management.azure.com' -or
                $nextUri.Port -ne 443 -or $nextUri.UserInfo -or $nextUri.Fragment -or
                $nextUri.AbsolutePath -ine "$($Context.BotServiceArmId)/channels") {
                throw 'Bot channel listing returned an unexpected pagination URL.'
            }
        }
    }
    $teams = @($channels | Where-Object { $_.properties.channelName -ceq 'MsTeamsChannel' })
    if ($teams.Count -gt 1) { throw 'The bot returned more than one Microsoft Teams channel.' }
    $teamsChannel = if ($teams.Count) { $teams[0] } else { $null }
    $flag = $agent.agent_endpoint.protocol_configuration.activity.enable_m365_public_endpoint
    $schemes = @($agent.agent_endpoint.authorization_schemes)
    $tenantAuth = @($schemes | Where-Object { $_.type -ceq 'BotServiceTenant' }).Count -eq 1 -and
        @($schemes | Where-Object { $_.type -ceq 'BotServiceRbac' }).Count -eq 0
    return [pscustomobject]@{
        Agent = $agent
        Bot = $bot
        TeamsChannel = $teamsChannel
        PublicActivityEnabled = ($flag -is [bool] -and $flag)
        TenantAuthorization = $tenantAuth
        TeamsChannelEnabled = ($null -ne $teamsChannel -and $teamsChannel.properties.properties.isEnabled -eq $true)
    }
}

function Assert-PublishingReady {
    param($State)

    if (-not $State.PublicActivityEnabled -or -not $State.TenantAuthorization -or -not $State.TeamsChannelEnabled) {
        throw 'Publishing prerequisites are not ready: the public Activity exception, BotServiceTenant authorization and Teams channel must be enabled. Run post-requisite 2 first.'
    }
}

function Get-TenantEndpointUpdate {
    param($Agent)

    $protocols = $Agent.agent_endpoint.protocol_configuration
    if ($null -eq $protocols) { $protocols = [pscustomobject]@{} }
    if ($protocols -isnot [pscustomobject]) { throw 'Expected an object for protocol_configuration.' }
    $protocols = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $protocols -Depth 100)
    if ($null -eq $protocols.activity) {
        $protocols | Add-Member -NotePropertyName activity -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($protocols.activity -isnot [pscustomobject]) { throw 'Expected an object for the Activity configuration.' }
    $protocols.activity | Add-Member -NotePropertyName enable_m365_public_endpoint -NotePropertyValue $true -Force
    $schemes = @($Agent.agent_endpoint.authorization_schemes | Where-Object {
        $null -ne $_ -and $_.type -cne 'BotServiceRbac' -and $_.type -cne 'BotServiceTenant'
    })
    $tenant = @($Agent.agent_endpoint.authorization_schemes | Where-Object { $_.type -ceq 'BotServiceTenant' })
    if ($tenant.Count -gt 1) { throw 'Duplicate BotServiceTenant authorization entries require manual review.' }
    $schemes += if ($tenant.Count) { $tenant[0] } else { [pscustomobject]@{ type = 'BotServiceTenant' } }
    return @{ agent_endpoint = @{ protocol_configuration = $protocols; authorization_schemes = $schemes } }
}

function ConvertTo-PublishingIconBase64 {
    param(
        [string]$Path,
        [string]$BaseDirectory,
        [string]$FieldName,
        [int]$Size
    )

    $iconPath = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $BaseDirectory $Path }
    $iconPath = [IO.Path]::GetFullPath($iconPath)
    try {
        $bytes = [IO.File]::ReadAllBytes($iconPath)
    } catch [IO.IOException] {
        throw "Cannot read $FieldName at '$iconPath'. Supply a readable PNG file."
    } catch [UnauthorizedAccessException] {
        throw "Access denied reading $FieldName at '$iconPath'."
    }
    if ($bytes.Length -lt 8 -or [BitConverter]::ToString($bytes, 0, 8) -cne '89-50-4E-47-0D-0A-1A-0A') {
        throw "$FieldName must be a valid PNG image."
    }
    Add-Type -AssemblyName System.Drawing
    $stream = [IO.MemoryStream]::new($bytes, $false)
    $image = $null
    try {
        try {
            $image = [Drawing.Image]::FromStream($stream, $false, $true)
        } catch [ArgumentException] {
            throw "$FieldName must be a valid, decodable PNG image."
        } catch [Runtime.InteropServices.ExternalException] {
            throw "$FieldName must be a valid, decodable PNG image."
        } catch [OutOfMemoryException] {
            throw "$FieldName could not be decoded as a PNG image (invalid image or insufficient memory)."
        }
        if ($image.RawFormat.Guid -ne [Drawing.Imaging.ImageFormat]::Png.Guid) {
            throw "$FieldName must be a valid PNG image."
        }
        if ($image.Width -ne $Size -or $image.Height -ne $Size) {
            throw "$FieldName must be exactly ${Size}x${Size} pixels; received $($image.Width)x$($image.Height)."
        }
        return [Convert]::ToBase64String($bytes)
    } finally {
        if ($null -ne $image) { $image.Dispose() }
        $stream.Dispose()
    }
}

function Read-PublishingMetadata {
    param([string]$Path)

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    try {
        $metadata = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($resolvedPath)) -ErrorAction Stop
    } catch {
        throw 'Unable to read publishing metadata. Supply a readable JSON file based on publish-request.example.json.'
    }
    if ($metadata -isnot [pscustomobject]) { throw 'Publishing metadata must be a JSON object.' }
    $required = @('agentDisplayName', 'appVersion', 'shortDescription', 'fullDescription',
        'developerName', 'developerWebsiteUrl', 'privacyUrl', 'termsOfUseUrl')
    $iconFields = @('colorIconPath', 'outlineIconPath')
    $optional = @('agentFullName', 'accentColor')
    foreach ($property in $metadata.PSObject.Properties) {
        if ($required -cnotcontains $property.Name -and $iconFields -cnotcontains $property.Name -and $optional -cnotcontains $property.Name) {
            throw "Unsupported package metadata field '$($property.Name)'. App identities come from the source ZIP and cannot be changed by metadata."
        }
    }
    foreach ($name in $required) {
        $value = $metadata.$name
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value -match '<[^>]+>') {
            throw "Publishing metadata '$name' must be a nonempty string with no template placeholders."
        }
    }
    if ($metadata.appVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw 'appVersion must use major.minor.patch format, for example 1.0.0. Increment it for each new prepared package.'
    }
    if ($null -ne $metadata.PSObject.Properties['agentFullName'] -and
        ($metadata.agentFullName -isnot [string] -or [string]::IsNullOrWhiteSpace($metadata.agentFullName) -or
         $metadata.agentFullName -match '<[^>]+>')) {
        throw 'agentFullName must be a nonempty string without template placeholders, or be omitted to use agentDisplayName.'
    }
    $limits = @{ agentDisplayName = 30; agentFullName = 100; shortDescription = 80; fullDescription = 4000; developerName = 32 }
    foreach ($name in $limits.Keys) {
        if ($metadata.$name.Length -gt $limits[$name]) {
            throw "Publishing metadata '$name' must not exceed $($limits[$name]) characters."
        }
    }
    if ($null -ne $metadata.PSObject.Properties['accentColor'] -and
        ($metadata.accentColor -isnot [string] -or $metadata.accentColor -cnotmatch '^#[0-9a-fA-F]{6}$')) {
        throw 'accentColor must be a #RRGGBB color, or be omitted to preserve the source manifest color.'
    }
    foreach ($name in @('developerWebsiteUrl', 'privacyUrl', 'termsOfUseUrl')) {
        $uri = $null
        if (-not [Uri]::TryCreate($metadata.$name, [UriKind]::Absolute, [ref]$uri) -or
            $uri.Scheme -ne 'https' -or $uri.UserInfo -or $metadata.$name -match '\s') {
            throw "Publishing metadata '$name' must be an HTTPS URL without embedded credentials."
        }
    }
    foreach ($name in $iconFields) {
        if ($null -ne $metadata.PSObject.Properties[$name] -and $metadata.$name -isnot [string]) {
            throw "Publishing metadata '$name' must be a string path or an empty string."
        }
    }
    $hasColor = -not [string]::IsNullOrWhiteSpace($metadata.colorIconPath)
    $hasOutline = -not [string]::IsNullOrWhiteSpace($metadata.outlineIconPath)
    if ($hasColor -ne $hasOutline) {
        throw 'Provide both colorIconPath and outlineIconPath, or leave both empty/omitted to retain the source icons.'
    }
    if ($hasColor) {
        $directory = [IO.Path]::GetDirectoryName($resolvedPath)
        $color = ConvertTo-PublishingIconBase64 -Path $metadata.colorIconPath -BaseDirectory $directory -FieldName colorIconPath -Size 192
        $outline = ConvertTo-PublishingIconBase64 -Path $metadata.outlineIconPath -BaseDirectory $directory -FieldName outlineIconPath -Size 32
        $metadata | Add-Member -NotePropertyName colorIconBase64 -NotePropertyValue $color
        $metadata | Add-Member -NotePropertyName outlineIconBase64 -NotePropertyValue $outline
    }
    foreach ($name in $iconFields) { $metadata.PSObject.Properties.Remove($name) }
    return $metadata
}

function ConvertTo-M365AppVersion {
    param([string]$Value, [string]$Description)

    $version = $null
    if ($Value -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' -or
        -not [Version]::TryParse($Value, [ref]$version)) {
        throw "$Description must contain a valid numeric major.minor.patch version."
    }
    return $version
}

function Assert-NewM365AppVersion {
    param([string]$AppId, [string]$SourceVersion, [string]$AppVersion, [string]$HistoryDirectory)

    $requested = ConvertTo-M365AppVersion -Value $AppVersion -Description 'appVersion'
    $sourceVersionNumber = ConvertTo-M365AppVersion -Value $SourceVersion -Description 'The source manifest'
    if ($requested -lt $sourceVersionNumber) {
        throw "appVersion '$AppVersion' must not be lower than the source version '$SourceVersion' for app '$AppId'. Existing ZIPs are unchanged."
    }
    $highest = $null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($file in Get-ChildItem -LiteralPath $HistoryDirectory -Filter 'appPackage.*.zip' -File -ErrorAction Stop) {
        $zip = $null
        try {
            $zip = [IO.Compression.ZipFile]::OpenRead($file.FullName)
            $entry = $zip.GetEntry('manifest.json')
            if ($null -eq $entry -or @($zip.Entries | Where-Object { $_.FullName -ieq 'manifest.json' }).Count -ne 1) {
                throw 'Expected exactly one root manifest.json.'
            }
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $previous = ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop } finally { $reader.Dispose() }
            $previousId = [Guid]::Empty
            if ($previous -isnot [pscustomobject] -or
                -not [Guid]::TryParse([string]$previous.id, [ref]$previousId) -or $previousId -eq [Guid]::Empty) {
                throw 'The manifest must contain a nonempty application id.'
            }
            if ($previous.id -ieq $AppId) {
                $version = ConvertTo-M365AppVersion -Value $previous.version -Description "The manifest in '$($file.Name)'"
                if ($null -eq $highest -or $version -gt $highest) { $highest = $version }
            }
        } catch {
            throw "Cannot read package history '$($file.FullName)': $($_.Exception.Message)"
        } finally {
            if ($null -ne $zip) { $zip.Dispose() }
        }
    }
    if ($null -ne $highest -and $requested -le $highest) {
        throw "appVersion '$AppVersion' must be higher than $highest for app '$AppId'. Update appVersion in the publishing JSON before generating another ZIP. Existing ZIPs are unchanged."
    }
}

function New-CustomizedM365Package {
    param([string]$Path, $Metadata, [string]$BotAppId, [string]$HistoryDirectory)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $source = [IO.Compression.ZipFile]::OpenRead($Path)
    $buffer = [IO.MemoryStream]::new()
    try {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $source.Entries) {
            if ($entry.FullName -match '(^/|\\|:|(^|/)\.\.?(/|$))' -or -not $names.Add($entry.FullName)) {
                throw "Source ZIP contains an unsafe or duplicate entry '$($entry.FullName)'."
            }
        }
        $manifestEntry = $source.GetEntry('manifest.json')
        if ($null -eq $manifestEntry) { throw 'Source ZIP must contain manifest.json at its root.' }
        $reader = [IO.StreamReader]::new($manifestEntry.Open())
        try {
            $manifest = ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop
        } finally { $reader.Dispose() }
        $appId = [Guid]::Empty
        if ($manifest -isnot [pscustomobject] -or
            -not [Guid]::TryParse([string]$manifest.id, [ref]$appId) -or $appId -eq [Guid]::Empty) {
            throw 'Source manifest must contain a nonempty application id.'
        }
        foreach ($field in @('name', 'description', 'developer', 'icons')) {
            if ($manifest.$field -isnot [pscustomobject]) { throw "Source manifest must contain a '$field' object." }
        }
        $botGuid = [Guid]::Empty
        if (@($manifest.bots).Count -ne 1 -or
            -not [Guid]::TryParse([string]$manifest.bots[0].botId, [ref]$botGuid) -or $botGuid -eq [Guid]::Empty -or
            $manifest.webApplicationInfo.id -ine [string]$botGuid -or
            ($BotAppId -and $manifest.bots[0].botId -ine $BotAppId)) {
            throw 'Source ZIP must contain one valid bot identity matching webApplicationInfo. Regenerate the package with azd for the intended deployment.'
        }
        $colorName = $manifest.icons.color
        $outlineName = $manifest.icons.outline
        if ($colorName -isnot [string] -or $outlineName -isnot [string] -or
            [string]::IsNullOrWhiteSpace($colorName) -or [string]::IsNullOrWhiteSpace($outlineName) -or
            $colorName -ieq $outlineName -or $colorName -ieq 'manifest.json' -or $outlineName -ieq 'manifest.json' -or
            $null -eq $source.GetEntry($colorName) -or $null -eq $source.GetEntry($outlineName) -or
            $colorName.EndsWith('/') -or $outlineName.EndsWith('/')) {
            throw 'Source manifest must reference two distinct icon files present in the ZIP.'
        }
        $sourceVersion = $manifest.version
        if ($HistoryDirectory) {
            Assert-NewM365AppVersion -AppId $manifest.id -SourceVersion $sourceVersion `
                -AppVersion $Metadata.appVersion -HistoryDirectory $HistoryDirectory
        }

        $fullName = if ($Metadata.agentFullName) { $Metadata.agentFullName } else { $Metadata.agentDisplayName }
        $manifest | Add-Member -NotePropertyName version -NotePropertyValue $Metadata.appVersion -Force
        $manifest.name | Add-Member -NotePropertyName short -NotePropertyValue $Metadata.agentDisplayName -Force
        $manifest.name | Add-Member -NotePropertyName full -NotePropertyValue $fullName -Force
        $manifest.description | Add-Member -NotePropertyName short -NotePropertyValue $Metadata.shortDescription -Force
        $manifest.description | Add-Member -NotePropertyName full -NotePropertyValue $Metadata.fullDescription -Force
        $developerFields = [ordered]@{ name = 'developerName'; websiteUrl = 'developerWebsiteUrl'; privacyUrl = 'privacyUrl'; termsOfUseUrl = 'termsOfUseUrl' }
        foreach ($field in $developerFields.Keys) {
            $manifest.developer | Add-Member -NotePropertyName $field -NotePropertyValue $Metadata.($developerFields[$field]) -Force
        }
        if ($Metadata.accentColor) {
            $manifest | Add-Member -NotePropertyName accentColor -NotePropertyValue $Metadata.accentColor -Force
        }
        $domains = @()
        if ($null -ne $manifest.PSObject.Properties['validDomains']) {
            if ($manifest.validDomains -isnot [array]) {
                throw 'Source manifest validDomains must be an array of nonempty domain strings.'
            }
            $domains = @($manifest.validDomains)
            foreach ($domain in $domains) {
                if ($domain -isnot [string] -or [string]::IsNullOrWhiteSpace($domain)) {
                    throw 'Source manifest validDomains must be an array of nonempty domain strings.'
                }
            }
        }
        if ($domains -notcontains 'token.botframework.com') { $domains += 'token.botframework.com' }
        $manifest | Add-Member -NotePropertyName validDomains -NotePropertyValue $domains -Force
        $replacementBytes = @{
            'manifest.json' = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $manifest -Depth 100))
        }
        if ($Metadata.colorIconBase64) {
            $replacementBytes[$colorName] = [Convert]::FromBase64String($Metadata.colorIconBase64)
            $replacementBytes[$outlineName] = [Convert]::FromBase64String($Metadata.outlineIconBase64)
        }
        $destination = [IO.Compression.ZipArchive]::new($buffer, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($entry in $source.Entries) {
                $copy = $destination.CreateEntry($entry.FullName, [IO.Compression.CompressionLevel]::Optimal)
                $copy.LastWriteTime = $entry.LastWriteTime
                $outputStream = $copy.Open()
                try {
                    if ($replacementBytes.ContainsKey($entry.FullName)) {
                        $bytes = $replacementBytes[$entry.FullName]
                        $outputStream.Write($bytes, 0, $bytes.Length)
                    } else {
                        $inputStream = $entry.Open()
                        try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose() }
                    }
                } finally { $outputStream.Dispose() }
            }
        } finally { $destination.Dispose() }
        return [pscustomobject]@{ Manifest = $manifest; SourceVersion = $sourceVersion; Bytes = $buffer.ToArray() }
    } finally {
        $source.Dispose()
        $buffer.Dispose()
    }
}

function Test-M365ArchiveContent {
    param([string]$Path, [byte[]]$ExpectedBytes)

    # Object property order/whitespace and ZIP timestamps are not manifest or asset changes.
    $normalizeJson = {
        param($Value)
        if ($Value -is [pscustomobject]) {
            $ordered = [ordered]@{}
            foreach ($key in @($Value.PSObject.Properties.Name | Sort-Object -CaseSensitive)) {
                $ordered[$key] = & $normalizeJson $Value.$key
            }
            return $ordered
        }
        if ($Value -is [array]) {
            $items = @(foreach ($item in $Value) { ,(& $normalizeJson $item) })
            return ,$items
        }
        return $Value
    }
    $memory = [IO.MemoryStream]::new($ExpectedBytes, $false)
    $expected = $null
    $actual = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $expected = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Read)
        $actual = [IO.Compression.ZipFile]::OpenRead($Path)
        if ($actual.Entries.Count -ne $expected.Entries.Count) { return $false }
        foreach ($entry in $expected.Entries) {
            $matches = @($actual.Entries | Where-Object { $_.FullName -ceq $entry.FullName })
            if ($matches.Count -ne 1) { return $false }
            $left = $entry.Open()
            $right = $matches[0].Open()
            try {
                if ($entry.FullName -ceq 'manifest.json') {
                    $leftReader = [IO.StreamReader]::new($left)
                    $rightReader = [IO.StreamReader]::new($right)
                    try {
                        $leftJson = & $normalizeJson (ConvertFrom-Json -InputObject $leftReader.ReadToEnd())
                        $rightJson = & $normalizeJson (ConvertFrom-Json -InputObject $rightReader.ReadToEnd())
                        if ((ConvertTo-Json -InputObject $leftJson -Depth 100 -Compress) -cne
                            (ConvertTo-Json -InputObject $rightJson -Depth 100 -Compress)) { return $false }
                    } finally { $leftReader.Dispose(); $rightReader.Dispose() }
                } elseif ([BitConverter]::ToString($sha.ComputeHash($left)) -cne
                    [BitConverter]::ToString($sha.ComputeHash($right))) {
                    return $false
                }
            } finally { $left.Dispose(); $right.Dispose() }
        }
        return $true
    } finally {
        if ($actual) { $actual.Dispose() }
        if ($expected) { $expected.Dispose() }
        $memory.Dispose()
        $sha.Dispose()
    }
}
