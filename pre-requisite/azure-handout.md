# Azure Orders Platform — Setup Handout

> A clean, step-by-step guide to provision and deploy the Orders Platform from scratch.
> Distilled from lessons learned — follow this order exactly to avoid errors.

---

## Overview

| Layer | Method | What |
|---|---|---|
| **Identity & Auth** | Manual (one-time) | Service Principal, OIDC, GitHub Secrets |
| **Terraform State** | Manual (one-time) | Storage Account for remote backend |
| **Infrastructure** | Terraform via GitHub Actions | RG, MI, ACR, PostgreSQL, ACA, Log Analytics |
| **Database Auth** | Manual (one-time, after Terraform) | Entra Admins on PostgreSQL, firewall, grants |
| **Application** | Automated CI/CD | Build image → Push to ACR → Deploy to ACA |

---

## Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                        Azure Subscription                         │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │ Resource Group: rg-orders-dev                               │  │
│  │                                                             │  │
│  │  ┌──────────────┐   ┌────────────────────────────────────┐  │  │
│  │  │ Managed      │   │ Azure Container Registry           │  │  │
│  │  │ Identity     │──►│ acrordersdev                       │  │  │
│  │  │ (AcrPull)    │   │ (stores Docker images)             │  │  │
│  │  └──────┬───────┘   └────────────────────────────────────┘  │  │
│  │         │                                                   │  │
│  │         │ identity attached                                 │  │
│  │         ▼                                                   │  │
│  │  ┌────────────────────────────────────────────────────────┐ │  │
│  │  │ Azure Container App: acrordersapp                      │ │  │
│  │  │ (Spring Boot app, port 8080, external ingress)         │ │  │
│  │  │                                                        │ │  │
│  │  │ Uses MI to:                                            │ │  │
│  │  │  • Pull images from ACR                                │ │  │
│  │  │  • Get AAD token for PostgreSQL (passwordless)         │ │  │
│  │  └───────────────────────┬────────────────────────────────┘ │  │
│  │                          │ AAD token auth                   │  │
│  │                          ▼                                  │  │
│  │  ┌────────────────────────────────────────────────────────┐ │  │
│  │  │ PostgreSQL Flexible Server: pg-orders-dev              │ │  │
│  │  │ (Entra-only auth, no passwords)                        │ │  │
│  │  │ Database: ordersdb | Schema: orders                    │ │  │
│  │  └────────────────────────────────────────────────────────┘ │  │
│  │                                                             │  │
│  │  ┌────────────────────────────────────────────────────────┐ │  │
│  │  │ Log Analytics Workspace: log-orders-dev                │ │  │
│  │  └────────────────────────────────────────────────────────┘ │  │
│  └─────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

---

## CI/CD Pipeline

```
git push to main
    │
    ├── application/** changed?
    │       YES ──► "Build and Push Image" (auto)
    │                    │ on success
    │                    ▼
    │              "Deploy to ACA" (auto)
    │
    ├── terraform/** changed?
    │       Run manually: Actions > "Provision Azure Infrastructure"
    │
    └── other files (docs, workflows)
            No action needed
```

| Workflow | File | Trigger | Manual? |
|---|---|---|---|
| **Provision Infrastructure** | `infra.yml` | Never auto | Always manual (plan/apply/destroy/import) |
| **Build and Push Image** | `build.yml` | Push to `main` when `application/**` changes | Also manual |
| **Deploy to ACA** | `deploy.yml` | After Build completes successfully | Also manual (with `fresh_deploy` option) |

---

## What Terraform Provisions (Automated)

These resources are created by `terraform apply` via the `infra.yml` workflow:

| Resource | Terraform File | Azure Resource |
|---|---|---|
| Resource Group | `main.tf` | `rg-orders-dev` |
| User-Assigned Managed Identity | `identity.tf` | `orders-service-identity` |
| Container Registry | `acr.tf` | `acrordersdev` |
| AcrPull Role Assignment | `acr.tf` | MI → ACR pull permission |
| PostgreSQL Flexible Server | `postgres.tf` | `pg-orders-dev` (Entra-only auth, v16) |
| PostgreSQL Firewall Rule | `postgres.tf` | `AllowAzureServices` (0.0.0.0) |
| PostgreSQL Database | `postgres.tf` | `ordersdb` |
| Log Analytics Workspace | `aca.tf` | `log-orders-dev` |
| Container Apps Environment | `aca.tf` | `managedEnvironment-rgordersdev-a29a` |
| Container App | `aca.tf` | `acrordersapp` (with MI, env vars, health probes) |

**Terraform CANNOT provision** (must be done manually):
- Service Principal + OIDC Federated Credential (chicken-and-egg: needed to run Terraform)
- Terraform state Storage Account (needed before first `terraform init`)
- GitHub repository secrets
- Entra Admins on PostgreSQL server (Azure limitation — not supported by AzureRM provider)
- PostgreSQL role grants (requires SQL commands inside the database)

---

## What Must Be Done Manually

### PHASE A — Before Terraform (one-time)

These create the identity and state infrastructure that Terraform itself needs to run.

| Step | Action | Command / Where |
|---|---|---|
| **A1** | Login to Azure CLI | `az login` then `az account set --subscription "0bb4f66b-be3a-4331-941c-fd6c8c0a3eef"` |
| **A2** | Create Terraform state storage | `az group create --name rg-terraform-state --location "Canada Central"` |
| | | `az storage account create --name stordersdevtfstate --resource-group rg-terraform-state --location "Canada Central" --sku Standard_LRS` |
| | | `az storage container create --name tfstate --account-name stordersdevtfstate` |
| **A3** | Create App Registration | `az ad app create --display-name "sp-orders-terraform"` |
| | Create Service Principal | `az ad sp create --id <appId>` |
| **A4** | Assign Contributor role | `az ad sp create-for-rbac --name "sp-orders-terraform" --role Contributor --scopes /subscriptions/0bb4f66b-be3a-4331-941c-fd6c8c0a3eef` |
| | Assign User Access Admin role | `az role assignment create --assignee <appId> --role "User Access Administrator" --scope /subscriptions/0bb4f66b-be3a-4331-941c-fd6c8c0a3eef` |
| **A5** | Create OIDC Federated Credential | `az ad app federated-credential create --id <APP_OBJECT_ID> --parameters '{"name":"github-actions-infra","issuer":"https://token.actions.githubusercontent.com","subject":"repo:roysantu2002/azure-container-app-spring-boot:ref:refs/heads/main","audiences":["api://AzureADTokenExchange"]}'` |
| **A6** | Set GitHub Secrets | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `ACR_NAME` |

**After Phase A:** Push code → Run `infra.yml` with `plan` then `apply`.

---

### PHASE B — After Terraform Apply (one-time)

These configure the database for passwordless Managed Identity authentication.
They must be manual because they require Entra Admin setup and SQL commands.

| Step | Action | Details |
|---|---|---|
| **B1** | Verify ACR Pull role | Terraform creates this. Verify with: `az role assignment list --assignee $MI_PRINCIPAL_ID --scope $ACR_ID` |
| **B2** | Verify PostgreSQL firewall | Terraform creates `AllowAzureServices` rule. Verify with: `az postgres flexible-server firewall-rule list --resource-group rg-orders-dev --server-name pg-orders-dev -o table` |
| **B3** | Set yourself as Entra Admin on PostgreSQL | Via Portal: `pg-orders-dev` > Authentication > Add your user |
| **B4** | Add Managed Identity as Entra Admin on PostgreSQL | See detailed steps below |
| **B5** | Grant database permissions | Connect via psql, run GRANT statements |

---

## PHASE B — Detailed Steps

### B1 + B2: Verify Terraform-Created Resources

```bash
# Get MI Principal ID
MI_PRINCIPAL_ID=$(az identity show --name orders-service-identity --resource-group rg-orders-dev --query "principalId" -o tsv)

# Verify AcrPull role
ACR_ID=$(az acr show --name acrordersdev --resource-group rg-orders-dev --query "id" -o tsv)
az role assignment list --assignee $MI_PRINCIPAL_ID --scope $ACR_ID --query "[].{role:roleDefinitionName}" -o table
# Expected: AcrPull listed

# Verify PostgreSQL firewall
az postgres flexible-server firewall-rule list --resource-group rg-orders-dev --server-name pg-orders-dev -o table
# Expected: AllowAzureServices  0.0.0.0  0.0.0.0
```

If either is missing, create manually:

```bash
# AcrPull (if missing)
az role assignment create --assignee $MI_PRINCIPAL_ID --role AcrPull --scope $ACR_ID

# Firewall (if missing)
az postgres flexible-server firewall-rule create --resource-group rg-orders-dev --server-name pg-orders-dev -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0
```

Also verify in Azure Portal: `pg-orders-dev` > **Networking** > **"Allow public access from Azure services and resources within Azure"** must be **checked**.

---

### B3: Set Yourself as Entra Admin

**Recommended: Azure Portal**

1. Go to **Azure Portal** > **pg-orders-dev** > **Authentication** (under Security)
2. Click **+ Add Microsoft Entra Admins**
3. Search for your email, select it, click **Save**

**Alternative: Azure CLI**

```bash
# Get your Object ID
az ad signed-in-user show --query "{displayName:displayName, objectId:id, email:userPrincipalName}" -o table

# Set as admin (newer CLI)
az postgres flexible-server microsoft-entra-admin create --server-name pg-orders-dev --resource-group rg-orders-dev --display-name "<YOUR_EMAIL>" --object-id <YOUR_OBJECT_ID> --type User
```

> **CLI version note:** Older Azure CLI uses `ad-admin` instead of `microsoft-entra-admin`.
> If you get "misspelled or not recognized", update your CLI or use the Portal.

---

### B4: Add Managed Identity as Entra Admin

This is the **critical step** — it auto-creates the PostgreSQL role linked to AAD.

```bash
# Get MI Principal ID (Object ID)
az identity show --name orders-service-identity --resource-group rg-orders-dev --query "{name:name, clientId:clientId, principalId:principalId}" -o table
```

**Add as Entra Admin:**

```bash
az postgres flexible-server microsoft-entra-admin create --server-name pg-orders-dev --resource-group rg-orders-dev --display-name "orders-service-identity" --object-id <MI_PRINCIPAL_ID> --type ServicePrincipal
```

**If you get "role already exists" error:**

This means a PostgreSQL role named `orders-service-identity` exists but isn't linked to Entra.
You must drop it first, then retry:

```bash
# Connect to PostgreSQL (get your UPN first)
az ad signed-in-user show --query "userPrincipalName" -o tsv
# e.g. roysantu2002_gmail.com#EXT#@roysantu2002gmail.onmicrosoft.com

export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)
psql "host=pg-orders-dev.postgres.database.azure.com port=5432 dbname=ordersdb user=<YOUR_UPN> sslmode=require"
```

```sql
-- Drop the stale role (revoke privileges first if needed)
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM "orders-service-identity";
REVOKE ALL ON SCHEMA public FROM "orders-service-identity";
DROP ROLE IF EXISTS "orders-service-identity";
\q
```

Then re-run the `microsoft-entra-admin create` command above.

**Verify both admins exist:**

```bash
az postgres flexible-server microsoft-entra-admin list --server-name pg-orders-dev --resource-group rg-orders-dev -o table
```

Expected: two entries — your user AND `orders-service-identity`.

---

### B5: Grant Database Permissions

Connect via psql as your Entra admin user:

```bash
export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken --output tsv)
psql "host=pg-orders-dev.postgres.database.azure.com port=5432 dbname=ordersdb user=<YOUR_UPN> sslmode=require"
```

> **Personal Microsoft accounts:** Use UPN format, not email.
> Find it with: `az ad signed-in-user show --query "userPrincipalName" -o tsv`
> Example: `roysantu2002_gmail.com#EXT#@roysantu2002gmail.onmicrosoft.com`

> **If "password authentication failed":** Token expired. Re-run the `export PGPASSWORD=...` line.

Run these grants:

```sql
-- Create schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS orders;

-- Allow MI to create schemas (needed for Flyway)
GRANT CREATE ON DATABASE ordersdb TO "orders-service-identity";

-- Grant schema access
GRANT ALL ON SCHEMA orders TO "orders-service-identity";
GRANT ALL ON SCHEMA public TO "orders-service-identity";

-- Grant table/sequence permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orders TO "orders-service-identity";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA orders TO "orders-service-identity";

-- Grant default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA orders
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "orders-service-identity";
ALTER DEFAULT PRIVILEGES IN SCHEMA orders
    GRANT USAGE, SELECT ON SEQUENCES TO "orders-service-identity";

\q
```

---

## Deploy and Validate

After Phase B, deploy the app:

**Option 1 — Fresh deploy (recommended for first time):**

Go to **GitHub Actions** > **Deploy to ACA** > **Run workflow** > set `fresh_deploy: true`

**Option 2 — Restart existing app:**

```bash
az containerapp revision restart --name acrordersapp --resource-group rg-orders-dev --revision $(az containerapp revision list --name acrordersapp --resource-group rg-orders-dev --query "[0].name" -o tsv)
```

**Verify:**

```bash
FQDN=$(az containerapp show --name acrordersapp --resource-group rg-orders-dev --query "properties.configuration.ingress.fqdn" -o tsv)

curl -s https://$FQDN/actuator/health
# Expected: {"status":"UP"}

curl -s https://$FQDN/orders
# Expected: 5 seeded order records
```

---

## Master Checklist

Use this to track progress when setting up from scratch:

| # | Phase | Task | Status |
|---|---|---|---|
| A1 | A | Azure CLI installed and logged in | ☐ |
| A2 | A | Terraform state Storage Account created | ☐ |
| A3 | A | App Registration + Service Principal created | ☐ |
| A4 | A | Contributor + User Access Administrator roles assigned | ☐ |
| A5 | A | OIDC Federated Credential created for GitHub Actions | ☐ |
| A6 | A | GitHub repository secrets configured | ☐ |
| — | — | **Run Terraform: `infra.yml` > plan > apply** | ☐ |
| B1 | B | ACR Pull role verified on Managed Identity | ☐ |
| B2 | B | PostgreSQL firewall rule verified (AllowAzureServices) | ☐ |
| B3 | B | Your user set as Entra Admin on PostgreSQL | ☐ |
| B4 | B | Managed Identity added as Entra Admin on PostgreSQL | ☐ |
| B5 | B | Database grants applied (GRANT statements) | ☐ |
| — | — | **Deploy app: `deploy.yml` > fresh_deploy: true** | ☐ |
| — | — | **Verify: /actuator/health returns UP** | ☐ |
| — | — | **Verify: /orders returns data** | ☐ |

---

## Troubleshooting Quick Reference

| Error in Container Logs | Cause | Fix |
|---|---|---|
| `pg_hba.conf rejects connection` | Firewall blocking ACA → PostgreSQL | Verify Step B2: firewall rule + Portal networking checkbox |
| `password authentication failed` | MI not an Entra Admin OR MI role not linked to AAD | Run Step B4: add MI as Entra Admin |
| `role "orders-service-identity" does not exist` | MI not added as Entra Admin | Run Step B4 |
| `role already exists` (when adding Entra Admin) | Stale manual role in PostgreSQL | Drop role via psql, then retry B4 |
| `permission denied for schema orders` | Grants not applied | Run Step B5 |
| `ManagedIdentityCredential authentication unavailable` | MI not attached to Container App | Redeploy with `fresh_deploy: true` |
| `unable to pull image` | AcrPull role missing | Run Step B1 fix |
| `AADSTS700016 Application not found` | Wrong AZURE_CLIENT_ID in GitHub secrets | Verify with: `az ad app list --filter "displayName eq 'sp-orders-terraform'" --query "[].appId" -o tsv` |
| `ContainerAppOperationInProgress` | Previous operation stuck | Wait or redeploy with `fresh_deploy: true` |

---

## Key Values Reference

| Item | Value |
|---|---|
| Subscription ID | `0bb4f66b-be3a-4331-941c-fd6c8c0a3eef` |
| Tenant ID | `f5666466-d48d-4b60-a921-7ebad0f1d5fc` |
| Resource Group | `rg-orders-dev` |
| Region | `Canada Central` |
| ACR Name | `acrordersdev` |
| PostgreSQL Server | `pg-orders-dev` |
| Database | `ordersdb` |
| Managed Identity | `orders-service-identity` |
| Container App | `acrordersapp` |
| ACA Environment | `managedEnvironment-rgordersdev-a29a` |
| GitHub Repo | `roysantu2002/azure-container-app-spring-boot` |
| SP Display Name | `sp-orders-terraform` |
| MI Principal ID | `a30d559b-94f1-40b1-b262-de88ff259c9d` |
| MI Client ID | `fe470e7c-def6-4461-91bb-b946338cb026` |

---

## GitHub Secrets Required

| Secret | Value | Used By |
|---|---|---|
| `AZURE_CLIENT_ID` | SP appId (`666401c9-e0bb-45db-b113-e087b49eddcd`) | All workflows |
| `AZURE_TENANT_ID` | `f5666466-d48d-4b60-a921-7ebad0f1d5fc` | All workflows |
| `AZURE_SUBSCRIPTION_ID` | `0bb4f66b-be3a-4331-941c-fd6c8c0a3eef` | All workflows |
| `ACR_NAME` | `acrordersdev` | Build, Deploy |

---

## Day-to-Day Workflow (After Setup)

Once everything is set up, the daily workflow is:

```
1. Edit Java code, SQL migrations, or config under application/
2. git add, commit, push to main
3. "Build and Push Image" triggers automatically
4. "Deploy to ACA" triggers automatically after build succeeds
5. New version is live
```

No manual steps needed for application changes. Infrastructure changes require manual `infra.yml` runs.