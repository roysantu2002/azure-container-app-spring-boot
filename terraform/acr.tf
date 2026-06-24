# -----------------------------------------------------------------------------
# Azure Container Registry
# -----------------------------------------------------------------------------
resource "azurerm_container_registry" "orders" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.orders.name
  location            = azurerm_resource_group.orders.location
  sku                 = "Basic"
  admin_enabled       = false

  tags = {
    environment = "dev"
    project     = "orders-platform"
  }
}

# Grant the Managed Identity AcrPull role so ACA can pull images
resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.orders.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.orders_service.principal_id
}