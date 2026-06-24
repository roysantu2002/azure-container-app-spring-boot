# -------------------------------------------------------
# Dev Environment — orders-platform
# -------------------------------------------------------
# These values are reused by both the infra workflow
# (terraform apply) and the image build/deploy workflow.
# -------------------------------------------------------

subscription_id       = "0bb4f66b-be3a-4331-941c-fd6c8c0a3eef"
tenant_id             = "f5666466-d48d-4b60-a921-7ebad0f1d5fc"
resource_group_name   = "rg-orders-dev"
location              = "Canada Central"

# Container Registry
acr_name              = "acrordersdev"

# Managed Identity
managed_identity_name = "orders-service-identity"

# PostgreSQL
postgres_server_name  = "pg-orders-dev"
postgres_db_name      = "ordersdb"

# Container Apps
aca_environment_name  = "managedEnvironment-rgordersdev-a29a"
container_app_name    = "acrordersapp"