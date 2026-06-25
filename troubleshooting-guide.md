# Troubleshooting Guide — Container App + PostgreSQL Managed Identity

> Straight-to-the-point guide. When your Container App fails, start here.

---

## Quick Diagnosis Flowchart

```
Container App not working?
  |
  +--> Check provisioning state
  |      |
  |      +--> "InProgress" --> WAIT. Do nothing until "Succeeded".
  |      +--> "Failed" --> Check logs (Section 1)
  |      +--> "Succeeded" --> Check app health (Section 2)
  |
  +--> App running but no DB?
  |      |
  |      +--> Check PostgreSQL connectivity (Section 3)
  |      +--> Check managed identity auth (Section 4)
  |      +--> Check grants/permissions (Section 5)
  |
  +--> Can't pull image? --> Section 6
  +--> Env vars missing? --> Section 7
```

---

## 0. First Commands to Run (Always Start Here)

```bash
# Check container app state
az containerapp show --name acrordersapp --resource-group rg-orders-dev \
  --query "{state:properties.provisioningState, image:properties.template.containers[0].image}" -o table

# Check logs (look for the FIRST error)
az containerapp logs show --name acrordersapp --resource-group rg-orders-dev --tail 100

# Check health endpoint
FQDN=$(az containerapp show --name acrordersapp --resource-group rg-orders-dev \
  --query "properties.configuration.ingress.fqdn" -o tsv)
curl -s https://$FQDN/actuator/health
```

**What to look for in logs:**
- `HikariPool-1 - Start completed` = DB connection works
- `Successfully applied X migrations` = Flyway ran OK
- `PSQLException` = PostgreSQL connection problem (go to Section 3)
- `ManagedIdentityCredential` = identity problem (go to Section 4)
- `ImagePullBackOff` or `unable to pull image` = ACR problem (go to Section 6)

---

## 1. Container App Stuck in Failed/InProgress State

### Problem: `provisioningState` shows `InProgress` or `Failed`

**Check:**
```bash
az containerapp show --name acrordersapp --resource-group rg-orders-dev \
  --query "{state:properties.provisioningState, image:properties.template.containers[0].image, \
  registries:properties.configuration.registries}" -o json
```

**If `InProgress`:** Wait. Do NOT run any update commands. Re-check every 30 seconds:
```bash
az containerapp show --name acrordersapp --resource-group rg-orders-dev \
  --query "properties.provisioningState" -o tsv
```

**If `Failed`:** Force a fresh deploy (delete + recreate):
```bash
# Delete the stuck app
az containerapp delete --name acrordersapp --resource-group rg-orders-dev --yes

# Redeploy via GitHub Actions with fresh_deploy: true
# OR manually recreate (see Section 8)
```

### Problem: `ContainerAppOperationInProgress` error

You ran an update while another operation was running. Wait for it to finish, then retry.

---

## 2. App Running But Returns Errors

### Problem: Health endpoint returns `{"status":"DOWN"}` or connection refused

**Check readiness:**
```bash
curl -s https://$FQDN/actuator/health/readiness
```

If readiness fails, the app started but can't connect to PostgreSQL. Go to Section 3.

### Problem: `502 Bad Gateway` or no response

The container is crashing on startup. Check logs:
```bash
az containerapp logs show --name acrordersapp --resource-group rg-orders-dev --tail 100
```

If you see `OOMKilled` — the container needs more memory. Current config is `1Gi`. If running out, update:
```bash
az containerapp update --name acrordersapp --resource-group rg-orders-dev \
  --cpu 1.0 --memory 2.0Gi
```

---

## 3. PostgreSQL Connection Failures

### Problem: `pg_hba.conf rejects connection for host "x.x.x.x"`

**Cause:** Firewall is blocking the Container App from reaching PostgreSQL.

**Fix — Check firewall rule:**
```bash
az postgres flexible-server firewall-rule list \
  --resource-group rg-orders-dev --server-name pg-orders-dev -o table
```

You MUST see `AllowAzureServices` with `0.0.0.0 - 0.0.0.0`. If missing:
```bash
az postgres flexible-server firewall-rule create \
  --resource-group rg-orders-dev --server-name pg-orders-dev \
  -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0
```

**IMPORTANT — Portal checkbox:** Even with the firewall rule, you may also need to verify in the Azure Portal:
1. Go to **PostgreSQL flexible server** > `pg-orders-dev`
2. Left menu > **Networking**
3. Ensure **"Allow public access from any Azure service within Azure to this server"** is checked
4. Click **Save**

This is a known gotcha — the Terraform firewall rule and the Portal checkbox are separate controls.

### Problem: `connection refused` or `could not translate host name`

**Check PostgreSQL is running:**
```bash
az postgres flexible-server show --name pg-orders-dev --resource-group rg-orders-dev \
  --query "{name:name, state:state, fqdn:fullyQualifiedDomainName}" -o table
```

State must be `Ready`. If it's `Stopped`:
```bash
az postgres flexible-server start --name pg-orders-dev --resource-group rg-orders-dev
```

**Check DNS (from Cloud Shell):**
```bash
nslookup pg-orders-dev.postgres.database.azure.com
```

### Problem: `SSL connection is required`

The JDBC URL must include `sslmode=require`. Verify the Container App's `POSTGRES_HOST` env var does NOT include the port or protocol — it should be just:
```
pg-orders-dev.postgres.database.azure.com
```

---

## 4. Managed Identity Authentication Failures

### Problem: `password authentication failed for user "orders-service-identity"`

**Cause:** The Managed Identity is NOT registered as an Entra Admin on PostgreSQL, OR the PostgreSQL role is not linked to Entra ID.

**Check Entra admins:**
```bash
az postgres flexible-server microsoft-entra-admin list \
  --server-name pg-orders-dev --resource-group rg-orders-dev -o table
```

You MUST see `orders-service-identity` listed as type `ServicePrincipal`. If missing:

```bash
MI_PRINCIPAL_ID=$(az identity show --name orders-service-identity \
  --resource-group rg-orders-dev --query "principalId" -o tsv)

az postgres flexible-server microsoft-entra-admin create \
  --server-name pg-orders-dev --resource-group rg-orders-dev \
  --display-name "orders-service-identity" \
  --object-id $MI_PRINCIPAL_ID --type ServicePrincipal
```

### Problem: `role "orders-service-identity" already exists` (when adding Entra Admin)

**Cause:** A PostgreSQL role with that name was created manually (not via Entra). It must be dropped and re-created properly.

**Fix:**
```bash
# Connect as your Entra admin user
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)

psql "host=pg-orders-dev.postgres.database.azure.com port=5432 dbname=ordersdb \
  user=<YOUR_UPN> sslmode=require"
```

```sql
-- Revoke everything first (needed if role has dependent objects)
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM "orders-service-identity";
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA orders FROM "orders-service-identity";
REVOKE ALL ON SCHEMA orders FROM "orders-service-identity";
REVOKE ALL ON SCHEMA public FROM "orders-service-identity";
REVOKE CREATE ON DATABASE ordersdb FROM "orders-service-identity";
DROP ROLE "orders-service-identity";
\q
```

Then re-run the `microsoft-entra-admin create` command above.

### Problem: `ManagedIdentityCredential authentication unavailable`

**Cause:** The User-Assigned Managed Identity is not attached to the Container App.

**Check:**
```bash
az containerapp identity show --name acrordersapp --resource-group rg-orders-dev -o json
```

You should see the MI listed under `userAssignedIdentities`. If empty or missing, redeploy with `fresh_deploy: true` via GitHub Actions, OR manually:

```bash
MI_ID=$(az identity show --name orders-service-identity --resource-group rg-orders-dev --query "id" -o tsv)

az containerapp identity assign --name acrordersapp --resource-group rg-orders-dev \
  --user-assigned $MI_ID
```

**Also check** the `AZURE_CLIENT_ID` env var is set correctly:
```bash
az containerapp show --name acrordersapp --resource-group rg-orders-dev \
  --query "properties.template.containers[0].env[?name=='AZURE_CLIENT_ID'].value" -o tsv
```

It must match the MI's client ID:
```bash
az identity show --name orders-service-identity --resource-group rg-orders-dev \
  --query "clientId" -o tsv
```

### Problem: `AADSTS700016: Application with identifier 'xxx' was not found`

**Cause:** `AZURE_CLIENT_ID` env var has the wrong value. It should be the Managed Identity's Client ID, NOT the Service Principal's App ID.

**Fix:** Get the correct value and update:
```bash
MI_CLIENT_ID=$(az identity show --name orders-service-identity \
  --resource-group rg-orders-dev --query "clientId" -o tsv)

az containerapp update --name acrordersapp --resource-group rg-orders-dev \
  --set-env-vars "AZURE_CLIENT_ID=$MI_CLIENT_ID"
```

---

## 5. Database Permission Errors

### Problem: `permission denied for schema orders`

**Cause:** The GRANT statements were not run after adding the MI as Entra Admin.

**Fix — connect as your Entra admin and run grants:**
```bash
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)

psql "host=pg-orders-dev.postgres.database.azure.com port=5432 dbname=ordersdb \
  user=<YOUR_UPN> sslmode=require"
```

```sql
GRANT CREATE ON DATABASE ordersdb TO "orders-service-identity";
CREATE SCHEMA IF NOT EXISTS orders;
GRANT ALL ON SCHEMA orders TO "orders-service-identity";
GRANT ALL ON SCHEMA public TO "orders-service-identity";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orders TO "orders-service-identity";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA orders TO "orders-service-identity";
ALTER DEFAULT PRIVILEGES IN SCHEMA orders
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "orders-service-identity";
ALTER DEFAULT PRIVILEGES IN SCHEMA orders
    GRANT USAGE, SELECT ON SEQUENCES TO "orders-service-identity";
\q
```

### Problem: `permission denied to create extension` or Flyway migration fails

Flyway needs `CREATE` on the database and `ALL` on the `orders` and `public` schemas. Re-run the grants above.

### Problem: `relation "orders.orders" does not exist`

Flyway migrations haven't run yet. This usually means the app crashed before Flyway could execute. Fix the root cause (usually a connection or auth issue above), then restart:

```bash
REVISION=$(az containerapp revision list --name acrordersapp --resource-group rg-orders-dev \
  --query "[0].name" -o tsv)
az containerapp revision restart --name acrordersapp --resource-group rg-orders-dev \
  --revision $REVISION
```

---

## 6. Image Pull Failures

### Problem: `unable to pull image` or `ImagePullBackOff`

**Check 1 — Does the image exist in ACR?**
```bash
az acr repository list --name acrordersdev -o table
az acr repository show-tags --name acrordersdev --repository orders-service -o table
```

**Check 2 — Does the MI have AcrPull role?**
```bash
MI_PRINCIPAL_ID=$(az identity show --name orders-service-identity \
  --resource-group rg-orders-dev --query "principalId" -o tsv)
ACR_ID=$(az acr show --name acrordersdev --resource-group rg-orders-dev --query "id" -o tsv)

az role assignment list --assignee $MI_PRINCIPAL_ID --scope $ACR_ID \
  --query "[].{role:roleDefinitionName}" -o table
```

If `AcrPull` is missing:
```bash
az role assignment create --assignee $MI_PRINCIPAL_ID --role AcrPull --scope $ACR_ID
```

**Check 3 — Is the registry configured on the Container App?**
```bash
az containerapp show --name acrordersapp --resource-group rg-orders-dev \
  --query "properties.configuration.registries" -o json
```

It should show `acrordersdev.azurecr.io` with the MI identity. If not, this requires redeployment via Terraform or `fresh_deploy: true`.

---

## 7. Missing or Wrong Environment Variables

**Check all env vars:**
```bash
az containerapp show --name acrordersapp --resource-group rg-orders-dev \
  --query "properties.template.containers[0].env[].{name:name, value:value}" -o table
```

**Required env vars:**

| Variable | Expected Value |
|---|---|
| `POSTGRES_HOST` | `pg-orders-dev.postgres.database.azure.com` |
| `POSTGRES_DB` | `ordersdb` |
| `POSTGRES_MI_USER` | `orders-service-identity` |
| `AZURE_CLIENT_ID` | MI's client ID (`fe470e7c-def6-4461-91bb-b946338cb026`) |
| `SPRING_DATASOURCE_AZURE_PASSWORDLESS_ENABLED` | `true` |
| `AZURE_MI_ENABLED` | `true` |

**Fix all at once:**
```bash
MI_CLIENT_ID=$(az identity show --name orders-service-identity \
  --resource-group rg-orders-dev --query "clientId" -o tsv)

az containerapp update --name acrordersapp --resource-group rg-orders-dev \
  --set-env-vars \
  "POSTGRES_HOST=pg-orders-dev.postgres.database.azure.com" \
  "POSTGRES_DB=ordersdb" \
  "POSTGRES_MI_USER=orders-service-identity" \
  "AZURE_CLIENT_ID=$MI_CLIENT_ID" \
  "SPRING_DATASOURCE_AZURE_PASSWORDLESS_ENABLED=true" \
  "AZURE_MI_ENABLED=true"
```

---

## 8. Manual Full Redeploy (Nuclear Option)

When nothing else works — delete the Container App and recreate it with all settings:

```bash
# Step 1: Delete the app
az containerapp delete --name acrordersapp --resource-group rg-orders-dev --yes

# Step 2: Wait until deletion completes
az containerapp show --name acrordersapp --resource-group rg-orders-dev 2>&1
# Should return "not found"

# Step 3: Redeploy via GitHub Actions
# Go to Actions > Deploy to ACA > Run workflow > check "fresh_deploy"

# OR redeploy via Terraform
# Go to Actions > Provision Azure Infrastructure > Run workflow > action: apply
```

After redeploy, verify identity is attached and env vars are set (Sections 4 and 7).

---

## 9. Connecting to PostgreSQL for Manual Debugging

### Finding your UPN (required for psql login)

For personal Microsoft accounts (Gmail, Outlook), your psql username is NOT your email:
```bash
az ad signed-in-user show --query "userPrincipalName" -o tsv
```

Example: `roysantu2002_gmail.com#EXT#@roysantu2002gmail.onmicrosoft.com`

### Connect via psql

```bash
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)

psql "host=pg-orders-dev.postgres.database.azure.com port=5432 dbname=ordersdb \
  user=<YOUR_UPN> sslmode=require"
```

### Useful psql commands once connected

```sql
\dn                                    -- list schemas
\dt orders.*                           -- list tables
\du orders-service-identity            -- check MI role exists
\dp orders.*                           -- check table permissions
SELECT count(*) FROM orders.orders;    -- verify data
SELECT * FROM flyway_schema_history;   -- check migration status
```

### Token expired?

If you get `password authentication failed`, the Entra token expired (tokens last ~1 hour). Re-run:
```bash
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)
```

---

## 10. What Terraform CANNOT Do (Must Be Done Manually)

These are Azure/PostgreSQL limitations — not Terraform bugs.

| Task | Why Manual | When to Do |
|---|---|---|
| Create Service Principal + OIDC federated credential | Chicken-and-egg: Terraform needs this SP to run | Before first `terraform apply` |
| Create Terraform state Storage Account | Terraform needs state backend before it can init | Before first `terraform apply` |
| Configure GitHub Secrets | GitHub API requires separate auth | Before first `terraform apply` |
| Add Entra Admin (your user) on PostgreSQL | Azure limitation: no Terraform resource for this | After `terraform apply`, one-time |
| Add Managed Identity as Entra Admin on PostgreSQL | Azure limitation: auto-creates the PG role linked to AAD | After `terraform apply`, one-time |
| Run SQL GRANT statements inside PostgreSQL | Requires SQL connection, not an Azure API call | After MI is added as Entra Admin |
| Portal "Allow Azure services" networking checkbox | Sometimes the Terraform firewall rule alone isn't sufficient | After `terraform apply`, verify once |

---

## 11. Order of Operations When Setting Up From Scratch

If you're rebuilding everything, follow this exact order:

```
1. az login + set subscription
2. Create Terraform state storage (storage account + container)
3. Create Service Principal + OIDC credential
4. Set GitHub Secrets
5. terraform apply (via GitHub Actions)
6. Verify firewall rule exists on PostgreSQL
7. Add YOUR USER as Entra Admin on PostgreSQL
8. Add MANAGED IDENTITY as Entra Admin on PostgreSQL
9. Connect via psql, run GRANT statements
10. Deploy the app (build + deploy workflows)
11. Verify: curl health endpoint + /orders
```

**Skip any step = broken app.** Steps 7-9 are the ones most commonly missed.

---

## 12. Quick Reference — Key Resource Names

| Resource | Name |
|---|---|
| Resource Group | `rg-orders-dev` |
| Managed Identity | `orders-service-identity` |
| MI Client ID | `fe470e7c-def6-4461-91bb-b946338cb026` |
| MI Principal ID | `a30d559b-94f1-40b1-b262-de88ff259c9d` |
| PostgreSQL Server | `pg-orders-dev` |
| PostgreSQL FQDN | `pg-orders-dev.postgres.database.azure.com` |
| Database | `ordersdb` |
| ACR | `acrordersdev` |
| ACR Login Server | `acrordersdev.azurecr.io` |
| Container App | `acrordersapp` |
| ACA Environment | `managedEnvironment-rgordersdev-a29a` |
| Subscription | `0bb4f66b-be3a-4331-941c-fd6c8c0a3eef` |
| Tenant | `f5666466-d48d-4b60-a921-7ebad0f1d5fc` |