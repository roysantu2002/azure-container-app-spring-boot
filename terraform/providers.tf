terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-terraform-state"
    storage_account_name = "stordersdevtfstate"
    container_name       = "tfstate"
    key                  = "orders-dev.terraform.tfstate"
    use_oidc             = true
  }
}

provider "azurerm" {
  features {}

  subscription_id     = var.subscription_id
  tenant_id           = var.tenant_id
  use_oidc            = true
}