$prerequisiteRoot = Split-Path $PSScriptRoot -Parent
$restoreScript = Join-Path $prerequisiteRoot '5.Configure-APIM-Named-Values\Restore-ApimNamedValues.ps1'

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live Azure CLI call.'
}
$restoreAzCommand = Get-Command az

function Write-TestBackup {
    param([string]$Path, [string[]]$AdditionalLines)
    @(
        'values:'
        '  apim-name: test-apim'
        '  rg: test-rg'
        '  sub-id: 11111111-1111-1111-1111-111111111111'
        '  tenant-id: 22222222-2222-2222-2222-222222222222'
        '  apim-mi-object-id: 33333333-3333-3333-3333-333333333333'
        $AdditionalLines
    ) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-RestoreTestValue {
    param(
        [string]$ResourceId,
        [string]$Name,
        [string]$DisplayName,
        [AllowEmptyString()][string]$Value,
        [bool]$Secret = $false
    )
    [pscustomobject]@{
        id = "$ResourceId/namedValues/$Name"
        name = $Name
        properties = [pscustomobject]@{
            displayName = $DisplayName
            value = $Value
            secret = $Secret
            tags = @('preserve-tag')
            provisioningState = 'Succeeded'
        }
    }
}

Describe 'APIM named value backup restore' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $backupPath = Join-Path $TestDrive '.backup.yaml'
        Write-TestBackup -Path $backupPath -AdditionalLines @(
            '  atlassian-mcp-path: /v1/working'
            '  Logger-Credentials--test: restored-credential'
        )
        $script:testResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test-rg/providers/Microsoft.ApiManagement/service/test-apim'
        $state = @{
            Entries = [System.Collections.Generic.List[object]]::new()
            Calls = [System.Collections.Generic.List[object]]::new()
            Writes = [System.Collections.Generic.List[object]]::new()
            BodyPaths = [System.Collections.Generic.List[string]]::new()
            Account = @{ id = '11111111-1111-1111-1111-111111111111'; tenantId = '22222222-2222-2222-2222-222222222222'; environmentName = 'AzureCloud' }
            Service = @{ id = $script:testResourceId; identity = @{ type = 'SystemAssigned'; principalId = '33333333-3333-3333-3333-333333333333'; tenantId = '22222222-2222-2222-2222-222222222222' } }
        }
        Mock Get-Command { $restoreAzCommand } -ParameterFilter { $Name -eq 'az' }
        Mock Start-Sleep {}
        Mock az {
            $state.Calls.Add($Arguments)
            $global:LASTEXITCODE = 0
            if ($Arguments[0] -eq 'account') {
                return ConvertTo-Json -InputObject $state.Account -Depth 5
            }
            if ($Arguments[0] -ne 'rest') { throw 'Unexpected Azure CLI operation.' }
            $method = $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
            $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1].Trim('"')
            $uri = [Uri]$url
            $name = [Uri]::UnescapeDataString($uri.Segments[-1])
            if ($method -in @('put', 'patch')) {
                $bodyArgument = $Arguments[[Array]::IndexOf($Arguments, '--body') + 1].Trim('"')
                $path = $bodyArgument.Substring(1)
                $state.BodyPaths.Add($path)
                $body = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                $state.Writes.Add(@{ Method = $method; Name = $name; Body = $body })
            }
            if ($uri.AbsolutePath -ieq $state.Service.id) {
                return ConvertTo-Json -InputObject $state.Service -Depth 5
            }
            if ($name -eq 'namedValues') {
                return ConvertTo-Json -InputObject @{ value = $state.Entries.ToArray(); nextLink = '' } -Depth 8
            }
            if ($method -eq 'get') {
                $found = @($state.Entries | Where-Object name -ceq $name)
                if ($found.Count -ne 1) {
                    $global:LASTEXITCODE = 1
                    return 'ERROR: (ResourceNotFound) not found'
                }
                return ConvertTo-Json -InputObject $found[0] -Depth 8
            }
            if ($method -eq 'put') {
                $state.Entries.Add((New-RestoreTestValue -ResourceId $state.Service.id -Name $name -DisplayName $body.properties.displayName -Value $body.properties.value))
                return
            }
            if ($method -eq 'patch') {
                $found = @($state.Entries | Where-Object name -ceq $name)
                if ($found.Count -ne 1) { throw 'Cannot patch unknown test value.' }
                $found[0].properties.value = $body.properties.value
                return
            }
            throw 'Unexpected REST method.'
        }
    }

    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
        foreach ($path in $state.BodyPaths) {
            Test-Path -LiteralPath $path | Should Be $false
        }
    }

    It 'restores public and secret entries while preserving existing metadata' {
        $public = New-RestoreTestValue -ResourceId $state.Service.id -Name 'generated-public' -DisplayName 'atlassian-mcp-path' -Value '/v1/new'
        $secret = New-RestoreTestValue -ResourceId $state.Service.id -Name 'generated-secret' -DisplayName 'Logger-Credentials--test' -Value '' -Secret $true
        $state.Entries.Add($public)
        $state.Entries.Add($secret)

        $null = & $restoreScript -BackupFile $backupPath -Confirm:$false 6>&1

        $state.Writes.Count | Should Be 7
        @($state.Writes | Where-Object Name -eq 'generated-public')[0].Method | Should BeExactly 'patch'
        @($state.Writes | Where-Object Name -eq 'generated-secret')[0].Method | Should BeExactly 'patch'
        $public.properties.tags[0] | Should BeExactly 'preserve-tag'
        $secret.properties.secret | Should Be $true
        $secret.properties.value | Should BeExactly 'restored-credential'
        ($state.Calls | ConvertTo-Json -Depth 4) | Should Not Match 'listSecrets|restored-credential'
    }

    It 'previews without writing and leaves unrelated values untouched' {
        $unrelated = New-RestoreTestValue -ResourceId $state.Service.id -Name 'unrelated' -DisplayName 'unrelated' -Value 'keep'
        $state.Entries.Add($unrelated)

        $null = & $restoreScript -BackupFile $backupPath -WhatIf 6>&1

        $state.Writes.Count | Should Be 0
        $unrelated.properties.value | Should BeExactly 'keep'
    }

    It 'rejects an identity mismatch before discovering or writing named values' {
        $state.Service.identity.principalId = '44444444-4444-4444-4444-444444444444'

        { & $restoreScript -BackupFile $backupPath -Confirm:$false 6>$null } | Should Throw 'does not match the backup'

        $state.Writes.Count | Should Be 0
        @($state.Calls | Where-Object { ($_ -join ' ') -match '/namedValues' }).Count | Should Be 0
    }

    It 'rejects duplicate, unsupported and missing backup data before Azure calls' {
        Add-Content -LiteralPath $backupPath -Value '  APIM-NAME: duplicate'
        { & $restoreScript -BackupFile $backupPath -Confirm:$false 6>$null } | Should Throw 'Duplicate named value'
        Write-TestBackup -Path $backupPath -AdditionalLines @('  unsupported: &anchor value')
        { & $restoreScript -BackupFile $backupPath -Confirm:$false 6>$null } | Should Throw 'Unsupported YAML syntax'
        Write-TestBackup -Path $backupPath -AdditionalLines @('  empty: ')
        { & $restoreScript -BackupFile $backupPath -Confirm:$false 6>$null } | Should Throw 'empty value'
        $state.Calls.Count | Should Be 0
    }

    It 'rejects Key Vault-backed entries without writing anything' {
        $item = New-RestoreTestValue -ResourceId $state.Service.id -Name 'atlassian-mcp-path' -DisplayName 'atlassian-mcp-path' -Value ''
        $item.properties | Add-Member -NotePropertyName keyVault -NotePropertyValue @{ secretIdentifier = 'https://example.vault.azure.net/secrets/test' }
        $state.Entries.Add($item)

        { & $restoreScript -BackupFile $backupPath -Confirm:$false 6>$null } | Should Throw 'Key Vault-backed'

        $state.Writes.Count | Should Be 0
    }
}
