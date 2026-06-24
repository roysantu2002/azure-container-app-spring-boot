# Terraform Commands Reference

> Useful commands for inspecting, managing, and debugging Terraform state and resources.

---

## Check Terraform State (What Has Been Created)

### Option A — Terraform CLI (local)

```bash
cd terraform

# Initialize (connects to remote backend)
terraform init

# List all resources in state
terraform state list

# Show details of a specific resource
terraform state show azurerm_resource_group.orders
terraform state show azurerm_container_registry.orders
terraform state show azurerm_postgresql_flexible_server.orders
terraform state show azurerm_container_app.orders
terraform state show azurerm_user_assigned_identity.orders_service
terraform state show azurerm_container_app_environment.orders
```

### Option B — Check State File in Azure Storage

```bash
# List state files in the storage container
az storage blob list \
  --account-name stordersdevtfstate \
  --container-name tfstate \
  --query "[].{name:name, lastModified:properties.lastModified}" -o table

# Download and inspect the state file
az storage blob download \
  --account-name stordersdevtfstate \
  --container-name tfstate \
  --name orders-dev.terraform.tfstate \
  --file /tmp/tfstate.json

# List all resource types in the state
cat /tmp/tfstate.json | python3 -m json.tool | grep '"type"'
```

### Option C — Azure Portal

Go to **Resource Groups > rg-orders-dev** to see all created resources.

---

## Terraform Plan (Preview Changes)

```bash
cd terraform

# Plan with dev variables
terraform plan -var-file=environments/dev.tfvars

# Plan and save to a file
terraform plan -var-file=environments/dev.tfvars -out=tfplan
```

---

## Terraform Apply (Create/Update Resources)

```bash
cd terraform

# Apply with dev variables (interactive approval)
terraform apply -var-file=environments/dev.tfvars

# Apply from a saved plan (no approval prompt)
terraform apply tfplan
```

---

## Terraform Destroy (Remove All Resources)

```bash
cd terraform

# Destroy with interactive confirmation
terraform destroy -var-file=environments/dev.tfvars

# Destroy without confirmation (use with caution)
terraform destroy -var-file=environments/dev.tfvars -auto-approve
```

---

## Terraform Outputs (View Created Resource Details)

```bash
cd terraform

# Show all outputs
terraform output

# Show a specific output
terraform output acr_login_server
terraform output postgres_fqdn
terraform output container_app_url
terraform output managed_identity_client_id
terraform output managed_identity_principal_id
```

---

## Terraform Formatting and Validation

```bash
cd terraform

# Check formatting (fails if any file is unformatted)
terraform fmt -check -recursive

# Auto-format all files
terraform fmt -recursive

# Validate configuration
terraform validate
```

---

## Terraform State Management

```bash
cd terraform

# List all resources in state
terraform state list

# Show full details of a resource
terraform state show <resource_address>

# Remove a resource from state (without destroying it in Azure)
terraform state rm <resource_address>

# Import an existing Azure resource into state
terraform import <resource_address> <azure_resource_id>
```

---

## Verify Azure Resources via CLI

```bash
# List all resources in the resource group
az resource list --resource-group rg-orders-dev --output table

# Check specific resources
az acr show --name acrordersdev --query "{name:name, loginServer:loginServer, sku:sku.name}" -o table

az postgres flexible-server show --name pg-orders-dev --resource-group rg-orders-dev --query "{name:name, state:state, version:version, fqdn:fullyQualifiedDomainName}" -o table

az containerapp show --name acrordersapp --resource-group rg-orders-dev --query "{name:name, fqdn:properties.configuration.ingress.fqdn, provisioningState:properties.provisioningState}" -o table

az identity show --name orders-service-identity --resource-group rg-orders-dev --query "{name:name, clientId:clientId, principalId:principalId}" -o table

az containerapp env show --name managedEnvironment-rgordersdev-a29a --resource-group rg-orders-dev --query "{name:name, provisioningState:properties.provisioningState}" -o table
```