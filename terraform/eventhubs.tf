# -----------------------------------------------------------------------------
# Azure Event Hubs (Kafka-compatible) — Namespace + Hub + Role Assignment
# -----------------------------------------------------------------------------
resource "azurerm_eventhub_namespace" "orders" {
  name                = var.eventhub_namespace_name
  resource_group_name = azurerm_resource_group.orders.name
  location            = azurerm_resource_group.orders.location
  sku                 = "Standard"

  tags = {
    environment = "dev"
    project     = "orders-platform"
  }
}

resource "azurerm_eventhub" "order_events" {
  name              = "order-events"
  namespace_id      = azurerm_eventhub_namespace.orders.id
  partition_count   = 2
  message_retention = 1
}

# Grant the managed identity "Azure Event Hubs Data Sender" for the deployed app
resource "azurerm_role_assignment" "eventhubs_sender" {
  scope                = azurerm_eventhub_namespace.orders.id
  role_definition_name = "Azure Event Hubs Data Sender"
  principal_id         = azurerm_user_assigned_identity.orders_service.principal_id
}
