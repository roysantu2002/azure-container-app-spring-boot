# Azure Verification Commands

> All `az` CLI commands needed to verify the orders-platform setup from start to finish.

---

## 1. Login and Subscription

```bash
# Login to Azure
az login

# Set the correct subscription
az account set --subscription "0bb4f66b-be3a-4331-941c-fd6c8c0a3eef"

# Verify current context
az account show --query "{name:name, subscriptionId:id, tenantId:tenantId, state:state}" -o table
```

---

## 2. Service Principal and OIDC

```bash
# List the app registration
az ad app list --filter "displayName eq 'sp-orders-terraform'" --query "[].{appId:appId, id:id, displayName:displayName}" -o table

# Show the service principal
az ad sp show --id 666401c9-e0bb-45db-b113-e087b49eddcd --query "{appId:appId, displayName:displayName}" -o table

# List federated credentials (OIDC for GitHub Actions)
az ad app federated-credential list \
  --id $(az ad app list --filter "displayName eq 'sp-orders-terraform'" --query "[0].id" -o tsv) \
  --query "[].{name:name, issuer:issuer, subject:subject}" -o table

# Verify role assignments on subscription
az role assignment list \
  --assignee 666401c9-e0bb-45db-b113-e087b49eddcd \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

---

## 3. Terraform State Storage

```bash
# Verify state resource group
az group show --name rg-terraform-state --query "{name:name, location:location, state:properties.provisioningState}" -o table

# Verify storage account
az storage account show --name stordersdevtfstate --query "{name:name, sku:sku.name, location:primaryLocation}" -o table

# Verify blob container
az storage container list --account-name stordersdevtfstate --query "[].{name:name}" -o table

# List state files
az storage blob list \
  --account-name stordersdevtfstate \
  --container-name tfstate \
  --query "[].{name:name, size:properties.contentLength, lastModified:properties.lastModified}" -o table
```

---

## 4. Resource Group

```bash
# Verify resource group exists
az group show --name rg-orders-dev --query "{name:name, location:location, state:properties.provisioningState}" -o table

# List all resources in the group
az resource list --resource-group rg-orders-dev --query "[].{name:name, type:type, location:location}" -o table
```

---

## 5. Managed Identity

```bash
# Verify managed identity
az identity show \
  --name orders-service-identity \
  --resource-group rg-orders-dev \
  --query "{name:name, clientId:clientId, principalId:principalId, location:location}" -o table

# Verify role assignments for the identity
az role assignment list \
  --assignee $(az identity show --name orders-service-identity --resource-group rg-orders-dev --query "principalId" -o tsv) \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

---

## 6. Container Registry (ACR)

```bash
# Verify ACR exists
az acr show --name acrordersdev --query "{name:name, loginServer:loginServer, sku:sku.name, adminEnabled:adminUserEnabled}" -o table

# List repositories
az acr repository list --name acrordersdev -o table

# List image tags
az acr repository show-tags --name acrordersdev --repository orders-service -o table

# Show image details (latest)
az acr repository show --name acrordersdev --image orders-service:latest -o table
```

---

## 7. PostgreSQL Flexible Server

```bash
# Verify server
az postgres flexible-server show \
  --name pg-orders-dev \
  --resource-group rg-orders-dev \
  --query "{name:name, state:state, version:version, fqdn:fullyQualifiedDomainName, sku:sku.name}" -o table

# Verify authentication method
az postgres flexible-server show \
  --name pg-orders-dev \
  --resource-group rg-orders-dev \
  --query "{passwordAuth:authConfig.passwordAuth, activeDirectoryAuth:authConfig.activeDirectoryAuth}" -o table

# List databases
az postgres flexible-server db list \
  --server-name pg-orders-dev \
  --resource-group rg-orders-dev \
  --query "[].{name:name, charset:charset, collation:collation}" -o table

# List firewall rules
az postgres flexible-server firewall-rule list \
  --name pg-orders-dev \
  --resource-group rg-orders-dev \
  --query "[].{name:name, startIp:startIpAddress, endIp:endIpAddress}" -o table

# Check Entra admin
az postgres flexible-server ad-admin list \
  --server-name pg-orders-dev \
  --resource-group rg-orders-dev \
  -o table
```

---

## 8. Connect to PostgreSQL (Manual Verification)

```bash
# Get Entra access token
export PGPASSWORD=$(az account get-access-token \
  --resource-type oss-rdbms \
  --query accessToken \
  --output tsv)

# Connect to ordersdb
psql "host=pg-orders-dev.postgres.database.azure.com \
      port=5432 \
      dbname=ordersdb \
      user=<YOUR_ENTRA_EMAIL> \
      sslmode=require"

# Once connected, verify schema and data:
# \dn                              -- list schemas
# \dt orders.*                     -- list tables in orders schema
# SELECT * FROM orders.orders;     -- check seeded data
# SELECT count(*) FROM orders.orders;
# \du orders-service-identity      -- verify MI role exists
```

---

## 9. Log Analytics Workspace

```bash
# Verify workspace
az monitor log-analytics workspace show \
  --workspace-name log-orders-dev \
  --resource-group rg-orders-dev \
  --query "{name:name, sku:sku.name, retentionDays:retentionInDays, state:provisioningState}" -o table
```

---

## 10. Container Apps Environment

```bash
# Verify ACA environment
az containerapp env show \
  --name managedEnvironment-rgordersdev-a29a \
  --resource-group rg-orders-dev \
  --query "{name:name, state:properties.provisioningState, location:location}" -o table
```

---

## 11. Container App

```bash
# Verify container app
az containerapp show \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --query "{name:name, image:properties.template.containers[0].image, fqdn:properties.configuration.ingress.fqdn, state:properties.provisioningState}" -o table

# Check current revision
az containerapp revision list \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --query "[].{name:name, active:properties.active, trafficWeight:properties.trafficWeight, createdTime:properties.createdTime}" -o table

# Check environment variables
az containerapp show \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --query "properties.template.containers[0].env[].{name:name, value:value}" -o table

# Check assigned identities
az containerapp identity show \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  -o table

# View recent logs
az containerapp logs show \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --tail 50
```

---

## 12. Test Application Endpoints

```bash
# Get the app FQDN
FQDN=$(az containerapp show \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --query "properties.configuration.ingress.fqdn" -o tsv)

echo "App URL: https://$FQDN"

# Health check
curl -s https://$FQDN/actuator/health | python3 -m json.tool

# Liveness probe
curl -s https://$FQDN/actuator/health/liveness | python3 -m json.tool

# Readiness probe
curl -s https://$FQDN/actuator/health/readiness | python3 -m json.tool

# List all orders (seeded data)
curl -s https://$FQDN/orders | python3 -m json.tool

# Get single order by ID
curl -s https://$FQDN/orders/a1b2c3d4-e5f6-7890-abcd-ef1234567890 | python3 -m json.tool

# Create a new order
curl -s -X POST https://$FQDN/orders \
  -H "Content-Type: application/json" \
  -d '{
    "customerName": "Test User",
    "customerEmail": "test@example.com",
    "productName": "Laptop Stand",
    "quantity": 1,
    "unitPrice": 2500.00
  }' | python3 -m json.tool
```

---

## 13. Troubleshooting

```bash
# Check container app provisioning errors
az containerapp show \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --query "properties.provisioningState" -o tsv

# Stream live logs
az containerapp logs show \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --follow

# Check if ACR image is pullable by the managed identity
az role assignment list \
  --scope $(az acr show --name acrordersdev --query id -o tsv) \
  --query "[].{principal:principalName, role:roleDefinitionName}" -o table

# Restart the container app
az containerapp revision restart \
  --name acrordersapp \
  --resource-group rg-orders-dev \
  --revision $(az containerapp revision list --name acrordersapp --resource-group rg-orders-dev --query "[0].name" -o tsv)

# Check DNS resolution for Postgres (from Cloud Shell)
nslookup pg-orders-dev.postgres.database.azure.com

# Verify Postgres connectivity (from Cloud Shell)
az postgres flexible-server connect \
  --name pg-orders-dev \
  --admin-user <YOUR_ENTRA_EMAIL> \
  --database-name ordersdb
```