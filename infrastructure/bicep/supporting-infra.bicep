// Bicep: Supporting infrastructure — Log Analytics Workspace + Key Vault
//
// These are created first so that:
//   - APIM can send diagnostics to Log Analytics
//   - App Gateway can read the SSL certificate from Key Vault
//
// Key Vault name is derived from a stable uniqueString of the resource group ID,
// so it stays the same across repeated `azd provision` runs.

targetScope = 'resourceGroup'

param location string
param prefix string
param environment string
param keyVaultName string
param vnetResourceId string
param privateEndpointSubnetId string
param tags object = {}

@description('Object ID of the deploying principal to grant read access to the generated Key Vault certificate. Leave blank to skip.')
param certificateReaderObjectId string = ''

// ---------------------------------------------------------------------------
// Log Analytics Workspace
// ---------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-${prefix}-ai-${environment}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ---------------------------------------------------------------------------
// Key Vault
// Name is supplied by main.bicep using the shared global naming suffix.
// Standard SKU is sufficient for dev; upgrade to Premium for HSM in production.
// ---------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true     // Use RBAC rather than access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource keyVaultPrivateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: keyVaultPrivateDnsZone
  name: 'link-${prefix}-keyvault'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetResourceId
    }
  }
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-${keyVaultName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'key-vault'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource keyVaultPrivateEndpointDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'key-vault'
        properties: {
          privateDnsZoneId: keyVaultPrivateDnsZone.id
        }
      }
    ]
  }
}

@description('Set to true to assign Key Vault Certificate User to certificateReaderObjectId. Requires resource-group-scoped role assignment permission.')
param deployRbac bool = false

// Key Vault Certificate User allows the deploying principal to verify and export
// the generated certificate without granting certificate-management permissions.
var kvCertificateUserRoleId = 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'

resource kvCertificateReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployRbac && !empty(certificateReaderObjectId)) {
  scope: keyVault
  name: guid(keyVault.id, certificateReaderObjectId, kvCertificateUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvCertificateUserRoleId)
    principalId: certificateReaderObjectId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output logAnalyticsWorkspaceId string = logAnalytics.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
