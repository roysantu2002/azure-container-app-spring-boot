# Review Checklist: Project Scope vs Terraform Coverage

> Generated from a comparison of `project-scope/azrure.md` against the Terraform files in `terraform/`.

---

## COVERED BY TERRAFORM (automated on `apply`)

| Scope Part | Requirement | Terraform Resource | File | Status |
|---|---|---|---|---|
| Prerequisites | Resource Group exists | `azurerm_resource_group.orders` | `main.tf` | COVERED |
| Prerequisites | ACR exists | `azurerm_container_registry.orders` | `acr.tf` | COVERED |
| Prerequisites | ACA Environment exists | `azurerm_container_app_environment.orders` | `aca.tf` | COVERED |
| **PART 1** | Create User-Assigned Managed Identity | `azurerm_user_assigned_identity.orders_service` | `identity.tf` | COVERED |
| **PART 2** | Create PostgreSQL Flexible Server | `azurerm_postgresql_flexible_server.orders` | `postgres.tf` | COVERED |
| **PART 2** | Entra-only auth (`password_auth_enabled = false`) | `authentication` block | `postgres.tf` | COVERED |
| **PART 2** | Version 16, Burstable B2ms, 32 GiB storage | `var.postgres_version/sku/storage_mb` | `postgres.tf` | COVERED |
| **PART 2** | Networking — Allow Azure Services firewall rule | `azurerm_postgresql_flexible_server_firewall_rule.allow_azure` | `postgres.tf` | COVERED |
| **PART 3** | Create `ordersdb` database (UTF8 / en_US.utf8) | `azurerm_postgresql_flexible_server_database.ordersdb` | `postgres.tf` | COVERED |
| **PART 5** | Attach UAMI to Container App | `identity { type = "UserAssigned" }` | `aca.tf` | COVERED |
| **PART 6** | Env vars: `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_MI_USER` | `env` blocks in container | `aca.tf` | COVERED |
| **PART 9** | Liveness probe `/actuator/health/liveness` (port 8080, delay 30s, period 30s) | `liveness_probe` block | `aca.tf` | COVERED |
| **PART 9** | Readiness probe `/actuator/health/readiness` (port 8080, delay 20s, period 10s) | `readiness_probe` block | `aca.tf` | COVERED |
| Extra | ACR Pull role for MI (so ACA can pull images) | `azurerm_role_assignment.acr_pull` | `acr.tf` | COVERED |
| Extra | ACR registry linked to Container App via MI | `registry` block | `aca.tf` | COVERED |
| Extra | Log Analytics for ACA monitoring | `azurerm_log_analytics_workspace.orders` | `aca.tf` | COVERED |
| Extra | Ingress (external, port 8080, 100% latest) | `ingress` block | `aca.tf` | COVERED |

---

## NOT COVERED BY TERRAFORM (manual steps required after `apply`)

| Scope Part | Requirement | Why Not Automated | Manual Action |
|---|---|---|---|
| **PART 2.3** | Set Entra Admin on PostgreSQL server | The `azurerm_postgresql_flexible_server_active_directory_administrator` resource requires a real Entra user/group Object ID that you must provide | Run: `az postgres flexible-server ad-admin create --server-name pg-orders-dev --resource-group rg-orders-dev --object-id <YOUR_ENTRA_USER_OBJECT_ID> --display-name <YOUR_EMAIL>` |
| **PART 4** | Create PostgreSQL role for MI via `pgaad.aad_create_principal_with_oid()` | This is a **SQL command** inside PostgreSQL — Terraform cannot run SQL statements against Postgres | Connect via `psql` with Entra token and run the SQL grants from Part 4.3 and 4.4 |
| **PART 4** | Grant schema/table permissions to MI role | Same — SQL-level grants | Run the `GRANT` statements from Part 4.3/4.4 after Flyway creates the `orders` schema |
| **PART 6** | `SPRING_PROFILES_ACTIVE` env var | Scope says "leave blank or set to a profile name" — intentionally left out since value is undefined | Add to `aca.tf` env block if you decide on a profile |
| **PART 7** | Private DNS Zone + VNet linking | Scope marks this as **Optional** (only for VNet/private access). Dev uses public access with firewall. | Only needed if you move to Option B (VNet) for prod |
| **PART 10** | Firewall rule for local dev IP | Scope marks this as **Optional**. Your local IP changes. | Add manually: `az postgres flexible-server firewall-rule create ...` |

---

## GAPS TO CONSIDER

| Gap | Impact | Recommendation |
|---|---|---|
| **No Terraform remote backend** | State file is local — lost on every GitHub Actions run | Add an `azurerm` backend with a Storage Account for state. This is critical before running in CI. |
| **No Entra Admin on PostgreSQL** | You cannot run Part 4 SQL grants without an admin | Add `azurerm_postgresql_flexible_server_active_directory_administrator` resource — you just need to supply your Entra user Object ID |
| **Terraform state storage not provisioned** | Chicken-and-egg: you need storage before Terraform can use remote state | Create a storage account manually once (or use a bootstrap script), then configure the backend |

---

## Post-Apply Manual Steps (in order)

1. **Set Entra Admin** on PostgreSQL (or add it to Terraform with your Object ID)
2. **Connect to `ordersdb`** via `psql` with Entra token
3. **Run SQL grants** from Part 4.3 + 4.4 (create MI role, grant schema permissions)
4. **Build & push** your Spring Boot image to `acrordersdev.azurecr.io` (next workflow)
5. **Update container image** in ACA to point to your real image (instead of the placeholder `quickstart:latest`)
6. **Verify** logs show `HikariCP pool initialised with AAD token`

---

## Summary Scorecard

| Category | Count |
|---|---|
| Scope items **fully automated** by Terraform | **13 of 17** |
| Scope items **not automatable** (SQL grants inside Postgres) | **2** |
| Scope items **optional** (skipped intentionally) | **2** |
| **Gaps** to address before production use | **3** (remote backend, Entra admin, state storage) |
