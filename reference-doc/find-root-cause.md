# Find Root Cause — Container App Crashes After Initialization

> Systematic guide for debugging a Spring Boot Container App that deploys successfully but crashes after startup.
> Written for a corporate setup where you have **limited permissions** (no admin access to the Managed Identity or subscription-level settings).

---

## Assumptions

- Spring Boot app with PostgreSQL (similar to orders-platform)
- Azure Container Apps + ACR + Managed Identity (corporate-managed)
- CI/CD deploys successfully (image builds + pushes + `az containerapp update` succeeds)
- Container starts, then crashes (restart loop)
- You have `az` CLI access with at least Reader/Contributor on the Resource Group

---

## Phase 1: Get the Actual Error (Logs)

The #1 mistake is guessing. Get the logs first.

### 1.1 Check Container App System Logs

```bash
# Replace these with your actual values
RG="your-resource-group"
APP="your-container-app-name"

# See current state
az containerapp show \
  --name $APP \
  --resource-group $RG \
  --query "{provisioningState:properties.provisioningState, runningStatus:properties.runningStatus, latestRevision:properties.latestRevisionName}" \
  -o table
```

### 1.2 Get Console Logs (Most Important)

```bash
# Stream live logs (if the container is restarting, you'll catch it)
az containerapp logs show \
  --name $APP \
  --resource-group $RG \
  --type console \
  --follow

# If --follow doesn't work (container crashes too fast), get recent logs:
az containerapp logs show \
  --name $APP \
  --resource-group $RG \
  --type console \
  --tail 300
```

**What to look for:**
- Java stack traces (the actual exception)
- `APPLICATION FAILED TO START` banner
- `HikariPool` connection errors
- `Flyway` migration errors
- `TokenCredentialAuthenticationPlugin` errors
- `FATAL: password authentication failed`
- `sslmode` errors
- `OOM` or `Killed` messages

### 1.3 Get System Logs (Container Platform Level)

```bash
az containerapp logs show \
  --name $APP \
  --resource-group $RG \
  --type system \
  --tail 100
```

**What to look for:**
- `Back-off restarting failed container` — app crashed, ACA is retrying
- `Liveness probe failed` — app started but health endpoint not responding
- `Readiness probe failed` — app can't connect to DB
- `OOMKilled` — app needs more memory
- `ImagePullBackOff` — ACR access issue (not your case, since deploy succeeds)

### 1.4 Query via Log Analytics (if console logs are empty)

Console logs can be lost if the container crashes too fast. Log Analytics retains them.

```bash
# Get the Log Analytics workspace ID for your ACA environment
ACA_ENV="your-aca-environment-name"

WORKSPACE_ID=$(az containerapp env show \
  --name $ACA_ENV \
  --resource-group $RG \
  --query "properties.appLogsConfiguration.logAnalyticsConfiguration.customerId" -o tsv)

echo "Log Analytics Workspace Customer ID: $WORKSPACE_ID"
```

Then run a KQL query:

```bash
# Get recent container logs (last 1 hour)
az monitor log-analytics query \
  --workspace $WORKSPACE_ID \
  --analytics-query "ContainerAppConsoleLogs_CL | where ContainerAppName_s == '$APP' | where TimeGenerated > ago(1h) | order by TimeGenerated desc | project TimeGenerated, Log_s" \
  --out table

# Get system-level events
az monitor log-analytics query \
  --workspace $WORKSPACE_ID \
  --analytics-query "ContainerAppSystemLogs_CL | where ContainerAppName_s == '$APP' | where TimeGenerated > ago(1h) | order by TimeGenerated desc | project TimeGenerated, EventSource_s, Reason_s, Log_s" \
  --out table
```

> **Note:** Log Analytics can have 5-10 minute ingestion delay. If you just deployed, wait a few minutes.

---

## Phase 2: Identify the Crash Category

Based on the logs from Phase 1, the crash will fall into one of these categories:

### Category A: Database Connection Failure

**Symptoms in logs:**
```
HikariPool-1 - Exception during pool initialization
FATAL: password authentication failed for user "..."
Connection to <host>:5432 refused
TokenCredentialAuthenticationPlugin ... failed to obtain token
```

**Go to → Phase 3A**

### Category B: Flyway Migration Failure

**Symptoms in logs:**
```
FlywayValidateException: Migration checksum mismatch
Flyway migration failed
ERROR: relation "..." already exists
```

**Go to → Phase 3B**

### Category C: Health Probe Timeout (App Starts Slowly)

**Symptoms in system logs:**
```
Liveness probe failed: connection refused
Readiness probe failed: HTTP probe failed with status code: 503
```

But **console logs show the app is still starting** (Spring Boot banner visible, Hibernate initializing, etc.)

**Go to → Phase 3C**

### Category D: Out of Memory

**Symptoms:**
```
OOMKilled
Killed
java.lang.OutOfMemoryError
```

**Go to → Phase 3D**

### Category E: Application Code Error

**Symptoms:**
```
APPLICATION FAILED TO START
BeanCreationException
NoSuchBeanDefinitionException
java.lang.ClassNotFoundException
```

**Go to → Phase 3E**

---

## Phase 3A: Database Connection Failure — Deep Dive

This is the most common cause in corporate setups. Trace step by step.

### 3A.1 Verify the PostgreSQL server is reachable

```bash
PG_SERVER="your-postgres-server-name"

# Check if the PG server exists and is running
az postgres flexible-server show \
  --name $PG_SERVER \
  --resource-group $RG \
  --query "{state:state, fqdn:fullyQualifiedDomainName, version:version}" \
  -o table
```

Expected: `state = Ready`

### 3A.2 Check firewall rules

```bash
# List firewall rules
az postgres flexible-server firewall-rule list \
  --name $PG_SERVER \
  --resource-group $RG \
  -o table
```

For Container Apps to connect, you need **one** of:
- A rule `0.0.0.0 → 0.0.0.0` (Allow Azure Services) — simplest
- VNet integration between ACA and PG

If the list is empty or missing the Azure rule:
```bash
# This requires Contributor on the PG server — ask admin if you can't run it
az postgres flexible-server firewall-rule create \
  --name $PG_SERVER \
  --resource-group $RG \
  --rule-name AllowAzureServices \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0
```

### 3A.3 Check the database exists

```bash
az postgres flexible-server db list \
  --server-name $PG_SERVER \
  --resource-group $RG \
  -o table
```

Verify your database name (e.g., `ordersdb`) is in the list.

### 3A.4 Check Managed Identity configuration

This is the most common failure point in corporate setups.

```bash
MI_NAME="your-managed-identity-name"

# Get the MI details
az identity show \
  --name $MI_NAME \
  --resource-group $RG \
  --query "{clientId:clientId, principalId:principalId, tenantId:tenantId}" \
  -o table
```

Then verify it's assigned to the Container App:

```bash
az containerapp show \
  --name $APP \
  --resource-group $RG \
  --query "identity" \
  -o json
```

Check that:
- `identity.type` includes `UserAssigned`
- The MI resource ID is in the `userAssignedIdentities` map

### 3A.5 Verify MI has a PostgreSQL role

This requires `psql` access (or ask the admin). The MI must have a role in PostgreSQL:

```sql
-- Run against the PostgreSQL server
SELECT rolname FROM pg_roles WHERE rolname = 'your-managed-identity-name';
```

If the role doesn't exist, this is your root cause. The admin needs to run:

```sql
-- Admin must execute this
SELECT * FROM pgaadauth_create_principal('your-managed-identity-name', false, false);
GRANT ALL ON SCHEMA your_schema TO "your-managed-identity-name";
GRANT ALL ON ALL TABLES IN SCHEMA your_schema TO "your-managed-identity-name";
GRANT ALL ON ALL SEQUENCES IN SCHEMA your_schema TO "your-managed-identity-name";
```

### 3A.6 Verify env vars on the Container App

```bash
az containerapp show \
  --name $APP \
  --resource-group $RG \
  --query "properties.template.containers[0].env[]" \
  -o table
```

Cross-check every value:

| Env Var | Must Match |
|---|---|
| `POSTGRES_HOST` | The PG server FQDN (without `https://`, without port) |
| `POSTGRES_DB` | The actual database name |
| `POSTGRES_MI_USER` | Exactly the MI name (case-sensitive) |
| `AZURE_CLIENT_ID` | The MI's **client ID** (not object ID, not principal ID) |
| `SPRING_DATASOURCE_AZURE_PASSWORDLESS_ENABLED` | `true` |
| `AZURE_MI_ENABLED` | `true` |
| `SPRING_PROFILES_ACTIVE` | The profile used on Azure (e.g., `dev`) |

**Common mistakes:**
- `AZURE_CLIENT_ID` set to the service principal's client ID instead of the **Managed Identity's** client ID
- `POSTGRES_MI_USER` has a typo or wrong casing
- `POSTGRES_HOST` includes `https://` or `:5432` (it should be just the hostname)

### 3A.7 Check if SSL is the problem

If the PG server requires SSL but your JDBC URL doesn't have `sslmode=require`, or vice versa:

```bash
az postgres flexible-server show \
  --name $PG_SERVER \
  --resource-group $RG \
  --query "properties.network" \
  -o json
```

---

## Phase 3B: Flyway Migration Failure — Deep Dive

### 3B.1 Checksum mismatch

Someone edited a migration file that was already applied. The log will show which version.

**Fix:** Never edit applied migrations. Create a new `V{n+1}__fix_xxx.sql` instead.

If you must fix it (dev environment only):
```sql
-- Find the bad entry
SELECT version, checksum, description FROM your_schema.flyway_schema_history;

-- Delete it so Flyway re-applies (DANGEROUS — only in dev)
DELETE FROM your_schema.flyway_schema_history WHERE version = 'X';
```

### 3B.2 Schema/table already exists

The migration tries to create something that already exists (e.g., someone created it manually).

**Fix:** Use `IF NOT EXISTS` in all migrations:
```sql
CREATE TABLE IF NOT EXISTS ...
CREATE SCHEMA IF NOT EXISTS ...
```

### 3B.3 Insufficient privileges

Flyway needs `CREATE` privilege on the database/schema. The MI may have `SELECT/INSERT/UPDATE/DELETE` but not `CREATE`.

**Fix (admin must run):**
```sql
GRANT CREATE ON SCHEMA your_schema TO "your-managed-identity-name";
GRANT CREATE ON DATABASE your_db TO "your-managed-identity-name";
```

---

## Phase 3C: Health Probe Timeout — Deep Dive

### 3C.1 Check probe configuration

```bash
az containerapp show \
  --name $APP \
  --resource-group $RG \
  --query "properties.template.containers[0].{liveness:probes[?type=='Liveness'],readiness:probes[?type=='Readiness']}" \
  -o json
```

### 3C.2 Common fixes

Spring Boot + Flyway + Hibernate can take 30-60s to start. If the liveness probe fires before the app is ready, ACA kills it.

**Increase initial delays:**

| Probe | Recommended for slow-starting apps |
|---|---|
| Liveness `initialDelaySeconds` | `60` (or higher) |
| Readiness `initialDelaySeconds` | `45` |

Update via Terraform or CLI:
```bash
# Quick fix via CLI — increase liveness initial delay
az containerapp update \
  --name $APP \
  --resource-group $RG \
  --set-env-vars "..." \
  # Unfortunately probe config can't be updated via simple CLI flags —
  # you need to use ARM template or Terraform
```

For Terraform, update the `liveness_probe` block:
```hcl
liveness_probe {
  transport        = "HTTP"
  path             = "/actuator/health/liveness"
  port             = var.container_port
  initial_delay    = 60    # ← increase this
  interval_seconds = 30
  failure_count_threshold = 5  # ← allow more failures before kill
}
```

### 3C.3 Check if the actuator path is correct

If your app uses `server.servlet.context-path` or a custom management port, the probe path may be wrong.

```bash
# Verify what paths the probes are hitting
az containerapp show \
  --name $APP \
  --resource-group $RG \
  --query "properties.template.containers[0].probes" \
  -o json
```

---

## Phase 3D: Out of Memory — Deep Dive

### 3D.1 Check current resource allocation

```bash
az containerapp show \
  --name $APP \
  --resource-group $RG \
  --query "properties.template.containers[0].resources" \
  -o json
```

### 3D.2 Increase memory

Spring Boot + JPA apps typically need at least 1Gi. Complex apps may need 2Gi.

```bash
az containerapp update \
  --name $APP \
  --resource-group $RG \
  --cpu 1.0 \
  --memory 2Gi
```

Valid ACA CPU/memory combinations:
| CPU | Memory |
|---|---|
| 0.25 | 0.5Gi |
| 0.5 | 1Gi |
| 1.0 | 2Gi |
| 2.0 | 4Gi |

### 3D.3 Set JVM heap limits

Add this env var to cap JVM heap and leave room for non-heap memory:

```
JAVA_OPTS=-XX:MaxRAMPercentage=70.0
```

---

## Phase 3E: Application Code Error — Deep Dive

### 3E.1 Run the image locally

If you can pull the image, run it locally to see the full error:

```bash
# Login to ACR
az acr login --name youracrname

# Pull the image
docker pull youracrname.azurecr.io/your-image:tag

# Run locally with minimal env vars (will fail on DB, but you'll see code errors)
docker run --rm \
  -e SERVER_PORT=8080 \
  -e SPRING_PROFILES_ACTIVE=local \
  -p 8080:8080 \
  youracrname.azurecr.io/your-image:tag
```

### 3E.2 Common Spring Boot startup errors

| Error | Cause | Fix |
|---|---|---|
| `NoSuchBeanDefinitionException` | Missing dependency or `@Component` annotation | Check bean definitions, package scanning |
| `BeanCreationException` | Constructor/injection failure | Check logs for the root cause nested exception |
| `ClassNotFoundException` | Dependency not in JAR | Check `pom.xml`, run `mvn dependency:tree` |
| `BindException: Address already in use` | Port conflict | Check `SERVER_PORT` env var |

---

## Phase 4: Quick Checks You Can Run Right Now

Run all of these in sequence. Copy-paste the block, replacing the variables at the top.

```bash
# ============================================================
# SET THESE VARIABLES FIRST
# ============================================================
RG="your-resource-group"
APP="your-container-app-name"
PG_SERVER="your-postgres-server-name"
MI_NAME="your-managed-identity-name"

# ============================================================
# 1. Container App state
# ============================================================
echo "=== CONTAINER APP STATUS ==="
az containerapp show --name $APP --resource-group $RG \
  --query "{name:name, provisioningState:properties.provisioningState, runningStatus:properties.runningStatus, latestRevision:properties.latestRevisionName, image:properties.template.containers[0].image, cpu:properties.template.containers[0].resources.cpu, memory:properties.template.containers[0].resources.memory}" \
  -o table

# ============================================================
# 2. Container App env vars
# ============================================================
echo ""
echo "=== ENV VARS ==="
az containerapp show --name $APP --resource-group $RG \
  --query "properties.template.containers[0].env[].{name:name, value:value}" \
  -o table

# ============================================================
# 3. Container App revision status
# ============================================================
echo ""
echo "=== REVISIONS ==="
az containerapp revision list --name $APP --resource-group $RG \
  --query "[].{name:name, active:properties.active, trafficWeight:properties.trafficWeight, healthState:properties.healthState, provisioningState:properties.provisioningState, createdTime:properties.createdTime}" \
  -o table

# ============================================================
# 4. Recent console logs
# ============================================================
echo ""
echo "=== CONSOLE LOGS (last 100 lines) ==="
az containerapp logs show --name $APP --resource-group $RG \
  --type console --tail 100

# ============================================================
# 5. System logs
# ============================================================
echo ""
echo "=== SYSTEM LOGS (last 50 lines) ==="
az containerapp logs show --name $APP --resource-group $RG \
  --type system --tail 50

# ============================================================
# 6. PostgreSQL server state
# ============================================================
echo ""
echo "=== POSTGRES SERVER ==="
az postgres flexible-server show --name $PG_SERVER --resource-group $RG \
  --query "{state:state, fqdn:fullyQualifiedDomainName, version:version, sku:sku.name}" \
  -o table

# ============================================================
# 7. PostgreSQL firewall rules
# ============================================================
echo ""
echo "=== POSTGRES FIREWALL RULES ==="
az postgres flexible-server firewall-rule list \
  --name $PG_SERVER --resource-group $RG -o table

# ============================================================
# 8. PostgreSQL databases
# ============================================================
echo ""
echo "=== POSTGRES DATABASES ==="
az postgres flexible-server db list \
  --server-name $PG_SERVER --resource-group $RG -o table

# ============================================================
# 9. Managed Identity
# ============================================================
echo ""
echo "=== MANAGED IDENTITY ==="
az identity show --name $MI_NAME --resource-group $RG \
  --query "{name:name, clientId:clientId, principalId:principalId}" \
  -o table

# ============================================================
# 10. ACR access — can the MI pull images?
# ============================================================
echo ""
echo "=== MI ROLE ASSIGNMENTS ==="
MI_PRINCIPAL=$(az identity show --name $MI_NAME --resource-group $RG --query "principalId" -o tsv)
az role assignment list --assignee $MI_PRINCIPAL --all \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

---

## Phase 5: Decision Tree

```
Got the logs from Phase 4?
  |
  ├── See a Java stack trace?
  |     |
  |     ├── Contains "HikariPool" or "Connection refused" or "password authentication"
  |     |     → DB connection issue → Phase 3A
  |     |
  |     ├── Contains "Flyway" or "checksum mismatch"
  |     |     → Migration issue → Phase 3B
  |     |
  |     ├── Contains "OutOfMemoryError"
  |     |     → OOM → Phase 3D
  |     |
  |     └── Contains "BeanCreation" or "ClassNotFound"
  |           → App code issue → Phase 3E
  |
  ├── System logs show "Liveness probe failed" but no Java error?
  |     → App starting too slowly → Phase 3C
  |
  ├── System logs show "OOMKilled"?
  |     → Not enough memory → Phase 3D
  |
  ├── No logs at all?
  |     |
  |     ├── Check if revision is active:
  |     |     az containerapp revision list --name $APP --resource-group $RG -o table
  |     |
  |     ├── If healthState = "Unhealthy" → Probes failing → Phase 3C
  |     |
  |     └── If no revisions → Deployment didn't actually create one
  |           → Check az containerapp update output in CI/CD logs
  |
  └── Logs show "Back-off restarting failed container"?
        → Container is crash-looping → The CONSOLE logs have the actual error
        → Run the Log Analytics KQL query from Phase 1.4
```

---

## Phase 6: What to Share With the Admin

If the root cause is something you can't fix (MI permissions, PG role, firewall), send the admin a clear request:

**Template:**

```
Subject: Container App crash — need PostgreSQL role for Managed Identity

Our Container App [APP_NAME] is crash-looping after deploy.

Root cause from logs:
  [PASTE THE EXACT ERROR LINE FROM LOGS]

What we need:
  1. Confirm the Managed Identity "[MI_NAME]" (client ID: [CLIENT_ID])
     has a PostgreSQL AAD role on server "[PG_SERVER]"

  2. If not, please run on the PG server:
     SELECT * FROM pgaadauth_create_principal('[MI_NAME]', false, false);
     GRANT ALL ON SCHEMA [schema_name] TO "[MI_NAME]";
     GRANT ALL ON ALL TABLES IN SCHEMA [schema_name] TO "[MI_NAME]";
     GRANT ALL ON ALL SEQUENCES IN SCHEMA [schema_name] TO "[MI_NAME]";

  3. Verify the PG firewall allows Azure services:
     Rule: 0.0.0.0 → 0.0.0.0 (AllowAzureServices)

Resource group: [RG]
Subscription: [SUB_ID]
```

---

## Common Root Causes — Ranked by Frequency

| # | Cause | How You'll Know | Fix |
|---|---|---|---|
| 1 | MI not registered as PG role | `FATAL: password authentication failed for user "mi-name"` | Admin runs `pgaadauth_create_principal` |
| 2 | Wrong `AZURE_CLIENT_ID` | `TokenCredentialAuthenticationPlugin` token error | Fix env var to MI's client ID (not SP's) |
| 3 | PG firewall missing Azure rule | `Connection refused` or `timeout` to PG host | Add `0.0.0.0` firewall rule |
| 4 | Health probe kills app before startup | System log: `Liveness probe failed`, no Java error | Increase `initial_delay` to 60+ |
| 5 | Flyway checksum mismatch | `FlywayValidateException` in logs | New migration to fix, don't edit old ones |
| 6 | OOM — app needs more memory | `OOMKilled` in system logs | Increase to `2Gi` memory |
| 7 | Wrong `SPRING_PROFILES_ACTIVE` | App tries local config on Azure | Fix env var to correct profile |
| 8 | Database doesn't exist | `FATAL: database "x" does not exist` | Create the database |
| 9 | Schema permissions | `permission denied for schema` | Admin grants CREATE/USAGE on schema |
| 10 | Missing env var | `Could not resolve placeholder` in Spring logs | Add missing env var to container app |
