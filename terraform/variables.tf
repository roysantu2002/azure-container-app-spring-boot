variable "subscription_id" {
  description = "Azure Subscription ID"
  type        = string
}

variable "tenant_id" {
  description = "Azure Tenant ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
}

variable "acr_name" {
  description = "Azure Container Registry name"
  type        = string
}

variable "managed_identity_name" {
  description = "User-Assigned Managed Identity name"
  type        = string
}

variable "postgres_server_name" {
  description = "PostgreSQL Flexible Server name (without .postgres.database.azure.com)"
  type        = string
}

variable "postgres_sku" {
  description = "PostgreSQL Flexible Server SKU"
  type        = string
  default     = "B_Standard_B2ms"
}

variable "postgres_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "postgres_storage_mb" {
  description = "PostgreSQL storage in MB"
  type        = number
  default     = 32768
}

variable "postgres_db_name" {
  description = "Name of the orders database"
  type        = string
}

variable "aca_environment_name" {
  description = "Azure Container Apps Environment name"
  type        = string
}

variable "container_app_name" {
  description = "Azure Container App name"
  type        = string
}

variable "container_image" {
  description = "Initial container image (updated by CI/CD later)"
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "container_port" {
  description = "Container port the app listens on"
  type        = number
  default     = 8080
}

variable "eventhub_namespace_name" {
  description = "Azure Event Hubs namespace name"
  type        = string
}

variable "spring_profiles_active" {
  description = "Spring Boot active profile (dev, staging, prod)"
  type        = string
  default     = "dev"
}