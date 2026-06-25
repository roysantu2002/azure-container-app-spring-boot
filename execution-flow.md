# Execution Flow — Local & Azure

> Step-by-step guide for running the orders-platform application locally and on Azure Container Apps.

---

## How Spring Profiles Work in This Project

Spring Boot loads configuration in layers:

1. `application.yml` — **always loaded** (base config for all environments)
2. `application-{profile}.yml` — **loaded on top** when that profile is active, overriding only the keys it declares

```
┌─────────────────────────────────────────────────────────────┐
│                     application.yml                         │
│  (base config — env var placeholders, Azure auth plugin,    │
│   Hikari pool, Flyway, JPA, actuator)                       │
├─────────────────────────────────────────────────────────────┤
│  Profile = "local"           │  Profile = "dev"             │
│  application-local.yml       │  (no file needed —           │
│  overrides:                  │   env vars set by            │
│  • plain JDBC URL            │   Terraform / GitHub         │
│  • password auth             │   Actions handle all         │
│  • no Azure MI               │   Azure-specific values)     │
│  • show-sql = true           │                              │
└──────────────────────────────┴──────────────────────────────┘
```

### Which profile is active?

Set by the env var `SPRING_PROFILES_ACTIVE`:

| Environment | Value | Who Sets It | Effect |
|---|---|---|---|
| Your laptop | `local` (default in `application.yml`) | No one — it's the default | Loads `application-local.yml` on top |
| Azure Container Apps | `dev` | Terraform `aca.tf` + GitHub Actions `deploy.yml` | Uses base `application.yml` only — no `application-dev.yml` exists (env vars provide all overrides) |

---

## Part 1: Running Locally

### 1.1 Prerequisites

| Requirement | Minimum Version | Verify Command |
|---|---|---|
| Java JDK | 21 | `java -version` |
| Maven | 3.9+ | `mvn -version` |
| Docker | any (for PostgreSQL) | `docker --version` |

### 1.2 Step-by-Step

#### Step 1 — Start PostgreSQL with Docker

```bash
docker run -d \
  --name ordersdb \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=ordersdb \
  -p 5432:5432 \
  postgres:16
```

This creates:
- A PostgreSQL 16 instance on `localhost:5432`
- A database named `ordersdb`
- A user `postgres` with password `postgres`

#### Step 2 — Create the `orders` schema

Flyway's config (`schemas: orders`) can create the schema, but the PostgreSQL user needs `CREATE ON DATABASE` privilege. With the default `postgres` superuser this works automatically. If you want to be explicit:

```bash
docker exec -it ordersdb psql -U postgres -d ordersdb -c "CREATE SCHEMA IF NOT EXISTS orders;"
```

#### Step 3 — Build the application

```bash
cd application
mvn clean package -DskipTests
```

This produces `target/orders-service-1.0.0.jar`.

#### Step 4 — Run the application

```bash
mvn spring-boot:run
```

**No flags or env vars needed.** The default `SPRING_PROFILES_ACTIVE` is `local` (set in `application.yml` line 9), which automatically loads `application-local.yml`.

#### Step 5 — Verify

```bash
# Health check
curl http://localhost:8080/actuator/health

# List orders (5 seed rows from V2 migration)
curl http://localhost:8080/api/v1/orders

# Create a new order
curl -X POST http://localhost:8080/api/v1/orders \
  -H "Content-Type: application/json" \
  -d '{"customerName":"Test User","customerEmail":"test@example.com","productName":"Laptop","quantity":1,"unitPrice":50000}'
```

#### Step 6 — Stop everything

```bash
# Stop the app: Ctrl+C in the terminal running mvn spring-boot:run

# Stop and remove PostgreSQL container
docker stop ordersdb && docker rm ordersdb
```

### 1.3 What Happens Under the Hood (Local)

```
mvn spring-boot:run
  │
  ├── Reads application.yml (base config)
  │     SPRING_PROFILES_ACTIVE defaults to "local"
  │
  ├── Detects profile = "local"
  │     Loads application-local.yml ON TOP of application.yml
  │
  ├── Final resolved datasource config:
  │     url      = jdbc:postgresql://localhost:5432/ordersdb   ← from local profile (no SSL, no Azure plugin)
  │     username = postgres                                    ← from local profile
  │     password = postgres                                    ← from local profile (password auth)
  │     azure.passwordless-enabled = false                     ← from local profile
  │     managed-identity-enabled   = false                     ← from local profile
  │     show-sql = true                                        ← from local profile
  │
  ├── HikariCP opens 2 connections (minimum-idle) to localhost PostgreSQL
  │
  ├── Flyway runs migrations:
  │     V1__create_orders_schema.sql → creates orders.orders table
  │     V2__seed_orders_data.sql     → inserts 5 sample rows
  │
  ├── Hibernate initializes (ddl-auto: none — no schema changes)
  │
  ├── Tomcat starts on port 8080
  │
  └── App is ready: http://localhost:8080
```

### 1.4 Using Custom Credentials

If your local PostgreSQL uses different credentials:

```bash
POSTGRES_USER=myuser POSTGRES_PASSWORD=mypass mvn spring-boot:run
```

Or create a `.env` file (gitignored — won't be committed):

```bash
# .env (in project root)
POSTGRES_USER=myuser
POSTGRES_PASSWORD=secret123
```

Then source it before running:

```bash
source .env && mvn spring-boot:run
```

---

## Part 2: Running on Azure (CI/CD Pipeline)

### 2.1 Prerequisites (Infrastructure)

All infrastructure is managed by Terraform. These must exist before deploying:

| Resource | Name | Managed By |
|---|---|---|
| Azure Subscription | `0bb4f66b-...` | `dev.tfvars` |
| Resource Group | `rg-orders-dev` | `terraform/rg.tf` |
| Container Registry (ACR) | `acrordersdev` | `terraform/acr.tf` |
| PostgreSQL Flexible Server | `pg-orders-dev` | `terraform/postgres.tf` |
| Managed Identity | `orders-service-identity` | `terraform/identity.tf` |
| Container Apps Environment | `managedEnvironment-rgordersdev-a29a` | `terraform/aca.tf` |
| Container App | `acrordersapp` | `terraform/aca.tf` |

#### Deploy infrastructure (if not already done):

```bash
cd terraform
terraform init
terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars
```

### 2.2 GitHub Secrets Required

These must be configured in GitHub → Repository → Settings → Secrets:

| Secret Name | Value | Purpose |
|---|---|---|
| `AZURE_CLIENT_ID` | Service principal / federated credential client ID | OIDC login for GitHub Actions |
| `AZURE_TENANT_ID` | Azure AD tenant ID | OIDC login |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID | OIDC login |
| `ACR_NAME` | `acrordersdev` | Container registry name |

### 2.3 Step-by-Step Deployment

#### Step 1 — Push code to `main`

```bash
git add .
git commit -m "your changes"
git push origin main
```

#### Step 2 — "Build and Push Image" workflow runs automatically

Triggered on push to `main`. It:

1. Checks out the code
2. Sets up Java 21
3. Runs `mvn clean package -DskipTests`
4. Builds Docker image using `application/Dockerfile`:
   ```dockerfile
   FROM eclipse-temurin:21-jre
   COPY target/*.jar app.jar
   ENTRYPOINT ["java","-jar","/app.jar"]
   ```
5. Pushes to ACR: `acrordersdev.azurecr.io/orders-service:<commit-sha>`

#### Step 3 — "Deploy to ACA" workflow runs automatically

Triggered after a successful build. It:

1. Logs into Azure via OIDC
2. Resolves the Managed Identity client ID
3. Updates (or creates) the Container App with these env vars:

```
POSTGRES_HOST                                = pg-orders-dev.postgres.database.azure.com
POSTGRES_DB                                  = ordersdb
POSTGRES_MI_USER                             = orders-service-identity
AZURE_CLIENT_ID                              = <managed identity client ID>
SPRING_DATASOURCE_AZURE_PASSWORDLESS_ENABLED = true
AZURE_MI_ENABLED                             = true
SERVER_PORT                                  = 8080
SPRING_PROFILES_ACTIVE                       = dev       ← THIS IS THE KEY DIFFERENCE
SPRING_APPLICATION_NAME                      = orders-platform
```

#### Step 4 — Verify

The workflow prints the app URL at the end. You can also find it manually:

```bash
az containerapp show \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --query "properties.configuration.ingress.fqdn" -o tsv
```

Then:

```bash
curl https://<fqdn>/actuator/health
curl https://<fqdn>/api/v1/orders
```

### 2.4 What Happens Under the Hood (Azure)

```
Container starts → java -jar /app.jar
  │
  ├── Reads application.yml (base config)
  │     SPRING_PROFILES_ACTIVE = "dev" (set by Container App env var)
  │
  ├── Detects profile = "dev"
  │     No application-dev.yml exists → uses application.yml as-is
  │     application-local.yml does NOT load (profile is "dev", not "local")
  │
  ├── Final resolved datasource config (env vars injected by Terraform/workflow):
  │     url      = jdbc:postgresql://pg-orders-dev.postgres.database.azure.com:5432/ordersdb
  │                ?sslmode=require                                    ← default in application.yml
  │                &authenticationPluginClassName=...AzurePostgresql   ← Azure AD token auth
  │     username = orders-service-identity                             ← managed identity name
  │     (no password — token-based auth via Azure plugin)
  │     azure.passwordless-enabled = true                              ← uses AAD tokens
  │     managed-identity-enabled   = true                              ← activates MI
  │     client-id = <actual MI client ID>                              ← which MI to use
  │
  ├── HikariCP opens connections to Azure PostgreSQL
  │     Azure auth plugin calls IMDS (169.254.169.254) to get OAuth2 token
  │     Token used as password — no credentials stored anywhere
  │
  ├── Flyway runs migrations (same V1, V2 — idempotent, skipped if already applied)
  │
  ├── Hibernate initializes (ddl-auto: none)
  │
  ├── Tomcat starts on port 8080
  │
  ├── ACA health probes begin:
  │     Liveness:  GET /actuator/health/liveness  every 30s (after 30s delay)
  │     Readiness: GET /actuator/health/readiness every 10s (after 20s delay)
  │
  └── ACA routes traffic → https://<fqdn>
```

### 2.5 Manual / Fresh Deploy

If the Container App is stuck in a failed state:

1. Go to GitHub → Actions → "Deploy to ACA"
2. Click "Run workflow"
3. Set `fresh_deploy` to `true`
4. (Optional) Specify an image tag, or leave empty for latest

This deletes the existing app and recreates it from scratch.

---

## Part 3: Environment Comparison

### Config Resolution Side-by-Side

| Config Key | Local (profile=local) | Azure (profile=dev) |
|---|---|---|
| `server.port` | `8080` (default) | `8080` (env var `SERVER_PORT`) |
| `spring.application.name` | `orders-platform` (default) | `orders-platform` (env var) |
| `datasource.url` | `jdbc:postgresql://localhost:5432/ordersdb` (overridden by local profile) | `jdbc:postgresql://pg-orders-dev....:5432/ordersdb?sslmode=require&authPlugin=...` |
| `datasource.username` | `postgres` (overridden by local profile) | `orders-service-identity` (env var `POSTGRES_MI_USER`) |
| `datasource.password` | `postgres` (set by local profile) | *(not set — token auth via Azure plugin)* |
| `azure.passwordless-enabled` | `false` (local profile) | `true` (env var) |
| `azure.managed-identity-enabled` | `false` (local profile) | `true` (env var) |
| `jpa.show-sql` | `true` (local profile — for debugging) | `false` (base default) |
| SSL mode | *(not in URL — plain connection)* | `require` (default in base URL) |
| Auth method | Password (`postgres`/`postgres`) | Azure Managed Identity (AAD token) |

### Env Vars Set Per Environment

| Env Var | Local | Azure (Terraform + Workflow) |
|---|---|---|
| `SERVER_PORT` | not set (defaults to `8080`) | `8080` |
| `SPRING_PROFILES_ACTIVE` | not set (defaults to `local`) | `dev` |
| `SPRING_APPLICATION_NAME` | not set (defaults to `orders-platform`) | `orders-platform` |
| `POSTGRES_HOST` | not set (defaults to `localhost`) | `pg-orders-dev.postgres.database.azure.com` |
| `POSTGRES_DB` | not set (defaults to `ordersdb`) | `ordersdb` |
| `POSTGRES_MI_USER` | not set (overridden by local profile) | `orders-service-identity` |
| `AZURE_CLIENT_ID` | not set | `<MI client ID>` |
| `SPRING_DATASOURCE_AZURE_PASSWORDLESS_ENABLED` | not set (local profile sets `false`) | `true` |
| `AZURE_MI_ENABLED` | not set (local profile sets `false`) | `true` |
| `POSTGRES_USER` | not set (defaults to `postgres`) | not set (not used on Azure) |
| `POSTGRES_PASSWORD` | not set (defaults to `postgres`) | not set (not used on Azure) |

---

## Part 4: Files Involved

```
orders-platform-scaffold/
├── application/
│   └── src/main/resources/
│       ├── application.yml              ← base config (all environments)
│       ├── application-local.yml        ← local overrides (password auth, no Azure)
│       └── db/migration/
│           ├── V1__create_orders_schema.sql
│           └── V2__seed_orders_data.sql
├── terraform/
│   ├── aca.tf                           ← Container App + env vars (SERVER_PORT, SPRING_PROFILES_ACTIVE, etc.)
│   ├── variables.tf                     ← spring_profiles_active variable
│   └── environments/
│       └── dev.tfvars                   ← spring_profiles_active = "dev"
├── .github/workflows/
│   └── deploy.yml                       ← env vars in create + update commands
└── .gitignore                           ← ignores .env, IDE files, build output
```

---

## Part 5: Troubleshooting

### Local

| Problem | Cause | Fix |
|---|---|---|
| `Connection refused: localhost:5432` | PostgreSQL not running | Run the `docker run` command from Step 1 |
| `FATAL: database "ordersdb" does not exist` | Database not created | Check docker run had `-e POSTGRES_DB=ordersdb` |
| `schema "orders" does not exist` | Schema not created | Run `CREATE SCHEMA` command from Step 2, or Flyway will create it if user has privileges |
| `Azure auth plugin class not found` | Running without local profile | Check `SPRING_PROFILES_ACTIVE` is `local` (default) — the local profile overrides the URL to remove the Azure plugin |
| App starts but uses Azure auth | Profile not set to `local` | Ensure you haven't set `SPRING_PROFILES_ACTIVE=dev` in your environment |

### Azure

| Problem | Cause | Fix |
|---|---|---|
| Health probes failing | App not started yet | Check initial_delay settings (liveness: 30s, readiness: 20s) — wait for startup |
| `TokenCredentialAuthenticationPlugin` error | MI not configured or wrong client ID | Verify `AZURE_CLIENT_ID` env var matches the MI's client ID |
| `FATAL: password authentication failed for user "orders-service-identity"` | `SPRING_DATASOURCE_AZURE_PASSWORDLESS_ENABLED` not `true` | Check env var is set in both Terraform and deploy workflow |
| Flyway checksum mismatch | A committed migration file was edited after being applied | Never edit applied migrations — create a new `V{n+1}` migration instead |
| Container stuck in "Failed" state | Previous deployment issue | Use `fresh_deploy = true` in the Deploy workflow |
| `sslmode=require` error locally | Running with `dev` profile locally | Don't set `SPRING_PROFILES_ACTIVE=dev` on your laptop — use `local` (default) |
