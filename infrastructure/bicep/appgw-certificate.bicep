targetScope = 'resourceGroup'

param keyVaultName string
param certificateName string

@secure()
param certificatePfxBase64 string

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = {
  name: keyVaultName
}

resource certificateSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: certificateName
  properties: {
    value: certificatePfxBase64
    contentType: 'application/x-pkcs12'
    attributes: {
      enabled: true
    }
  }
}

output certificateSecretId string = '${keyVault.properties.vaultUri}secrets/${certificateSecret.name}'