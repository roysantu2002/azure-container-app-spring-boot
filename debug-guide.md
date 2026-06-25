# Debug Guide — Running in VS Code

> Step-by-step instructions for debugging the Spring Boot app in VS Code, both against a local Docker DB and the real Azure PostgreSQL.

---

source ../.env.azure-debug && mvn spring-boot:run


## Prerequisites

### VS Code Extensions (Required)

Install these from the Extensions panel (`Cmd+Shift+X`):

1. **Extension Pack for Java** (Microsoft) — includes:
   - Language Support for Java
   - Debugger for Java
   - Maven for Java
   - Project Manager for Java
2. **Spring Boot Extension Pack** (VMware/Broadcom) — includes:
   - Spring Boot Tools
   - Spring Boot Dashboard

After installing, **restart VS Code**.

### Verify Java is detected

Open the VS Code terminal (`Ctrl+`` `) and run:

```bash
java -version     # should show 21+
mvn -version      # should show 3.9+
```

---

## Option A: Debug Against Local Docker PostgreSQL

This is the simplest setup — no Azure credentials needed.

### Step 1 — Start PostgreSQL

```bash
docker run -d \
  --name ordersdb \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=ordersdb \
  -p 5432:5432 \
  postgres:16
```

### Step 2 — Open the project in VS Code

```bash
code /path/to/orders-platform-scaffold
```

VS Code should detect it as a Java/Maven project automatically (look for the Java progress bar in the bottom status bar).

### Step 3 — Set breakpoints

Open any Java file (e.g., `OrderController.java`) and click on the left gutter (to the left of the line numbers) to add a red breakpoint dot.

Good places to set breakpoints:
- `OrderController.java` line 24 — `listOrders()` method
- `OrderController.java` line 36 — `createOrder()` method

### Step 4 — Start debugging

**Method 1 — Run and Debug panel:**
1. Click the **Run and Debug** icon in the left sidebar (play button with a bug)
2. Select **"Debug Local (Docker PostgreSQL)"** from the dropdown at the top
3. Click the green **play** button (or press `F5`)

**Method 2 — Spring Boot Dashboard:**
1. Open the Spring Boot Dashboard (icon in the left sidebar, or `Cmd+Shift+P` → "Spring Boot Dashboard")
2. Right-click on `orders-service` → **Debug**

### Step 5 — Test

Once the console shows `Started OrdersApplication`, hit the endpoints:

```bash
curl http://localhost:8080/api/v1/orders
```

VS Code will pause at your breakpoint. You can:
- **F10** — Step over (next line)
- **F11** — Step into (enter a method)
- **Shift+F11** — Step out (exit current method)
- **F5** — Continue (run until next breakpoint)
- Hover over variables to see their values
- Use the **VARIABLES** panel on the left to inspect objects
- Use the **DEBUG CONSOLE** at the bottom to evaluate expressions

### Step 6 — Stop

Click the red **stop** button in the debug toolbar, or press `Shift+F5`.

```bash
# Clean up Docker
docker stop ordersdb && docker rm ordersdb
```

---

## Option B: Debug Against Azure PostgreSQL (Service Principal)

Use this when you need to debug with real Azure data and only a service identity has PostgreSQL access.

### Why not Managed Identity directly?

Managed Identity tokens come from Azure's Instance Metadata Service (IMDS at `169.254.169.254`), which is **only available inside Azure** (Container Apps, VMs, etc.). Your laptop cannot call IMDS, so you cannot use the MI directly.

The solution: create a **Service Principal** with a client secret. Give it the same PostgreSQL role as the MI. The `DefaultAzureCredential` in the Azure JDBC plugin picks up SP credentials from environment variables automatically.

### Step 1 — Admin creates a Service Principal (one-time setup)

Ask your admin to run:

```bash
# Create an App Registration + Service Principal
az ad app create --display-name "orders-service-local-debug"
APP_ID=$(az ad app list --display-name "orders-service-local-debug" --query "[0].appId" -o tsv)

az ad sp create --id $APP_ID

# Create a client secret (save the output — password is shown only once)
az ad app credential reset --id $APP_ID --display-name "local-debug" --years 1
```

The output will show:

```json
{
  "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",    <-- this is the CLIENT_ID
  "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",    <-- this is the CLIENT_SECRET
  "tenant": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"     <-- this is the TENANT_ID
}
```

**Save these three values.** The password is shown only once.

Then register the SP as a PostgreSQL role:

```sql
-- Admin runs this on the Azure PostgreSQL server
SELECT * FROM pgaadauth_create_principal('orders-service-local-debug', false, false);
GRANT USAGE ON SCHEMA orders TO "orders-service-local-debug";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orders TO "orders-service-local-debug";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA orders TO "orders-service-local-debug";
```

### Step 2 — Add your IP to the PostgreSQL firewall

```bash
MY_IP=$(curl -s https://ifconfig.me)
echo "Your IP: $MY_IP"

az postgres flexible-server firewall-rule create \
  --name pg-orders-dev \
  --resource-group rg-orders-dev \
  --rule-name AllowMyIP \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP
```

### Step 3 — Set breakpoints

Same as Option A — click the gutter next to any line in your Java files.

### Step 4 — Start debugging

1. Click **Run and Debug** in the left sidebar
2. Select **"Debug Azure DB (Service Principal)"** from the dropdown
3. Press `F5`
4. VS Code will prompt for three values:
   - **Service Principal App/Client ID** — the `appId` from Step 1
   - **Client Secret** — the `password` from Step 1 (masked input)
   - **Tenant ID** — the `tenant` from Step 1
5. The app starts, gets an AAD token using the SP credentials, connects to Azure PostgreSQL

### How it works under the hood

```
App starts with profile=azure-debug
  |
  ├── JDBC URL has authenticationPluginClassName=AzurePostgresqlAuthenticationPlugin
  |
  ├── managed-identity-enabled = false
  |
  ├── DefaultAzureCredential activates, checks in order:
  |     1. EnvironmentCredential → finds AZURE_CLIENT_ID + AZURE_CLIENT_SECRET + AZURE_TENANT_ID
  |     2. Gets an AAD token for https://ossrdbms-aad.database.windows.net
  |
  ├── Token sent as password to Azure PostgreSQL
  |     PG validates: "is orders-service-local-debug a valid AAD principal with a role?"
  |
  ├── Connection established — same DB, same data as production
  |
  └── Flyway DISABLED — no accidental migrations on shared DB
```

### Step 5 — Test

```bash
# List orders from the real Azure database
curl http://localhost:8080/api/v1/orders

# Get a specific order
curl http://localhost:8080/api/v1/orders/<uuid>
```

The debugger will pause at your breakpoints, showing real Azure data in the variable inspector.

### Step 6 — Stop

`Shift+F5` or click the red stop button.

---

## Option C: Debug Against Azure PostgreSQL (az login)

Use this if your AAD user (your email) has been granted a PostgreSQL role directly.

### Step 1 — Login to Azure CLI

```bash
az login
az account show --query "{name:name, id:id}" -o table
```

### Step 2 — Admin grants your AAD user a PostgreSQL role (one-time)

```sql
SELECT * FROM pgaadauth_create_principal('your-email@domain.com', false, true);
GRANT USAGE ON SCHEMA orders TO "your-email@domain.com";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA orders TO "your-email@domain.com";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA orders TO "your-email@domain.com";
```

### Step 3 — Start debugging

1. Click **Run and Debug** in the left sidebar
2. Select **"Debug Azure DB (az login)"** from the dropdown
3. Press `F5`
4. Enter your Azure AD email when prompted

---

## Debug Configurations Reference

The file `.vscode/launch.json` contains three configurations:

| Configuration | Profile | Database | Auth Method |
|---|---|---|---|
| Debug Local (Docker PostgreSQL) | `local` | `localhost:5432` | password (`postgres/postgres`) |
| Debug Azure DB (Service Principal) | `azure-debug` | Azure PG server | SP client secret → AAD token |
| Debug Azure DB (az login) | `azure-debug` | Azure PG server | Azure CLI → AAD token |

### Customizing

To avoid being prompted for SP credentials every time, hardcode them in `.vscode/launch.json`:

```json
"env": {
    "SPRING_PROFILES_ACTIVE": "azure-debug",
    "POSTGRES_HOST": "your-pg-server.postgres.database.azure.com",
    "POSTGRES_DB": "ordersdb",
    "POSTGRES_AZURE_USER": "orders-service-local-debug",
    "AZURE_CLIENT_ID": "your-sp-app-id",
    "AZURE_CLIENT_SECRET": "your-sp-secret",
    "AZURE_TENANT_ID": "your-tenant-id"
}
```

**Note:** `launch.json` is in `.vscode/` which should be gitignored if it contains secrets. Alternatively, put secrets in a `.env` file and reference it.

---

## Troubleshooting

### "Build failed" when pressing F5

```bash
# Build manually first to see the full error
cd application && mvn clean compile
```

### "Cannot resolve symbol" or red squiggles everywhere

VS Code Java needs to build its index. Try:
1. `Cmd+Shift+P` → **"Java: Clean Java Language Server Workspace"**
2. Restart VS Code

### Azure debug: "Failed to obtain token" or "AADSTS..."

```bash
# Check your az login is still valid
az account get-access-token --resource https://ossrdbms-aad.database.windows.net --query "expiresOn" -o tsv
```

If expired:
```bash
az login
```

### Azure debug: "FATAL: password authentication failed for user"

Your AAD user doesn't have a PostgreSQL role. Ask admin to run the `pgaadauth_create_principal` command from Step 2 of Option B.

### Azure debug: "Connection refused" or "timeout"

The Azure PG server firewall may not allow your IP:

```bash
# Check current firewall rules
az postgres flexible-server firewall-rule list \
  --name pg-orders-dev \
  --resource-group rg-orders-dev \
  -o table

# Add your IP (if you have permission)
MY_IP=$(curl -s https://ifconfig.me)
az postgres flexible-server firewall-rule create \
  --name pg-orders-dev \
  --resource-group rg-orders-dev \
  --rule-name AllowMyIP \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP
```

### Flyway runs and modifies the Azure DB

This shouldn't happen — `application-azure-debug.yml` sets `flyway.enabled: false`. If it does, check that the profile is `azure-debug` (not `dev` or `local`).

### Port 8080 already in use

Another instance is running. Kill it:

```bash
lsof -i :8080 | grep LISTEN
# Then kill the PID shown
kill <pid>
```

---

## Quick Reference — Debug Keyboard Shortcuts (VS Code)

| Action | Shortcut |
|---|---|
| Start/Continue debugging | `F5` |
| Stop debugging | `Shift+F5` |
| Step over | `F10` |
| Step into | `F11` |
| Step out | `Shift+F11` |
| Toggle breakpoint | `F9` |
| Restart debugging | `Cmd+Shift+F5` |
| Open Debug Console | `Cmd+Shift+Y` |
| Evaluate expression | Select text → right-click → "Evaluate in Debug Console" |
