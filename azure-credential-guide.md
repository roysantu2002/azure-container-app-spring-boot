# Azure Credential & PostgreSQL Authentication — How It Works

---

## The Connection Flow

```
Your laptop                                            Azure
──────────                                             ─────

1. You run: az login
   Browser opens → you authenticate
   Azure CLI stores a refresh token locally (~/.azure/)

2. App starts with SPRING_PROFILES_ACTIVE=azure-debug

3. AzureCredentialConfig.java creates a TokenCredential bean
   using DefaultAzureCredentialBuilder

4. HikariCP opens a connection → JDBC driver sees
   authenticationPluginClassName in the URL

5. AzurePostgresqlAuthenticationPlugin activates
   Calls DefaultAzureCredential to get a token

6. DefaultAzureCredential tries each credential in order:

   EnvironmentCredential      → skipped (no AZURE_CLIENT_SECRET set)
   WorkloadIdentityCredential → skipped (not in Kubernetes)
   ManagedIdentityCredential  → skipped (not inside Azure)
   SharedTokenCacheCredential → skipped
   IntelliJCredential         → skipped
   AzureCliCredential         → ✅ FOUND — uses your az login session
                                   │
                                   ▼
7. AzureCliCredential calls:      Azure AD (Entra ID)
   "Give me a token for            │
    https://ossrdbms-aad.           │
    database.windows.net"           │
                                    ▼
8. Azure AD validates your      Returns OAuth2 JWT token
   identity and returns           (valid ~1 hour)
   a short-lived token              │
                                    │
9. JDBC plugin sends:              ▼
   username = your Entra email   Azure PostgreSQL
   password = the JWT token        │
                                   ▼
10. PostgreSQL checks:          "Is this user an Entra AD admin
                                 on this server?"
                                    │
                                    ▼
                                 ✅ YES → connection established
                                 ❌ NO  → FATAL: password
                                          authentication failed
```

---

## Identity Types in Azure PostgreSQL

Azure PostgreSQL supports three types of Entra ID identities. Each type requires a matching token type.

```
Identity Type          Where It Works           How Token Is Obtained
─────────────────────  ───────────────────────   ──────────────────────────────
Managed Identity       Inside Azure only         IMDS (169.254.169.254)
                       (Container Apps, VMs)     Automatic, no credentials

Service Principal      Anywhere                  Client ID + Client Secret
                       (local, CI/CD, Azure)     az ad app credential reset

Entra AD User          Anywhere                  az login (browser auth)
                       (local, portal)           No secret needed
```

### Why Managed Identity didn't work locally

```
Your laptop → calls IMDS at 169.254.169.254 → ❌ TIMEOUT
                                                  (IMDS only exists inside Azure)
```

### Why Service Principal didn't work

```
orders-service-identity is registered in PostgreSQL as MI type
Your token was from AzureCliCredential (user type)
PostgreSQL rejected: token type ≠ role type
```

### What works: Entra AD Admin

```
You are registered as Entra AD Admin on the PG server
  (via az postgres flexible-server ad-admin create)
az login gives you a user token
PostgreSQL validates: "Is this user an AD admin?" → YES
✅ Connected
```

---

## How Entra AD Admin Differs from pgaadauth_create_principal

| Method | Command | What It Does |
|---|---|---|
| **Entra AD Admin** | `az postgres flexible-server ad-admin create` | Grants full admin access to the PG server via Azure control plane. No SQL needed. |
| **pgaadauth_create_principal** | `SELECT * FROM pgaadauth_create_principal(...)` | Creates a PG role for a specific identity. Requires an existing admin connection. Deprecated in newer Entra versions. |

Your setup uses the **Entra AD Admin** approach — simpler, managed via Azure CLI, no SQL grants needed.

---

## Files Involved

```
orders-platform-scaffold/
│
├── .env.azure-debug                          ← Your credentials (gitignored)
│     SPRING_PROFILES_ACTIVE=azure-debug
│     POSTGRES_HOST=pg-orders-dev...
│     POSTGRES_DB=ordersdb
│     POSTGRES_AZURE_USER=your-entra-email
│
├── application/src/main/
│   ├── resources/
│   │   ├── application.yml                   ← Base config (used by all profiles)
│   │   ├── application-local.yml             ← Local: localhost, password auth
│   │   └── application-azure-debug.yml       ← Azure: remote host, token auth
│   │
│   └── java/com/example/orders/config/
│       ├── AzureCredentialConfig.java         ← Creates DefaultAzureCredential bean
│       │                                        Only loads when profile=azure-debug
│       └── StartupInfoLogger.java            ← Logs DB connection details on startup
│
└── .vscode/launch.json                       ← VS Code debug configs (reads .env file)
```

### AzureCredentialConfig.java — What it does

```java
@Configuration
@Profile("azure-debug")                       // Only loads for azure-debug profile
public class AzureCredentialConfig {

    @Bean
    public TokenCredential defaultAzureCredential() {
        return new DefaultAzureCredentialBuilder().build();
        //     ↑
        //     Creates a credential chain that tries multiple methods
        //     in order until one succeeds.
        //     Locally: AzureCliCredential wins (from your az login)
        //     On Azure: ManagedIdentityCredential wins (from IMDS)
    }
}
```

### application-azure-debug.yml — What it overrides

```yaml
spring.datasource:
  url: jdbc:postgresql://${POSTGRES_HOST}:5432/...   # → Azure PG (from .env)
  username: ${POSTGRES_AZURE_USER}                   # → Your Entra email (from .env)
  azure.passwordless-enabled: true                   # → Use token, not password
  cloud.azure.credential.managed-identity-enabled: false  # → Don't try IMDS

spring.jpa.show-sql: true                            # → See SQL in console
spring.flyway.enabled: false                         # → Don't run migrations on Azure DB
```

---

## How Token Refresh Works

```
Token lifetime: ~1 hour

HikariCP max-lifetime: 30 minutes
  → Connections are recycled every 30 min
  → When a new connection is created, the plugin fetches a fresh token
  → AzureCliCredential uses az login refresh token (valid for days)
  → Result: as long as az login session is valid, tokens auto-refresh

If az login expires (after days of inactivity):
  → App throws "Failed to obtain token"
  → Fix: run "az login" again, restart the app
```

---

## Environment Comparison

| Setting | Local (Docker) | Azure Debug | Azure Production |
|---|---|---|---|
| Profile | `local` | `azure-debug` | `dev` |
| PG Host | `localhost` | `pg-orders-dev...azure.com` | `pg-orders-dev...azure.com` |
| Auth | Password (`postgres/postgres`) | Entra AD token (az login) | MI token (IMDS) |
| Credential Bean | Not loaded | `AzureCredentialConfig` | Spring Cloud Azure auto-config |
| Credential Chain Winner | N/A | `AzureCliCredential` | `ManagedIdentityCredential` |
| Flyway | Enabled (runs migrations) | Disabled (safety) | Enabled |
| SSL | Off | Require | Require |
| Token source | N/A | `~/.azure/` (az login cache) | IMDS `169.254.169.254` |

---

## Quick Commands

```bash
# Login
az login

# Check who you're logged in as
az account show --query "{user:user.name, subscription:name}" -o table

# Check if your token is still valid
az account get-access-token \
  --resource https://ossrdbms-aad.database.windows.net \
  --query "{expiresOn:expiresOn}" -o table

# Check Entra AD admins on the PG server
az postgres flexible-server ad-admin list \
  --server-name pg-orders-dev \
  --resource-group rg-orders-dev \
  -o table

# Run the app
cd application
source ../.env.azure-debug && mvn spring-boot:run
```
