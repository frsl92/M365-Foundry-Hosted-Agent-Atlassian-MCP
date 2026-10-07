$prerequisiteRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $prerequisiteRoot 'Common.ps1')
$registrationScript = Join-Path $prerequisiteRoot '4.Register-Entra-Applications\Register-EntraApplications.ps1'

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live Azure CLI call.'
}
$registrationAzCommand = Get-Command az

Describe 'Entra application registration prerequisite' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $envPath = Join-Path $TestDrive 'registration.env'
        if (Test-Path -LiteralPath $envPath) { Remove-Item -LiteralPath $envPath }
        $subscriptionId = '11111111-1111-1111-1111-111111111111'
        $tenantId = '22222222-2222-2222-2222-222222222222'
        $apiId = '33333333-3333-3333-3333-333333333333'
        $apiObjectId = '44444444-4444-4444-4444-444444444444'
        $authId = '55555555-5555-5555-5555-555555555555'
        $authObjectId = '66666666-6666-6666-6666-666666666666'
        $apiPrincipalId = '88888888-8888-8888-8888-888888888888'
        $authPrincipalId = '99999999-9999-9999-9999-999999999999'
        $redirectUri = 'https://token.botframework.com/.auth/web/redirect'
        $state = @{
            Account = @{ id = $subscriptionId; tenantId = $tenantId; environmentName = 'AzureCloud' }
            DefaultAccount = @{ id = $subscriptionId; tenantId = $tenantId; environmentName = 'AzureCloud' }
            Apps = @{}
            Principals = @{}
            BadPrincipalList = ''
            BadPrincipalCreate = ''
            BadPrincipalShowIdentity = $false
            PrincipalDelayReads = 0
            PrincipalFailClientId = ''
            Calls = [System.Collections.Generic.List[object]]::new()
            Bodies = [System.Collections.Generic.List[object]]::new()
            Paths = [System.Collections.Generic.List[string]]::new()
            ExtraMatches = @()
            Fail = ''
            UsageError = ''
            BadList = ''
            BadShowIdentity = $false
            CliMissing = $false
            DelayReads = 0
            IgnorePatch = $false
        }
        Update-PrerequisiteEnv -Path $envPath -Values @{
            AZURE_APIM_NAME = 'test-apim'
            AZURE_SUBSCRIPTION_ID = $subscriptionId
            AZURE_APIM_IDENTITY_TENANT_ID = $tenantId
            ATLASSIAN_MCP_CLIENT_SECRET = 'preserve-existing-secret'
        }
        Mock Get-Command {
            if (-not $state.CliMissing) { $registrationAzCommand }
        } -ParameterFilter { $Name -eq 'az' }
        Mock Start-Sleep {} -ParameterFilter { $Seconds -gt 0 }
        Mock az {
            $state.Calls.Add($Arguments)
            $global:LASTEXITCODE = 0
            $operation = if ($Arguments[0] -eq 'account') { 'account' } elseif ($Arguments[0] -eq 'rest') {
                $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
            } elseif ($Arguments[1] -eq 'sp') { "sp-$($Arguments[2])" } else { $Arguments[2] }
            if ($Arguments[0] -eq 'ad' -and $Arguments -contains '--subscription') {
                $global:LASTEXITCODE = 2
                return 'ERROR: unrecognized arguments: --subscription'
            }
            if ($state.UsageError -eq $operation) {
                $global:LASTEXITCODE = 2
                return 'ERROR: unrecognized arguments: --unsupported preserve-existing-secret'
            }
            if ($state.Fail -eq $operation) {
                $global:LASTEXITCODE = 1
                return 'ERROR: (Authorization_RequestDenied) preserve-existing-secret'
            }
            switch ($operation) {
                'sp-list' {
                    if ($state.BadPrincipalList) { return $state.BadPrincipalList }
                    $filter = $Arguments[[Array]::IndexOf($Arguments, '--filter') + 1]
                    if ($filter -notmatch "^appId eq '([0-9a-f-]{36})'$" -or $Arguments -notcontains '--all') {
                        throw 'Service principal discovery must filter by client ID and include all matches.'
                    }
                    $clientId = $Matches[1]
                    $principals = @($state.Principals.Values | Where-Object { $_.appId -eq $clientId })
                    return (ConvertTo-Json -InputObject $principals -Depth 10)
                }
                'sp-create' {
                    $clientId = $Arguments[[Array]::IndexOf($Arguments, '--id') + 1]
                    if ($clientId -notin @($apiId, $authId)) { throw 'Service principal creation requires an application/client ID.' }
                    if ($state.Principals.ContainsKey($clientId)) { throw 'Duplicate service principal create attempted.' }
                    if ($state.PrincipalFailClientId -eq $clientId) {
                        $global:LASTEXITCODE = 1
                        return '{"error":{"code":"Authorization_RequestDenied"}}'
                    }
                    if ($state.BadPrincipalCreate) { return $state.BadPrincipalCreate }
                    $principal = @{
                        id = $(if ($clientId -eq $apiId) { $apiPrincipalId } else { $authPrincipalId })
                        appId = $clientId
                        appOwnerOrganizationId = $tenantId
                        servicePrincipalType = 'Application'
                        accountEnabled = $true
                    }
                    $state.Principals[$clientId] = $principal
                    return ($principal | ConvertTo-Json)
                }
                'sp-show' {
                    if ($state.PrincipalDelayReads -gt 0) {
                        $state.PrincipalDelayReads--
                        $global:LASTEXITCODE = 1
                        return '{"error":{"code":"Request_ResourceNotFound"}}'
                    }
                    $objectId = $Arguments[[Array]::IndexOf($Arguments, '--id') + 1]
                    $principal = $state.Principals.Values | Where-Object { $_.id -eq $objectId } | Select-Object -First 1
                    if (-not $principal) { throw 'Service principal verification must use the object ID.' }
                    $saved = Read-PrerequisiteEnv -Path $envPath
                    $key = if ($principal.appId -eq $apiId) { 'APIM_API_SERVICE_PRINCIPAL_ID' } else { 'AUTH_SERVICE_PRINCIPAL_ID' }
                    if ($saved[$key] -ne $objectId) { throw 'Service principal recovery ID must be saved before verification.' }
                    if ($state.BadPrincipalShowIdentity) {
                        $principal = $principal.Clone()
                        $principal.id = '77777777-7777-7777-7777-777777777777'
                    }
                    return ($principal | ConvertTo-Json)
                }
                'account' {
                    if ($Arguments -contains '--subscription') { return ($state.Account | ConvertTo-Json) }
                    return ($state.DefaultAccount | ConvertTo-Json)
                }
                'list' {
                    if ($state.BadList) { return $state.BadList }
                    $name = $Arguments[[Array]::IndexOf($Arguments, '--display-name') + 1]
                    $apps = @($state.Apps.Values | Where-Object { $_.displayName -ieq $name })
                    $apps += $state.ExtraMatches
                    return (ConvertTo-Json -InputObject $apps -Depth 10)
                }
                'show' {
                    if ($state.DelayReads -gt 0) {
                        $state.DelayReads--
                        $global:LASTEXITCODE = 1
                        return '{"error":{"code":"Request_ResourceNotFound"}}'
                    }
                    $id = $Arguments[[Array]::IndexOf($Arguments, '--id') + 1]
                    $app = $state.Apps.Values | Where-Object { $_.id -eq $id -or $_.appId -eq $id } | Select-Object -First 1
                    if (-not $app) {
                        $global:LASTEXITCODE = 1
                        return '{"error":{"code":"Request_ResourceNotFound"}}'
                    }
                    if ($state.BadShowIdentity) {
                        $app = $app | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                        $app.appId = '77777777-7777-7777-7777-777777777777'
                    }
                    return ($app | ConvertTo-Json -Depth 10)
                }
                { $_ -in @('post', 'patch') } {
                    $path = $Arguments[[Array]::IndexOf($Arguments, '--body') + 1].Trim('"').Substring(1)
                    $body = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                    $state.Paths.Add($path)
                    $state.Bodies.Add($body)
                    if ($operation -eq 'patch') {
                        $saved = Read-PrerequisiteEnv -Path $envPath
                        if ($saved['APIM_API_CLIENT_ID'] -ne $apiId -or $saved['APIM_API_OBJECT_ID'] -ne $apiObjectId) {
                            throw 'API recovery IDs were not saved before PATCH.'
                        }
                        $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1]
                        if ($url -ne "https://graph.microsoft.com/v1.0/applications/$apiObjectId") {
                            throw 'PATCH must use the object ID, not the client ID.'
                        }
                        if (-not $state.IgnorePatch) {
                            $state.Apps.api | Add-Member -NotePropertyName identifierUris -NotePropertyValue $body.identifierUris -Force
                        }
                        return
                    }
                    $kind = if ($body.api) { 'api' } else { 'auth' }
                    if ($kind -eq 'auth') {
                        $saved = Read-PrerequisiteEnv -Path $envPath
                        if ($saved['APIM_SCOPE'] -ne "api://$apiId/Mcp.Invoke") { throw 'API must be verified and saved before client creation.' }
                        if ($state.Fail -eq 'auth-create') {
                            $global:LASTEXITCODE = 1
                            return '{"error":{"code":"Authorization_RequestDenied"}}'
                        }
                    }
                    $body | Add-Member -NotePropertyName appId -NotePropertyValue $(if ($kind -eq 'api') { $apiId } else { $authId })
                    $body | Add-Member -NotePropertyName id -NotePropertyValue $(if ($kind -eq 'api') { $apiObjectId } else { $authObjectId })
                    $state.Apps[$kind] = $body
                    return ($body | ConvertTo-Json -Depth 10)
                }
                default { throw "Unexpected CLI operation '$operation'." }
            }
        }
    }

    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
    }

    It 'creates exactly the two specified single-tenant registrations and saves verified configuration' {
        Push-Location $TestDrive
        try { $null = & $registrationScript -EnvFile '.\registration.env' 6>&1 } finally { Pop-Location }
        $state.Apps.Count | Should Be 2
        $api = $state.Apps.api
        $api.displayName | Should BeExactly 'test-apim-gateway-api'
        $api.signInAudience | Should BeExactly 'AzureADMyOrg'
        $api.api.requestedAccessTokenVersion | Should Be 2
        $api.identifierUris.Count | Should Be 1
        $api.identifierUris[0] | Should BeExactly "api://$apiId"
        $scope = $api.api.oauth2PermissionScopes[0]
        $api.api.oauth2PermissionScopes.Count | Should Be 1
        $scope.value | Should BeExactly 'Mcp.Invoke'
        $scope.type | Should BeExactly 'Admin'
        $scope.isEnabled | Should Be $true
        [Guid]$scope.id | Should Not Be ([Guid]::Empty)
        $scope.adminConsentDisplayName | Should BeExactly 'Use the Atlassian MCP gateway as the signed-in user'
        $api.web | Should BeNullOrEmpty
        $auth = $state.Apps.auth
        $auth.displayName | Should BeExactly 'test-apim-user-sign-in'
        $auth.signInAudience | Should BeExactly 'AzureADMyOrg'
        $auth.isFallbackPublicClient | Should Be $false
        $auth.web.redirectUris.Count | Should Be 1
        $auth.web.redirectUris[0] | Should BeExactly $redirectUri
        $auth.web.implicitGrantSettings.enableIdTokenIssuance | Should Be $false
        $auth.web.implicitGrantSettings.enableAccessTokenIssuance | Should Be $false
        $auth.requiredResourceAccess.Count | Should Be 1
        $auth.requiredResourceAccess[0].resourceAppId | Should BeExactly $apiId
        $auth.requiredResourceAccess[0].resourceAccess.Count | Should Be 1
        $auth.requiredResourceAccess[0].resourceAccess[0].id | Should BeExactly $scope.id
        $auth.requiredResourceAccess[0].resourceAccess[0].type | Should BeExactly 'Scope'
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['AZURE_TENANT_ID'] | Should BeExactly $tenantId
        $saved['APIM_API_CLIENT_ID'] | Should BeExactly $apiId
        $saved['APIM_API_OBJECT_ID'] | Should BeExactly $apiObjectId
        $saved['AUTH_CLIENT_ID'] | Should BeExactly $authId
        $saved['AUTH_OBJECT_ID'] | Should BeExactly $authObjectId
        $state.Principals.Count | Should Be 2
        $saved['APIM_API_SERVICE_PRINCIPAL_ID'] | Should BeExactly $apiPrincipalId
        $saved['AUTH_SERVICE_PRINCIPAL_ID'] | Should BeExactly $authPrincipalId
        $saved['APIM_API_SCOPE_ID'] | Should BeExactly $scope.id
        $saved['APIM_API_IDENTIFIER_URI'] | Should BeExactly "api://$apiId"
        $saved['APIM_SCOPE'] | Should BeExactly "api://$apiId/Mcp.Invoke"
        $saved['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'true'
        $saved['ATLASSIAN_MCP_CLIENT_SECRET'] | Should BeExactly 'preserve-existing-secret'
        foreach ($call in $state.Calls) {
            if ($call[0] -eq 'ad') {
                $call -contains '--subscription' | Should Be $false
            } elseif ($call[0] -eq 'rest' -or $call -contains '--subscription') {
                $call -contains '--subscription' | Should Be $true
                $call -contains $subscriptionId | Should Be $true
            }
            ($call -join ' ') | Should Not Match 'credential|admin-consent|permission grant|oauth2PermissionGrants|addPassword|create-for-rbac|role assignment'
        }
        Assert-MockCalled az -Times 1 -Exactly -Scope It -ParameterFilter { $Arguments[0] -eq 'account' -and $Arguments -contains '--subscription' }
        Assert-MockCalled az -Times 1 -Exactly -Scope It -ParameterFilter { $Arguments[0] -eq 'account' -and $Arguments -notcontains '--subscription' }
        foreach ($body in $state.Bodies) {
            ($body | ConvertTo-Json -Depth 10) | Should Not Match 'passwordCredentials|keyCredentials|preAuthorizedApplications|access_as_user'
        }
        foreach ($path in $state.Paths) { Test-Path -LiteralPath $path | Should Be $false }
    }

    It 'adds a blank manual secret input and prints portal steps using the actual apps and configuration path' {
        $output = (& $registrationScript -EnvFile $envPath -ApimApiAppName 'Custom API' `
            -AuthAppName 'Custom Sign-in' -AuthRedirectUri 'https://example.test/oauth' 6>&1 | Out-String)
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved.Contains('AUTH_CLIENT_SECRET') | Should Be $true
        $saved['AUTH_CLIENT_SECRET'] | Should BeExactly ''
        $content = [System.IO.File]::ReadAllText($envPath)
        $content.IndexOf('# Inputs first used by 4.') | Should BeLessThan $content.IndexOf('AUTH_CLIENT_SECRET=')
        $content.IndexOf('AUTH_CLIENT_SECRET=') | Should BeLessThan $content.IndexOf('# Script-generated values')
        foreach ($expected in @(
            $tenantId, 'Custom API', $apiId, "api://$apiId", 'Expose an API', 'Mcp.Invoke', 'Admins only',
            'Custom Sign-in', $authId, 'https://example.test/oauth', 'Delegated',
            'Grant admin consent', 'Granted for <tenant>', 'Certificates & secrets', 'New client secret',
            'Value immediately, NOT the Secret ID', 'expiration', $envPath,
            'AUTH_CLIENT_SECRET="<paste the client secret Value here>"',
            'Do not create a client secret for this API app', 'Both enterprise applications now exist',
            'does not verify consent or the secret'
        )) {
            $output.Contains($expected) | Should Be $true
        }
    }

    It 'preserves a manually supplied secret on reruns without printing it or sending it to Azure' {
        $secret = 'test-auth-secret$with#symbols\and"quotes'
        Update-PrerequisiteEnv -Path $envPath -Values @{ AUTH_CLIENT_SECRET = $secret }
        foreach ($run in @(1, 2)) {
            $output = (& $registrationScript -EnvFile $envPath 6>&1 | Out-String)
            (Read-PrerequisiteEnv -Path $envPath)['AUTH_CLIENT_SECRET'] | Should BeExactly $secret
            $output | Should Not Match 'test-auth-secret'
        }
        ($state.Calls | ConvertTo-Json -Depth 10) | Should Not Match 'test-auth-secret'
        ($state.Bodies | ConvertTo-Json -Depth 10) | Should Not Match 'test-auth-secret|passwordCredentials|addPassword'
    }

    It 'reuses saved registrations and scope IDs without any write on subsequent runs' {
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $scopeId = $state.Apps.api.api.oauth2PermissionScopes[0].id
        Update-PrerequisiteEnv -Path $envPath -Values @{
            APIM_API_SERVICE_PRINCIPAL_ID = ''; AUTH_SERVICE_PRINCIPAL_ID = ''
        }
        $state.Bodies.Clear()
        $state.Calls.Clear()
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Bodies.Count | Should Be 0
        @($state.Calls | Where-Object { $_[1] -eq 'sp' -and $_[2] -eq 'create' }).Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['APIM_API_SCOPE_ID'] | Should BeExactly $scopeId
        (Read-PrerequisiteEnv -Path $envPath)['APIM_API_SERVICE_PRINCIPAL_ID'] | Should BeExactly $apiPrincipalId
        (Read-PrerequisiteEnv -Path $envPath)['AUTH_SERVICE_PRINCIPAL_ID'] | Should BeExactly $authPrincipalId
    }

    It 'repairs registrations created by the older script without replacing apps, scope, or secret' {
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $scopeId = $state.Apps.api.api.oauth2PermissionScopes[0].id
        $state.Principals.Clear()
        $state.Bodies.Clear()
        $state.Calls.Clear()
        Update-PrerequisiteEnv -Path $envPath -Values @{
            APIM_API_SERVICE_PRINCIPAL_ID = ''; AUTH_SERVICE_PRINCIPAL_ID = ''
            AUTH_CLIENT_SECRET = 'existing-auth-secret'
        }
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Bodies.Count | Should Be 0
        $state.Principals.Count | Should Be 2
        $state.Apps.api.api.oauth2PermissionScopes[0].id | Should BeExactly $scopeId
        (Read-PrerequisiteEnv -Path $envPath)['AUTH_CLIENT_SECRET'] | Should BeExactly 'existing-auth-secret'
        @($state.Calls | Where-Object { $_[1] -eq 'sp' -and $_[2] -eq 'create' }).Count | Should Be 2
    }

    It 'does not create principals after failed or malformed service principal lookups' {
        $state.Fail = 'sp-list'
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Authorization_RequestDenied'
        $state.Fail = ''
        foreach ($response in @('null', 'invalid JSON', '{}', '[{}]', '[{},{}]',
            '{"id":"88888888-8888-8888-8888-888888888888","appId":"33333333-3333-3333-3333-333333333333"}')) {
            $state.BadPrincipalList = $response
            $failure = ''
            try { $null = & $registrationScript -EnvFile $envPath 6>&1 }
            catch { $failure = $_.Exception.Message }
            if (-not $failure) { throw "Expected lookup rejection for fixture: $response" }
        }
        @($state.Calls | Where-Object { $_[1] -eq 'sp' -and $_[2] -eq 'create' }).Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'rejects disabled, foreign-tenant, wrong-type, or mismatched existing principals without modifying them' {
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Calls.Clear()
        foreach ($case in @(
            @{ Property = 'accountEnabled'; Value = $false },
            @{ Property = 'appOwnerOrganizationId'; Value = '77777777-7777-7777-7777-777777777777' },
            @{ Property = 'servicePrincipalType'; Value = 'ManagedIdentity' },
            @{ Property = 'appId'; Value = $authId }
        )) {
            $principal = $state.Principals[$apiId].Clone()
            $principal[$case.Property] = $case.Value
            $state.BadPrincipalList = ConvertTo-Json -InputObject @($principal)
            $failure = ''
            try { $null = & $registrationScript -EnvFile $envPath 6>&1 }
            catch { $failure = $_.Exception.Message }
            if (-not $failure) { throw "Expected principal rejection for fixture property: $($case.Property)" }
        }
        @($state.Calls | Where-Object { $_[1] -eq 'sp' -and $_[2] -in @('create', 'update') }).Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'resumes a partial service principal failure without duplicating the API principal' {
        $state.PrincipalFailClientId = $authId
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'az ad sp create'
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['APIM_API_SERVICE_PRINCIPAL_ID'] | Should BeExactly $apiPrincipalId
        $saved['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
        $state.Principals.Count | Should Be 1
        $state.PrincipalFailClientId = ''
        $state.Bodies.Clear()
        $state.Calls.Clear()
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Principals.Count | Should Be 2
        $state.Bodies.Count | Should Be 0
        @($state.Calls | Where-Object { $_[1] -eq 'sp' -and $_[2] -eq 'create' }).Count | Should Be 1
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'true'
    }

    It 'does not retry a create with an invalid service principal response or report success' {
        $state.BadPrincipalCreate = '{}'
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'nonempty GUID'
        @($state.Calls | Where-Object { $_[1] -eq 'sp' -and $_[2] -eq 'create' }).Count | Should Be 1
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'retries only missing service principal reads with bounded propagation delays' {
        $state.PrincipalDelayReads = 3
        $null = & $registrationScript -EnvFile $envPath 6>&1
        foreach ($delay in @(2, 4, 8)) {
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Seconds -eq $delay }
        }
        $state.Principals.Count | Should Be 2
    }

    It 'retains recovery IDs without printing consent steps if service principal verification never succeeds' {
        $state.PrincipalDelayReads = 4
        $captured = [System.Collections.Generic.List[string]]::new()
        $message = ''
        try { & $registrationScript -EnvFile $envPath 6>&1 | ForEach-Object { $captured.Add([string]$_) } }
        catch { $message = $_.Exception.Message }
        $message | Should Match 'Service principal could not be verified after four reads'
        ($captured -join "`n") | Should Not Match 'Complete these manual steps|Grant admin consent'
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['APIM_API_SERVICE_PRINCIPAL_ID'] | Should BeExactly $apiPrincipalId
        $saved['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
        $state.Principals.Count | Should Be 1
    }

    It 'does not retry service principal authorization failures or accept a different verification object' {
        $state.Fail = 'sp-show'
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Authorization_RequestDenied'
        @($state.Calls | Where-Object { $_[1] -eq 'sp' -and $_[2] -eq 'show' }).Count | Should Be 1
        $state.Fail = ''
        $state.BadPrincipalShowIdentity = $true
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'different service principal object ID'
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'finds exact matching registrations by name without creating duplicates' {
        $null = & $registrationScript -EnvFile $envPath 6>&1
        Update-PrerequisiteEnv -Path $envPath -Values @{ APIM_API_CLIENT_ID = ''; AUTH_CLIENT_ID = '' }
        $state.Bodies.Clear()
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Bodies.Count | Should Be 0
        Assert-MockCalled az -Scope It -ParameterFilter { $Arguments -contains 'list' -and $Arguments -contains '--all' }
    }

    It 'uses saved names and redirect URI, with explicit parameters taking precedence' {
        Update-PrerequisiteEnv -Path $envPath -Values @{
            APIM_API_APP_NAME = 'Saved API'; AUTH_APP_NAME = 'Saved Auth'
            AUTH_REDIRECT_URI = 'https://example.test/saved'
        }
        $null = & $registrationScript -EnvFile $envPath -AuthAppName 'Explicit Auth' -AuthRedirectUri 'https://example.test/redirect' 6>&1
        $state.Apps.api.displayName | Should BeExactly 'Saved API'
        $state.Apps.auth.displayName | Should BeExactly 'Explicit Auth'
        $state.Apps.auth.web.redirectUris[0] | Should BeExactly 'https://example.test/redirect'
        (Read-PrerequisiteEnv -Path $envPath)['AUTH_APP_NAME'] | Should BeExactly 'Explicit Auth'
    }

    It 'stops on tenant, subscription, or cloud mismatches before directory lookups or writes' {
        foreach ($field in @('tenantId', 'id', 'environmentName')) {
            $original = $state.Account[$field]
            $state.Account[$field] = 'wrong'
            $expectedError = if ($field -eq 'environmentName') { 'public cloud only' } else { 'does not match' }
            { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw $expectedError
            $state.Account[$field] = $original
        }
        $state.Apps.Count | Should Be 0
        @($state.Calls | Where-Object { $_[0] -ne 'account' }).Count | Should Be 0
    }

    It 'rejects conflicting saved tenant values before any CLI call' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ AZURE_TENANT_ID = '77777777-7777-7777-7777-777777777777' }
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Selected tenant differs'
        $state.Calls.Count | Should Be 0
    }

    It 'stops before lookups or configuration changes when the active CLI tenant is different or missing' {
        $before = [System.IO.File]::ReadAllText($envPath)
        foreach ($activeTenant in @('77777777-7777-7777-7777-777777777777', '')) {
            $state.DefaultAccount.tenantId = $activeTenant
            { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'active Azure CLI tenant'
        }
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $before
        @($state.Calls | Where-Object { $_[0] -ne 'account' }).Count | Should Be 0
    }

    It 'allows another active subscription in the same tenant without changing the CLI account' {
        $state.DefaultAccount.id = '77777777-7777-7777-7777-777777777777'
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Apps.Count | Should Be 2
        @($state.Calls | Where-Object { $_[0] -eq 'account' -and $_[1] -ne 'show' }).Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_SUBSCRIPTION_ID'] | Should BeExactly $subscriptionId
    }

    It 'stops before lookups or configuration changes when the active account cannot be read' {
        $before = [System.IO.File]::ReadAllText($envPath)
        $state.DefaultAccount = $null
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'invalid or empty JSON'
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $before
        @($state.Calls | Where-Object { $_[0] -ne 'account' }).Count | Should Be 0
    }

    It 'reports CLI argument errors separately from Entra permission errors without leaking output' {
        $state.UsageError = 'list'
        $message = ''
        try { $null = & $registrationScript -EnvFile $envPath 6>&1 } catch { $message = $_.Exception.Message }
        $message | Should Match 'az ad app list'
        $message | Should Match 'CLI usage error'
        $message | Should Match 'exit code 2'
        $message | Should Not Match 'preserve-existing-secret|Contributor alone'
        $state.Apps.Count | Should Be 0
    }

    It 'requires an explicit or saved tenant and subscription instead of silently choosing a directory' {
        { & $registrationScript -EnvFile $envPath -TenantId '' 6>$null } | Should Throw 'Supply -TenantId'
        { & $registrationScript -EnvFile $envPath -SubscriptionId '' 6>$null } | Should Throw 'nonempty GUID'
        $state.Calls.Count | Should Be 0
    }

    It 'rejects invalid names, GUIDs, and unsafe redirect URIs before any CLI call' {
        { & $registrationScript -EnvFile $envPath -ApimApiAppName '' 6>$null } | Should Throw 'Supply distinct app names'
        { & $registrationScript -EnvFile $envPath -AuthAppName 'bad&name' 6>$null } | Should Throw 'Supply distinct app names'
        { & $registrationScript -EnvFile $envPath -AuthAppName 'test-apim-gateway-api' 6>$null } | Should Throw 'must be different'
        { & $registrationScript -EnvFile $envPath -ApimApiClientId 'not-a-guid' 6>$null } | Should Throw 'nonempty GUID'
        { & $registrationScript -EnvFile $envPath -AuthClientId $apiId -ApimApiClientId $apiId 6>$null } | Should Throw 'must be different'
        foreach ($uri in @('http://example.test', 'https://example.test/#fragment', 'relative')) {
            { & $registrationScript -EnvFile $envPath -AuthRedirectUri $uri 6>$null } | Should Throw 'absolute HTTPS'
        }
        $state.Calls.Count | Should Be 0
    }

    It 'requires Azure CLI without starting login' {
        $state.CliMissing = $true
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Azure CLI is required'
        $state.Calls.Count | Should Be 0
    }

    It 'never interprets a failed lookup or malformed collection as an absent app' {
        $state.Fail = 'list'
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Authorization_RequestDenied'
        $state.Fail = ''
        foreach ($response in @('null', 'invalid JSON', '{}')) {
            $state.BadList = $response
            $message = if ($response -eq '{}') { 'unexpected application list' } else { 'invalid or empty JSON' }
            { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw $message
        }
        foreach ($response in @('[null]', '[{}]', '[1]')) {
            $state.BadList = $response
            { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'nonempty GUID'
        }
        $state.Apps.Count | Should Be 0
    }

    It 'fails for a missing saved client ID rather than silently creating a replacement' {
        Update-PrerequisiteEnv -Path $envPath -Values @{ APIM_API_CLIENT_ID = $apiId }
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Request_ResourceNotFound'
        $state.Apps.Count | Should Be 0
    }

    It 'rejects ambiguous display names before creating or modifying applications' {
        $state.ExtraMatches = @(
            @{ displayName = 'test-apim-gateway-api'; appId = $apiId; id = $apiObjectId },
            @{ displayName = 'test-apim-gateway-api'; appId = $authId; id = $authObjectId }
        )
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Multiple registrations match'
        $state.Bodies.Count | Should Be 0
    }

    It 'ignores prefix matches returned by the CLI when finding an exact name' {
        $state.ExtraMatches = @(@{ displayName = 'test-apim-gateway-api-old'; appId = $authId; id = $authObjectId })
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Apps.Count | Should Be 2
    }

    It 'refuses to overwrite an incompatible API registration' {
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Bodies.Clear()
        $state.Apps.api.api.oauth2PermissionScopes[0].type = 'User'
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'api.oauth2PermissionScopes'
        $state.Bodies.Count | Should Be 0
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
    }

    It 'does not replace a different nonempty API identifier URI' {
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Bodies.Clear()
        $state.Apps.api.identifierUris = @('api://another-api')
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'identifierUris'
        $state.Bodies.Count | Should Be 0
    }

    It 'does not broaden consent or accept application permissions instead of the delegated scope' {
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Bodies.Clear()
        $state.Apps.auth.requiredResourceAccess[0].resourceAccess[0].type = 'Role'
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'requiredResourceAccess'
        $state.Bodies.Count | Should Be 0
    }

    It 'checks an existing client for conflicts before completing a pending API URI update' {
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Bodies.Clear()
        $state.Apps.api.identifierUris = @()
        $state.Apps.auth.web.redirectUris = @('https://example.test/wrong')
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'web.redirectUris'
        $state.Bodies.Count | Should Be 0
    }

    It 'resumes after an API URI write failure without creating another API or scope' {
        $state.Fail = 'patch'
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Authorization_RequestDenied'
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['APIM_API_CLIENT_ID'] | Should BeExactly $apiId
        $saved['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
        $scopeId = $state.Apps.api.api.oauth2PermissionScopes[0].id
        $state.Fail = ''
        $null = & $registrationScript -EnvFile $envPath 6>&1
        $state.Apps.api.api.oauth2PermissionScopes[0].id | Should BeExactly $scopeId
        @($state.Bodies | Where-Object { $_.api }).Count | Should Be 1
    }

    It 'retains verified API outputs and resumes when sign-in client creation initially fails' {
        $state.Fail = 'auth-create'
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'Authorization_RequestDenied'
        (Read-PrerequisiteEnv -Path $envPath)['APIM_SCOPE'] | Should BeExactly "api://$apiId/Mcp.Invoke"
        $state.Fail = ''
        $null = & $registrationScript -EnvFile $envPath 6>&1
        @($state.Bodies | Where-Object { $_.api }).Count | Should Be 1
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'true'
    }

    It 'bounds read-after-create propagation retries' {
        $state.DelayReads = 3
        $null = & $registrationScript -EnvFile $envPath 6>&1
        foreach ($delay in @(2, 4, 8)) {
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Seconds -eq $delay }
        }
    }

    It 'does not claim success or create the client if the API configuration never verifies' {
        $state.IgnorePatch = $true
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'could not be verified after four reads'
        $state.Apps.ContainsKey('auth') | Should Be $false
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APP_REGISTRATIONS_CONFIGURED'] | Should BeExactly 'false'
        Assert-MockCalled az -Times 4 -Exactly -Scope It -ParameterFilter { $Arguments[1] -eq 'app' -and $Arguments[2] -eq 'show' }
    }

    It 'rejects a different application identity in verification responses' {
        $state.BadShowIdentity = $true
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'different application client ID'
        $state.Apps.ContainsKey('auth') | Should Be $false
    }

    It 'withholds echoed output and cleans temporary request files on failure' {
        $state.Fail = 'post'
        $message = ''
        try { $null = & $registrationScript -EnvFile $envPath 6>&1 } catch { $message = $_.Exception.Message }
        $message | Should Match 'Authorization_RequestDenied'
        $message | Should Not Match 'preserve-existing-secret'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '.env.*.request.json' -Force).Count | Should Be 0
    }

    It 'stops before Azure mutation if initial configuration persistence fails' {
        Mock Join-Path { throw 'Simulated configuration save failure' } -ParameterFilter { $ChildPath -like '.env.*.tmp' }
        { & $registrationScript -EnvFile $envPath 6>$null } | Should Throw 'configuration save failure'
        $state.Apps.Count | Should Be 0
        @($state.Calls | Where-Object { $_[0] -ne 'account' }).Count | Should Be 0
        Assert-MockCalled Join-Path -Times 1 -Exactly -Scope It -ParameterFilter { $ChildPath -like '.env.*.tmp' }
    }
}

Describe 'Entra registration Windows native argument handling' {
    It 'reads a complete request body path containing spaces and ampersands through a cmd launcher' -Skip:($env:OS -ne 'Windows_NT') {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($registrationScript, [ref]$tokens, [ref]$parseErrors)
        foreach ($name in @('Invoke-RegistrationCli', 'Invoke-RegistrationWrite')) {
            $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $directory = Join-Path $TestDrive 'request folder & more'
        $null = New-Item -ItemType Directory -Path $directory
        $EnvFile = Join-Path $directory '.env'
        $fixture = Join-Path $PSScriptRoot 'Fixtures\Echo-AzureCliBody.cmd'
        $azureCliCommand = Get-Command $fixture
        $SubscriptionId = '11111111-1111-1111-1111-111111111111'
        $previousAlias = Get-Alias az -ErrorAction SilentlyContinue
        $previousExitCode = $global:LASTEXITCODE
        try {
            Set-Alias -Name az -Value $fixture -Scope Local
            $result = Invoke-RegistrationWrite -Method post -Body @{ displayName = 'Native request probe' }
            $result.displayName | Should BeExactly 'Native request probe'
            @(Get-ChildItem -LiteralPath $directory -Force).Count | Should Be 0
        } finally {
            if ($previousAlias) {
                Set-Alias -Name az -Value $previousAlias.Definition -Scope Local
            } else {
                Remove-Item Alias:\az
            }
            $global:LASTEXITCODE = $previousExitCode
        }
    }
}
