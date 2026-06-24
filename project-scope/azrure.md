# Azure Portal Step-by-Step Guide
## PostgreSQL Flexible Server + Managed Identity → Spring Boot (orders-service)

> **Scope:** Aligned to the Enterprise Azure Platform Framework (ACA + PostgreSQL + Managed Identity).
> All steps are performed via the Azure Portal (no CLI required).
> Estimated time: 45–60 minutes end-to-end.

---

## Prerequisites (confirm before starting)

| Requirement | Notes |
|---|---|
| Azure subscription | Owner or Contributor + User Access Administrator role |
| Resource Group exists | e.g. `rg-orders-dev` |
| ACA Environment exists | e.g. `cae-orders-dev` (with VNet if applicable) |
| ACR exists | e.g. `acrordersdev.azurecr.io` |
| Entra ID access | Ability to create Managed Identities and assign DB roles |

---

## PART 1 — Create User-Assigned Managed Identity (UAMI)

The identity is what your Spring Boot app will use to authenticate to PostgreSQL — no passwords ever.

### Step 1.1 — Create the Managed Identity

1. In the Azure Portal search bar, type **Managed Identities** and select it.
2. Click **+ Create**.
3. Fill in:
   - **Subscription:** your subscription
   - **Resource Group:** `rg-orders-dev`
   - **Region:** same region as your PostgreSQL server (e.g. East US, Central India)
   - **Name:** `orders-service-identity`
4. Click **Review + Create** → **Create**.
5. Once deployed, click **Go to resource**.
6. **Copy and save** the following (you'll need them later):
   - **Client ID** (shown on the Overview blade)
   - **Object (Principal) ID**
   - **Name:** `orders-service-identity`

---

## PART 2 — Create PostgreSQL Flexible Server

### Step 2.1 — Open the creation wizard

1. In the portal search bar, type **Azure Database for PostgreSQL flexible servers**.
2. Click **+ Create** → choose **Flexible server**.

### Step 2.2 — Basics tab

| Field | Value |
|---|---|
| Subscription | your subscription |
| Resource Group | `rg-orders-dev` |
| Server name | `pg-orders-dev` (must be globally unique; becomes `pg-orders-dev.postgres.database.azure.com`) |
| Region | same as your ACA environment |
| PostgreSQL version | **16** (or 15 minimum) |
| Workload type | Development (for dev/test) / Production (for prod) |
| Availability zone | No preference (or Zone 1 for HA) |
| High availability | ✅ Enable only for production (adds cost) |
| Authentication method | **Microsoft Entra authentication only** ← CRITICAL |

> ⚠️ **Important:** Selecting "Microsoft Entra authentication only" disables password logins entirely. This is the secure default aligned to the platform framework. If you need password access for migration scripts, choose "Microsoft Entra and PostgreSQL authentication" temporarily, then switch after setup.

### Step 2.3 — Set Entra Admin

Still on the Basics tab, under **Microsoft Entra admin**:

1. Click **Set admin**.
2. Search for and select your own Entra user account (the one you are logged into the portal with).
3. Click **Select**.
4. Your account is now the Entra admin for this PostgreSQL server.

> Your Entra admin account allows you to connect as a superuser via `psql` using an AAD token. This is needed for the role grant in Part 4.

### Step 2.4 — Compute + Storage tab

| Field | Recommendation |
|---|---|
| Compute tier | **Burstable** (dev) / **General Purpose** (prod) |
| Compute size | Standard_B2ms (dev) / Standard_D4ds_v5 (prod) |
| Storage | 32 GiB (auto-grow enabled) |
| Backup retention | 7 days (dev) / 35 days (prod) |

### Step 2.5 — Networking tab

**Choose based on your architecture:**

**Option A — Public access with firewall (dev/test only)**
- Connectivity method: **Public access (allowed IP addresses)**
- Allow Azure services: ✅ (tick this so ACA can connect)
- Add your local IP if you want to connect from your machine

**Option B — Private access / VNet (recommended for prod)**
- Connectivity method: **Private access (VNet integration)**
- Virtual Network: select your spoke VNet (e.g. `vnet-orders-dev`)
- Subnet: select or create a **delegated subnet** for PostgreSQL (e.g. `snet-postgres-dev`)
  - Minimum subnet size: `/28`
  - Delegation: `Microsoft.DBforPostgreSQL/flexibleServers`
- Private DNS zone: let Azure create `privatelink.postgres.database.azure.com` or use your existing one

> If using VNet (Option B), your ACA environment must be in the same VNet or a peered VNet for the private DNS to resolve.

### Step 2.6 — Review + Create

1. Click **Review + Create**.
2. Review all settings.
3. Click **Create**.
4. ⏳ Wait 5–10 minutes for provisioning.
5. Click **Go to resource** when complete.

### Step 2.7 — Note the server details

From the Overview blade, copy:
- **Server name:** `pg-orders-dev.postgres.database.azure.com`

---

## PART 3 — Create the Orders Database

### Step 3.1

1. On your PostgreSQL server page, in the left menu under **Settings**, click **Databases**.
2. Click **+ Add**.
3. Enter:
   - **Database name:** `ordersdb`
   - **Character set:** UTF8
   - **Collation:** en_US.utf8
4. Click **Save**.

---

## PART 4 — Grant the Managed Identity Access to PostgreSQL

This is the key step. We create a PostgreSQL role mapped to the Managed Identity's Entra principal.

### Step 4.1 — Connect to PostgreSQL as Entra Admin

You need a PostgreSQL client. Options:

**Option A: Azure Cloud Shell (simplest — no local install)**
1. Click the **Cloud Shell** icon (>_) in the top-right portal toolbar.
2. Choose **Bash**.

**Option B: Local psql with Azure CLI**
- Requires: `psql` and `az` CLI installed locally.

### Step 4.2 — Acquire an Entra token and connect

**In Cloud Shell:**

```bash
# Get an access token for PostgreSQL
export PGPASSWORD=$(az account get-access-token \
  --resource-type oss-rdbms \
  --query accessToken \
  --output tsv)

# Connect as your Entra admin
psql "host=pg-orders-dev.postgres.database.azure.com \
      port=5432 \
      dbname=ordersdb \
      user=<your-entra-email@domain.com> \
      sslmode=require"
```

Replace `<your-entra-email@domain.com>` with the email address of your Entra admin account (the one you set in Step 2.3).

### Step 4.3 — Create the role for the Managed Identity

Once connected, run:

```sql
-- 1. Enable the pgaad extension (required for AAD role mapping)
SELECT * FROM pg_available_extensions WHERE name = 'pgaad';

-- 2. Create a PostgreSQL role mapped to the Managed Identity
--    The name MUST exactly match the Managed Identity display name in Entra
SELECT * FROM pgaad.aad_create_principal_with_oid(
    'orders-service-identity',              -- Managed Identity display name
    '<OBJECT-ID-FROM-PART-1>',              -- Object (Principal) ID from Step 1.1
    'service'                               -- type: 'service' for Managed Identity
);

-- 3. Grant schema and table permissions
GRANT USAGE ON SCHEMA orders TO "orders-service-identity";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orders TO "orders-service-identity";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA orders TO "orders-service-identity";

-- 4. Grant default privileges for future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA orders
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "orders-service-identity";

-- 5. Verify
\du orders-service-identity
```

> **Note:** The Flyway migration (V1__create_orders_schema.sql) creates the `orders` schema and table. If you run Flyway before this grant, run the grants after migration completes. If you need Flyway to run as the MI, grant `CREATE` on the database as well.

### Step 4.4 — Grant Flyway migration permissions (if running as the MI)

If your Spring Boot app runs Flyway at startup (as configured), the MI also needs DDL rights:

```sql
GRANT CREATE ON DATABASE ordersdb TO "orders-service-identity";
GRANT ALL ON SCHEMA orders TO "orders-service-identity";
```

---

## PART 5 — Assign the Managed Identity to Your Container App

### Step 5.1

1. In the portal, navigate to your **Container App** (e.g. `ca-orders-dev`).
2. In the left menu under **Settings**, click **Identity**.
3. Click the **User assigned** tab.
4. Click **+ Add**.
5. Select `orders-service-identity` from the list.
6. Click **Add**.

Your Container App is now associated with the Managed Identity and will use it when `DefaultAzureCredential` runs.

---

## PART 6 — Configure Container App Environment Variables

The Spring Boot app reads these at startup.

### Step 6.1

1. In your Container App, go to **Settings → Environment variables** (or **Containers → Edit and deploy** → select your container).
2. Add the following environment variables:

| Name | Value | Secret? |
|---|---|---|
| `POSTGRES_HOST` | `pg-orders-dev.postgres.database.azure.com` | No |
| `POSTGRES_DB` | `ordersdb` | No |
| `POSTGRES_MI_USER` | `orders-service-identity` | No |
| `SPRING_PROFILES_ACTIVE` | (leave blank or set to a profile name) | No |

3. Click **Save** / **Create revision**.

> **No password is set.** The Spring Boot `AzurePostgresDataSourceConfig` bean fetches the token from `DefaultAzureCredential` using the attached UAMI automatically.

---

## PART 7 — (Optional) Configure Private DNS for VNet Deployments

If you chose **Option B (private access)** in Step 2.5:

### Step 7.1 — Verify Private DNS Zone

1. In the portal, search for **Private DNS zones**.
2. Find `privatelink.postgres.database.azure.com`.
3. Click on it and check **Virtual network links**.
4. Verify your ACA spoke VNet is linked. If not:
   - Click **+ Add** under Virtual network links.
   - Select your spoke VNet.
   - Enable auto-registration if desired.
   - Click **OK**.

### Step 7.2 — Verify A Record

1. In the same Private DNS zone, click **Overview** → **Recordsets**.
2. You should see an A record for `pg-orders-dev` pointing to a private IP.
3. If missing, go back to your PostgreSQL server → **Networking** → verify private endpoint is created.

---

## PART 8 — Verify the Connection

### Step 8.1 — Check Container App logs

1. Navigate to your Container App → **Monitoring → Log stream**.
2. Deploy or restart the app.
3. Look for these log lines from `AzurePostgresDataSourceConfig`:

```
INFO  c.e.o.config.AzurePostgresDataSourceConfig - HikariCP pool initialised with AAD token for user 'orders-service-identity'
```

If you see a Hikari pool error or `PSQLException`, check:
- The MI is attached to the Container App (Part 5)
- The role was created in PostgreSQL (Part 4)
- The `POSTGRES_MI_USER` env var matches the MI display name exactly

### Step 8.2 — Test the /orders endpoint

Once running, test with a quick HTTP call:

**POST /orders — create an order:**
```http
POST https://<your-aca-fqdn>/orders
Content-Type: application/json

{
  "customerName": "Priya Sharma",
  "customerEmail": "priya@example.com",
  "productName": "Wireless Keyboard",
  "quantity": 2,
  "unitPrice": 1499.99,
  "notes": "Gift wrap requested"
}
```

Expected response `201 Created`:
```json
{
  "id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
  "customerName": "Priya Sharma",
  "customerEmail": "priya@example.com",
  "productName": "Wireless Keyboard",
  "quantity": 2,
  "unitPrice": 1499.99,
  "totalPrice": 2999.98,
  "status": "PENDING",
  "notes": "Gift wrap requested",
  "createdAt": "2025-06-24T10:30:00Z",
  "updatedAt": "2025-06-24T10:30:00Z"
}
```

**GET /orders — list all orders:**
```http
GET https://<your-aca-fqdn>/orders
GET https://<your-aca-fqdn>/orders?status=PENDING
GET https://<your-aca-fqdn>/orders?customerEmail=priya@example.com
GET https://<your-aca-fqdn>/orders?page=0&size=10&sort=createdAt,desc
```

**GET /orders/{id} — retrieve one order:**
```http
GET https://<your-aca-fqdn>/orders/3fa85f64-5717-4562-b3fc-2c963f66afa6
```

---

## PART 9 — Health Probes (ACA Liveness + Readiness)

The app exposes Spring Actuator at `/actuator/health`.

### Step 9.1 — Configure probes in ACA

1. In your Container App → **Containers → Edit and deploy**.
2. Select your container → **Health probes**.
3. Add:

**Liveness probe:**
| Field | Value |
|---|---|
| Type | HTTP |
| Path | `/actuator/health/liveness` |
| Port | 8080 |
| Initial delay | 30 seconds |
| Period | 30 seconds |

**Readiness probe:**
| Field | Value |
|---|---|
| Type | HTTP |
| Path | `/actuator/health/readiness` |
| Port | 8080 |
| Initial delay | 20 seconds |
| Period | 10 seconds |

---

## PART 10 — Firewall Rule for Local Development (Optional)

To connect from your laptop using `psql` or a DB client:

1. Go to your PostgreSQL server → **Networking**.
2. Under **Firewall rules**, click **+ Add current client IP address**.
3. Click **Save**.
4. Connect using an AAD token (same as Part 4.2) or, if you enabled password auth, with a password.

---

## Summary Checklist

| Step | Task | Done |
|---|---|---|
| 1 | User-Assigned Managed Identity created (`orders-service-identity`) | ☐ |
| 2 | PostgreSQL Flexible Server created with **Entra auth only** | ☐ |
| 3 | `ordersdb` database created | ☐ |
| 4 | Entra admin set on the PostgreSQL server | ☐ |
| 5 | MI role created in PostgreSQL + grants applied | ☐ |
| 6 | UAMI attached to Container App | ☐ |
| 7 | Environment variables set in Container App | ☐ |
| 8 | Private DNS linked to VNet (if using private access) | ☐ |
| 9 | App deployed, logs show successful pool init | ☐ |
| 10 | POST /orders and GET /orders return correct responses | ☐ |

---

## Troubleshooting Reference

| Symptom | Likely Cause | Fix |
|---|---|---|
| `FATAL: password authentication failed` | Using wrong auth method; password field non-empty | Ensure datasource.password is blank; check Entra-only mode is on |
| `role "orders-service-identity" does not exist` | Part 4 role grant not run | Re-run `pgaad.aad_create_principal_with_oid(...)` |
| `Connection timed out` (VNet) | Private DNS not linked | Link spoke VNet to `privatelink.postgres.database.azure.com` |
| `ManagedIdentityCredential authentication unavailable` | UAMI not attached to Container App | Redo Part 5; redeploy |
| `Object ID mismatch` | Wrong Object ID used in `aad_create_principal_with_oid` | Use the **Object (Principal) ID** from Managed Identity → Overview, not the Client ID |
| Flyway migration fails | MI lacks CREATE privilege | Grant `CREATE ON DATABASE ordersdb` to MI role |

---

*Guide aligned to: Enterprise-ready Cloud-Native Platform Architecture Framework — Azure PostgreSQL Flexible Server + Managed Identity passwordless authentication.*
