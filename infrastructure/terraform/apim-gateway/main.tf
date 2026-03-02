# Azure API Management Gateway for AI Services
# Equivalent to infrastructure/bicep/apim-gateway.bicep

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
  features {}
}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# Application Insights for APIM logging
resource "azurerm_application_insights" "apim_insights" {
  name                = "${var.apim_name}-insights"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "other"
  tags                = var.tags
}

# API Management Instance (Standard tier)
resource "azurerm_api_management" "apim" {
  name                = var.apim_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = var.apim_sku

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# APIM Logger for Application Insights
resource "azurerm_api_management_logger" "apim_logger" {
  name                = "appinsights-logger"
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name

  application_insights {
    instrumentation_key = azurerm_application_insights.apim_insights.instrumentation_key
  }
}

# Azure OpenAI Backend (Primary)
resource "azurerm_api_management_backend" "azure_openai" {
  name                = "azure-openai-backend"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  protocol            = "http"
  url                 = var.azure_openai_endpoint

  credentials {
    header = {
      "api-key" = var.azure_openai_key
    }
  }
}

# AI-Standard Product (Sandbox)
resource "azurerm_api_management_product" "ai_standard" {
  product_id            = "ai-standard"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  display_name          = "AI Standard"
  description           = "Sandbox tier: GPT-4o-mini, semantic caching mandatory, low token quotas"
  subscription_required = true
  approval_required     = false
  published             = true

  # Rate limiting: 100K tokens per hour
  subscriptions_limit = 100
}

# AI-Premium Product (Production)
resource "azurerm_api_management_product" "ai_premium" {
  product_id            = "ai-premium"
  api_management_name   = azurerm_api_management.apim.name
  resource_group_name   = azurerm_resource_group.rg.name
  display_name          = "AI Premium"
  description           = "Production tier: GPT-4o/o1, Agent Service, high quotas, circuit breakers"
  subscription_required = true
  approval_required     = true
  published             = true

  subscriptions_limit = 50
}

# AI Inference API
resource "azurerm_api_management_api" "ai_inference" {
  name                = "ai-inference-api"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "AI Inference API"
  path                = "ai/inference"
  protocols           = ["https"]
  service_url         = var.azure_openai_endpoint

  subscription_key_parameter_names {
    header = "Ocp-Apim-Subscription-Key"
    query  = "subscription-key"
  }
}

# Chat Completions Operation
resource "azurerm_api_management_api_operation" "chat_completions" {
  operation_id        = "chat-completions"
  api_name            = azurerm_api_management_api.ai_inference.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
  display_name        = "Chat Completions"
  method              = "POST"
  url_template        = "/chat/completions"

  request {
    description = "Chat completion request"
  }

  response {
    status_code = 200
    description = "Successful response"
  }
}

# API-Product Association
resource "azurerm_api_management_product_api" "ai_standard_inference" {
  api_name            = azurerm_api_management_api.ai_inference.name
  product_id          = azurerm_api_management_product.ai_standard.product_id
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_api_management_product_api" "ai_premium_inference" {
  api_name            = azurerm_api_management_api.ai_inference.name
  product_id          = azurerm_api_management_product.ai_premium.product_id
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.rg.name
}

# Named Value for OpenAI Key (encrypted)
resource "azurerm_api_management_named_value" "openai_key" {
  name                = "openai-api-key"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  display_name        = "openai-api-key"
  value               = var.azure_openai_key
  secret              = true
}

# Outputs
output "apim_gateway_url" {
  description = "APIM Gateway URL for developers"
  value       = azurerm_api_management.apim.gateway_url
}

output "apim_resource_id" {
  description = "APIM Resource ID"
  value       = azurerm_api_management.apim.id
}

output "apim_principal_id" {
  description = "APIM Managed Identity Principal ID"
  value       = azurerm_api_management.apim.identity[0].principal_id
}

output "ai_standard_subscription_url" {
  description = "URL to create AI-Standard subscriptions"
  value       = "${azurerm_api_management.apim.management_api_url}/subscriptions?api-version=2021-08-01"
}

output "application_insights_id" {
  description = "Application Insights Resource ID"
  value       = azurerm_application_insights.apim_insights.id
}
