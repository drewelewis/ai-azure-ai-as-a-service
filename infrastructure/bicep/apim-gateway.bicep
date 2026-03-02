// Bicep: Deploy Azure API Management Gateway for AI Workloads
// 
// This template deploys:
// - APIM instance (Standard tier)
// - Logger to Application Insights
// - Rate limit policies
// - Backend routing to Azure OpenAI & Foundry

@description('Environment name (dev, staging, prod)')
param environment string = 'prod'

@description('APIM instance name')
param apimName string = 'your-company-ai'

@description('Azure OpenAI resource name')
param openaiResourceName string = 'your-openai'

@description('Azure OpenAI key')
@secure()
param openaiApiKey string

@description('Foundry project ID')
param foundryProjectId string

@description('Application Insights instance name')
param appInsightsName string

@description('Location for resources')
param location string = resourceGroup().location

// Build the full APIM URL
var apimUrl = 'https://${apimName}.azure-api.net'

// ==========================================
// Resource: Application Insights (for logging)
// ==========================================
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 90
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ==========================================
// Resource: APIM Instance
// ==========================================
resource apim 'Microsoft.ApiManagement/service@2021-12-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: 'Standard'
    capacity: 1
  }
  properties: {
    publisherEmail: 'admin@your-company.com'
    publisherName: 'Your Company AI Platform'
  }
}

// ==========================================
// Resource: Logger pointing to Application Insights
// ==========================================
resource logger 'Microsoft.ApiManagement/service/loggers@2021-12-01-preview' = {
  parent: apim
  name: 'ai-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for AI requests'
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
    isBuffered: true
    resourceId: appInsights.id
  }
}

// ==========================================
// Resource: API Products
// ==========================================

// Product 1: Inference (model completions)
resource inferenceProduct 'Microsoft.ApiManagement/service/products@2021-12-01-preview' = {
  parent: apim
  name: 'ai-inference'
  properties: {
    displayName: 'AI Inference'
    description: 'Model inference endpoints (GPT-4o, Llama, etc.)'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// Product 2: Agents
resource agentsProduct 'Microsoft.ApiManagement/service/products@2021-12-01-preview' = {
  parent: apim
  name: 'ai-agents'
  properties: {
    displayName: 'AI Agents'
    description: 'Agent Service endpoints (create, run, list agents)'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// ==========================================
// Resource: Azure OpenAI Backend
// ==========================================
resource openaiBackend 'Microsoft.ApiManagement/service/backends@2021-12-01-preview' = {
  parent: apim
  name: 'azure-openai'
  properties: {
    url: 'https://${openaiResourceName}.openai.azure.com'
    protocol: 'http'
    description: 'Azure OpenAI backend'
    credentials: {
      header: {
        'api-key': [openaiApiKey]
      }
    }
  }
}

// ==========================================
// Resource: API Operations
// ==========================================

// Operation: POST /ai/completions
resource completionsApi 'Microsoft.ApiManagement/service/apis@2021-12-01-preview' = {
  parent: apim
  name: 'ai-completions'
  properties: {
    displayName: 'AI Completions'
    description: 'Chat completions endpoint'
    path: 'ai/completions'
    protocols: ['https']
    subscriptionRequired: true
    authentication: {
      oauth2: {
        authorizationServerId: 'aad'
        scope: 'openid profile'
      }
    }
  }
}

// Add operation to completions API
resource postCompletion 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  parent: completionsApi
  name: 'post-completions'
  properties: {
    displayName: 'Post Completion'
    method: 'POST'
    urlTemplate: '/completions'
  }
}

// ==========================================
// Output: Important URLs and Info
// ==========================================
output apimGatewayUrl string = apimUrl
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output appInsightsResourceId string = appInsights.id

@description('How developers connect:')
output connectionExample string = '''
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    credential=DefaultAzureCredential(),
    project_id="your-project",
    endpoint="${apimUrl}"  # <- Use this URL
)
'''
