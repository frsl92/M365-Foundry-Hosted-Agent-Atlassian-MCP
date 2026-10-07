# Configure the APIM managed identity

[Configure-ApimIdentity.ps1](./Configure-ApimIdentity.ps1) validates the **system-assigned** managed identity of an existing API Management instance and grants it **API Management Service Contributor**, scoped **only to that APIM resource**.

The script does not enable an identity, create an APIM instance, or grant resource-group/subscription-wide access. A user-assigned identity alone does not satisfy this prerequisite.

## Requirements

- PowerShell and [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).
- Sign in using `az login`. This is separate from `Connect-AzAccount` used by prerequisite 1's optional Key Vault integration.
- Access to read the APIM resource and its role assignments.
- Permission to create role assignments at the APIM scope, for example **Role Based Access Control Administrator**, **User Access Administrator**, or **Owner**, subject to any assignment conditions. Contributor alone cannot grant roles.
- The APIM name, resource group name, and subscription **ID** (GUID).

The requested role can manage the APIM service and its APIs. It does not grant permission to create further role assignments.

## Run

From the repository root:

```powershell
az login

.\pre-requisites\2.Configure-APIM-Identity\Configure-ApimIdentity.ps1 `
    -ApimName "my-apim" `
    -ResourceGroupName "my-rg" `
    -SubscriptionId "11111111-1111-1111-1111-111111111111"
```

Alternatively, set the inputs in the root `.env`:

```dotenv
AZURE_APIM_NAME="my-apim"
AZURE_RESOURCE_GROUP_NAME="my-rg"
AZURE_SUBSCRIPTION_ID="11111111-1111-1111-1111-111111111111"
```

Then run without parameters:

```powershell
.\pre-requisites\2.Configure-APIM-Identity\Configure-ApimIdentity.ps1
```

An APIM name saved by prerequisite 1 is reused. Explicit parameters override saved inputs. All three inputs must be present; the script does not fall back to the Azure CLI's default subscription or resource group.

| Parameter | Shared configuration key |
| --- | --- |
| `-ApimName` | `AZURE_APIM_NAME` |
| `-ResourceGroupName` | `AZURE_RESOURCE_GROUP_NAME` |
| `-SubscriptionId` | `AZURE_SUBSCRIPTION_ID` |
| `-EnvFile` | Not saved; optional alternative configuration file |

The default `.env` is resolved relative to the repository, regardless of the current directory. Relative `-EnvFile` paths are resolved against the current PowerShell directory. Custom configuration files must also be kept out of source control.

## If the identity is disabled

The script saves the checked resource details, records `AZURE_APIM_IDENTITY_ENABLED="false"`, clears stale identity/assignment IDs, and stops with instructions:

1. Open the APIM instance in the Azure portal.
2. Select **Security > Managed identities**.
3. On **System assigned**, set **Status** to **On** and select **Save**.
4. Wait for the update to complete, then rerun the script.

If the identity is enabled but its principal or tenant ID is not yet available, the script stops without assigning a role and asks you to wait and rerun.

## Saved outputs

| Key | Meaning |
| --- | --- |
| `AZURE_APIM_RESOURCE_ID` | Validated APIM resource ID; also the role-assignment scope |
| `AZURE_APIM_IDENTITY_ENABLED` | Whether the system-assigned identity is enabled (`true` or `false`) |
| `AZURE_APIM_IDENTITY_PRINCIPAL_ID` | Managed identity's Entra object/principal ID, not an application/client ID |
| `AZURE_APIM_IDENTITY_TENANT_ID` | Managed identity's Entra tenant ID |
| `AZURE_APIM_CONTRIBUTOR_ROLE_ASSIGNMENT_ID` | Verified, unconditional contributor role assignment at the exact APIM scope |

Identity details and resolved inputs are saved **before** role assignment, preserving values from other prerequisites. The saved assignment ID is cleared before each RBAC check and is populated only after verification, so failures do not leave a stale success indicator.

The built-in role ID is `312a565d-c81f-4fd8-895a-4e21e48d571c`. Role creation uses the identity's object ID and `ServicePrincipal` type; no Microsoft Graph lookup is required.

## Reruns and errors

- Reruns reread the live APIM identity and reuse an existing matching assignment. No force switch is needed.
- An assignment to another principal, another role, a parent scope, or a conditional assignment does not count as the required exact assignment.
- Failed Azure CLI operations stop the script and surface an error. If assignment fails, the validated identity details remain available in `.env`.
- Role creation is verified with bounded read retries. If it is not yet visible, wait and rerun rather than assuming success.
- RBAC permission propagation may take several minutes after the assignment is visible.
- If local saving fails after Azure created the assignment, fix file access and rerun; the existing assignment will be detected.
- Run prerequisites sequentially, not concurrently.

## Infrastructure-as-code equivalent

For reference, the role-assignment portion can also be expressed in Bicep at resource-group deployment scope. This is not executed by the script and assumes the system-assigned identity is already enabled:

```bicep
param apimName string

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

var roleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '312a565d-c81f-4fd8-895a-4e21e48d571c')

resource contributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(apim.id, apim.identity.principalId, roleId)
  scope: apim
  properties: {
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleId
  }
}
```

Use one provisioning approach for the assignment; do not deploy this separately over an assignment created by the script.

## References

- [APIM managed identities and activation instructions](https://learn.microsoft.com/azure/api-management/api-management-howto-use-managed-service-identity)
- [API Management Service Contributor role](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/integration#api-management-service-contributor)
- [Azure CLI role assignment commands](https://learn.microsoft.com/cli/azure/role/assignment)
