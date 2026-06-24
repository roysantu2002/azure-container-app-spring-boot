output "resource_group_name" {
  value = azurerm_resource_group.orders.name
}

output "acr_login_server" {
  value = azurerm_container_registry.orders.login_server
}

output "managed_identity_client_id" {
  value = azurerm_user_assigned_identity.orders_service.client_id
}

output "managed_identity_principal_id" {
  value = azurerm_user_assigned_identity.orders_service.principal_id
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.orders.fqdn
}

output "aca_environment_id" {
  value = azurerm_container_app_environment.orders.id
}

output "container_app_fqdn" {
  value = azurerm_container_app.orders.ingress[0].fqdn
}

output "container_app_url" {
  value = "https://${azurerm_container_app.orders.ingress[0].fqdn}"
}