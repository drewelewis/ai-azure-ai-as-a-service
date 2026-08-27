// Bicep: Deploy 2 Azure AI Foundry Accounts (non-hub architecture)
//
// NOTE: The ML Workspace Hub resource type is deprecated.
//       The current Foundry resource is Microsoft.CognitiveServices/accounts
//       with kind: 'AIServices' (S0 SKU — only supported tier).
//
// This template creates:
//   - 2 Foundry accounts (East US primary, West US secondary)
//     aligned with the inline APIM failover policy
//   - A configurable portfolio of chat and embedding deployments on each account

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Prefix for resource names (e.g. "contoso")')
param accountPrefix string = 'foundry'

@description('Primary region — must match APIM circuit breaker primaryBackend')
param primaryLocation string = 'eastus'

@description('Secondary region — must match APIM circuit breaker secondaryBackend')
param secondaryLocation string = 'westus'

@description('Model portfolio deployed identically to both regions. Each item supplies deployment/model identity, SKU, regional capacities, capability, and product tiers.')
@minLength(5)
param modelDeployments array

@description('Resource ID of the VNet to link the private DNS zone to. Required when privateEndpointSubnetId is set.')
param vnetResourceId string = ''

@description('Resource ID of the private endpoint subnet (snet-private-endpoints). Leave empty to skip private endpoint creation.')
param privateEndpointSubnetId string = ''

// ---------------------------------------------------------------------------
// Foundry Account 1 — Primary (East US)
// ---------------------------------------------------------------------------

resource foundry1 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${accountPrefix}-primary'
  location: primaryLocation
  kind: 'AIServices'
  sku: {
    name: 'S0'  // Only supported tier for AIServices
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Disabled'  // Traffic via APIM / private endpoints only
    disableLocalAuth: true           // Entra ID / managed identity auth only
    customSubDomainName: '${accountPrefix}-primary'
  }
}

@batchSize(1)
resource primaryModelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [for model in modelDeployments: {
  parent: foundry1
  name: model.deploymentName
  sku: {
    name: model.skuName
    capacity: model.primaryCapacity
  }
  properties: {
    model: {
      format: model.format
      name: model.modelName
      version: model.version
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}]

// ---------------------------------------------------------------------------
// Foundry Account 2 — Secondary (West US)
// ---------------------------------------------------------------------------

resource foundry2 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${accountPrefix}-secondary'
  location: secondaryLocation
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    customSubDomainName: '${accountPrefix}-secondary'
  }
}

@batchSize(1)
resource secondaryModelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [for model in modelDeployments: {
  parent: foundry2
  name: model.deploymentName
  sku: {
    name: model.skuName
    capacity: model.secondaryCapacity
  }
  properties: {
    model: {
      format: model.format
      name: model.modelName
      version: model.version
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}]

// ---------------------------------------------------------------------------
// Private Endpoints + Private DNS
//
// Both Foundry accounts have publicNetworkAccess: 'Disabled'.
// Private endpoints give APIM (VNet-internal) a private IP for each account.
//
// DNS resolution chain:
//   contoso-foundry-primary.cognitiveservices.azure.com
//     → CNAME → contoso-foundry-primary.privatelink.cognitiveservices.azure.com
//     → A     → 10.100.5.x (private endpoint NIC in snet-private-endpoints)
//
// Cross-region PE: pe-secondary PE NIC is in EastUS VNet but routes to WestUS
// Foundry account via Azure backbone — fully supported for Cognitive Services.
// ---------------------------------------------------------------------------

var deployPrivateEndpoints = !empty(privateEndpointSubnetId)

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (deployPrivateEndpoints) {
  name: 'privatelink.cognitiveservices.azure.com'
  location: 'global'
  properties: {}
}

resource privateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (deployPrivateEndpoints) {
  parent: privateDnsZone
  name: 'link-foundry-dns-to-vnet'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnetResourceId
    }
    registrationEnabled: false
  }
}

// Private endpoint for primary Foundry (EastUS)
resource pe1 'Microsoft.Network/privateEndpoints@2023-05-01' = if (deployPrivateEndpoints) {
  name: 'pe-${accountPrefix}-primary'
  location: primaryLocation
  // Must wait for ALL model deployments to complete before creating the PE.
  // Model deployments put the account in 'Accepted' state; PE creation fails if
  // the account is not in 'Succeeded' state.
  dependsOn: [primaryModelDeployments]
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${accountPrefix}-primary'
        properties: {
          privateLinkServiceId: foundry1.id
          groupIds: ['account']
        }
      }
    ]
  }
}

resource pe1DnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = if (deployPrivateEndpoints) {
  parent: pe1
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-cognitiveservices'
        properties: {
          privateDnsZoneId: deployPrivateEndpoints ? privateDnsZone.id : ''
        }
      }
    ]
  }
}

// Private endpoint for secondary Foundry (WestUS resource, PE NIC in primary VNet / EastUS)
// Cross-region private endpoints are supported for Cognitive Services.
resource pe2 'Microsoft.Network/privateEndpoints@2023-05-01' = if (deployPrivateEndpoints) {
  name: 'pe-${accountPrefix}-secondary'
  location: primaryLocation  // PE location = VNet region, not the target resource region
  dependsOn: [secondaryModelDeployments]
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${accountPrefix}-secondary'
        properties: {
          privateLinkServiceId: foundry2.id
          groupIds: ['account']
        }
      }
    ]
  }
}

resource pe2DnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = if (deployPrivateEndpoints) {
  parent: pe2
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-cognitiveservices'
        properties: {
          privateDnsZoneId: deployPrivateEndpoints ? privateDnsZone.id : ''
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output foundry1Endpoint string = foundry1.properties.endpoint
output foundry1ResourceId string = foundry1.id
output foundry1PrincipalId string = foundry1.identity.principalId

output foundry2Endpoint string = foundry2.properties.endpoint
output foundry2ResourceId string = foundry2.id
output foundry2PrincipalId string = foundry2.identity.principalId
