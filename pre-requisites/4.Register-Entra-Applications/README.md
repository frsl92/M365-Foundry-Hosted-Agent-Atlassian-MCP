# Register the APIM API and Bot OAuth sign-in applications

[Register-EntraApplications.ps1](./Register-EntraApplications.ps1) creates or
reuses **two single-tenant Microsoft Entra app registrations** and their
**service principals (Enterprise applications)**, using Azure CLI.
It implements the APIM API registration and the registration portion of the
user-sign-in setup, not the end-to-end bot deployment.

| Registration | Configuration |
| --- | --- |
| APIM API | `AzureADMyOrg`; Application ID URI `api://<APIM_API_CLIENT_ID>`; access token version `2`; one enabled delegated scope, `Mcp.Invoke`, with **Admins only** consent; no redirect URI or application role |
| User sign-in client | `AzureADMyOrg`; Web redirect `https://token.botframework.com/.auth/web/redirect`; delegated permission to that API's `Mcp.Invoke` scope; public-client fallback and implicit grants disabled |

The API scope has consent display name
`Use the Atlassian MCP gateway as the signed-in user` and description
`Access the caller's own connection status and permitted Atlassian MCP operations.`
The client does not request Microsoft Graph `User.Read` or application permissions.

**Deferred:** client secrets/certificates, administrator consent,
Azure Bot resources and OAuth connections, Teams SSO (`access_as_user`,
Teams preauthorization and manifests), APIM policies, and agent code.
Declaring a delegated API permission **does not grant consent**. These registrations
alone do not make bot sign-in functional. The APIM API app needs no client secret
for token validation; the sign-in client will need a supported confidential-client
credential later.

The sign-in registration is **not** the bot's channel identity or the APIM managed
identity. Do not replace either with `AUTH_CLIENT_ID`.

## Requirements

- PowerShell and Azure CLI, authenticated with `az login` in the intended tenant.
- Azure public cloud. Other clouds require different endpoints and are not
  supported by this script.
- Microsoft Entra permission to create applications and their service principals,
  and read/manage the selected registrations. Tenant user-registration policy
  and app ownership apply;
  Application Developer can be suitable for creating owned registrations, while
  managing other apps can require an appropriate application administrator role.
  **Azure subscription Contributor does not grant these directory permissions.**
  For app-only automation, Microsoft Graph application permissions and ownership
  must be provisioned separately; this script never grants itself permissions.
- Saved `AZURE_SUBSCRIPTION_ID` and tenant information. `AZURE_TENANT_ID` defaults
  to prerequisite 2's `AZURE_APIM_IDENTITY_TENANT_ID`; use `-TenantId` if neither
  is saved. The selected subscription's tenant must match, and conflicting saved
  tenant values stop the script.
- The active Azure CLI account must also belong to that tenant. Entra
  `az ad app list/show` and `az ad sp list/create/show` commands use the active
  tenant and **do not accept `--subscription`**. The script checks this before
  directory lookups or saving configuration. Another active subscription in the
  same tenant is allowed.
  If the active tenant differs, explicitly select the intended subscription
  with `az account set --subscription <AZURE_SUBSCRIPTION_ID>` and rerun.
  The script never changes your default CLI account or starts login.

App registrations are tenant-level objects, not resources in the APIM resource
group. The selected subscription supplies the authentication context for Graph
REST writes; Entra CLI operations use the separately validated active tenant. The
resource group is not required for this step. Avoid changing the CLI account
while the script is running.

## Run

From the repository root, after the earlier prerequisites:

```powershell
.\pre-requisites\4.Register-Entra-Applications\Register-EntraApplications.ps1
```

Default names are `<AZURE_APIM_NAME>-gateway-api` and
`<AZURE_APIM_NAME>-user-sign-in`. To use the example names from the authentication
guide:

```powershell
.\pre-requisites\4.Register-Entra-Applications\Register-EntraApplications.ps1 `
    -ApimApiAppName "Atlassian MCP Gateway API" `
    -AuthAppName "Teams Atlassian User Sign-in"
```

Parameters override nonempty saved values, which override defaults:

| Parameter | Shared configuration | Default |
| --- | --- | --- |
| `-ApimName` | `AZURE_APIM_NAME` | Used only to derive default names |
| `-SubscriptionId` | `AZURE_SUBSCRIPTION_ID` | Required |
| `-TenantId` | `AZURE_TENANT_ID` | Saved APIM identity tenant |
| `-ApimApiAppName` | `APIM_API_APP_NAME` | `<ApimName>-gateway-api` |
| `-AuthAppName` | `AUTH_APP_NAME` | `<ApimName>-user-sign-in` |
| `-ApimApiClientId` | `APIM_API_CLIENT_ID` | Exact-name lookup, then creation if absent |
| `-AuthClientId` | `AUTH_CLIENT_ID` | Exact-name lookup, then creation if absent |
| `-AuthRedirectUri` | `AUTH_REDIRECT_URI` | Bot Framework redirect above |
| `-EnvFile` | Not saved | Repository-root `.env`, regardless of working directory |

Names must be distinct, 1-120 ASCII letters/digits/spaces/dots/underscores/hyphens,
start with a letter or digit, and have no trailing space. This restriction avoids
Windows CLI shell metacharacters. The redirect must be HTTPS with no userinfo
or fragment; override it for the documented regional Bot OAuth endpoint if needed.

To select already-created apps, provide their **application/client IDs**, not
object IDs, along with their exact display names. Incompatible apps are not
automatically reconfigured.

## Saved values and recovery

Inputs and outputs are merged into the shared ignored `.env`, preserving earlier
credentials and unrelated configuration:

| Key | Meaning |
| --- | --- |
| `AZURE_TENANT_ID` | Validated directory; corresponds to `TENANT_ID` in the guide |
| `APIM_API_CLIENT_ID` | API application ID; the `aud` expected in a v2 APIM access token |
| `APIM_API_OBJECT_ID` | Directory object ID, used for Graph updates |
| `APIM_API_SERVICE_PRINCIPAL_ID` | API's Enterprise application object ID, distinct from the app registration object ID |
| `APIM_API_IDENTIFIER_URI` | `api://<APIM_API_CLIENT_ID>` |
| `APIM_API_SCOPE_ID` | Stable GUID of the API's delegated scope |
| `APIM_SCOPE` | `api://<APIM_API_CLIENT_ID>/Mcp.Invoke` |
| `AUTH_CLIENT_ID` | Dedicated OAuth sign-in client's application ID |
| `AUTH_OBJECT_ID` | Sign-in client's directory object ID |
| `AUTH_SERVICE_PRINCIPAL_ID` | Sign-in client's Enterprise application object ID |
| `AZURE_APP_REGISTRATIONS_CONFIGURED` | `true` only after both registrations and service principals are read back and verified |

The script also saves the selected subscription, app names and redirect URI.
On successful completion, it adds `AUTH_CLIENT_SECRET=""` to the step 4
**input** section if the key is absent. This is a manually supplied credential,
not a script-generated output. An existing value is preserved on every rerun.
The script does not create, print, use or validate the secret.

- Saved/explicit client IDs take priority over name lookup. A missing or
  inaccessible saved app is an error, not permission to create a replacement.
- Name lookup includes all pages and filters exact names locally. Multiple
  matches stop the script; select IDs explicitly.
- Matching apps are reused with their existing scope GUID. Conflicting audience,
  scope, redirect, permission or other checked authentication settings stop the
  script without overwriting them. Extra Graph permissions are not removed.
- The only in-place completion is setting an **empty** API identifier URI to
  `api://<client-id>` after verifying its other settings. A nonempty, different URI
  is never replaced.
- IDs are saved immediately after creation, before dependent steps. An API-only
  partial success remains saved if client creation fails. Fix the cause and rerun.
- Service principals are looked up by **application/client ID**, never by display
  name or by the app registration's object ID. Existing principals are reused;
  missing ones are created. Each principal's object ID is saved before read-back
  verification. A partial failure can be resumed without recreating either app
  or a principal that was already created.
- Disabled, foreign-home-tenant or non-Application service principals stop the
  script instead of being modified. Failed or malformed lookups are errors, not
  permission to create a principal.
- Verification makes up to four reads, with 2/4/8-second backoff for directory
  propagation. Authentication/permission errors are not retried as missing
  applications or service principals. Create operations are not blindly retried.
- The configured flag is cleared before directory work. On failure, previously
  saved values may remain for recovery; do not interpret them as verified success.
- If creation succeeds but the response or local save is lost, inspect Entra
  before rerunning. Exact-name recovery can find matching apps, but display names
  are not unique: **run this prerequisite sequentially**, not concurrently.
- To intentionally create another pair, use another `-EnvFile`. Changing names
  alone will not bypass saved client IDs.

Graph request bodies are passed through temporary `.env.<random>.request.json`
files beside the selected configuration file and removed in `finally`. They
contain registration settings, not secrets. This naming pattern is already
ignored by the repository. Failed CLI output is withheld; errors include a
command name and service error code when available. CLI argument/usage errors
(exit code 2) are identified separately from directory permission errors.
An `unrecognized arguments: --subscription` failure from an older version of
this script occurs before the application lookup runs; use the updated script
and rerun rather than changing Entra permissions. No applications are
automatically deleted or rolled back on a later failure.

## Implementation and subsequent steps

The script uses `az account show`, `az ad app list/show`,
`az ad sp list/create/show`, and `az rest` against Microsoft Graph v1.0:

1. Validate tenant and look up both registrations before writing.
2. `POST /applications` creates the API manifest, including the scope and v2
   access-token setting.
3. `PATCH /applications/<object-id>` sets its identifier URI using the returned
   client ID. Verify the API.
4. `POST /applications` creates the Web client with `requiredResourceAccess`
   referencing the API client ID and scope GUID (`type: Scope`). Verify the client.
5. For each verified app, `az ad sp list --filter "appId eq '<client-id>'" --all`
   checks for its service principal. Only if missing,
   `az ad sp create --id <client-id>` creates it. Save the returned object ID and verify it with
   `az ad sp show --id <service-principal-object-id>`.

Unlike registration through the portal, creating an application through Microsoft
Graph requires a separate service-principal step
([Microsoft documentation](https://learn.microsoft.com/en-us/entra/identity-platform/app-objects-and-service-principals)).
These commands do **not** use `create-for-rbac` and do not create credentials,
role assignments or consent grants.

### Repairing the missing-service-principal consent error

If admin consent reports **"Your organization does not have a subscription (or
service principal) for the following API(s)"**, rerun this updated prerequisite
using the same `.env`. It reuses the registrations and scope, creates any missing
Enterprise applications and preserves your saved secret. No new Azure billing
subscription is required: the error refers to the API's tenant-local identity.

After the script succeeds, allow directory propagation, refresh the OAuth sign-in
app's **API permissions** page and retry admin consent. If it still fails, ask the
tenant administrator to confirm the directory, the API client ID targeted by the
permission and the administrator's consent permissions.

## After creation: Azure portal checklist

The script prints these steps using your actual app names, client IDs, redirect
URI and configuration file path. Run them manually before configuring Bot OAuth:

1. Open [Azure portal](https://portal.azure.com), switch to the directory matching
   `AZURE_TENANT_ID`, and go to **Microsoft Entra ID > App registrations >
   All applications**. Use the client IDs below to distinguish apps with similar
   names.
2. Open the **APIM API app** (`APIM_API_APP_NAME`, client ID `APIM_API_CLIENT_ID`).
   Under **Expose an API**, verify the Application ID URI is
   `api://<APIM_API_CLIENT_ID>` and `Mcp.Invoke` is enabled with **Admins only**
   consent. The script already configured these settings; do not add another
   scope. **This API app does not need a client secret.**
3. Open the **OAuth sign-in app** (`AUTH_APP_NAME`, client ID `AUTH_CLIENT_ID`):
   - Under **Authentication > Web**, verify the redirect URI matches
     `AUTH_REDIRECT_URI` (normally
     `https://token.botframework.com/.auth/web/redirect`). Leave implicit grants
     and public client flows disabled.
   - Under **API permissions**, verify the APIM API's `Mcp.Invoke` permission
     appears as **Delegated**. Do not add Microsoft Graph permissions.
   - Have an authorized tenant administrator select **Grant admin consent for
     \<tenant\> > Yes**. Refresh and confirm **Granted for \<tenant\>** for the
     permission. If already granted, no new grant is needed. If the action is
     unavailable or fails, ask the tenant administrator to check consent
     permissions. Both Enterprise applications now exist; for a stale
     missing-service-principal error, wait for propagation, refresh and retry.
     The script does not grant consent.
4. Still in the **OAuth sign-in app**, select **Certificates & secrets > Client
   secrets > New client secret**. Enter a description such as `Bot OAuth`,
   choose an expiration following your organization policy, and select **Add**.
   Copy the **Value**, not the **Secret ID**, immediately: it is only shown once.
   Record the expiration and plan rotation. Skip creating another secret if you
   already have a valid one saved for this app.
5. Edit the shared ignored [`.env`](../../.env), or the file passed to
   `-EnvFile`. Populate the existing key in the step 4 input section without
   adding a duplicate:

   ```dotenv
   AUTH_CLIENT_SECRET="<paste the OAuth sign-in app's client secret Value here>"
   ```

   Replace the placeholder with the real Value, keeping the surrounding quotes.
   Keep the file private; do not commit it, paste it into chat, or put the secret
   in [`.env.v1.example`](../../.env.v1.example). Rerunning the script preserves the
   value and never prints it. Merely saving a value does not verify that it is
   valid, unexpired, or belongs to the selected app.

`AZURE_APP_REGISTRATIONS_CONFIGURED=true` only means the registration settings and
service principals were verified; it does **not** mean the manual
consent/credential steps are done.
The [Bot OAuth post-requisite](../../post-requisites/README.md) uses `AUTH_CLIENT_ID`, `AZURE_TENANT_ID`,
`AUTH_CLIENT_SECRET`, and `openid profile offline_access <APIM_SCOPE>`. This step
only reserves the secret input; it does not configure a bot connection.
The Bot OAuth connection leaves Token Exchange URL empty, as in the chosen setup.

## Validation

```powershell
Invoke-Pester -Script .\pre-requisites\Tests\EntraApplications.Tests.ps1
```

Tests mock all Azure calls and use temporary configuration. They do not create
real registrations.

## References

- [Create an application with Microsoft Graph](https://learn.microsoft.com/graph/api/application-post-applications?view=graph-rest-1.0)
- [API application settings and token version](https://learn.microsoft.com/graph/api/resources/apiapplication?view=graph-rest-1.0)
- [Azure CLI application commands](https://learn.microsoft.com/cli/azure/ad/app)
- [Add a client secret in the portal](https://learn.microsoft.com/entra/identity-platform/how-to-add-credentials#add-a-client-secret)
- [Configure API permissions and grant admin consent](https://learn.microsoft.com/entra/identity-platform/quickstart-configure-app-access-web-apis)
