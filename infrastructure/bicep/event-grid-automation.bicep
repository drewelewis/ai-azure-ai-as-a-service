# Event Grid Topic for APIM Subscription Events
# Triggered when APIM subscriptions are created/updated/deleted

param location string = resourceGroup().location
param eventGridTopicName string = 'evt-apim-subscriptions'
param tags object = {
  environment: 'production'
  purpose: 'apim-automation'
}

// Event Grid Topic
resource eventGridTopic 'Microsoft.EventGrid/topics@2023-06-01-preview' = {
  name: eventGridTopicName
  location: location
  tags: tags
  properties: {
    inputSchema: 'EventGridSchema'
    publicNetworkAccess: 'Enabled'
  }
}

// Event Grid System Topic for APIM (captures subscription events)
// Note: Requires APIM resource ID
param apimResourceId string

resource apimSystemTopic 'Microsoft.EventGrid/systemTopics@2023-06-01-preview' = {
  name: 'systopic-apim-events'
  location: location
  tags: tags
  properties: {
    source: apimResourceId
    topicType: 'Microsoft.ApiManagement.Service'
  }
}

// Storage Account for Function App
param storageAccountName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// App Service Plan for Function App
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: 'asp-apim-automation'
  location: location
  tags: tags
  sku: {
    name: 'Y1'  // Consumption plan
    tier: 'Dynamic'
  }
  properties: {}
}

// Function App for automation
param functionAppName string
param applicationInsightsConnectionString string

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(functionAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsightsConnectionString
        }
        {
          name: 'EventGridTopicEndpoint'
          value: eventGridTopic.properties.endpoint
        }
        {
          name: 'EventGridTopicKey'
          value: eventGridTopic.listKeys().key1
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

// Event Grid Subscription (APIM events → Function App)
resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-06-01-preview' = {
  parent: apimSystemTopic
  name: 'apim-subscription-created'
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionApp.id}/functions/ApimSubscriptionHandler'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.ApiManagement.SubscriptionCreated'
        'Microsoft.ApiManagement.SubscriptionUpdated'
      ]
    }
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

// RBAC: Function App managed identity → APIM Contributor
param apimResourceGroupId string

resource functionToApimRBAC 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionApp.id, apimResourceId, 'Contributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c') // Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Outputs
output eventGridTopicEndpoint string = eventGridTopic.properties.endpoint
output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output eventSubscriptionId string = eventSubscription.id
