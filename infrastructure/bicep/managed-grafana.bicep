# Azure Managed Grafana with LOB Folder Isolation
# Provides portal-less access to telemetry for developers

param location string = resourceGroup().location
param grafanaName string = 'grafana-ai-gateway'
param tags object = {
  environment: 'production'
  purpose: 'developer-observability'
}

// Managed Grafana Instance
resource managedGrafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: grafanaName
  location: location
  tags: tags
  sku: {
    name: 'Standard'  // Supports Entra ID SSO, folder permissions
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Enabled'
    apiKey: 'Enabled'
    deterministicOutboundIP: 'Enabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: []
    }
  }
}

// RBAC: Grafana Admin role to IT team
param itTeamObjectId string

resource itAdminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedGrafana.id, itTeamObjectId, 'Admin')
  scope: managedGrafana
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41') // Grafana Admin
    principalId: itTeamObjectId
    principalType: 'Group'
  }
}

// RBAC: Grafana managed identity → Monitoring Reader on subscription
// Allows Grafana to query Application Insights, Log Analytics
resource grafanaToMonitoring 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managedGrafana.id, subscription().id, 'MonitoringReader')
  scope: subscription()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05') // Monitoring Reader
    principalId: managedGrafana.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Azure Monitor Data Source
param applicationInsightsId string

resource dataSource 'Microsoft.Dashboard/grafana/managedPrivateEndpoints@2023-09-01' = {
  parent: managedGrafana
  name: 'azure-monitor-datasource'
  properties: {
    groupIds: [
      'azuremonitor'
    ]
    privateLinkResourceId: applicationInsightsId
    privateLinkServiceConnectionState: {
      actionsRequired: 'None'
      description: 'Auto-approved'
      status: 'Approved'
    }
  }
}

// Outputs
output grafanaEndpoint string = managedGrafana.properties.endpoint
output grafanaId string = managedGrafana.id
output grafanaPrincipalId string = managedGrafana.identity.principalId

// Instructions for folder-based LOB isolation
output setupInstructions string = '''
Next Steps:
1. Log in to Grafana: ${managedGrafana.properties.endpoint}
2. Create folders for each LOB:
   - Settings → Folders → New Folder
   - Create: "Marketing", "Sales", "Engineering", etc.
3. Set folder permissions:
   - Marketing folder → Add permission → Entra ID group "AI-Project-marketing-*" → Viewer
   - Sales folder → Add permission → Entra ID group "AI-Project-sales-*" → Viewer
4. Import dashboards:
   - Upload observability/grafana/dashboards/*.json
   - Assign to appropriate LOB folders
5. Developers access via:
   - Direct URL: ${managedGrafana.properties.endpoint}
   - VS Code: Install Grafana extension
'''
