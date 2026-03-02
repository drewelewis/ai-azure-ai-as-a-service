# Variables for Foundry Hub and Project deployment

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-foundry-projects"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "hub_name" {
  description = "Name of the Foundry Hub"
  type        = string
  validation {
    condition     = length(var.hub_name) >= 3 && length(var.hub_name) <= 33
    error_message = "Hub name must be between 3 and 33 characters"
  }
}

variable "project_name" {
  description = "Name of the Foundry Project"
  type        = string
  validation {
    condition     = length(var.project_name) >= 3 && length(var.project_name) <= 33
    error_message = "Project name must be between 3 and 33 characters"
  }
}

variable "team_name" {
  description = "Name of the team owning this project"
  type        = string
}

variable "storage_account_name" {
  description = "Storage account name for Foundry artifacts"
  type        = string
  validation {
    condition     = length(var.storage_account_name) >= 3 && length(var.storage_account_name) <= 24
    error_message = "Storage account name must be between 3 and 24 characters"
  }
}

variable "key_vault_name" {
  description = "Key Vault name for secrets"
  type        = string
  validation {
    condition     = length(var.key_vault_name) >= 3 && length(var.key_vault_name) <= 24
    error_message = "Key Vault name must be between 3 and 24 characters"
  }
}

variable "search_service_name" {
  description = "Azure AI Search service name"
  type        = string
  validation {
    condition     = length(var.search_service_name) >= 2 && length(var.search_service_name) <= 60
    error_message = "Search service name must be between 2 and 60 characters"
  }
}

variable "search_sku" {
  description = "Azure AI Search SKU"
  type        = string
  default     = "standard"
  validation {
    condition     = contains(["free", "basic", "standard", "standard2", "standard3"], var.search_sku)
    error_message = "Valid SKUs: free, basic, standard, standard2, standard3"
  }
}

variable "developer_object_ids" {
  description = "List of Entra ID object IDs for developers"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    environment = "production"
    project     = "ai-foundry"
    managedby   = "terraform"
  }
}
