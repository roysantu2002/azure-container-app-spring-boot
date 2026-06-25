# Run Locally Against Azure PostgreSQL

---

## One-Time Setup

### 1. Edit `.env.azure-debug`

Open the file at the project root and replace the three `REPLACE_ME` values:

```bash
SPRING_PROFILES_ACTIVE=azure-debug
POSTGRES_HOST=pg-orders-dev.postgres.database.azure.com
POSTGRES_DB=ordersdb
POSTGRES_AZURE_USER=orders-service-local-debug
AZURE_CLIENT_ID=<paste your SP client id>
AZURE_CLIENT_SECRET=<paste your SP client secret>
AZURE_TENANT_ID=<paste your tenant id>
```

This file is **gitignored** — your secrets will not be committed.

### 2. Add your IP to the PostgreSQL firewall

```bash
az login

MY_IP=$(curl -s https://ifconfig.me)

az postgres flexible-server firewall-rule create \
  --name pg-orders-dev \
  --resource-group rg-orders-dev \
  --rule-name AllowMyIP \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP
```

### 3. Verify the SP has a PostgreSQL role

If not done, ask admin to run on the Azure PostgreSQL server:

```sql
SELECT * FROM pgaadauth_create_principal('orders-service-local-debug', false, false);
GRANT USAGE ON SCHEMA orders TO "orders-service-local-debug";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orders TO "orders-service-local-debug";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA orders TO "orders-service-local-debug";
```

---

## Run from Terminal

```bash
cd application
source ../.env.azure-debug && mvn spring-boot:run
```

That's it. Wait for:

```
HikariPool-1 - Start completed.          ← connected to Azure DB
Started OrdersApplication in X seconds   ← app ready
```

Test:

```bash
curl http://localhost:8080/api/v1/orders
```

Stop: `Ctrl+C`

---

## Run from VS Code (Debug Mode)

1. Open project in VS Code
2. Set breakpoints in any Java file (click left of line numbers)
3. Press `Cmd+Shift+D` → select **"Debug Azure DB (Service Principal)"**
4. Press `F5`

VS Code reads credentials from `.env.azure-debug` automatically. No prompts.

Test:

```bash
curl http://localhost:8080/api/v1/orders
```

VS Code pauses at your breakpoint. Use:

| Key | Action |
|---|---|
| `F10` | Step over |
| `F11` | Step into |
| `Shift+F11` | Step out |
| `F5` | Continue |
| `Shift+F5` | Stop |

---

## How It Works

```
.env.azure-debug                          Azure
─────────────────                         ─────
AZURE_CLIENT_ID      ─┐
AZURE_CLIENT_SECRET  ─┼──► AzureCredentialConfig.java
AZURE_TENANT_ID      ─┘    creates DefaultAzureCredential
                                    │
                                    ▼
                            Gets AAD token ──────────► Azure AD
                                                         │
                            Receives token ◄─────────────┘
                                    │
                                    ▼
POSTGRES_HOST        ───► JDBC connects to ──────────► Azure PostgreSQL
POSTGRES_AZURE_USER  ───► username                     validates token
POSTGRES_DB          ───► database                           │
                                                       ✅ Connected
```

**Files involved:**

| File | Purpose |
|---|---|
| `.env.azure-debug` | Your credentials (gitignored) |
| `application-azure-debug.yml` | Spring config: Azure PG URL, passwordless auth, Flyway off |
| `AzureCredentialConfig.java` | Creates `TokenCredential` bean from `DefaultAzureCredentialBuilder` |
| `.vscode/launch.json` | VS Code reads `.env.azure-debug` for debug runs |

---

## Troubleshooting

| Error | Fix |
|---|---|
| `password authentication failed` | SP has no PG role — ask admin to run `pgaadauth_create_principal` |
| `Connection refused` / timeout | Your IP not in PG firewall — redo Step 2 |
| `AADSTS700016: Application not found` | Wrong `AZURE_CLIENT_ID` in `.env.azure-debug` |
| `AADSTS7000215: Invalid client secret` | Wrong or expired `AZURE_CLIENT_SECRET` |
| `Could not resolve placeholder` | Missing value in `.env.azure-debug` |
| Port 8080 in use | `lsof -i :8080` then `kill <pid>` |
