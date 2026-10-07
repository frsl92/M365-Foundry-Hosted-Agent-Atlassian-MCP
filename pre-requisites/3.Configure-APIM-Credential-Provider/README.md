# Configure the APIM credential provider

[Configure-ApimCredentialProvider.ps1](./Configure-ApimCredentialProvider.ps1)
creates the Credential Manager **provider** shown in the portal example:
`atlassian`, **OAuth 2.1 with PKCE with DCR**, **Authorization code**.
It reuses the shared repository-root `.env` from prerequisites 1 and 2.

This step does **not** create a connection, grant connection access, perform
Atlassian consent, register another OAuth client, or configure an API policy.
Those are separate steps before the provider can be used to obtain tokens.

## Requirements

- Complete [client registration](../1.Register-Atlassian-Client/README.md) and
  [APIM identity setup](../2.Configure-APIM-Identity/README.md) for the same APIM.
- PowerShell and [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
- Sign in with `az login`. The **CLI caller** needs authorization-provider
  read/write access on APIM, for example API Management Service Contributor.
  Assigning that role to APIM's managed identity in step 2 does not grant it
  to the caller.
- An existing APIM instance with Credential Manager support and outbound access
  to the identity provider. This script targets Azure public cloud.

## Run

From the repository root, with the earlier steps' values already saved:

```powershell
.\pre-requisites\3.Configure-APIM-Credential-Provider\Configure-ApimCredentialProvider.ps1
```

Optional explicit inputs:

```powershell
.\pre-requisites\3.Configure-APIM-Credential-Provider\Configure-ApimCredentialProvider.ps1 `
    -ApimName "my-apim" `
    -ResourceGroupName "my-rg" `
    -SubscriptionId "11111111-1111-1111-1111-111111111111" `
    -ProviderName "atlassian"
```

| Parameter | Saved input | Default |
| --- | --- | --- |
| `-ApimName` | `AZURE_APIM_NAME` | Required |
| `-ResourceGroupName` | `AZURE_RESOURCE_GROUP_NAME` | Required |
| `-SubscriptionId` | `AZURE_SUBSCRIPTION_ID` | Required GUID |
| `-ProviderName` | `AZURE_APIM_CREDENTIAL_PROVIDER_NAME` | `atlassian` |
| `-EnvFile` | Alternative shared configuration file | Repository-root `.env` |
| `-UpdateExisting` | Not saved | Off |

Explicit parameters override saved values. The script never uses the Azure CLI
default subscription. The default configuration path is independent of the
working directory; relative `-EnvFile` paths are relative to your current
PowerShell directory. Keep custom configuration files out of source control too.

Changing APIM requires a client registered with that APIM's callback URL.
The script rejects a mismatched registration callback or saved APIM resource ID
rather than applying another instance's configuration.

## Portal fields and saved values

| Portal field | Source / value |
| --- | --- |
| Credential provider name | `AZURE_APIM_CREDENTIAL_PROVIDER_NAME`, default `atlassian` |
| Identity provider | `oauth2pkcewithdcr` (OAuth 2.1 with PKCE with DCR) |
| Grant type | `authorizationCode` |
| Authorization URL | `ATLASSIAN_MCP_AUTHORIZATION_URL` |
| Client ID | `ATLASSIAN_MCP_CLIENT_ID` |
| Client secret | `ATLASSIAN_MCP_CLIENT_SECRET` |
| Refresh URL | `ATLASSIAN_MCP_TOKEN_URL` |
| Server URL | `ATLASSIAN_MCP_ENDPOINT` |
| Token URL | `ATLASSIAN_MCP_TOKEN_URL` |
| Scopes | `ATLASSIAN_MCP_SCOPES` |
| Redirect URL | `https://authorization-manager.consent.azure-apim.net/redirect/apim/<ApimName>` |

The example uses `https://auth.atlassian.com/authorize` for authorization,
`https://auth.atlassian.com/oauth/token` for token and refresh, and
`https://mcp.atlassian.com/v1/mcp/authv2` for the server. Values are read from
configuration, not hardcoded from the screenshot.

**Server URL deliberately uses `ATLASSIAN_MCP_ENDPOINT`**, the MCP endpoint
registered in step 1. `ATLASSIAN_MCP_SERVER_URL` is the protected-resource
identifier discovered from metadata and can differ from the endpoint in the
portal example. It is not substituted here.

## Azure CLI requests

The script uses `az rest`, because the installed `az apim` command group does
not expose Credential Manager operations. It uses the documented
`Microsoft.ApiManagement/service/authorizationProviders` ARM API, not
`authorizationServers` or the developer portal's `identityProviders`.

The request sequence is equivalent to:

```powershell
$collectionUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName/authorizationProviders?api-version=2024-05-01"
$providerUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ApiManagement/service/$ApimName/authorizationProviders/${ProviderName}?api-version=2024-05-01"

# Read existing providers (the script also follows pagination).
az rest --method get --url $collectionUrl --subscription $SubscriptionId --output json

# Create using the temporary JSON payload prepared by the script.
az rest --method put --url $providerUrl --subscription $SubscriptionId `
    --headers "Content-Type=application/json" --body "@$bodyPath" --output none

# For an explicitly requested update, also send the documented If-Match header.
az rest --method put --url $providerUrl --subscription $SubscriptionId `
    --headers "Content-Type=application/json" "If-Match=*" `
    --body "@$bodyPath" --output none
```

These snippets describe the calls; run the script for validation, secret
handling, read-back verification and persistence. The request body places
`displayName`, `identityProvider` and `oauth2` under `properties`;
`redirectUrl` and `grantTypes` under `oauth2`; and all seven authorization
settings (including the secret) under `grantTypes.authorizationCode`.
The identity-provider identifier and field names were also confirmed by a
read-only inspection of the working provider.

## Reruns, updates and outputs

- If no provider exists, create it, then verify its public settings with up to
  four reads (waiting 2, 4 and 8 seconds between unsuccessful reads).
- If public settings match, reuse it without a write. Scope order and whitespace
  do not count as differences.
- If settings differ, stop and list **field names only**. No Azure settings are
  changed unless you explicitly use `-UpdateExisting`.
- Azure does not return the client secret on reads. Matching public settings
  do **not** verify the secret. To rotate credentials, update the saved
  registration and run:

  ```powershell
  .\pre-requisites\3.Configure-APIM-Credential-Provider\Configure-ApimCredentialProvider.ps1 -UpdateExisting
  ```

  This writes the saved secret even when public settings match. It updates the
  provider in place, without deleting it; changing credentials or scopes may
  require existing connections to be authorized again.
- Successful verification saves `AZURE_APIM_CREDENTIAL_PROVIDER_NAME` and
  `AZURE_APIM_CREDENTIAL_PROVIDER_ID`, plus the resolved target inputs.
  Other prerequisites' values are preserved.
- The provider ID is cleared before Azure requests so a failed run does not
  leave a stale success indicator. Failed validation before requests leaves
  configuration unchanged.
- If a write succeeds but verification or local saving fails, fix the problem
  and rerun. Do not assume the provider is absent or create a different name.
- Run prerequisites sequentially. Do not edit the provider concurrently with
  this script: updates use `If-Match=*`, not an ETag-based concurrency check.

## Secret handling and errors

Credentials are loaded from the shared file; this script never prints them.
The secret is not passed on the CLI command line. For a write, a UTF-8 JSON
request file named `.env.<random>.request.json` is created beside the selected
configuration file and removed in `finally`, including on CLI failure.
The repository's `.gitignore` already ignores this pattern.

The temporary file contains plaintext credentials, just like `.env`. Restrict
access to the configuration directory, avoid shell tracing/debug logging, and
never commit either file. An abruptly terminated process can leave its request
file behind; remove that specific leftover after ensuring the run has stopped.

CLI failures report the operation, exit code and Azure error code when available.
Raw CLI output is withheld because service validation errors can echo the
request body. Check login/tenant, subscription access, caller permissions, saved
URLs and the APIM provider in the portal. After prerequisite 2, RBAC propagation
can take several minutes. The script stops rather than treating a failed read
as a missing provider.

On Windows, the script adds literal quotes around request URLs when using
`az.cmd` or another batch launcher. This keeps `&` in Azure pagination links
inside the URL instead of letting `cmd.exe` interpret it as a command separator.
A command-shell parsing failure is reported separately from an Azure API error.

## References

- [Credential provider settings](https://learn.microsoft.com/azure/api-management/credentials-configure-common-providers)
- [Create or update an authorization provider](https://learn.microsoft.com/rest/api/apimanagement/authorization-provider/create-or-update?view=rest-apimanagement-2024-05-01)
- [List authorization providers](https://learn.microsoft.com/rest/api/apimanagement/authorization-provider/list-by-service?view=rest-apimanagement-2024-05-01)
