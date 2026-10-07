# 7. Create Atlassian Connect and expose the external MCP

[Configure-ApimApis.ps1](./Configure-ApimApis.ps1) uses Azure CLI `az rest` for
both APIs and their policies:

| Resource | Configuration |
|---|---|
| Atlassian Connect HTTP API | Imports [Atlassian Connect.openapi.yaml](./assets/Atlassian%20Connect.openapi.yaml) |
| Connect `get-status` operation (`GET /status`) | Applies [get-status.xml](./assets/get-status.xml), including its inbound onboarding logic |
| External Atlassian MCP | Creates API type `mcp` with Streamable HTTP transport |
| MCP API-level policy | Applies [atlassian-mcp.xml](./assets/atlassian-mcp.xml) |

This is the programmatic equivalent of **Expose an existing/external MCP
server**, not **Expose a REST API as an MCP server**. Connect remains a separate
HTTP onboarding API; it is not exported as MCP tools.

## Requirements and configuration

- Complete prerequisites 5 and 6 for the selected APIM resource.
- Azure CLI signed in to the saved public-cloud subscription and tenant, with
  permission to read APIM configuration and write APIs, operations and policies,
  for example API Management Service Contributor.
- An APIM tier/gateway supporting external MCP servers and Streamable HTTP.
  Unsupported tiers/features are reported as Azure errors, not replaced with
  an HTTP API or a different MCP mode.
- Keep the supplied fragment assets and the twelve public named values from
  prerequisite 5. Referenced named values are checked against the saved values.

The backend uses **`ATLASSIAN_MCP_BASE_URL` + `ATLASSIAN_MCP_PATH`**, saved by
prerequisite 5, by default `https://mcp.atlassian.com/v2/mcp`.
`ATLASSIAN_MCP_ENDPOINT` remains the registration/discovery endpoint from
prerequisite 1 and is not changed or used as an implicit override.
The supplied MCP policy obtains the user's credential, replaces `Authorization`,
rewrites the request to that backend and removes the APIM subscription key before
forwarding it upstream.

The existing OpenAPI `servers` entry is deployment-specific. The import request
explicitly overrides its backend URL, protocols, API route and subscription-key
settings; it does not target the APIM hostname hard-coded in that source spec.

Optional first-use inputs in [.env.v1.example](../../.env.v1.example):

| Input | Default | Meaning |
|---|---|---|
| `AZURE_APIM_CONNECT_API_ID` | `atlassian-connect` | ARM API identifier |
| `AZURE_APIM_CONNECT_API_PATH` | `atlassian-connect` | Gateway route prefix |
| `AZURE_APIM_MCP_API_ID` | `atlassian-mcp` | ARM external MCP API identifier |
| `AZURE_APIM_MCP_API_PATH` | `atlassian-mcp` | Gateway route prefix |

Route prefixes exclude leading/trailing slashes and must not overlap each other.
The gateway MCP client endpoint is `/mcp`. The MCP resource declares the backend
origin as `serviceUrl` and `ATLASSIAN_MCP_PATH` as its `message` endpoint's
`uriTemplate`; backend routing is independent of the gateway route prefix.
The REST payload uses a keyed `endpoints` object (`message: { uriTemplate: ... }`),
as required by the live management contract, rather than the array shown in
some documentation examples.
This contract can omit `transportType` on read-back. Verification requires
exactly the `message` endpoint (no SSE endpoint) with the configured backend
path; any explicitly reported conflicting transport is rejected.
Default client URLs:

```text
https://<gateway>/atlassian-connect/status
https://<gateway>/atlassian-mcp/mcp
```

## Authentication

Both API definitions set `subscriptionRequired: true` and
`subscriptionKeyParameterNames.header: Ocp-Apim-Subscription-Key`. Neither is
created with anonymous/subscription-free access. The shared user-auth fragment
also checks `context.Subscription` before token validation and returns HTTP 401
when no valid subscription was resolved. This closes APIM's open-product
fallback for missing or invalid keys, without changing unrelated products.

Requests require a valid APIM subscription covering the called API. To use
one key for both APIs, use a subscription covering all APIs, or associate both
with a subscription-protected product and use that product's subscription.
These scripts do not create subscriptions, attach products, retrieve keys or
print/save subscription-key values. The standard `subscription-key` query
alternative declared in the supplied spec is retained; prefer the header to
avoid credentials in URLs.

The subscription key does **not** replace user authentication. The supplied
policies also require:

- `Authorization: Bearer <delegated APIM token>` with the expected tenant,
  audience, sign-in client and `Mcp.Invoke` scope.
- `x-teams-user-oid` and `x-teams-tenant-id` matching the validated token.
- Per-user Atlassian authorization. The Connect status endpoint can return a
  login link when consent is needed.

Bot OAuth configuration, admin consent, existing product/global policy
inheritance and end-to-end client testing remain separate. The scripts do not
alter unrelated products.

## Run from the repository root

Preview:

```powershell
.\pre-requisites\7.Create-APIM-APIandMCP\Configure-ApimApis.ps1 -WhatIf
```

Create or reuse:

```powershell
.\pre-requisites\7.Create-APIM-APIandMCP\Configure-ApimApis.ps1
```

Review conflicts before explicitly authorizing updates:

```powershell
.\pre-requisites\7.Create-APIM-APIandMCP\Configure-ApimApis.ps1 -UpdateExisting
```

Parameters `-ConnectApiId`, `-ConnectApiPath`, `-McpApiId` and `-McpApiPath`
override saved inputs. `-ApimName`, `-ResourceGroupName`, `-SubscriptionId` and
`-EnvFile` follow the earlier shared configuration conventions.
`-AssetDirectory` must contain all three named assets.
`-FragmentAssetDirectory` selects the two fragment assets used by prerequisite
6 (by default its sibling assets directory). Live fragment contents must match
them; a stale completion flag cannot bypass fragment verification.

Matching managed properties and policies are reused without ARM writes.
Conflicts require `-UpdateExisting`. An existing API of another type or a
Connect API containing unrelated operations is never replaced, even with that
switch. A missing/different saved OpenAPI fingerprint requires an explicit
reimport before the script can adopt or update an existing Connect API.
Unmanaged API description, authentication and version metadata are preserved.

External MCP requests pin **`2025-09-01-preview`**, as required by the documented
MCP management contract. Connect, named values and fragments use `2024-05-01`.
This is separate from the `arm-api-version` named value used by runtime policies.

## Read-back and saved outputs

After an approved run begins, `AZURE_APIM_APIS_CONFIGURED` is set to `false`.
The script verifies each API's properties, the imported operation route, both
policies and the subscription-key requirement before setting it to `true`.
Async resource reads are retried within a bounded window. Azure failures or
read-back mismatches stop the script; partial resources are retained for recovery.
There is no success flag on a failed or unverified run.
`-WhatIf` makes no ARM or environment writes.

ARM may omit `properties.type` for a default HTTP API; verification treats this
as HTTP only. MCP APIs must still explicitly report `type: mcp`, and missing
subscription-key settings never count as a match. If an interrupted first run
created Connect but did not save its specification fingerprint, review the
partial resources, then rerun with `-UpdateExisting` to reimport and finish.

Policy reads use Azure CLI `--output-file` and PowerShell JSON parsing. All ARM
writes also capture and discard their response bodies through `--output-file`:
`--output none` alone does not bypass Azure CLI's response decoding. This
handles BOM-prefixed APIM responses without Azure CLI's Windows console encoding
failure. Temporary response files are removed on success and failure. Request
errors identify the HTTP method and resource path without printing bodies,
credentials or query parameters.

Generated values are added below all inputs under **Generated by
7.Create-APIM-APIandMCP**, never to the example:

- `AZURE_APIM_CONNECT_API_RESOURCE_ID`
- `AZURE_APIM_CONNECT_SPEC_SHA256`
- `AZURE_APIM_CONNECT_STATUS_URL`
- `AZURE_APIM_MCP_API_RESOURCE_ID`
- `AZURE_APIM_MCP_SERVER_URL`
- `AZURE_APIM_APIS_CONFIGURED`

Successful provisioning proves configuration, not functional user consent or
live MCP delivery. Test clients with the correct key and user credentials;
also verify rejection of missing/invalid credentials before rollout.

References:
[External MCP management](https://learn.microsoft.com/en-us/azure/api-management/manage-mcp-servers-rest-api),
[Expose an existing MCP server](https://learn.microsoft.com/en-us/azure/api-management/expose-existing-mcp-server),
[API import/create contract](https://learn.microsoft.com/en-us/rest/api/apimanagement/api/create-or-update).
