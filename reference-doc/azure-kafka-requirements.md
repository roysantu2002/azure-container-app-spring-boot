# Azure Kafka (Event Hubs) — Requirements & Dev Environment Setup

## Overview

This document captures all requirements for adding Kafka-based event producing to the orders-platform, using **Azure Event Hubs with Kafka protocol** as the broker. No Docker is used — all services run in Azure.

---

## Current State

| Service        | Status       | Auth Method                          |
|----------------|-------------|--------------------------------------|
| PostgreSQL     | Running      | Azure Entra ID via `az login` (local) / Managed Identity (deployed) |
| Kafka          | Not set up   | —                                    |

The app currently runs locally against Azure PostgreSQL using the `azure-debug` Spring profile and `DefaultAzureCredential` (your `az login` session). The same pattern will be extended to Kafka.

---

## Why Azure Event Hubs (not native Kafka)

- Docker is not allowed on dev machines → can't run Kafka locally
- Event Hubs provides a **Kafka-compatible endpoint** (protocol-level compatibility)
- Supports **Entra ID (AAD) authentication** — same `az login` session, no connection strings or passwords
- Managed service — no brokers, ZooKeeper, or infrastructure to maintain
- Already in the Azure ecosystem alongside PostgreSQL

---

## What We Need

### 1. Azure Infrastructure (Terraform)

| Resource | Details |
|----------|---------|
| **Event Hubs Namespace** | Name: `evhns-orders-dev`, SKU: Standard, Kafka enabled |
| **Event Hub (topic)** | Name: `order-events`, Partitions: 2, Retention: 1 day |
| **Role Assignment (Managed Identity)** | `Azure Event Hubs Data Sender` on namespace → `orders-service-identity` (for deployed ACA app) |
| **Role Assignment (Dev User)** | `Azure Event Hubs Data Sender` on namespace → each developer's AAD user (for local dev) |

**New Terraform variables:**
- `eventhub_namespace_name` (default: `evhns-orders-dev`)

### 2. Maven Dependencies

| Dependency | Purpose |
|------------|---------|
| `spring-kafka` (Spring Boot managed) | KafkaTemplate, producer config |
| `spring-cloud-azure-starter` (from `spring-cloud-azure-dependencies` BOM, already imported) | Credential/token support for Event Hubs SASL/OAUTHBEARER |

### 3. Spring Configuration

#### Base config (`application.yml`)
```yaml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS:localhost:9092}
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
      acks: all
```

#### Azure debug profile (`application-azure-debug.yml`)
```yaml
spring:
  kafka:
    bootstrap-servers: ${KAFKA_BOOTSTRAP_SERVERS}
    properties:
      security.protocol: SASL_SSL
      sasl.mechanism: OAUTHBEARER
      sasl.login.callback.handler.class: com.azure.identity.extensions.kafka.AzureIdentityLoginCallbackHandler
      sasl.jaas.config: >-
        org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;
```

This uses `DefaultAzureCredential` — same `az login` session as PostgreSQL. No passwords or connection strings.

#### Local profile (`application-local.yml`)
No Kafka config needed. Without Docker there's no local broker. Developers use the `azure-debug` profile for full-stack development.

### 4. Java Code

**`OrderEventProducer.java`** — A simple `@Service` wrapping `KafkaTemplate`:
- `publish(topic, key, event)` method
- Called from the orders service when creating/updating orders
- Produce-only (no consumers needed yet)

### 5. Environment Variables

Add to `.env.azure-debug`:
```bash
export KAFKA_BOOTSTRAP_SERVERS=evhns-orders-dev.servicebus.windows.net:9093
```

Port **9093** is the Event Hubs Kafka endpoint (TLS).

### 6. Deployed App (ACA) Environment Variables

Add to Container App env vars (in Terraform `aca.tf` and `deploy.yml`):
```
KAFKA_BOOTSTRAP_SERVERS=evhns-orders-dev.servicebus.windows.net:9093
```

---

## Dev Environment Setup (Complete)

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Java | 21 | `sdk install java 21-tem` (SDKMAN) |
| Maven | 3.9+ | `sdk install maven` or manual |
| Azure CLI | latest | `brew install azure-cli` |
| Azure subscription | — | Access to `rg-orders-dev` resource group |

### One-Time Azure Setup

#### A. Authenticate
```bash
az login
```

#### B. Provision infrastructure (if not already done)
```bash
cd terraform
terraform init
terraform apply -var-file=environments/dev.tfvars
```

#### C. Add your dev IP to PostgreSQL firewall
```bash
MY_IP=$(curl -s ifconfig.me)
az postgres flexible-server firewall-rule create \
  --resource-group rg-orders-dev \
  --name pg-orders-dev \
  --rule-name "dev-$(whoami)" \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP
```

#### D. Grant your AAD user Event Hubs access
```bash
USER_ID=$(az ad signed-in-user show --query id -o tsv)
NAMESPACE_ID=$(az eventhubs namespace show \
  --resource-group rg-orders-dev \
  --name evhns-orders-dev \
  --query id -o tsv)
az role assignment create \
  --role "Azure Event Hubs Data Sender" \
  --assignee $USER_ID \
  --scope $NAMESPACE_ID
```

### Running the App (Against Azure)

```bash
az login                           # refresh token if needed
cd application
source ../.env.azure-debug         # exports SPRING_PROFILES_ACTIVE, POSTGRES_*, KAFKA_*
mvn spring-boot:run
```

Or use the script:
```bash
bash run-azure.sh
```

### Verification

1. **PostgreSQL** — StartupInfoLogger prints:
   ```
   DB Connection  : *** AZURE POSTGRESQL ***
   DB Host        : pg-orders-dev.postgres.database.azure.com
   ```

2. **Kafka** — POST an order, check app logs for Kafka produce confirmation

3. **Azure Portal** — Event Hubs > `evhns-orders-dev` > `order-events` > Metrics > Incoming Messages

### Switching to Local Profile (Postgres only, no Kafka)

Open a **new terminal** (clears exported Azure env vars), then:
```bash
cd application
mvn spring-boot:run                # defaults to 'local' profile
```

Or explicitly:
```bash
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run
```

---

## Files That Will Be Created/Modified

| File | Action | Purpose |
|------|--------|---------|
| `terraform/eventhubs.tf` | Create | Event Hubs namespace + hub + role assignments |
| `terraform/variables.tf` | Edit | Add `eventhub_namespace_name` variable |
| `terraform/environments/dev.tfvars` | Edit | Set `eventhub_namespace_name = "evhns-orders-dev"` |
| `terraform/aca.tf` | Edit | Add `KAFKA_BOOTSTRAP_SERVERS` env var to container |
| `application/pom.xml` | Edit | Add `spring-kafka` + `spring-cloud-azure-starter` |
| `application/src/main/resources/application.yml` | Edit | Add base Kafka producer config |
| `application/src/main/resources/application-azure-debug.yml` | Edit | Add Event Hubs SASL/OAUTHBEARER config |
| `application/src/main/java/.../service/OrderEventProducer.java` | Create | KafkaTemplate wrapper |
| `.env.azure-debug` | Edit | Add `KAFKA_BOOTSTRAP_SERVERS` |
| `.github/workflows/deploy.yml` | Edit | Add `KAFKA_BOOTSTRAP_SERVERS` env var |

---

## Authentication Flow Summary

```
Local Dev Machine                          Azure
─────────────────                          ─────
az login (your AAD user)
    │
    ├─→ DefaultAzureCredential ──→ PostgreSQL (Entra ID token)
    │
    └─→ OAUTHBEARER callback ────→ Event Hubs / Kafka (Entra ID token)


Deployed (ACA)                             Azure
──────────────                             ─────
Managed Identity (orders-service-identity)
    │
    ├─→ DefaultAzureCredential ──→ PostgreSQL (Entra ID token)
    │
    └─→ OAUTHBEARER callback ────→ Event Hubs / Kafka (Entra ID token)
```

Same credential mechanism, different identity source. No passwords anywhere.

---

## Spring Boot Dependencies for Azure Event Hubs (Kafka) with SP & Managed Identity

This section documents the exact dependencies needed for any Spring Boot application to connect to Azure Event Hubs using the Kafka protocol with passwordless authentication (Service Principal or Managed Identity).

### Required Maven Dependencies

```xml
<!-- 1. Spring Cloud Azure BOM — manages all Azure starter versions -->
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>com.azure.spring</groupId>
            <artifactId>spring-cloud-azure-dependencies</artifactId>
            <version>5.21.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>

<dependencies>
    <!-- 2. Spring Kafka — KafkaTemplate, @KafkaListener, producer/consumer -->
    <dependency>
        <groupId>org.springframework.kafka</groupId>
        <artifactId>spring-kafka</artifactId>
    </dependency>

    <!-- 3. Spring Cloud Azure Starter — DefaultAzureCredential,
         auto-configures SASL_SSL + OAUTHBEARER for Event Hubs -->
    <dependency>
        <groupId>com.azure.spring</groupId>
        <artifactId>spring-cloud-azure-starter</artifactId>
    </dependency>
</dependencies>
```

### What Each Dependency Does

| Dependency | Role |
|---|---|
| `spring-cloud-azure-dependencies` (BOM) | Version management for all Azure starters. Ensures compatible versions across all `com.azure.spring` artifacts. |
| `spring-kafka` | Provides `KafkaTemplate`, `@KafkaListener`, consumer/producer factories. Standard Spring Kafka — nothing Azure-specific. |
| `spring-cloud-azure-starter` | The key piece. Provides `DefaultAzureCredential` and **auto-configures** Kafka security properties when it detects `servicebus.windows.net` in bootstrap servers. |

### What Spring Cloud Azure Auto-Configures (No Manual Config Needed)

When `spring-cloud-azure-starter` detects an Event Hubs endpoint (`*.servicebus.windows.net`) in `spring.kafka.bootstrap-servers`, it automatically sets these Kafka properties:

```properties
security.protocol=SASL_SSL
sasl.mechanism=OAUTHBEARER
sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required;
sasl.login.callback.handler.class=com.azure.identity.extensions.kafka.AzureIdentityLoginCallbackHandler
```

You do **not** need to add these to `application.yml` — the starter handles it.

### Minimal application.yml

```yaml
spring:
  kafka:
    bootstrap-servers: <namespace>.servicebus.windows.net:9093
    producer:
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
    consumer:
      group-id: my-app
      auto-offset-reset: earliest
```

Port **9093** is the Event Hubs Kafka-compatible TLS endpoint.

### Authentication Modes

All three modes use the same code and same dependencies. `DefaultAzureCredential` tries them in this order:

| Mode | How It Works | When Used |
|------|-------------|-----------|
| **Service Principal** | Set env vars: `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` | CI/CD pipelines, automated environments |
| **`az login`** | Run `az login` before starting the app. DefaultAzureCredential picks up the session. | Local development (simplest) |
| **Managed Identity** | No env vars needed. DefaultAzureCredential detects the identity from the Azure runtime. | Deployed apps (Container Apps, AKS, VMs) |

### Azure-Side RBAC Prerequisite

The SP or Managed Identity must have the appropriate RBAC role on the Event Hubs **namespace**:

| Role | Purpose |
|------|---------|
| `Azure Event Hubs Data Sender` | Required for producing messages |
| `Azure Event Hubs Data Receiver` | Required for consuming messages |

Grant via Azure CLI:
```bash
az role assignment create \
  --role "Azure Event Hubs Data Sender" \
  --assignee <principal-id-or-object-id> \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.EventHub/namespaces/<namespace>
```

Without the correct role, the OAUTHBEARER token is valid but authorization will fail with a permission error.

### Event Hubs SKU Requirement

The Event Hubs namespace must be **Standard**, **Premium**, or **Dedicated** tier. The **Basic** tier does not support the Kafka protocol.