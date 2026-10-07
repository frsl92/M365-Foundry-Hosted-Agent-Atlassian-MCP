# Post-requisites: bot OAuth, M365 endpoint and manual Teams upload

Run these steps after [agent deployment](../agent-deployment/README.md):

1. Configure an **Azure Active Directory v2** OAuth connection on the existing bot.
2. Configure the M365 Activity endpoint and enable the existing bot's Teams channel.
3. Customize the azd-generated app ZIP **offline**, then upload it manually in
   the **Teams admin center**.

No script registers, publishes or installs a Teams app. Toolkit/Graph automation
and its CLI/authentication requirements have been removed. The previous
validation-only step is replaced by OAuth configuration; deployment identity and
endpoint validation remains inside the Azure-changing steps.

## Configuration and requirements

Steps 1 and 2 use [the shared helpers](../common-scripts/Common.ps1) to read the
root `.env`, independently of the working directory. Use `-EnvFile` for another
configuration file. They do not modify the root environment or deploy resources.
The [root template](../.env.v1.example) groups inputs by when you first supply them;
generated deployment/APIM/app-registration outputs stay at the bottom of `.env`.

Deployment saves `AZURE_FOUNDRY_PROJECT_ENDPOINT`, `AZURE_FOUNDRY_AGENT_NAME` and
the verified `AZURE_BOT_SERVICE_RESOURCE_ID`. Steps 1 and 2 use those values and
support `-ProjectEndpoint`, `-AgentName` and `-BotServiceArmId` overrides. They
refuse bot/agent identity, tenant or messaging-endpoint mismatches.

For steps 1 and 2:

- Run `az login --tenant <tenant GUID>` in the correct Azure public-cloud tenant.
- The signed-in account needs Foundry agent read/write access and permission to
  read/configure the bot's connections/channels, such as Azure Bot Service Contributor.
- Private projects require working private DNS and project-endpoint connectivity.
- Complete prerequisite 4's administrator consent and client-secret checklist.
- Keep the root `.env` private. Never paste a real client secret into metadata,
  an example, source control or CLI diagnostics shared with other people.

Step 3 requires only PowerShell and the existing source ZIP/metadata/icons.
It does not read `.env`, contact Azure/Graph/Teams or require Node.js, `atk`,
Graph modules or any cloud login.

Commands below assume the repository root as the working directory.

## 1. Configure the Bot Service OAuth connection

[Configure-BotOAuth.ps1](./1.Configure-Bot-OAuth/Configure-BotOAuth.ps1) reuses
the deployed bot; it does not create another app registration, bot or secret.

| Portal setting | Value/source |
|---|---|
| Name | `AZURE_BOT_SERVICE_OAUTH_CONNECTION_NAME`, also injected into the agent during deployment |
| Service Provider | **Azure Active Directory v2** (`Aadv2`; provider ID discovered using Azure CLI) |
| Client id | `AUTH_CLIENT_ID` from prerequisite 4's **user sign-in app**, not the bot or API app ID |
| Client secret | `AUTH_CLIENT_SECRET`, supplied manually after prerequisite 4 |
| Token Exchange URL | Empty |
| Tenant ID | `AZURE_TENANT_ID`; must match the verified bot/CLI tenant |
| Scopes | `openid profile offline_access <APIM_SCOPE>` |

`APIM_SCOPE` is the generated `api://<your APIM API application ID>/Mcp.Invoke`;
the screenshot's application ID is not hardcoded. The secret must be its **Value**,
not Secret ID, and belong to the user sign-in app with the configured redirect
URI and delegated permission. Consent and interactive sign-in are separate from
configuration read-back.

```powershell
.\post-requisites\1.Configure-Bot-OAuth\Configure-BotOAuth.ps1 -WhatIf
.\post-requisites\1.Configure-Bot-OAuth\Configure-BotOAuth.ps1
```

The script validates the agent, bot, messaging endpoint and tenant, discovers the
Azure AD v2 provider, and lists only this bot's OAuth connections. List responses
may omit configuration fields, so an existing connection is read individually
before comparison. Matching public
settings are reused without writing. A conflict requires reviewed opt-in:

```powershell
.\post-requisites\1.Configure-Bot-OAuth\Configure-BotOAuth.ps1 -UpdateExisting
```

Use the same switch to reapply or rotate the secret. Azure does not return the
saved secret, so a no-op never claims that it matches. The write uses `az rest`
with a temporary JSON body file, not a client-secret command-line argument;
the file is removed in `finally`, including on failure. Request responses are
withheld on CLI errors. Public settings are read back with bounded polling
without retrying the write. Other OAuth connections are left unchanged.
Azure may lowercase provider parameter names and add mirrors of `clientId`,
`scopes` and a redacted `clientSecret`. Verification accepts both response forms,
checks the public mirrors for consistency and never compares the secret.
Duplicate parameters, unknown parameters and conflicting values still fail.

If an earlier run created the connection but failed read-back verification,
rerun normally first: a matching connection is reused without another write.

`-WhatIf` performs read-only Azure checks but writes neither a secret body file
nor a resource. Normal Azure-changing runs request confirmation; reviewed
automation can use `-Confirm:$false`. Completed Azure changes are not rolled
back after a later failure.

The bot connection name must match the agent handler setting already injected
by deployment. `-ConnectionName` is a temporary target override; it does not
rename the agent setting or save it into `.env`. If changing the name, update
the root input and redeploy the agent before using the new connection.

## 2. Configure the M365 endpoint and Teams channel

The existing [Enable-M365Publishing.ps1](./2.Configure-M365-Endpoint/Enable-M365Publishing.ps1)
behavior is retained:

```powershell
.\post-requisites\2.Configure-M365-Endpoint\Enable-M365Publishing.ps1 -WhatIf
.\post-requisites\2.Configure-M365-Endpoint\Enable-M365Publishing.ps1
```

It verifies the selected deployment and then:

- Enables only the agent's restricted public Activity route.
- Uses `BotServiceTenant`, replacing `BotServiceRbac` while preserving other
  authorization schemes.
- Creates/enables the existing bot's `MsTeamsChannel`, preserving its other properties.
- Reads back the settings before reporting readiness.

Other protocols, version routing, other channels, bot network settings and
Foundry account public network access remain unchanged. A matching configuration
is a no-op. This does **not** upload an app or prove end-to-end Teams delivery.

See Microsoft's [Activity endpoint configuration guide](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/publish-copilot-virtual-network).

## 3. Prepare a Teams package offline

The source defaults to [the deployment's appPackage.zip](../agent-deployment/agent/appPackage.zip).
Use the package generated for the intended deployment, not an older agent's ZIP.
Because this step is offline, it verifies internal manifest identities but cannot
prove they match currently deployed Azure resources.

Create a private metadata file from
[publish-request.example.json](./3.Prepare-Teams-Package/publish-request.example.json),
or reuse your existing metadata JSON:

```powershell
Copy-Item .\post-requisites\3.Prepare-Teams-Package\publish-request.example.json `
    .\post-requisites\3.Prepare-Teams-Package\package-metadata.local.json
```

Populate real names, descriptions and organization URLs before running:

| JSON field | Requirement |
|---|---|
| `agentDisplayName` | Required, up to 30 characters |
| `agentFullName` | Optional, up to 100 characters; defaults to display name |
| `appVersion` | Required numeric `major.minor.patch` |
| `shortDescription` / `fullDescription` | Required; up to 80 / 4,000 characters |
| `developerName` | Required, up to 32 characters |
| `developerWebsiteUrl`, `privacyUrl`, `termsOfUseUrl` | Required HTTPS URLs, no embedded credentials |
| `accentColor` | Optional `#RRGGBB`; omitted retains the source value |
| `colorIconPath` / `outlineIconPath` | Both provided, or both empty/omitted to retain source icons |

Replacement icons must be valid PNGs sized **192x192** and **32x32**, respectively.
Relative icon paths are resolved from the JSON file's directory; absolute paths
are supported. Icons replace the bytes at the source manifest's existing paths.
App ID, bot ID, permissions/scopes, web application identity, custom-engine-agent
configuration and unknown fields/assets are preserved, not configurable
through metadata.

Step 3 also ensures `validDomains` contains **`token.botframework.com`**, required
for the Bot Service OAuth **Sign in** button in Teams. Existing domains and their
order are preserved, and an existing entry is recognized case-insensitively
without adding a duplicate. Missing/empty domain arrays are populated; malformed
domain lists fail explicitly. This changes only the prepared ZIP, not the azd
source package or deployment identities. See
[Microsoft's Teams bot authentication guide](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/authentication/add-authentication).

```powershell
.\post-requisites\3.Prepare-Teams-Package\Prepare-TeamsPackage.ps1 `
    -MetadataFile .\post-requisites\3.Prepare-Teams-Package\package-metadata.local.json `
    -WhatIf

.\post-requisites\3.Prepare-Teams-Package\Prepare-TeamsPackage.ps1 `
    -MetadataFile .\post-requisites\3.Prepare-Teams-Package\package-metadata.local.json
```

`-PublishRequestFile` remains an alias for `-MetadataFile`; no publishing action
is attached to it. `-PackagePath` selects another source ZIP. Optional
`-OutputPackagePath` makes an additional copy in an existing directory.

The script:

1. Validates JSON, optional icons, source ZIP entries and internal app/bot identities.
2. Leaves the source ZIP unchanged and prepares the customized package in memory,
   including the required OAuth domain while retaining existing domains.
3. Enforces version history for the same app identity. The first package may use
   the source version; later packages must exceed all archived versions and
   never downgrade the source.
4. Locks local history, rechecks versions and writes `appPackage.<version>.zip`
   beside the script. Neither archives nor alternate destinations are overwritten.
5. Reads back manifest/assets to verify the archive before reporting the path.
6. Prints manual-upload instructions and returns `Published=false`.

`-WhatIf` does local validation only: no files, locks or cloud actions.
There is no `-Resume`, Toolkit lifecycle, catalog lookup or publication retry.
Increment the JSON version for each new package; retain archives so the local
history check remains effective. The remote Teams catalog is **not** queried:
also choose a version greater than the one already uploaded there.
For a package prepared before the OAuth-domain fix, increment `appVersion`
(for example, from `1.0.0` to `1.0.1`), rerun step 3 and use **Upload file** on
the existing app in Teams admin center. Existing archives are not rewritten.

Existing ZIPs, JSON files, icons and generated Toolkit state were preserved when
the folder was renamed to `3.Prepare-Teams-Package`. The old Toolkit state is
ignored and is no longer read or updated; its lifecycle configuration was removed.
Do not delete older archives simply to bypass version checks.

## 4. Upload the prepared ZIP manually

A **Teams administrator** uploads it for the organization:

1. Open [Teams admin center](https://admin.teams.microsoft.com).
2. Go to **Teams apps > Manage apps**.
3. For a new app, select **Upload new app > Upload**, or
   **Actions > Upload new app**, depending on the current UI.
4. Select the **prepared versioned ZIP**, not the original azd ZIP.
5. To update an existing app, open its app details and select **Upload file**.
6. Review the app's availability, organization-wide custom-app settings and
   applicable user access policies. Allow time for catalog/client propagation.
7. Find the app in Teams, sign in through the configured OAuth connection, and
   test an Atlassian status/tool request with a permitted user.

Preparing a ZIP does not publish an app. Admin upload does not itself prove
OAuth consent, Atlassian authorization, network connectivity or subscription-key
validity. Both APIM APIs still require `Ocp-Apim-Subscription-Key` and the supplied
user authentication. Use **Test Connection** in the bot's OAuth settings to
check actual sign-in; the script only verifies configuration.

Official guidance: [manage custom app upload and updates](https://learn.microsoft.com/en-us/microsoftteams/teams-custom-app-policies-and-settings).

## Tests

```powershell
$result = Invoke-Pester -Script .\post-requisites\Tests -PassThru
if ($result.FailedCount -gt 0) { throw 'Post-requisite tests failed.' }
```

Tests use temporary packages and mocked Azure calls. They do not mutate Azure,
contact Teams/Graph or run Toolkit automation.
