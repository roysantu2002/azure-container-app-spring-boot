# Connect to Azure PostgreSQL via pgAdmin

> Use pgAdmin to browse, query, and edit data in the Azure PostgreSQL database using your Service Principal credentials.

---

   az account get-access-token --resource https://ossrdbms-aad.database.windows.net --query "accessToken" -o tsv  

  - AZURE_CLIENT_ID — run az ad sp list --display-name "orders-service-identity" --query "[0].appId" -o tsv                                         
  - AZURE_CLIENT_SECRET — this was shown only once when the SP was created. If you don't have it, ask admin to reset it: az ad app credential reset 
  --id <appId>    

## Prerequisites

- pgAdmin installed ([download here](https://www.pgadmin.org/download/))
- Azure CLI installed (`az --version`)
- Your SP credentials (same values from `.env.azure-debug`)
- Your IP already in the PostgreSQL firewall (see `run-with-azure.md` Step 2)

---

## Step 1 — Get an Access Token

Open a terminal and run:

```bash
# Login as the Service Principal
az login --service-principal \
  --username <AZURE_CLIENT_ID from .env.azure-debug> \
  --password <AZURE_CLIENT_SECRET from .env.azure-debug> \
  --tenant <AZURE_TENANT_ID from .env.azure-debug>

# Get a token for PostgreSQL
az account get-access-token \
  --resource https://ossrdbms-aad.database.windows.net \
  --query "accessToken" -o tsv
```

This prints a long token string. **Copy it** — this is your password for pgAdmin.

---

## Step 2 — Register a New Server in pgAdmin

1. Open pgAdmin
2. Right-click **Servers** → **Register** → **Server...**

### General tab

| Field | Value |
|---|---|
| Name | `Azure Orders Dev` |

### Connection tab

| Field | Value |
|---|---|
| Host name/address | `pg-orders-dev.postgres.database.azure.com` |
| Port | `5432` |
| Maintenance database | `ordersdb` |
| Username | `orders-service-local-debug` |
| Password | Paste the token from Step 1 |
| Save password | **No** |

### SSL tab

| Field | Value |
|---|---|
| SSL mode | `Require` |

Click **Save**.

---

## Step 3 — Browse and Edit Data

Navigate in the left panel:

```
Azure Orders Dev
  └── Databases
        └── ordersdb
              └── Schemas
                    └── orders
                          └── Tables
                                └── orders    ← right-click this
```

- **View data:** Right-click table → **View/Edit Data** → **All Rows**
- **Edit a cell:** Click any cell in the grid → type new value → press `F6` or click the save button (lightning bolt icon) to commit
- **Run SQL:** Click **Tools** → **Query Tool**, then write and run any SQL:

```sql
-- View all orders
SELECT * FROM orders.orders;

-- Update a specific order
UPDATE orders.orders SET customer_name = 'Updated Name' WHERE id = 'paste-uuid-here';

-- Delete a test order
DELETE FROM orders.orders WHERE customer_name = 'Local Debug Test';
```

---

## Step 4 — Verify Changes from Your App

If your app is running locally (see `run-with-azure.md`), confirm the changes:

```bash
curl http://localhost:8080/api/v1/orders
```

The response should reflect the data you modified in pgAdmin.

---

## Token Refresh

The access token **expires in ~1 hour**. When pgAdmin disconnects:

1. Run the token command again:

   ```bash
   az account get-access-token \
     --resource https://ossrdbms-aad.database.windows.net \
     --query "accessToken" -o tsv
   ```

2. In pgAdmin: right-click **Azure Orders Dev** → **Properties** → **Connection** tab → paste new token in Password → **Save**

3. Right-click **Azure Orders Dev** → **Connect Server**

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `FATAL: password authentication failed` | Token expired — get a new one (see above). Or SP has no PG role — ask admin to run `pgaadauth_create_principal`. |
| `could not connect to server: Connection refused` | Your IP is not in the PG firewall. Run: `MY_IP=$(curl -s https://ifconfig.me) && az postgres flexible-server firewall-rule create --name pg-orders-dev --resource-group rg-orders-dev --rule-name AllowMyIP --start-ip-address $MY_IP --end-ip-address $MY_IP` |
| `SSL connection is required` | Go to server Properties → SSL tab → set SSL mode to `Require` |
| `permission denied for schema orders` | SP needs grants — ask admin to run `GRANT USAGE ON SCHEMA orders TO "orders-service-local-debug"` |
| Can't see tables | Make sure you navigate to **ordersdb** → **Schemas** → **orders** (not the default `public` schema) |
