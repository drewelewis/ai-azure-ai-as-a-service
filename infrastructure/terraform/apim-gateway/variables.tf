# Variables for APIM Gateway Terraform deployment

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
  default     = "rg-ai-gateway"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus"
}

variable "apim_name" {
  description = "Name of the API Management instance"
  type        = string
  validation {
    condition     = length(var.apim_name) >= 1 && length(var.apim_name) <= 50
    error_message = "APIM name must be between 1 and 50 characters"
  }
}

variable "apim_sku" {
  description = "SKU for APIM (Standard recommended for production)"
  type        = string
  default     = "Standard_1"
  validation {
    condition     = contains(["Developer_1", "Standard_1", "Premium_1"], var.apim_sku)
    error_message = "Valid SKUs are: Developer_1, Standard_1, Premium_1"
  }
}

variable "publisher_name" {
  description = "Publisher name for APIM"
  type        = string
}

variable "publisher_email" {
  description = "Publisher email for APIM"
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.publisher_email))
    error_message = "Must be a valid email address"
  }
}

variable "azure_openai_endpoint" {
  description = "Azure OpenAI service endpoint URL"
  type        = string
  validation {
    condition     = can(regex("^https://.*\\.openai\\.azure\\.com/?$", var.azure_openai_endpoint))
    error_message = "Must be a valid Azure OpenAI endpoint"
  }
}

variable "azure_openai_key" {
  description = "Azure OpenAI API key (will be stored encrypted)"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    environment = "production"
    project     = "ai-gateway"
    managedby   = "terraform"
  }
}

variable "ai_standard_token_quota" {
  description = "Token quota per hour for AI-Standard product"
  type        = number
  default     = 100000
}

variable "ai_premium_token_quota" {
  description = "Token quota per hour for AI-Premium product"
  type        = number
  default     = 1000000
}
