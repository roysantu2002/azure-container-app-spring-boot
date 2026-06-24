# Azure Pre-Requisites

> Complete these steps **before** pushing code and running the `infra.yml` GitHub Action.
> All commands use Azure CLI (`az`). Run them from your terminal or Azure Cloud Shell.

---

## Checklist Summary

| # | Task | Status |
|---|---|---|
| 1 | Azure CLI installed and logged in | ☐ |
| 2 | Terraform state Storage Account created | ☐ |
| 3 | App Registration + Service Principal created | ☐ |
| 4 | Contributor role assigned to Service Principal | ☐ |
| 5 | OIDC Federated Credential created for GitHub Actions | ☐ |
| 6 | GitHub repository secrets configured | ☐ |

---

## Step 1 — Azure CLI Login

Ensure you are logged in and targeting the correct subscription.

```bash
az login
az account set --subscription "0bb4f66b-be3a-4331-941c-fd6c8c0a3eef"
az account show --query "{subscriptionId:id, tenantId:tenantId, name:name}" -o table
```

---

## Step 2 — Create Terraform State Storage

Terraform needs a remote backend to persist state between GitHub Actions runs.
This is a **one-time manual setup**.

```bash
# Create a dedicated resource group for state storage
az group create \
  --name rg-terraform-state \
  --location "Canada Central"

# Create the storage account (name must be globally unique, lowercase, no hyphens)
az storage account create \
  --name stordersdevtfstate \
  --resource-group rg-terraform-state \
  --location "Canada Central" \
  --sku Standard_LRS

# Create the blob container for state files
az storage container create \
  --name tfstate \
  --account-name stordersdevtfstate
```

**Verify:**

```bash
az storage container list --account-name stordersdevtfstate --query "[].name" -o tsv
# Expected output: tfstate
```

---

## Step 3 — Create App Registration and Service Principal

GitHub Actions authenticates to Azure via OIDC using an App Registration.

```bash
# Create the App Registration
az ad app create --display-name "sp-orders-terraform"
```

From the output, note the `appId` value. Then create the Service Principal:

```bash
az ad sp create --id <appId-from-above>
```

---

## Step 4 — Assign Contributor Role to the Service Principal

The Service Principal needs Contributor access on your subscription to create resources.

```bash
az ad sp create-for-rbac \
  --name "sp-orders-terraform" \
  --role Contributor \
  --scopes /subscriptions/0bb4f66b-be3a-4331-941c-fd6c8c0a3eef
```

Output will look like:

```json
{
  "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "displayName": "sp-orders-terraform",
  "password": "...",
  "tenant": "f5666466-d48d-4b60-a921-7ebad0f1d5fc"
}
```

**Save the `appId`** — this is your `AZURE_CLIENT_ID`.
The `password` is **not needed** since we use OIDC (no secret-based auth).

> **Note:** The Service Principal also needs `User Access Administrator` role if Terraform
> will create role assignments (e.g. AcrPull). Add it with:
>
> ```bash
> az role assignment create \
>   --assignee <appId> \
>   --role "User Access Administrator" \
>   --scope /subscriptions/0bb4f66b-be3a-4331-941c-fd6c8c0a3eef
> ```

---

## Step 5 — Create OIDC Federated Credential for GitHub Actions

This allows GitHub Actions to authenticate to Azure without storing a client secret.

### 5.1 — Get the App Object ID

```bash
az ad app list \
  --filter "displayName eq 'sp-orders-terraform'" \
  --query "[].id" \
  -o tsv
```

### 5.2 — Create the Federated Credential

```bash
az ad app federated-credential create \
  --id <APP_OBJECT_ID_FROM_5.1> \
  --parameters '{
    "name": "github-actions-infra",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:roysantu2002/azure-container-app-spring-boot:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

**Verify:**

```bash
az ad app federated-credential list --id <APP_OBJECT_ID> --query "[].{name:name, subject:subject}" -o table
```

Expected output:

```
Name                   Subject
---------------------  ---------------------------------------------------------------
github-actions-infra   repo:roysantu2002/azure-container-app-spring-boot:ref:refs/heads/main
```

---

## Step 6 — Configure GitHub Repository Secrets

Go to your GitHub repository: **Settings > Secrets and variables > Actions > New repository secret**

| Secret Name | Value | Where to Find It |
|---|---|---|
| `AZURE_CLIENT_ID` | `appId` from Step 4 output | `az ad app list --filter "displayName eq 'sp-orders-terraform'" --query "[].appId" -o tsv` |
| `AZURE_TENANT_ID` | `f5666466-d48d-4b60-a921-7ebad0f1d5fc` | `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | `0bb4f66b-be3a-4331-941c-fd6c8c0a3eef` | `az account show --query id -o tsv` |
| `ACR_NAME` | `acrordersdev` | Used by the image build/deploy workflow (not infra) |

---

## What These Pre-Requisites Enable

```
┌─────────────────────────────────────────────────────────────────┐
│                     GitHub Actions Runner                       │
│                                                                 │
│  1. azure/login@v2  ──── OIDC ────►  App Registration          │
│                                      (sp-orders-terraform)      │
│                                      with Federated Credential  │
│                                             │                   │
│  2. terraform init  ──── reads ────►  Storage Account           │
│                                      (stordersdevtfstate)       │
│                                      container: tfstate         │
│                                             │                   │
│  3. terraform apply ──── creates ──►  Azure Resources           │
│                                      - Resource Group           │
│                                      - Managed Identity         │
│                                      - Container Registry       │
│                                      - PostgreSQL Server + DB   │
│                                      - ACA Environment          │
│                                      - Container App            │
└─────────────────────────────────────────────────────────────────┘
```

---

## After Pre-Requisites Are Complete

1. Add the remote backend to `terraform/providers.tf` (if not already done)
2. Push your code to `main`
3. Go to **Actions > Provision Azure Infrastructure > Run workflow**
4. Select `dev` environment and `plan` action first to verify
5. Run again with `apply` to create all resources