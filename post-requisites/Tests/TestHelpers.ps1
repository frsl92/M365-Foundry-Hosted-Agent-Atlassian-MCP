$postRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $postRoot '..\common-scripts\Common.ps1')

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    throw 'Unexpected live Azure CLI call.'
}
function atk { throw 'Unexpected live Toolkit call.' }
function Invoke-MgGraphRequest { throw 'Unexpected live Graph call.' }
function Get-MgContext { throw 'Unexpected live Graph context call.' }
$testAzCommand = Get-Command az

function Write-TestPackage {
    param([string]$Path, $Manifest, [string[]]$ExtraEntries = @())
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Create($Path)
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = @{
            'manifest.json' = ($Manifest | ConvertTo-Json -Depth 100)
            'default-color-icon.png' = 'original-color-bytes'
            'default-outline-icon.png' = 'original-outline-bytes'
            'resources/extra.txt' = 'preserve this asset'
        }
        foreach ($name in @($files.Keys) + $ExtraEntries) {
            $writer = [IO.StreamWriter]::new($zip.CreateEntry($name).Open())
            try { $writer.Write([string]$files[$name]) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}

function Read-TestPackageEntry {
    param([string]$Path, [string]$Name = 'manifest.json', [switch]$Base64)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $inputStream = $zip.GetEntry($Name).Open()
        $buffer = [IO.MemoryStream]::new()
        try {
            $inputStream.CopyTo($buffer)
            if ($Base64) { return [Convert]::ToBase64String($buffer.ToArray()) }
            return ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($buffer.ToArray()))
        } finally { $inputStream.Dispose(); $buffer.Dispose() }
    } finally { $zip.Dispose() }
}

function New-TestPng {
    param([string]$Path, [int]$Width, [int]$Height)
    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Bitmap]::new($Width, $Height)
    try { $image.Save($Path, [Drawing.Imaging.ImageFormat]::Png) } finally { $image.Dispose() }
}

function New-TestDeployment {
    param([string]$Root)
    $endpoint = 'https://test-account.services.ai.azure.com/api/projects/test-project'
    $subscription = '11111111-1111-1111-1111-111111111111'
    $tenant = '22222222-2222-2222-2222-222222222222'
    $client = '33333333-3333-3333-3333-333333333333'
    $botId = "/subscriptions/$subscription/resourceGroups/test-rg/providers/Microsoft.BotService/botServices/test-bot"
    $envPath = Join-Path $Root 'post.env'
    [IO.File]::WriteAllLines($envPath, @(
        "AZURE_FOUNDRY_PROJECT_ENDPOINT=$endpoint", 'AZURE_FOUNDRY_AGENT_NAME=atlassian-agent',
        "AZURE_BOT_SERVICE_RESOURCE_ID=$botId", "AZURE_TENANT_ID=$tenant",
        'AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME=apim-user',
        'AUTH_CLIENT_ID=55555555-5555-5555-5555-555555555555',
        'AUTH_CLIENT_SECRET=must-not-be-printed',
        'APIM_SCOPE=api://66666666-6666-6666-6666-666666666666/Mcp.Invoke'
    ))
    return @{
        EnvPath = $envPath; OriginalEnv = [IO.File]::ReadAllText($envPath)
        Endpoint = $endpoint; Subscription = $subscription; Tenant = $tenant
        BotId = $botId; Client = $client
        Provider = @{ properties = @{ id = '30dd229c-58e3-4a48-bdfd-91ec48eb906c'; serviceProviderName = 'Aadv2' } }
        Agent = [pscustomobject]@{
            name = 'atlassian-agent'; instance_identity = @{ client_id = $client }
            agent_endpoint = [pscustomobject]@{
                protocol_configuration = [pscustomobject]@{
                    responses = [pscustomobject]@{}
                    activity = [pscustomobject]@{ enable_m365_public_endpoint = $false; existing = 'keep' }
                }
                authorization_schemes = @(
                    [pscustomobject]@{ type = 'Entra'; existing = 'keep' },
                    [pscustomobject]@{ type = 'BotServiceRbac' })
                version_selector = @{ marker = 'keep-routing' }
            }
        }
        Bot = [pscustomobject]@{
            id = $botId; location = 'global'
            properties = @{
                msaAppId = $client; msaAppTenantId = $tenant
                endpoint = "$endpoint/agents/atlassian-agent/endpoint/protocols/activityProtocol?api-version=2025-05-15-preview"
                publicNetworkAccess = 'Disabled'
            }
        }
        Channels = @(); Connections = @()
        Calls = [Collections.Generic.List[object]]::new()
        BodyPaths = [Collections.Generic.List[string]]::new()
        ErrorMethod = ''; InvalidJson = $false; IgnoreWrites = $false
        NextLink = ''; ConnectionNextLink = ''; AccountTenant = $tenant
        ListingCount = 0; Appearance = $null; ReadBackDelay = 0
    }
}
