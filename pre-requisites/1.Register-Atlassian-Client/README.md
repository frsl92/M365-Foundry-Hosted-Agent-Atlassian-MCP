# Register an Atlassian MCP client

[Register-AtlassianMcpClient.ps1](./Register-AtlassianMcpClient.ps1) registers an OAuth client with Atlassian's Rovo MCP authorization server using Dynamic Client Registration (DCR). It discovers the OAuth endpoints, registers a confidential client using `client_secret_post`, and saves inputs and generated values to the repository-root `.env` for later prerequisites. It also prints the registration environment variables.

> Registration creates a **new client**, not an update. If the `.env` already contains a client ID or secret, the script stops before making network calls unless you explicitly pass `-ForceRegistration`. It does not complete user authorization and consent.

## Prerequisites

- PowerShell and network access to Atlassian's MCP and authorization endpoints.
- The name of the Azure API Management (APIM) instance that will handle the OAuth callback.
- If Atlassian rejects the redirect domain, ask an Atlassian organization administrator to allowlist `authorization-manager.consent.azure-apim.net` under **Rovo MCP server > Allowed domains** in Atlassian Admin.
- For optional Key Vault storage: an existing vault, the `Az.Accounts` and `Az.KeyVault` PowerShell modules, an authenticated Azure session, and permission and network access to set secrets in that vault.

## Register a client

On a fresh checkout, you can copy the committed [template](../../.env.v1.example) to `.env` at the repository root and set `AZURE_APIM_NAME`. Do not overwrite an existing `.env`:

```powershell
if (-not (Test-Path -LiteralPath .\.env)) {
    Copy-Item .\.env.v1.example .\.env
}
```

This is optional: a successful registration creates the file if it does not exist.

From the repository root, change to this prerequisite's directory:

```powershell
Set-Location .\pre-requisites\1.Register-Atlassian-Client
```

Run the script with your APIM instance name (not its URL or resource ID):

```powershell
.\Register-AtlassianMcpClient.ps1 -ApimName "my-apim"
```

The script derives and registers this redirect URI:

```text
https://authorization-manager.consent.azure-apim.net/redirect/apim/my-apim
```

There is no separate `-RedirectUri` parameter. `-ApimName` only supplies the name used in this URL; the script does not create or configure an APIM instance.

If `AZURE_APIM_NAME` is already filled in and no registration is saved yet, no parameters are needed:

```powershell
.\Register-AtlassianMcpClient.ps1
```

## Shared configuration and saved values

The script resolves inputs in this order:

1. Explicit command-line parameters, including an explicitly empty `-KeyVaultName ""` to disable vault storage.
2. Nonempty values in the shared `.env`.
3. Script defaults.

The default `.env` path is relative to the script location, not your current working directory. Use `-EnvFile "C:\path\to\.env"` to select another configuration file, and pass the same path to subsequent scripts. Process environment variables are not an additional input source.

After registration, the script merges its inputs and outputs into `.env` without removing unrelated keys or standalone comments. Existing lines for keys it updates are replaced. Writes use a temporary file in the same directory followed by replacement, rather than editing the file in place. **Run prerequisites sequentially**; concurrent writers are not supported.

The printed output still has this shape (placeholder values below are not usable credentials):

```dotenv
ATLASSIAN_MCP_CLIENT_ID="<registered-client-id>"
ATLASSIAN_MCP_CLIENT_SECRET="<registered-client-secret>"
ATLASSIAN_MCP_AUTHORIZATION_URL="<discovered-authorization-endpoint>"
ATLASSIAN_MCP_TOKEN_URL="<discovered-token-endpoint>"
ATLASSIAN_MCP_SERVER_URL="<discovered-resource-url>"
ATLASSIAN_MCP_REDIRECT_URI="https://authorization-manager.consent.azure-apim.net/redirect/apim/my-apim"
ATLASSIAN_MCP_SCOPES="<requested-scopes>"
```

- No manual copying is needed for later prerequisites using the shared file.
- The script does not set process environment variables or copy anything to the clipboard.
- Credentials are printed and saved locally before optional Key Vault writes, even when Key Vault storage is enabled.
- The registration access token, when returned, is also saved as `ATLASSIAN_MCP_REGISTRATION_ACCESS_TOKEN`, but is not printed. A replacement registration without a token clears any previously saved token.
- The client secret is visible in the terminal and stored in plaintext locally. Avoid shared logs or transcripts and restrict access to the file.
- The root [.gitignore](../../.gitignore) excludes `.env` and `.env.*`, except the example templates. Never add real credentials to the template. If you choose a custom filename, ensure it is ignored too.

### Rerunning registration

Later prerequisites should consume the saved values, not rerun registration. To intentionally create a replacement client:

```powershell
.\Register-AtlassianMcpClient.ps1 -ForceRegistration
```

This uses saved inputs unless overridden and replaces the saved registration values only after successful registration. It does not revoke the old client or update downstream services automatically. Reconfigure consumers and obtain new user consent as needed.

## Optionally store credentials in Key Vault

If the required modules are not already installed:

```powershell
Install-Module -Name Az.Accounts, Az.KeyVault -Scope CurrentUser
```

Sign in and run the script with the vault name:

```powershell
Connect-AzAccount

.\Register-AtlassianMcpClient.ps1 `
    -ApimName "my-apim" `
    -KeyVaultName "my-vault"
```

With the default secret prefix, the script stores:

| Secret name | Value |
| --- | --- |
| `atlassian-mcp-client-id` | Registered client ID |
| `atlassian-mcp-client-secret` | Registered client secret |
| `atlassian-mcp-registration-token` | Registration access token, only if Atlassian returns one |

Use `-SecretPrefix` to change the prefix. The registration access token is not included in the printed environment variables.

Key Vault storage happens **after** local persistence and console output. If a vault write fails, the error is surfaced and the registered credentials remain in `.env`. Do not use `-ForceRegistration` just to retry vault storage; fix vault access and store the existing values instead:

```powershell
. ..\Common.ps1
$configuration = Read-PrerequisiteEnv
$prefix = $configuration['ATLASSIAN_MCP_SECRET_PREFIX']
$secretKeys = @{
    'client-id'          = 'ATLASSIAN_MCP_CLIENT_ID'
    'client-secret'      = 'ATLASSIAN_MCP_CLIENT_SECRET'
    'registration-token' = 'ATLASSIAN_MCP_REGISTRATION_ACCESS_TOKEN'
}
foreach ($entry in $secretKeys.GetEnumerator()) {
    $value = $configuration[$entry.Value]
    if ($value) {
        Set-AzKeyVaultSecret -VaultName $configuration['AZURE_KEY_VAULT_NAME'] `
            -Name "$prefix-$($entry.Key)" `
            -SecretValue (ConvertTo-SecureString $value -AsPlainText -Force) | Out-Null
    }
}
```

For a custom configuration file, supply `-Path` to `Read-PrerequisiteEnv`.

## Parameters

| Parameter | Saved input key | Default / purpose |
| --- | --- | --- |
| `-ApimName` | `AZURE_APIM_NAME` | Required via parameter or `.env`; APIM instance name for the redirect URI. |
| `-McpServerUrl` | `ATLASSIAN_MCP_ENDPOINT` | `https://mcp.atlassian.com/v1/mcp/authv2`; endpoint used for metadata discovery. Distinct from the discovered `ATLASSIAN_MCP_SERVER_URL` output. |
| `-Scopes` | `ATLASSIAN_MCP_SCOPES` | Space-separated scopes; defaults to the list below. |
| `-ClientName` | `ATLASSIAN_MCP_CLIENT_NAME` | `Atlassian MCP Client`; display name sent during registration. |
| `-KeyVaultName` | `AZURE_KEY_VAULT_NAME` | Optional vault. Empty by default; explicit `""` disables a saved vault. |
| `-SecretPrefix` | `ATLASSIAN_MCP_SECRET_PREFIX` | `atlassian-mcp`; prefix for Key Vault secret names. |
| `-EnvFile` | Not saved | Defaults to `.env` at the repository root. |
| `-ForceRegistration` | Not saved | Allows creating a new client when credentials are already saved. |

Default scopes:

```text
read:account read:me offline_access read:jira-work write:jira-work search:confluence read:page:confluence write:page:confluence read:space:confluence read:comment:confluence write:comment:confluence
```

To request a different set of scopes:

```powershell
.\Register-AtlassianMcpClient.ps1 `
    -ApimName "my-apim" `
    -ClientName "My Atlassian MCP Client" `
    -Scopes "read:account read:me offline_access read:jira-work"
```

The script adds `read:account` if omitted, warns if `offline_access` is missing, and warns about scopes not advertised by the server.

## Using shared configuration in later scripts

Scripts in other prerequisite subdirectories should dot-source [Common.ps1](../Common.ps1), validate their required inputs, and merge only the values they own after a successful operation:

Declare user inputs in [.env.v1.example](../../.env.v1.example) under the
first script that requires them. Register generated outputs in
`Get-PrerequisiteGeneratedSections` in [the shared helper](../../common-scripts/Common.ps1),
not the template. Do not duplicate keys reused from earlier scripts.
The shared save helper maintains this [configuration layout](../README.md#configuration-layout)
automatically.

```powershell
param([string]$ApimName)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')

$configuration = Read-PrerequisiteEnv
$ApimName = Resolve-PrerequisiteValue -Parameters $PSBoundParameters `
    -ParameterName 'ApimName' -Values $configuration -Key 'AZURE_APIM_NAME'
if ([string]::IsNullOrWhiteSpace($ApimName)) {
    throw 'Supply -ApimName or set AZURE_APIM_NAME in the shared .env.'
}
if (-not $configuration['ATLASSIAN_MCP_CLIENT_ID']) {
    throw 'Run prerequisite 1 to register an Atlassian MCP client first.'
}

# Perform this prerequisite's operation using the resolved values.
# Only after success, merge its outputs:
Update-PrerequisiteEnv -Values @{ AZURE_APIM_NAME = $ApimName }
```

`Read-PrerequisiteEnv` returns a key/value dictionary. A missing file returns an empty dictionary; malformed files and duplicate keys cause an error with the line number, without echoing secret values.

The supported format is deliberately small: `KEY=value`, single- or double-quoted values, blank lines, and `#` comments. In double-quoted values, `\\`, `\"`, `\n`, `\r`, and `\t` are decoded; single-quoted values are literal. Unquoted comments start with `#` at the beginning of the value or after whitespace. Keys are case-sensitive. Variable interpolation, `export` statements, multiline literal values, and executing file contents are not supported. Always use the helper to write generated values so escaping stays consistent.

### Tests

With Pester installed, run from the repository root:

```powershell
Invoke-Pester -Script .\pre-requisites\Tests\Configuration.Tests.ps1
```

The tests use temporary configuration files and mock registration and Key Vault calls. They do not modify your root `.env` or create real clients.

## Warnings and troubleshooting

- **Missing APIM name:** pass `-ApimName` or set `AZURE_APIM_NAME` in `.env`.
- **Existing registration:** use the saved credentials in later steps, or explicitly pass `-ForceRegistration` for a new client.
- **Local save failed:** the client may already exist remotely. Preserve the printed values and fix the file access problem before taking further action.
- **Redirect rejected:** check the APIM instance name and the Atlassian allowed-domain setting described above.
- **Metadata or registration unsupported:** the authorization server must advertise a registration endpoint and support `client_secret_post`.
- **Secret expiration:** if Atlassian returns an expiration time, the script prints a warning. Plan to re-register and replace the credentials before expiration.
- **No registration access token:** the script warns that the client cannot be updated later. Changing scopes then requires a new registration and user consent.
