# Configure the APIM named values

[Configure-ApimNamedValues.ps1](./Configure-ApimNamedValues.ps1) creates or reuses
the **12 non-secret named values** consumed by the upcoming APIM policies. It uses
Azure CLI `az rest` against the existing APIM service; it does not create a service,
deploy policies, configure connections, grant consent or configure a Bot Service.

The masked secret entry from the example configuration and all unrelated named
values are deliberately outside this script's scope.

[Restore-ApimNamedValues.ps1](./Restore-ApimNamedValues.ps1) provides a separate,
explicit recovery path for restoring the named values saved in the repository-root
`.backup.yaml`. It does not read values from `.env`.

## Before running

- Complete prerequisites [2](../2.Configure-APIM-Identity/README.md),
  [3](../3.Configure-APIM-Credential-Provider/README.md) and
  [4](../4.Register-Entra-Applications/README.md), using the same configuration
  file and APIM instance.
- Install Azure CLI and sign in with `az login` in the correct tenant.
- The **signed-in CLI identity** needs permission to read APIM and read/write its
  named values. API Management Service Contributor at the APIM resource scope is
  sufficient. The role granted to APIM's own managed identity in step 2 does not
  give these permissions to your user.
- This script targets Azure public cloud. It validates the selected subscription's
  tenant and the live system-assigned APIM identity against the saved configuration.
- Run one configuration writer at a time; avoid simultaneous portal edits to these
  named values while running the script.

The script needs the generated application/client IDs, not a client secret.
Neither `AUTH_CLIENT_SECRET` nor Atlassian credentials are sent to APIM or printed.

## Run using the shared configuration

From the repository root:

```powershell
.\pre-requisites\5.Configure-APIM-Named-Values\Configure-ApimNamedValues.ps1
```

No parameters are needed when the earlier prerequisites populated the root `.env`.
For a separate configuration file, pass `-EnvFile` to **every** prerequisite:

```powershell
.\pre-requisites\5.Configure-APIM-Named-Values\Configure-ApimNamedValues.ps1 `
    -EnvFile 'C:\config\demo.env'
```

Explicit parameters override saved values. Blank saved optional inputs use the
defaults below; explicitly passing a blank parameter is an error.

## Named-value mapping

Names in this table are APIM **display names**, which policies reference using
`{{display-name}}`.

| Display name | Shared configuration source | Default, where applicable |
|---|---|---|
| `apim-api-client-id` | `APIM_API_CLIENT_ID` from step 4 | No default |
| `apim-mi-object-id` | `AZURE_APIM_IDENTITY_PRINCIPAL_ID` from step 2 | No default |
| `apim-name` | `AZURE_APIM_NAME` | No default |
| `arm-api-version` | `AZURE_APIM_POLICY_ARM_API_VERSION` | `2022-08-01` |
| `atlassian-credential-provider` | `AZURE_APIM_CREDENTIAL_PROVIDER_NAME` from step 3 | Uses the saved resource name, including its casing |
| `atlassian-mcp-base-url` | `ATLASSIAN_MCP_BASE_URL` | `https://mcp.atlassian.com` |
| `atlassian-mcp-path` | `ATLASSIAN_MCP_PATH` | `/v2/mcp` |
| `atlassian-post-login-redirect-url` | `ATLASSIAN_POST_LOGIN_REDIRECT_URL` | `https://www.atlassian.com/software/jira` |
| `bot-user-auth-client-id` | `AUTH_CLIENT_ID` from step 4 | No default |
| `rg` | `AZURE_RESOURCE_GROUP_NAME` | No default |
| `sub-id` | `AZURE_SUBSCRIPTION_ID` | No default |
| `tenant-id` | `AZURE_TENANT_ID` from step 4 | Must match APIM's identity tenant |

The two client-ID entries are **application/client IDs**, not application object
IDs, Enterprise application IDs or `api://` identifier URIs. The managed identity
entry is APIM's system-assigned principal ID, not either app's service principal.

The backend origin/path are independent of the step 1 registration endpoint.
The backend path defaults to `/v2/mcp`; an explicitly saved path or parameter
overrides that default. This step does not change `ATLASSIAN_MCP_ENDPOINT` or test
whether that route is supported by the backend. Verify the route when deploying
and testing policies.

`arm-api-version` is for policy calls to ARM. The script itself uses management API
version `2024-05-01` for named-value operations; these are separate settings.

## Customize the four new inputs

Edit the **step 5 input section** in `.env`, using
[.env.v1.example](../../.env.v1.example) as the input layout reference, or pass:

```powershell
.\pre-requisites\5.Configure-APIM-Named-Values\Configure-ApimNamedValues.ps1 `
    -ArmApiVersion '2022-08-01' `
    -McpBaseUrl 'https://mcp.atlassian.com' `
    -McpPath '/v2/mcp' `
    -PostLoginRedirectUrl 'https://www.atlassian.com/software/jira'
```

Use an HTTPS origin for `-McpBaseUrl` and a separate absolute path for `-McpPath`.
The redirect must be HTTPS with no embedded credentials or fragment.
These are public configuration values: do not put credentials or tokens in URLs.

`-ApimName`, `-ResourceGroupName` and `-SubscriptionId` are also supported, but must
match the earlier outputs. To change targets, first rerun the earlier prerequisites
for that target, preferably using a separate configuration file.

Resolved inputs are saved in their original input sections. The only new generated
output, at the bottom of the file, is:

```dotenv
AZURE_APIM_NAMED_VALUES_CONFIGURED="true"
```

That flag is cleared to `false` after target validation and before discovery/writes.
It becomes `true` only after all twelve values have been read back and verified.
Failures before target validation leave the existing configuration unchanged.
It is a record of the last verified run, not ongoing drift monitoring or proof of
end-to-end authentication.

## Reruns and existing values

1. Read **all pages** of named values and preflight the full set.
2. Find existing entries by display name, preserving their resource names, including
   generated GUID names. New resource names equal their display names.
3. Reuse matching public values without a write.
4. If a public value differs, stop **before any Azure writes** and list the
   conflicting names, not their values.
5. After reviewing the configuration, explicitly authorize changes:

   ```powershell
   .\pre-requisites\5.Configure-APIM-Named-Values\Configure-ApimNamedValues.ps1 -UpdateExisting
   ```

Approved updates PATCH only the value, retaining existing tags and display names.
They use `If-Match=*`, not a version-specific ETag: this is **not** a concurrent-edit
lock or an atomic transaction across twelve resources.

Secret/Key Vault-backed collisions, missing secrecy metadata, duplicate display
names, casing ambiguities, or a resource name belonging to another display name
stop the script even with `-UpdateExisting`. Resolve these manually; the script
never converts secrets to plaintext or renames unrelated entries.

No `listSecrets` requests are made. If Azure omits a managed public value from its
response, the script fails instead of retrieving secrets or assuming a match.

## Verification and recovery

Every managed value is verified with a resource GET. Delayed visibility is retried
up to four reads, with 2-, 4- and 8-second waits. A reported failed/canceled
provisioning state or permission failure stops immediately; pending provisioning
does not count as success.

If a write or verification fails, already completed writes remain in Azure. The
script does not roll back or delete resources. Fix the reported issue, allow pending
operations to settle and rerun. Discovery reuses successfully created values.
Raw Azure responses are withheld to avoid accidental disclosure; safe Azure error
codes remain in diagnostics. Temporary JSON request files are removed in `finally`.

In the Azure portal, open **API Management > your service > Named values** and
confirm the twelve display names and their non-secret values. The configured flag
does not mean that the subsequent policies or Bot OAuth configuration are ready.

### Restore from `.backup.yaml`

Preview the target and planned create/update counts without writing to Azure:

```powershell
.\pre-requisites\5.Configure-APIM-Named-Values\Restore-ApimNamedValues.ps1 -WhatIf
```

Restore interactively:

```powershell
.\pre-requisites\5.Configure-APIM-Named-Values\Restore-ApimNamedValues.ps1
```

For non-interactive execution after reviewing the preview:

```powershell
.\pre-requisites\5.Configure-APIM-Named-Values\Restore-ApimNamedValues.ps1 -Confirm:$false
```

Use `-BackupFile` to select a different file with the same structure. The script:

1. Parses only the top-level `values:` mapping and rejects duplicate, empty,
   multiline, aliased or tagged values.
2. Takes the subscription, tenant, resource group, APIM name and managed identity
   from the backup, then verifies all of them against the signed-in Azure context
   and live APIM service before any write.
3. Preflights every backup entry before asking for confirmation.
4. PATCHes existing entries so their display names, secrecy setting and tags are
   retained, and creates missing entries as non-secret values.
5. Verifies each restored entry without printing values. Existing secret values
   are not retrieved; a successful PATCH and provisioning state are verified.

Key Vault-backed entries are rejected because a plaintext backup cannot safely
restore their Key Vault metadata. Named values absent from the backup are never
deleted or changed. The script does not alter `.env`, including
`AZURE_APIM_NAMED_VALUES_CONFIGURED`. The ignored `.backup.yaml` file can contain
sensitive values; keep it local and access-controlled.

## Tests

From the repository root:

```powershell
Invoke-Pester -Script @(
    '.\pre-requisites\Tests\ApimNamedValues.Tests.ps1',
    '.\pre-requisites\Tests\RestoreApimNamedValues.Tests.ps1',
    '.\pre-requisites\Tests\Configuration.Tests.ps1'
)
```

These tests use mocked Azure calls and temporary configuration only.
