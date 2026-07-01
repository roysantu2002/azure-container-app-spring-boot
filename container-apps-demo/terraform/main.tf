# Unique suffix so ACR name (globally unique, alphanumeric only) doesn't clash
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

# ── Resource Group ──────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# ── Log Analytics (required by Container Apps Environment) ───────────────────
resource "azurerm_log_analytics_workspace" "law" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

# ── Container Apps Environment ───────────────────────────────────────────────
resource "azurerm_container_app_environment" "env" {
  name                       = "${var.prefix}-env"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
}

# ── Azure Container Registry ─────────────────────────────────────────────────
resource "azurerm_container_registry" "acr" {
  name                = "${var.prefix}acr${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# ── App 1 ── internal only (no public ingress) ───────────────────────────────
resource "azurerm_container_app" "app1" {
  name                         = "app-1"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  template {
    container {
      name   = "app-1"
      image  = "${azurerm_container_registry.acr.login_server}/app-1:latest"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  # Internal ingress only — app-2 reaches this via http://app-1 inside the environment
  ingress {
    allow_insecure_connections = true
    external_enabled           = false
    target_port                = 8080
    transport                  = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}

# ── App 2 ── externally accessible, calls App 1 internally ──────────────────
resource "azurerm_container_app" "app2" {
  name                         = "app-2"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  template {
    container {
      name   = "app-2"
      image  = "${azurerm_container_registry.acr.login_server}/app-2:latest"
      cpu    = 0.25
      memory = "0.5Gi"

      # Within the same environment, app-1 is reachable by its name on port 80
      env {
        name  = "APP1_URL"
        value = "http://app-1"
      }
    }
  }

  ingress {
    allow_insecure_connections = false
    external_enabled           = true
    target_port                = 8080
    transport                  = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  depends_on = [azurerm_container_app.app1]
}