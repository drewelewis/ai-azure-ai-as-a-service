# Azure AI Foundry Hub and Project with App Insights
# Equivalent to infrastructure/bicep/foundry-hub-project.bicep

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.75"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.9"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

data "azurerm_client_config" "current" {}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# Application Insights for tracing
resource "azurerm_application_insights" "foundry_insights" {
  name                = "${var.project_name}-insights"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  tags                = var.tags
}

# Storage Account for Foundry artifacts
resource "azurerm_storage_account" "foundry_storage" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags
}

# Key Vault for secrets
resource "azurerm_key_vault" "foundry_kv" {
  name                       = var.key_vault_name
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  tags                       = var.tags

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Get", "List", "Set", "Delete", "Purge"
    ]
  }
}

# Azure AI Search for RAG
resource "azurerm_search_service" "ai_search" {
  name                = var.search_service_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = var.search_sku
  tags                = var.tags
}

# Azure AI Foundry Hub (using azapi as native support may not exist)
resource "azapi_resource" "foundry_hub" {
  type      = "Microsoft.MachineLearningServices/workspaces@2023-10-01"
  name      = var.hub_name
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location

  body = jsonencode({
    properties = {
      description = "Central hub for AI Foundry projects"
      friendlyName = var.hub_name
      keyVault = azurerm_key_vault.foundry_kv.id
      storageAccount = azurerm_storage_account.foundry_storage.id
      applicationInsights = azurerm_application_insights.foundry_insights.id
    }
    identity = {
      type = "SystemAssigned"
    }
    kind = "Hub"
  })

  tags = var.tags
}

# Azure AI Foundry Project
resource "azapi_resource" "foundry_project" {
  type      = "Microsoft.MachineLearningServices/workspaces@2023-10-01"
  name      = var.project_name
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location

  body = jsonencode({
    properties = {
      description = "AI Foundry project for team ${var.team_name}"
      friendlyName = var.project_name
      hubResourceId = azapi_resource.foundry_hub.id
      applicationInsights = azurerm_application_insights.foundry_insights.id
    }
    identity = {
      type = "SystemAssigned"
    }
    kind = "Project"
  })

  tags = merge(var.tags, {
    team = var.team_name
  })

  depends_on = [
    azapi_resource.foundry_hub
  ]
}

# RBAC: Developer access to project
resource "azurerm_role_assignment" "developer_access" {
  for_each = toset(var.developer_object_ids)

  scope                = azapi_resource.foundry_project.id
  role_definition_name = "Cognitive Services User"
  principal_id         = each.value
}

# RBAC: Project managed identity to Key Vault
resource "azurerm_role_assignment" "project_to_kv" {
  scope                = azurerm_key_vault.foundry_kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = jsondecode(azapi_resource.foundry_project.output).identity.principalId
}

# RBAC: Project managed identity to Storage
resource "azurerm_role_assignment" "project_to_storage" {
  scope                = azurerm_storage_account.foundry_storage.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = jsondecode(azapi_resource.foundry_project.output).identity.principalId
}

# RBAC: Project managed identity to AI Search
resource "azurerm_role_assignment" "project_to_search" {
  scope                = azurerm_search_service.ai_search.id
  role_definition_name = "Search Index Data Contributor"
  principal_id         = jsondecode(azapi_resource.foundry_project.output).identity.principalId
}

# Outputs
output "project_id" {
  description = "Foundry Project ID for developers"
  value       = azapi_resource.foundry_project.id
}

output "project_endpoint" {
  description = "Foundry Project discovery endpoint"
  value       = "https://${azurerm_resource_group.rg.location}.api.azureml.ms/discovery/workspaces/${azapi_resource.foundry_project.id}"
}

output "application_insights_connection_string" {
  description = "App Insights connection string"
  value       = azurerm_application_insights.foundry_insights.connection_string
  sensitive   = true
}

output "search_service_endpoint" {
  description = "Azure AI Search endpoint for RAG"
  value       = "https://${azurerm_search_service.ai_search.name}.search.windows.net"
}

output "project_principal_id" {
  description = "Project managed identity principal ID"
  value       = jsondecode(azapi_resource.foundry_project.output).identity.principalId
}
