$prerequisiteRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $prerequisiteRoot 'Common.ps1')
$identityScript = Join-Path $prerequisiteRoot '2.Configure-APIM-Identity\Configure-ApimIdentity.ps1'

# Mock the CLI entry point so these tests cannot reach Azure.
function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live Azure CLI call.'
}
$azCommand = Get-Command az

Describe 'APIM managed identity prerequisite' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $envPath = Join-Path $TestDrive 'apim.env'
        if (Test-Path -LiteralPath $envPath) { Remove-Item -LiteralPath $envPath }
        $subscriptionId = '11111111-1111-1111-1111-111111111111'
        $principalId = '22222222-2222-2222-2222-222222222222'
        $tenantId = '33333333-3333-3333-3333-333333333333'
        $resourceId = "/subscriptions/$subscriptionId/resourceGroups/test-rg/providers/Microsoft.ApiManagement/service/test-apim"
        $roleId = '312a565d-c81f-4fd8-895a-4e21e48d571c'
        $assignment = [pscustomobject]@{
            id = "$resourceId/providers/Microsoft.Authorization/roleAssignments/44444444-4444-4444-4444-444444444444"
            principalId = $principalId
            scope = $resourceId
            roleDefinitionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/$roleId"
            condition = $null
        }
        $state = @{
            ResourceId = $resourceId
            Identity = [pscustomobject]@{ type = 'SystemAssigned'; principalId = $principalId; tenantId = $tenantId }
            Assignments = @()
            CreatedAssignment = $assignment
            PublishAssignment = $true
            Created = $false
            DelayedReads = 0
            FailOperation = ''
            InvalidJson = $false
            CliMissing = $false
            Calls = [System.Collections.Generic.List[object]]::new()
        }
        Update-PrerequisiteEnv -Path $envPath -Values @{
            AZURE_APIM_NAME = 'test-apim'
            AZURE_RESOURCE_GROUP_NAME = 'test-rg'
            AZURE_SUBSCRIPTION_ID = $subscriptionId
            ATLASSIAN_MCP_CLIENT_SECRET = 'preserve-test-secret'
            AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID = 'stale-assignment'
        }
        Mock az {
            $state.Calls.Add($Arguments)
            $global:LASTEXITCODE = 0
            $operation = if ($Arguments[0] -eq 'apim') { $Arguments[1] } else { $Arguments[2] }
            if ($state.FailOperation -eq $operation) {
                $global:LASTEXITCODE = 1
                return 'Simulated Azure CLI failure'
            }
            if ($state.InvalidJson) { return 'invalid JSON' }
            switch ($operation) {
                'show' {
                    return ([pscustomobject]@{ id = $state.ResourceId; identity = $state.Identity } | ConvertTo-Json -Depth 5)
                }
                'list' {
                    if ($state.Created -and $state.DelayedReads -gt 0) {
                        $state.DelayedReads--
                        return '[]'
                    }
                    return (ConvertTo-Json -InputObject @($state.Assignments) -Depth 5)
                }
                'create' {
                    $saved = Read-PrerequisiteEnv -Path $envPath
                    if ($saved['AZURE_APIM_IDENTITY_PRINCIPAL_ID'] -cne $principalId -or
                        $saved['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] -cne '') {
                        throw 'Identity must be saved and stale assignment cleared before creating a role assignment.'
                    }
                    if ($state.PublishAssignment) { $state.Assignments = @($state.CreatedAssignment) }
                    $state.Created = $true
                    return ($state.CreatedAssignment | ConvertTo-Json -Depth 5)
                }
                default { throw "Unexpected CLI operation '$operation'." }
            }
        }
        Mock Start-Sleep {} -ParameterFilter { $Seconds -gt 0 }
        Mock Get-Command {
            if (-not $state.CliMissing) { $azCommand }
        } -ParameterFilter { $Name -eq 'az' }
    }

    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
    }

    It 'loads saved inputs, grants the exact resource-scoped role, and saves verified identity and assignment IDs' {
        Push-Location $TestDrive
        try {
            $null = & $identityScript -EnvFile '.\apim.env' 6>&1
        } finally { Pop-Location }
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['AZURE_APIM_RESOURCE_ID'] | Should BeExactly $resourceId
        $saved['AZURE_APIM_IDENTITY_ENABLED'] | Should BeExactly 'true'
        $saved['AZURE_APIM_IDENTITY_PRINCIPAL_ID'] | Should BeExactly $principalId
        $saved['AZURE_APIM_IDENTITY_TENANT_ID'] | Should BeExactly $tenantId
        $saved['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] | Should BeExactly $assignment.id
        $saved['ATLASSIAN_MCP_CLIENT_SECRET'] | Should BeExactly 'preserve-test-secret'
        Assert-MockCalled az -Times 1 -Exactly -Scope It -ParameterFilter {
            $Arguments[0] -eq 'role' -and $Arguments[2] -eq 'create' -and
            $Arguments -contains $resourceId -and $Arguments -contains $roleId -and
            $Arguments -contains '--assignee-object-id' -and $Arguments -contains $principalId -and
            $Arguments -contains '--assignee-principal-type' -and $Arguments -contains 'ServicePrincipal'
        }
        foreach ($call in $state.Calls) {
            $call -contains '--subscription' | Should Be $true
            $call -contains $subscriptionId | Should Be $true
            $call -contains '--output' | Should Be $true
        }
    }

    It 'overrides saved inputs with explicit parameters' {
        $newSubscription = '55555555-5555-5555-5555-555555555555'
        $state.ResourceId = "/subscriptions/$newSubscription/resourceGroups/other-rg/providers/Microsoft.ApiManagement/service/other-apim"
        $assignment.scope = $state.ResourceId
        $assignment.id = "$($state.ResourceId)/providers/Microsoft.Authorization/roleAssignments/test"
        $state.Assignments = @($assignment)
        $null = & $identityScript -EnvFile $envPath -ApimName 'other-apim' -ResourceGroupName 'other-rg' -SubscriptionId $newSubscription 6>&1
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['AZURE_APIM_NAME'] | Should BeExactly 'other-apim'
        $saved['AZURE_RESOURCE_GROUP_NAME'] | Should BeExactly 'other-rg'
        $saved['AZURE_SUBSCRIPTION_ID'] | Should BeExactly $newSubscription
    }

    It 'reuses an existing assignment on repeated runs without creating duplicates' {
        $state.Assignments = @($assignment)
        $null = & $identityScript -EnvFile $envPath 6>&1
        $null = & $identityScript -EnvFile $envPath 6>&1
        Assert-MockCalled az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[2] -eq 'create' }
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] | Should BeExactly $assignment.id
    }

    It 'accepts a combined system-assigned and user-assigned identity' {
        $state.Identity.type = 'SystemAssigned, UserAssigned'
        $null = & $identityScript -EnvFile $envPath 6>&1
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_IDENTITY_PRINCIPAL_ID'] | Should BeExactly $principalId
    }

    It 'instructs activation for disabled or user-assigned-only identities and clears stale IDs' {
        foreach ($identity in @($null, [pscustomobject]@{ type = 'None' }, [pscustomobject]@{ type = 'UserAssigned'; principalId = $principalId })) {
            $state.Identity = $identity
            Update-PrerequisiteEnv -Path $envPath -Values @{
                AZURE_APIM_IDENTITY_PRINCIPAL_ID = 'stale-principal'
                AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID = 'stale-assignment'
            }
            { & $identityScript -EnvFile $envPath 6>$null } | Should Throw 'set Status to On'
            $saved = Read-PrerequisiteEnv -Path $envPath
            $saved['AZURE_APIM_IDENTITY_ENABLED'] | Should BeExactly 'false'
            $saved['AZURE_APIM_IDENTITY_PRINCIPAL_ID'] | Should BeExactly ''
            $saved['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] | Should BeExactly ''
        }
        Assert-MockCalled az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[0] -ne 'apim' -or $Arguments[1] -ne 'show' }
    }

    It 'stops when an enabled identity has no usable principal ID' {
        $state.Identity.principalId = $null
        { & $identityScript -EnvFile $envPath 6>$null } | Should Throw 'not ready'
        Assert-MockCalled az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[0] -eq 'role' }
    }

    It 'rejects missing required inputs before calling Azure' {
        foreach ($key in @('AZURE_APIM_NAME', 'AZURE_RESOURCE_GROUP_NAME', 'AZURE_SUBSCRIPTION_ID')) {
            $values = Read-PrerequisiteEnv -Path $envPath
            $original = $values[$key]
            Update-PrerequisiteEnv -Path $envPath -Values @{ $key = '' }
            { & $identityScript -EnvFile $envPath } | Should Throw $key
            Update-PrerequisiteEnv -Path $envPath -Values @{ $key = $original }
        }
        Assert-MockCalled az -Times 0 -Exactly -Scope It
    }

    It 'rejects a subscription display name before calling Azure' {
        { & $identityScript -EnvFile $envPath -SubscriptionId 'my subscription' } | Should Throw 'subscription GUID'
        Assert-MockCalled az -Times 0 -Exactly -Scope It
    }

    It 'instructs installation when Azure CLI is unavailable' {
        $state.CliMissing = $true
        { & $identityScript -EnvFile $envPath } | Should Throw 'Azure CLI is required'
        Assert-MockCalled az -Times 0 -Exactly -Scope It
    }

    It 'rejects a mismatched resource response without changing saved configuration' {
        $before = [System.IO.File]::ReadAllText($envPath)
        $state.ResourceId = "$resourceId-wrong"
        { & $identityScript -EnvFile $envPath 6>$null } | Should Throw 'unexpected APIM resource ID'
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $before
    }

    It 'surfaces CLI failures such as resource not found or failed authentication' {
        $state.FailOperation = 'show'
        $before = [System.IO.File]::ReadAllText($envPath)
        { & $identityScript -EnvFile $envPath 6>$null } | Should Throw 'exit code 1'
        [System.IO.File]::ReadAllText($envPath) | Should BeExactly $before
    }

    It 'stops on invalid JSON from the CLI' {
        $state.InvalidJson = $true
        { & $identityScript -EnvFile $envPath 6>$null } | Should Throw 'JSON'
        Assert-MockCalled az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[0] -eq 'role' }
    }

    It 'does not interpret a failed assignment lookup as permission to create' {
        $state.FailOperation = 'list'
        { & $identityScript -EnvFile $envPath 6>$null } | Should Throw 'exit code 1'
        Assert-MockCalled az -Times 0 -Exactly -Scope It -ParameterFilter { $Arguments[2] -eq 'create' }
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] | Should BeExactly ''
    }

    It 'retains identity details when role creation is denied' {
        $state.FailOperation = 'create'
        { & $identityScript -EnvFile $envPath 6>$null } | Should Throw 'RBAC permissions'
        $saved = Read-PrerequisiteEnv -Path $envPath
        $saved['AZURE_APIM_IDENTITY_PRINCIPAL_ID'] | Should BeExactly $principalId
        $saved['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] | Should BeExactly ''
    }

    It 'does not count assignments for other scopes, principals, roles, or conditions' {
        $state.Assignments = @(
            [pscustomobject]@{ principalId = $principalId; scope = "/subscriptions/$subscriptionId"; roleDefinitionId = $assignment.roleDefinitionId; id = 'parent' }
            [pscustomobject]@{ principalId = $tenantId; scope = $resourceId; roleDefinitionId = $assignment.roleDefinitionId; id = 'other-principal' }
            [pscustomobject]@{ principalId = $principalId; scope = $resourceId; roleDefinitionId = 'other-role'; id = 'other-role' }
            [pscustomobject]@{ principalId = $principalId; scope = $resourceId; roleDefinitionId = $assignment.roleDefinitionId; condition = 'some-condition'; id = 'conditional' }
        )
        $null = & $identityScript -EnvFile $envPath 6>&1
        Assert-MockCalled az -Times 1 -Exactly -Scope It -ParameterFilter { $Arguments[2] -eq 'create' }
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] | Should BeExactly $assignment.id
    }

    It 'bounds verification retries and never records unverified success' {
        $state.PublishAssignment = $false
        { & $identityScript -EnvFile $envPath 6>$null } | Should Throw 'could not yet be verified'
        Assert-MockCalled az -Times 5 -Exactly -Scope It -ParameterFilter { $Arguments[2] -eq 'list' }
        Assert-MockCalled Start-Sleep -Times 3 -Exactly -Scope It -ParameterFilter { $Seconds -gt 0 }
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] | Should BeExactly ''
    }

    It 'verifies an assignment after transient ARM read propagation delay' {
        $state.DelayedReads = 2
        $null = & $identityScript -EnvFile $envPath 6>&1
        Assert-MockCalled az -Times 4 -Exactly -Scope It -ParameterFilter { $Arguments[2] -eq 'list' }
        Assert-MockCalled Start-Sleep -Times 2 -Exactly -Scope It -ParameterFilter { $Seconds -gt 0 }
        (Read-PrerequisiteEnv -Path $envPath)['AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID'] | Should BeExactly $assignment.id
    }
}
