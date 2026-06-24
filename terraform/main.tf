# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "orders" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    environment = "dev"
    project     = "orders-platform"
    managed_by  = "terraform"
  }
}