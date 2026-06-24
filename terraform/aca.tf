# -----------------------------------------------------------------------------
# Log Analytics Workspace (required by ACA Environment)
# -----------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "orders" {
  name                = "log-orders-dev"
  resource_group_name = azurerm_resource_group.orders.name
  location            = azurerm_resource_group.orders.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    environment = "dev"
    project     = "orders-platform"
  }
}

# -----------------------------------------------------------------------------
# Azure Container Apps Environment
# -----------------------------------------------------------------------------
resource "azurerm_container_app_environment" "orders" {
  name                       = var.aca_environment_name
  resource_group_name        = azurerm_resource_group.orders.name
  location                   = azurerm_resource_group.orders.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.orders.id

  tags = {
    environment = "dev"
    project     = "orders-platform"
  }
}

# -----------------------------------------------------------------------------
# Azure Container App
# -----------------------------------------------------------------------------
resource "azurerm_container_app" "orders" {
  name                         = var.container_app_name
  container_app_environment_id = azurerm_container_app_environment.orders.id
  resource_group_name          = azurerm_resource_group.orders.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.orders_service.id]
  }

  registry {
    server   = azurerm_container_registry.orders.login_server
    identity = azurerm_user_assigned_identity.orders_service.id
  }

  ingress {
    external_enabled = true
    target_port      = var.container_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 3

    container {
      name   = "orders-service"
      image  = var.container_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "POSTGRES_HOST"
        value = "${var.postgres_server_name}.postgres.database.azure.com"
      }

      env {
        name  = "POSTGRES_DB"
        value = var.postgres_db_name
      }

      env {
        name  = "POSTGRES_MI_USER"
        value = var.managed_identity_name
      }

      liveness_probe {
        transport        = "HTTP"
        path             = "/actuator/health/liveness"
        port             = var.container_port
        initial_delay    = 30
        interval_seconds = 30
      }

      readiness_probe {
        transport        = "HTTP"
        path             = "/actuator/health/readiness"
        port             = var.container_port
        initial_delay    = 20
        interval_seconds = 10
      }
    }
  }

  tags = {
    environment = "dev"
    project     = "orders-platform"
  }
}