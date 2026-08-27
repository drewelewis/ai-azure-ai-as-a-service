targetScope = 'resourceGroup'

param location string
param appGwName string
param keyVaultName string
param tags object = {}

var keyVaultCertificateUserRoleId = 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

resource appGwIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${appGwName}-identity'
  location: location
  tags: tags
}

resource certificateUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, appGwIdentity.id, keyVaultCertificateUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultCertificateUserRoleId)
    principalId: appGwIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output identityResourceId string = appGwIdentity.id
output identityPrincipalId string = appGwIdentity.properties.principalId