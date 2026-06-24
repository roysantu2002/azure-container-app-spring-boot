# -----------------------------------------------------------------------------
# User-Assigned Managed Identity
# -----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "orders_service" {
  name                = var.managed_identity_name
  resource_group_name = azurerm_resource_group.orders.name
  location            = azurerm_resource_group.orders.location

  tags = {
    environment = "dev"
    project     = "orders-platform"
  }
}