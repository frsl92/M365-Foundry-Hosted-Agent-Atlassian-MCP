# Prerequisites

Run these steps sequentially. Scripts share the repository-root `.env` using
[common-scripts/Common.ps1](../common-scripts/Common.ps1), through the compatibility
entry point [Common.ps1](./Common.ps1); command-line parameters override saved inputs.
Use [.env.v1.example](../.env.v1.example) as a template and keep real configuration
and credentials out of source control.

Configuration saves use atomic replacement and briefly retry transient Windows
file locks. Persistent save failures stop the script; they are not ignored.

## Configuration layout

The root [.env.v1.example](../.env.v1.example) contains only user inputs for
prerequisites, deployment and post-requisites, in first-use order. It is the
source of truth for input layout in `.env`, including custom `-EnvFile` files.
Deployment has its own group between prerequisite 7 and post-requisite 1;
do not overwrite an existing environment with a template.

- **Inputs first used by each script:** group each input under the first
  prerequisite that needs it. Later prerequisites reuse that key without
  duplicating it. Optional inputs and overrides belong in these sections too.
- **Script-generated values at the bottom:** the shared helper adds outputs
  below all input sections, grouped by the script that creates them. They do
  not appear in the example. An output consumed by a later prerequisite stays
  here, rather than becoming a duplicate input.
- An input that a script saves back (for example, the APIM name or subscription)
  remains an input; saving it does not make it a generated output.

Every `Update-PrerequisiteEnv` save applies the template's ordering and headings.
Existing values are retained, absent keys are not populated from the template,
and unchanged assignments retain their original quoting and inline comments.
Custom comments and unrelated keys are preserved ahead of the managed sections.
Empty sections can appear until their script first saves values.

**For every future prerequisite or post-requisite:** add new user inputs once,
under the first script that needs them in the template. Register generated root
outputs in `Get-PrerequisiteGeneratedSections` in the shared helper, not the
example. Continue using the shared helpers for reads and saves; do not append
assignments directly or introduce a second parser. Never put real values in
the template. Post-requisites do not save environment outputs. Package preparation
uses a metadata JSON and creates versioned ZIPs, not Toolkit or Graph state.

Existing-app selection in prerequisite 4 can use `-ApimApiClientId` and
`-AuthClientId`. These IDs are otherwise generated and saved at the bottom.
`AUTH_CLIENT_SECRET` is a manual input supplied after prerequisite 4;
[post-requisite 1](../post-requisites/README.md) consumes it for Bot OAuth.
Prerequisites do not consume or generate the secret.

To reorganize an existing configuration without running any prerequisite or
changing its values:

```powershell
. .\pre-requisites\Common.ps1
Update-PrerequisiteEnv -Values @{}
```

## Steps

1. [Register an Atlassian MCP client](./1.Register-Atlassian-Client/README.md):
   register the OAuth client and save its credentials and endpoints.
2. [Configure the APIM managed identity](./2.Configure-APIM-Identity/README.md):
   validate the system-assigned identity and grant API Management Service
   Contributor on the APIM resource itself.
3. [Configure the APIM credential provider](./3.Configure-APIM-Credential-Provider/README.md):
   create or reuse the Atlassian OAuth 2.1 with PKCE with DCR provider using the
   saved client registration. Connections and interactive consent are separate.
4. [Register the Entra applications](./4.Register-Entra-Applications/README.md):
   expose the APIM API's delegated `Mcp.Invoke` scope and register a dedicated
   Bot OAuth sign-in client that requests it. Create or reuse both Enterprise
   applications (service principals) required for consent. Follow the printed
   portal checklist to grant administrator consent and manually populate `AUTH_CLIENT_SECRET`
   for that sign-in app in the step 4 input section. Neither action is automated.
   Teams SSO and Bot Service configuration remain deferred.
5. [Configure the APIM named values](./5.Configure-APIM-Named-Values/README.md):
   create or reuse the twelve public policy settings using earlier outputs and
   configurable backend/redirect defaults. Matching entries are reused; changes
   require `-UpdateExisting`. Secret and unrelated entries remain untouched.
   Policies follow in steps 6 and 7; end-to-end authentication testing is separate.
6. [Create the APIM policy fragments](./6.Create-APIM-Fragments/README.md):
   deploy or reuse the supplied user-authentication and safe-error XML assets.
   All dependencies and both fragments are preflighted before writes.
7. [Create the Connect API and expose the external MCP](./7.Create-APIM-APIandMCP/README.md):
   import the OpenAPI spec, apply its `get-status` operation policy, and expose
   the external Atlassian MCP with its supplied API policy. Both require APIM
   subscription keys alongside the supplied delegated user authentication.
   MCP management pins `2025-09-01-preview`; this is not the runtime policy ARM version.

From the repository root, run the mock-based tests with Pester:

```powershell
Invoke-Pester -Script @('.\common-scripts\Tests', '.\pre-requisites\Tests')
```

The tests use temporary configuration and mocked external calls. They do not
register real clients or modify Azure resources.