# Dev Environment Setup Guide

Complete guide for running the orders-platform locally against Azure backing services (PostgreSQL + Event Hubs/Kafka). Docker is not used on dev machines.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Java | 21 | `sdk install java 21-tem` (SDKMAN) or [Adoptium](https://adoptium.net/) |
| Maven | 3.9+ | `sdk install maven` or [Apache Maven](https://maven.apache.org/) |
| Azure CLI | latest | `brew install azure-cli` or [docs](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Terraform | 1.5+ | `brew install terraform` (only needed for infra changes) |

You also need access to the Azure subscription used by this project.

## Authentication

All Azure services use **passwordless authentication** via `DefaultAzureCredential`. On your dev machine this resolves to your `az login` session.

```bash
az login
```

Verify you're in the correct subscription:

```bash
az account show --query "{name:name, id:id}" -o table
```

## Azure Resources (One-Time Setup via Terraform)

The following resources are provisioned by Terraform in `terraform/`:

- **Resource Group** — `rg-orders-dev`
- **PostgreSQL Flexible Server** — `pg-orders-dev` (Entra ID auth, no passwords)
- **Azure Event Hubs Namespace** — `evhns-orders-dev` (Kafka-enabled, Standard tier)
- **Event Hub (topic)** — `order-events` (2 partitions, 1-day retention)
- **Managed Identity** — `orders-service-identity` (used by deployed app)

To apply infrastructure changes:

```bash
cd terraform
terraform init
terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars
```

## Developer Access Setup

### Add Your Dev IP to PostgreSQL Firewall

Azure PostgreSQL blocks connections by default. Add your current IP:

```bash
MY_IP=$(curl -s ifconfig.me)
az postgres flexible-server firewall-rule create \
  --resource-group rg-orders-dev \
  --name pg-orders-dev \
  --rule-name "dev-$(whoami)" \
  --start-ip-address $MY_IP \
  --end-ip-address $MY_IP
```

> Re-run this if your IP changes (e.g. different network).

### Grant Your AAD User Event Hubs Access

Your AAD user needs the **Azure Event Hubs Data Sender** role to produce messages:

```bash
USER_ID=$(az ad signed-in-user show --query id -o tsv)
NAMESPACE_ID=$(az eventhubs namespace show \
  -g rg-orders-dev \
  -n evhns-orders-dev \
  --query id -o tsv)

az role assignment create \
  --role "Azure Event Hubs Data Sender" \
  --assignee $USER_ID \
  --scope $NAMESPACE_ID
```

This is a one-time setup. Role assignments take a few minutes to propagate.

## Running the App (Azure Profile)

```bash
az login
cd application
source ../.env.azure-debug
mvn spring-boot:run
```

The `source ../.env.azure-debug` sets these environment variables:

| Variable | Value |
|----------|-------|
| `SPRING_PROFILES_ACTIVE` | `azure-debug` |
| `POSTGRES_HOST` | `pg-orders-dev.postgres.database.azure.com` |
| `POSTGRES_DB` | `ordersdb` |
| `POSTGRES_AZURE_USER` | Your AAD user |
| `KAFKA_BOOTSTRAP_SERVERS` | `evhns-orders-dev.servicebus.windows.net:9093` |

Alternatively, use the helper script:

```bash
./run-azure.sh
```

## Verifying Everything Works

### PostgreSQL Connection

Look for this in the startup logs:

```
*** AZURE POSTGRESQL ***
```

The app connects using `DefaultAzureCredential` (your `az login` session) with the Azure PostgreSQL authentication plugin. No passwords are involved.

### Kafka / Event Hubs Connection

After starting the app:

1. POST an order via the API
2. Check the application logs for `Publishing event to topic=order-events`
3. In Azure Portal: **Event Hubs namespace > order-events > Metrics** — verify incoming message count increases

### Health Check

```bash
curl http://localhost:8080/actuator/health
```

## Switching Back to Local (PostgreSQL Only)

If you want to run against a local PostgreSQL (no Kafka):

1. Open a **new terminal** (clears exported env vars from `source`)
2. Run:

```bash
cd application
SPRING_PROFILES_ACTIVE=local mvn spring-boot:run
```

The `local` profile connects to `localhost:5432` and does not require Event Hubs.

## Troubleshooting

### "FATAL: password authentication failed"

You're connecting to Azure PostgreSQL but `DefaultAzureCredential` can't get a token. Run `az login` again and verify your AAD user has a PostgreSQL role.

### "Connection refused" on PostgreSQL

Your IP is not in the PostgreSQL firewall. Re-run the firewall rule command above.

### Kafka "SASL authentication failed"

Your AAD user doesn't have the Event Hubs Data Sender role, or the role assignment hasn't propagated yet. Re-run the role assignment command and wait a few minutes.

### "Bootstrap broker ... disconnected"

Check that `KAFKA_BOOTSTRAP_SERVERS` is set correctly (port `9093`, not `9092`). Event Hubs uses TLS on port 9093.
