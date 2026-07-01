# Azure Pre-Requisites — Complete Manual Setup Guide

> Complete ALL steps in this guide before the application can run successfully.
> There are two phases: **Phase A** (before Terraform) and **Phase B** (after Terraform).

---

## Master Checklist

| # | Phase | Task | When | Status |
|---|---|---|---|---|
| 1 | A | Azure CLI installed and logged in | Before anything | ☐ |
| 2 | A | Terraform state Storage Account created | Before Terraform | ☐ |
| 3 | A | App Registration + Service Principal created | Before Terraform | ☐ |
| 4 | A | Contributor + User Access Administrator roles assigned | Before Terraform | ☐ |
| 5 | A | OIDC Federated Credential created for GitHub Actions | Before Terraform | ☐ |
| 6 | A | GitHub repository secrets configured | Before Terraform | ☐ |
| 7 | B | ACR Pull role assigned to Managed Identity | After Terraform apply | ☐ |
| 7b | B | PostgreSQL firewall allows Azure services (0.0.0.0) | After Terraform apply | ☐ |
| 8 | B | Entra Admin (your user) set on PostgreSQL server | After Terraform apply | ☐ |
| 9 | B | Managed Identity added as Entra Admin on PostgreSQL | After Step 8 | ☐ |
| 10 | B | PostgreSQL schema/table grants applied | After MI role created | ☐ |

---

# PHASE A — Before Running Terraform

> These steps create the authentication and state infrastructure that Terraform and GitHub Actions need.

---

## Step 1 — Azure CLI Login

```bash
az login
az account set --subscription "0bb4f66b-be3a-4331-941c-fd6c8c0a3eef"
az account show --query "{subscriptionId:id, tenantId:tenantId, name:name}" -o table
```

---

## Step 2 — Create Terraform State Storage

One-time setup. Terraform needs a remote backend to persist state between GitHub Actions runs.

```bash
az group create --name rg-terraform-state --location "Canada Central"

az storage account create --name stordersdevtfstate --resource-group rg-terraform-state --location "Canada Central" --sku Standard_LRS

az storage container create --name tfstate --account-name stordersdevtfstate
```

**Verify:**

```bash
az storage container list --account-name stordersdevtfstate --query "[].name" -o tsv
```

Expected: `tfstate`

---

## Step 3 — Create App Registration and Service Principal

GitHub Actions authenticates to Azure via OIDC using an App Registration.

```bash
az ad app create --display-name "sp-orders-terraform"
```

Note the `appId` from the output. Then create the Service Principal:

```bash
az ad sp create --id <appId-from-above>
```

---

## Step 4 — Assign Roles to the Service Principal

The Service Principal needs **two roles** on your subscription.

### 4.1 — Contributor (to create resources)

```bash
az ad sp create-for-rbac --name "sp-orders-terraform" --role Contributor --scopes /subscriptions/0bb4f66b-be3a-4331-941c-fd6c8c0a3eef
```

Output:

```json
{
  "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "displayName": "sp-orders-terraform",
  "password": "...",
  "tenant": "f5666466-d48d-4b60-a921-7ebad0f1d5fc"
}
```

**Save the `appId`** — this is your `AZURE_CLIENT_ID`.
The `password` is NOT needed (we use OIDC).

### 4.2 — User Access Administrator (to create role assignments like AcrPull)

```bash
az role assignment create --assignee <appId> --role "User Access Administrator" --scope /subscriptions/0bb4f66b-be3a-4331-941c-fd6c8c0a3eef
```

**Verify both roles:**

```bash
az role assignment list --assignee <appId> --query "[].{role:roleDefinitionName}" -o table
```

Expected:

```
Role
----------------------------
Contributor
User Access Administrator
```

---

## Step 5 — Create OIDC Federated Credential for GitHub Actions

### 5.1 — Get the App Object ID

```bash
az ad app list --filter "displayName eq 'sp-orders-terraform'" --query "[].id" -o tsv
```

### 5.2 — Create the Federated Credential

Replace `<APP_OBJECT_ID>` with the value from 5.1:

```bash
az ad app federated-credential create --id <APP_OBJECT_ID> --parameters '{"name":"github-actions-infra","issuer":"https://token.actions.githubusercontent.com","subject":"repo:roysantu2002/azure-container-app-spring-boot:ref:refs/heads/main","audiences":["api://AzureADTokenExchange"]}'
```

**Verify:**

```bash
az ad app federated-credential list --id <APP_OBJECT_ID> --query "[].{name:name, subject:subject}" -o table
```

Expected:

```
Name                   Subject
---------------------  ---------------------------------------------------------------
github-actions-infra   repo:roysantu2002/azure-container-app-spring-boot:ref:refs/heads/main
```

---

## Step 6 — Configure GitHub Repository Secrets

Go to: **GitHub repo > Settings > Secrets and variables > Actions > New repository secret**

| Secret Name | Value | How to find it |
|---|---|---|
| `AZURE_CLIENT_ID` | `appId` from Step 4 | `az ad app list --filter "displayName eq 'sp-orders-terraform'" --query "[].appId" -o tsv` |
| `AZURE_TENANT_ID` | `f5666466-d48d-4b60-a921-7ebad0f1d5fc` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `0bb4f66b-be3a-4331-941c-fd6c8c0a3eef` | `az account show --query id -o tsv` |
| `ACR_NAME` | `acrordersdev` | Used by build/deploy workflows |

---

# Run Terraform Apply

After Phase A is complete:

1. Push code to `main`
2. Go to **Actions > Provision Azure Infrastructure > Run workflow**
3. Select `dev` + `plan` — review output
4. Select `dev` + `apply` — create all resources

Terraform creates: Resource Group, Managed Identity, ACR, PostgreSQL Server + DB, ACA Environment, Container App, Log Analytics.

---

# PHASE B — After Terraform Apply

> These steps configure the database for passwordless authentication.
> They MUST be done manually because they require SQL commands inside PostgreSQL.

---

## Step 7 — Verify ACR Pull Role for Managed Identity

Terraform creates this, but verify it exists. If missing (e.g. after a recreate), add it:

```bash
MI_PRINCIPAL_ID=$(az identity show --name orders-service-identity --resource-group rg-orders-dev --query "principalId" -o tsv)

ACR_ID=$(az acr show --name acrordersdev --resource-group rg-orders-dev --query "id" -o tsv)

az role assignment list --assignee $MI_PRINCIPAL_ID --scope $ACR_ID --query "[].{role:roleDefinitionName}" -o table
```

If `AcrPull` is NOT listed:

```bash
az role assignment create --assignee $MI_PRINCIPAL_ID --role AcrPull --scope $ACR_ID
```

---

## Step 7b — Verify PostgreSQL Firewall Allows Azure Services

The Container App connects to PostgreSQL over the Azure backbone network. A firewall rule must exist to allow this. Terraform creates it, but verify it exists:

```bash
az postgres flexible-server firewall-rule list --resource-group rg-orders-dev --server-name pg-orders-dev -o table
```

If `AllowAzureServices` (0.0.0.0 → 0.0.0.0) is NOT listed, create it:

```bash
az postgres flexible-server firewall-rule create --resource-group rg-orders-dev --server-name pg-orders-dev -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0
```

> **What this does:** The `0.0.0.0` to `0.0.0.0` range is a special Azure convention meaning
> "allow connections from all Azure services" (e.g. Container Apps, Functions, App Service).
>
> **Terraform reference:** This is defined in `terraform/postgres.tf` as
> `azurerm_postgresql_flexible_server_firewall_rule.allow_azure`. If Terraform apply was
> run successfully, this rule should already exist. Add it manually only if missing.

**Symptom if missing:** Container app logs show:
```
pg_hba.conf rejects connection for host "x.x.x.x", user "orders-service-identity", database "ordersdb", SSL encryption
```

---

## Step 8 — Set Entra Admin on PostgreSQL Server

You need TWO Entra admins on the PostgreSQL server:
1. **Your own account** — so you can connect via psql and run grants
2. **The Managed Identity** — so the app can authenticate with AAD tokens

### 8.1 — Get your Entra User Object ID

```bash
az ad signed-in-user show --query "{displayName:displayName, objectId:id, email:userPrincipalName}" -o table
```

### 8.2 — Set yourself as Entra Admin

> **Important:** The old CLI command `az postgres flexible-server ad-admin` was renamed.
> Use `microsoft-entra-admin` in newer Azure CLI versions.

**Option A — Azure CLI (newer versions):**

```bash
az postgres flexible-server microsoft-entra-admin create --server-name pg-orders-dev --resource-group rg-orders-dev --display-name "<YOUR_EMAIL>" --object-id <YOUR_OBJECT_ID> --type User
```

**Option B — Azure CLI (older versions):**

```bash
az postgres flexible-server ad-admin create -s pg-orders-dev -g rg-orders-dev -u "<YOUR_EMAIL>" -i <YOUR_OBJECT_ID> -t User
```

**Option C — Azure Portal (recommended if CLI fails):**

1. Go to **Azure Database for PostgreSQL flexible servers** > `pg-orders-dev`
2. Left menu > **Authentication** (under Security)
3. Click **+ Add Microsoft Entra Admins**
4. Search for your email (e.g. `roysantu2002@gmail.com`)
5. Select it and click **Save**

**Verify:**

```bash
az postgres flexible-server microsoft-entra-admin list --server-name pg-orders-dev --resource-group rg-orders-dev -o table
```

---

## Step 9 — Add the Managed Identity as an Entra Admin on PostgreSQL

This is the critical step. Adding the Managed Identity as an Entra Admin on the PostgreSQL server automatically creates the PostgreSQL role AND enables AAD token authentication for it. This replaces the old `pgaad` extension approach.

### 9.1 — Get the Managed Identity details

```bash
az identity show --name orders-service-identity --resource-group rg-orders-dev --query "{name:name, clientId:clientId, principalId:principalId}" -o table
```

Note the `principalId` — this is the Object ID needed below.

### 9.2 — Add MI as Entra Admin

**Option A — Azure CLI (newer versions, recommended):**

```bash
az postgres flexible-server microsoft-entra-admin create --server-name pg-orders-dev --resource-group rg-orders-dev --display-name "orders-service-identity" --object-id <MI_PRINCIPAL_ID> --type ServicePrincipal
```

Replace `<MI_PRINCIPAL_ID>` with the `principalId` from Step 9.1 (e.g. `a30d559b-94f1-40b1-b262-de88ff259c9d`).

**Option B — Azure CLI (older versions):**

```bash
az postgres flexible-server ad-admin create -s pg-orders-dev -g rg-orders-dev -u "orders-service-identity" -i <MI_PRINCIPAL_ID> -t ServicePrincipal
```

**Option C — Azure Portal:**

1. Go to **Azure Database for PostgreSQL flexible servers** > `pg-orders-dev`
2. Left menu > **Authentication** (under Security)
3. Click **+ Add Microsoft Entra Admins**
4. Search for `orders-service-identity`
5. Select the Managed Identity and click **Save**

> **Note:** PostgreSQL Flexible Server supports multiple Entra admins.
> Both your user account AND the managed identity can be admins simultaneously.

### 9.2a — Troubleshooting: "role already exists" error

If Step 9.2 fails with:

```
(AadAuthPrincipalCreationFailed) Failed to create Microsoft Entra principal.
Reason: '42710: role "orders-service-identity" already exists'.
```

This means a PostgreSQL role with that name exists but is NOT linked to Entra/AAD.
This happens if someone ran `CREATE ROLE "orders-service-identity"` manually before.
You must drop the stale role first, then re-create it as an Entra Admin.

**Fix — connect via psql and drop the stale role:**

```bash
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)
psql "host=pg-orders-dev.postgres.database.azure.com port=5432 dbname=ordersdb user=roysantu2002_gmail.com#EXT#@roysantu2002gmail.onmicrosoft.com sslmode=require"
```

```sql
-- Check if the role exists but is not an Entra principal
\du orders-service-identity

-- Drop the stale role
DROP ROLE IF EXISTS "orders-service-identity";
\q
```

> **If DROP ROLE fails with "role has dependent objects"**, revoke privileges first:
>
> ```sql
> REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM "orders-service-identity";
> REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA orders FROM "orders-service-identity";
> REVOKE ALL ON SCHEMA orders FROM "orders-service-identity";
> REVOKE ALL ON SCHEMA public FROM "orders-service-identity";
> REVOKE CREATE ON DATABASE ordersdb FROM "orders-service-identity";
> DROP ROLE "orders-service-identity";
> \q
> ```

**Then re-run Step 9.2** to create the role properly linked to the Managed Identity.

**Verify both admins are listed:**

```bash
az postgres flexible-server microsoft-entra-admin list --server-name pg-orders-dev --resource-group rg-orders-dev -o table
```

Expected: two entries — your user account and `orders-service-identity`.

### 9.3 — Verify the MI role exists in PostgreSQL

Connect to PostgreSQL as your Entra admin user:

> **Important:** For personal Microsoft accounts (Gmail, Outlook via live.com), the psql username
> is the UPN format, NOT your email. Find your UPN:
>
> ```bash
> az ad signed-in-user show --query "userPrincipalName" -o tsv
> ```
>
> It will look like: `roysantu2002_gmail.com#EXT#@roysantu2002gmail.onmicrosoft.com`

```bash
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)

psql "host=pg-orders-dev.postgres.database.azure.com port=5432 dbname=ordersdb user=<YOUR_UPN> sslmode=require"
```

Replace `<YOUR_UPN>` with the UPN from above (NOT your email).

**Example for a personal Microsoft account:**

```bash
psql "host=pg-orders-dev.postgres.database.azure.com port=5432 dbname=ordersdb user=roysantu2002_gmail.com#EXT#@roysantu2002gmail.onmicrosoft.com sslmode=require"
```

> **Troubleshooting:** If `password authentication failed`, the token may have expired.
> Re-run the `export PGPASSWORD=...` command to get a fresh token and try again.

Once connected, verify the MI role was auto-created:

```sql
\du orders-service-identity
```

Expected output should show the role listed. If the role does NOT appear after adding the MI as Entra Admin, wait 1-2 minutes and reconnect — it may take a moment to propagate.

---

## Step 10 — Grant Database Permissions to the MI Role

Still inside the same psql session, run all of these:

```sql
-- Allow the MI to create schemas (needed for Flyway)
GRANT CREATE ON DATABASE ordersdb TO "orders-service-identity";

-- Grant full access to the orders schema (create if it doesn't exist yet)
CREATE SCHEMA IF NOT EXISTS orders;
GRANT ALL ON SCHEMA orders TO "orders-service-identity";

-- Grant access to public schema (for Flyway history table)
GRANT ALL ON SCHEMA public TO "orders-service-identity";

-- Grant table permissions in orders schema
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orders TO "orders-service-identity";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA orders TO "orders-service-identity";

-- Grant default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA orders
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "orders-service-identity";

ALTER DEFAULT PRIVILEGES IN SCHEMA orders
    GRANT USAGE, SELECT ON SEQUENCES TO "orders-service-identity";
```

**Verify:**

```sql
\du orders-service-identity
\dp orders.*
```

Exit psql:

```sql
\q
```

---

# After All Steps Are Complete

## Deploy and Validate

```bash
FQDN=$(az containerapp show --name acrordersapp --resource-group rg-orders-dev --query "properties.configuration.ingress.fqdn" -o tsv)

curl -s https://$FQDN/actuator/health

curl -s https://$FQDN/orders
```

## Expected Results

- `/actuator/health` returns `{"status":"UP"}`
- `/orders` returns 5 seeded order records
- Container logs show `HikariPool-1 - Start completed`

## If Something Goes Wrong

Check the logs:

```bash
az containerapp logs show --name acrordersapp --resource-group rg-orders-dev --tail 100
```

| Error | Cause | Fix |
|---|---|---|
| `pg_hba.conf rejects connection` | Firewall blocking ACA → PostgreSQL | Verify Step 7b: firewall rule + Portal networking checkbox |
| `password authentication failed` | MI not an Entra Admin OR MI role not linked to AAD | Run Step 9 to add MI as Entra Admin |
| `role "orders-service-identity" does not exist` | Step 9 not completed | Add MI as Entra Admin (Step 9.2) |
| `role already exists` (when adding Entra Admin) | Stale manual role in PostgreSQL | Drop role via psql (Step 9.2a), then retry |
| `permission denied for schema orders` | Step 10 grants not applied | Run the GRANT statements |
| `ManagedIdentityCredential authentication unavailable` | UAMI not attached to Container App | Redeploy with `fresh_deploy: true` |
| `unable to pull image` | AcrPull role missing | Run Step 7 to add the role |
| `AADSTS700016 Application not found` | Wrong AZURE_CLIENT_ID in GitHub secrets | Verify SP appId matches secret |
| `ContainerAppOperationInProgress` | Previous operation stuck | Wait or redeploy with `fresh_deploy: true` |

---

## Architecture Flow

```
┌──────────────────────────────────────────────────────────┐
│ PHASE A (one-time, before Terraform)                     │
│                                                          │
│  Storage Account ← Terraform state                       │
│  App Registration ← OIDC auth for GitHub Actions         │
│  Federated Credential ← trust GitHub token issuer        │
│  GitHub Secrets ← connect GitHub to Azure                │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│ TERRAFORM APPLY (automated via GitHub Actions)           │
│                                                          │
│  Creates: RG, MI, ACR, PostgreSQL, ACA Env, App, Logs   │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│ PHASE B (one-time, after Terraform)                      │
│                                                          │
│  Verify AcrPull role + firewall rule                     │
│  Set your user as Entra Admin on PostgreSQL              │
│  Add Managed Identity as Entra Admin on PostgreSQL       │
│  Grant schema/table permissions via psql                 │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────┐
│ APP READY                                                │
│                                                          │
│  Push code → Build → Deploy → App connects to DB         │
│  with AAD token (passwordless)                           │
└──────────────────────────────────────────────────────────┘
```