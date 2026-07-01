variable "prefix" {
  description = "Short prefix for all resource names (lowercase alphanumeric, max 8 chars)"
  type        = string
  default     = "capdemo"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "rg-container-apps-demo"
}