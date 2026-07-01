output "acr_name" {
  description = "ACR name (needed for build-and-push step)"
  value       = azurerm_container_registry.acr.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "app2_url" {
  description = "Publicly accessible URL for App 2"
  value       = "https://${azurerm_container_app.app2.ingress[0].fqdn}"
}

output "app2_fetch_endpoint" {
  description = "Endpoint that demonstrates App 2 calling App 1 internally"
  value       = "https://${azurerm_container_app.app2.ingress[0].fqdn}/fetch-from-app1"
}