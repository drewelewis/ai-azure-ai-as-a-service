// main.bicep — azd entry point
// Orchestrates all infrastructure modules.
//
// `azd provision` creates EVERYTHING — no pre-existing resources required.
//
// Provision order:
//   1. networking          (VNet + subnets)
//   2. supportingInfra     (Log Analytics + Key Vault)
//   3. foundryAccounts     (2x AIServices — outputs feed apim-gateway)
//   4. apimGateway         (depends on foundry + networking + supportingInfra outputs)
//   5. apimSubscriptions   (catalog-driven LOB use-case subscriptions)
//   6. appGwPrimaryIdentity (UAMI + Key Vault Certificate User RBAC)
//   7. appGwCertificate     (default self-signed TLS certificate secret)
//   8. wafAppGwPrimary      (East US — always deployed)
//   9. foundryApimRbac      (Cognitive Services User for APIM identity)

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Parameters — all have defaults so `azd provision` works without prompts.
// Override via `azd env set <NAME> <value>` before provisioning.
// ---------------------------------------------------------------------------

@description('Primary Azure region — resource group, APIM, networking, and supporting infra')
@allowed([
  'eastus'
  'eastus2'
  'westus'
  'westus2'
  'westus3'
  'centralus'
  'northcentralus'
  'southcentralus'
  'uksouth'
  'ukwest'
  'northeurope'
  'westeurope'
  'francecentral'
  'germanywestcentral'
  'norwayeast'
  'swedencentral'
  'switzerlandnorth'
  'australiaeast'
  'japaneast'
  'koreacentral'
  'southeastasia'
  'eastasia'
  'canadacentral'
  'brazilsouth'
])
param location string = 'eastus'

@description('Secondary Azure region for the mirrored Foundry failover account')
@allowed([
  'eastus'
  'eastus2'
  'westus'
  'westus2'
  'westus3'
  'centralus'
  'northcentralus'
  'southcentralus'
  'uksouth'
  'ukwest'
  'northeurope'
  'westeurope'
  'francecentral'
  'germanywestcentral'
  'norwayeast'
  'swedencentral'
  'switzerlandnorth'
  'australiaeast'
  'japaneast'
  'koreacentral'
  'southeastasia'
  'eastasia'
  'canadacentral'
  'brazilsouth'
])
param secondaryLocation string = 'westus'

@description('Environment tag — controls resource naming (e.g. dev, staging, prod, or your azd env name)')
param environment string = 'dev'

@description('Short prefix used in all resource names, e.g. "contoso" -> apim name becomes "contoso-ai"')
param companyPrefix string = 'contoso'

@description('Set to true only if your account has Owner or User Access Administrator on the subscription. Enables declared platform role assignments. Can be set after provisioning by someone with the right permissions.')
param deployRbac bool = true

// ---------------------------------------------------------------------------
// App Gateway WAF (HTTPS termination layer in front of APIM)
// The certificate-less bootstrap pass creates Key Vault and the base platform.
// The post-provision hook then creates the certificate and runs a second pass,
// which deploys App Gateway with its required HTTPS listener.
// ---------------------------------------------------------------------------

@secure()
@description('Use __GENERATE__ or blank to create a self-signed certificate in Key Vault, or provide a CA-signed certificate secret ID. Format: https://<kv>.vault.azure.net/secrets/<name>/<version>')
param sslCertKeyVaultSecretId string = ''

@secure()
@description('Base64-encoded passwordless PFX generated once per azd environment when sslCertKeyVaultSecretId is __GENERATE__.')
param generatedSslCertificatePfx string = ''

@description('Forces idempotent data-plane deployment steps to verify their declared state on each provision.')
param deploymentStamp string = utcNow()

// One deterministic suffix for every globally scoped name. Including tenant,
// subscription, environment, and company prevents collisions across customers
// and parallel environments while keeping repeat deployments idempotent.
var globalNameSuffix = uniqueString(tenant().tenantId, subscription().subscriptionId, environment, companyPrefix)
var compactPrefix = take(toLower(replace(companyPrefix, '-', '')), 6)
var modelDeployments = loadJsonContent('../model-portfolio.json')
var apimSubscriptionCatalog = loadJsonContent('../subscriptions/catalog.json')
var bronzeModelDeploymentNames = map(filter(modelDeployments, model => contains(model.tiers, 'bronze')), model => model.deploymentName)
var silverModelDeploymentNames = map(filter(modelDeployments, model => contains(model.tiers, 'silver')), model => model.deploymentName)
var generateSslCertificate = empty(sslCertKeyVaultSecretId) || sslCertKeyVaultSecretId == '__GENERATE__'

// ---------------------------------------------------------------------------
// Resource group
// ---------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: 'rg-${companyPrefix}-ai-platform-${environment}'
  location: location
  tags: {
    environment: environment
    managedBy: 'azd'
    purpose: 'ai-as-a-service-platform'
    // Required: azd uses this tag to identify which resource group belongs to this environment
    'azd-env-name': environment
  }
}

// ---------------------------------------------------------------------------
// Module 1: Networking (VNet + subnets)
// Created first — APIM and App Gateway both depend on this VNet.
// ---------------------------------------------------------------------------

module networking 'networking.bicep' = {
  name: 'networking'
  scope: rg
  params: {
    location: location
    prefix: companyPrefix
    tags: {
      environment: environment
      managedBy: 'azd'
    }
  }
}

// ---------------------------------------------------------------------------
// Module 2: Supporting infrastructure (Log Analytics Workspace + Key Vault)
// Created early so APIM can reference workspace ID and App GW can use the KV.
// ---------------------------------------------------------------------------

module supportingInfra 'supporting-infra.bicep' = {
  name: 'supporting-infra'
  scope: rg
  params: {
    location: location
    prefix: companyPrefix
    environment: environment
    keyVaultName: 'kv-${compactPrefix}-${globalNameSuffix}'
    vnetResourceId: networking.outputs.vnetId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    deployRbac: deployRbac
    certificateReaderObjectId: deployingUserObjectId
    tags: {
      environment: environment
      managedBy: 'azd'
    }
  }
}

// ---------------------------------------------------------------------------
// Module 3: Foundry Accounts (2 × AIServices — primary East US, secondary West US)
// Hub workspaces are deprecated; Foundry now uses CognitiveServices/accounts.
// Deployed BEFORE apimGateway so its endpoint outputs can be passed in.
// ---------------------------------------------------------------------------

module foundryAccounts 'foundry-hub-project.bicep' = {
  name: 'foundry-accounts'
  scope: rg
  params: {
    accountPrefix: '${take(companyPrefix, 12)}-foundry-${globalNameSuffix}'
    primaryLocation: location
    secondaryLocation: secondaryLocation
    modelDeployments: modelDeployments
    vnetResourceId: networking.outputs.vnetId
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
  }
}

// ---------------------------------------------------------------------------
// Module 4: APIM Gateway
// Depends on foundryAccounts (endpoints), networking (VNet), supportingInfra (Log Analytics).
// ---------------------------------------------------------------------------

// APIM service names are GLOBALLY unique (they become {name}.azure-api.net).
var apimName = 'apim-${take(companyPrefix, 12)}-${take(environment, 8)}-${globalNameSuffix}'
// App Gateway PIP DNS labels are globally unique per region.
var appGwDnsLabel = toLower('${take(companyPrefix, 12)}-ai-gw-${take(environment, 8)}-${globalNameSuffix}')

module apimGateway 'apim-gateway.bicep' = {
  name: 'apim-gateway'
  scope: rg
  params: {
    apimName: apimName
    appInsightsName: 'appi-${companyPrefix}-ai-${environment}'
    location: location
    logAnalyticsWorkspaceId: supportingInfra.outputs.logAnalyticsWorkspaceId
    vnetResourceId: networking.outputs.vnetId
    foundryPrimaryEndpoint: foundryAccounts.outputs.foundry1Endpoint
    foundrySecondaryEndpoint: foundryAccounts.outputs.foundry2Endpoint
    bronzeModelDeploymentNames: bronzeModelDeploymentNames
    silverModelDeploymentNames: silverModelDeploymentNames
  }
}

// ---------------------------------------------------------------------------
// Module 4b: APIM subscriptions
// The catalog is the single source of subscription IDs, product assignments,
// and onboarding metadata. APIM generates keys; no keys are stored in source.
// ---------------------------------------------------------------------------

module apimSubscriptions 'apim-subscriptions.bicep' = {
  name: 'apim-subscriptions'
  scope: rg
  dependsOn: [
    apimGateway
  ]
  params: {
    apimName: apimName
    location: location
    subscriptionCatalog: apimSubscriptionCatalog
    forceUpdateTag: deploymentStamp
    tags: {
      environment: environment
      managedBy: 'azd'
      purpose: 'apim-subscription-reconciliation'
    }
  }
}

// ---------------------------------------------------------------------------
// Module 5a: App Gateway WAF v2 — East US (Primary)
// The default self-signed certificate is stored through the Key Vault ARM API.
// A versioned Key Vault secret URI can be supplied to use a CA-signed certificate.
// ---------------------------------------------------------------------------

module appGwPrimaryIdentity 'appgw-identity.bicep' = {
  name: 'appgw-primary-identity'
  scope: rg
  params: {
    location: location
    appGwName: 'agw-${companyPrefix}-ai-primary'
    keyVaultName: supportingInfra.outputs.keyVaultName
    tags: {
      environment: environment
      managedBy: 'azd'
      region: 'primary'
    }
  }
}

module appGwCertificate 'appgw-certificate.bicep' = if (generateSslCertificate) {
  name: 'appgw-certificate'
  scope: rg
  params: {
    keyVaultName: supportingInfra.outputs.keyVaultName
    certificateName: 'appgw-ssl-cert'
    certificatePfxBase64: generatedSslCertificatePfx
  }
}

#disable-next-line BCP318
var resolvedSslCertUri = generateSslCertificate ? appGwCertificate.outputs.certificateSecretId : sslCertKeyVaultSecretId

module wafAppGwPrimary 'waf-appgw.bicep' = {
  name: 'waf-appgw-primary'
  scope: rg
  params: {
    location: location
    appGwName: 'agw-${companyPrefix}-ai-primary'
    appGwIdentityResourceId: appGwPrimaryIdentity.outputs.identityResourceId
    domainNameLabel: appGwDnsLabel
    vnetResourceId: networking.outputs.vnetId
    appGwSubnetName: 'snet-appgw-primary'
    apimInternalIpAddress: apimGateway.outputs.apimPrivateIpAddress
    apimGatewayHostname: '${apimName}.azure-api.net'
    sslCertKeyVaultSecretId: resolvedSslCertUri
    logAnalyticsWorkspaceId: supportingInfra.outputs.logAnalyticsWorkspaceId
    tags: {
      environment: environment
      managedBy: 'azd'
      region: 'primary'
    }
  }
}

// ---------------------------------------------------------------------------
// Module 6: Foundry <-> APIM RBAC
// Grants APIM managed identity 'Cognitive Services User' on both Foundry accounts.
// Separate module to avoid circular dependency.
// ---------------------------------------------------------------------------

module foundryApimRbac 'foundry-apim-rbac.bicep' = {
  name: 'foundry-apim-rbac'
  scope: rg
  params: {
    foundry1ResourceId: foundryAccounts.outputs.foundry1ResourceId
    foundry2ResourceId: foundryAccounts.outputs.foundry2ResourceId
    apimPrincipalId: apimGateway.outputs.apimManagedIdentityPrincipalId
    deployRbac: deployRbac
  }
}

@description('Object ID of the principal running azd. Used for least-privilege certificate access during deployment.')
param deployingUserObjectId string = ''

// ---------------------------------------------------------------------------
// Module 7: Azure Monitor Workbooks
// ---------------------------------------------------------------------------

module workbooks 'workbooks.bicep' = {
  name: 'workbooks'
  scope: rg
  params: {
    location: location
    logAnalyticsWorkspaceId: supportingInfra.outputs.logAnalyticsWorkspaceId
    tags: {
      environment: environment
      managedBy: 'azd'
    }
  }
}

// ---------------------------------------------------------------------------
// Module 9: Jumpbox — Azure Container Instance (VNet-internal testing)
// Deploy with: azd env set AZURE_DEPLOY_JUMPBOX true
// Provides a Linux container inside the VNet for testing APIM (Internal mode).
// Supports ad hoc VNet-internal diagnostics. Load tests run through Azure Load Testing.
// Uses ACI (no VM SKU needed) — avoids SkuNotAvailable errors in subscriptions
// with capacity restrictions.
// ---------------------------------------------------------------------------

@description('Deploy the ACI jumpbox for VNet-internal APIM testing. Set with: azd env set AZURE_DEPLOY_JUMPBOX true')
param deployJumpbox bool = true

module jumpbox 'jumpbox.bicep' = if (deployJumpbox) {
  name: 'jumpbox'
  scope: rg
  params: {
    location: location
    prefix: companyPrefix
    vnetResourceId: networking.outputs.vnetId
    tags: {
      environment: environment
      managedBy: 'azd'
      purpose: 'vnet-testing-jumpbox'
    }
  }
}

// ---------------------------------------------------------------------------
// Module 11: Azure Load Testing
// Required by the complete-development profile and omitted by production.
// Test definitions are wired by scripts/configure-load-test.ps1.
// ---------------------------------------------------------------------------

@description('Deploy Azure Load Testing. Required by the complete-development profile and disabled by production.')
param deployLoadTest bool = true

module loadTesting 'load-testing.bicep' = if (deployLoadTest) {
  name: 'load-testing'
  scope: rg
  params: {
    location: location
    environment: environment
    loadTestName: 'lt-${take(companyPrefix, 12)}-${take(environment, 8)}-${globalNameSuffix}'
    vnetId: networking.outputs.vnetId
    tags: {
      environment: environment
      managedBy: 'azd'
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs surfaced to azd (available via `azd env get-values`)
// ---------------------------------------------------------------------------

output APIM_GATEWAY_URL string = apimGateway.outputs.apimGatewayUrl
output APIM_PRINCIPAL_ID string = apimGateway.outputs.apimManagedIdentityPrincipalId
output APP_INSIGHTS_CONNECTION_STRING string = apimGateway.outputs.appInsightsConnectionString
output FOUNDRY_PRIMARY_ENDPOINT string = foundryAccounts.outputs.foundry1Endpoint
output FOUNDRY_SECONDARY_ENDPOINT string = foundryAccounts.outputs.foundry2Endpoint
output KEY_VAULT_NAME string = supportingInfra.outputs.keyVaultName
output KEY_VAULT_URI string = supportingInfra.outputs.keyVaultUri
output APP_GATEWAY_RESOURCE_ID string = wafAppGwPrimary.outputs.appGwResourceId
output APP_GATEWAY_FQDN string = wafAppGwPrimary.outputs.appGwFqdn
output APP_GATEWAY_IDENTITY_PRINCIPAL_ID string = appGwPrimaryIdentity.outputs.identityPrincipalId
@secure()
output APP_GATEWAY_CERTIFICATE_SECRET_ID string = resolvedSslCertUri
output LOAD_TEST_SUBNET_ID string = networking.outputs.loadTestSubnetId
