# -----------------------------------------------------------------------------
# PostgreSQL Flexible Server
# -----------------------------------------------------------------------------
resource "azurerm_postgresql_flexible_server" "orders" {
  name                = var.postgres_server_name
  resource_group_name = azurerm_resource_group.orders.name
  location            = azurerm_resource_group.orders.location
  version             = var.postgres_version
  sku_name            = var.postgres_sku
  storage_mb          = var.postgres_storage_mb

  # Entra-only authentication (no password)
  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = false
    tenant_id                     = var.tenant_id
  }

  zone = "1"

  tags = {
    environment = "dev"
    project     = "orders-platform"
  }
}

# Firewall rule: Allow Azure services to connect (for ACA)
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.orders.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Orders database
resource "azurerm_postgresql_flexible_server_database" "ordersdb" {
  name      = var.postgres_db_name
  server_id = azurerm_postgresql_flexible_server.orders.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}