#!/bin/bash
# Full deployment: infra → build images → deploy apps
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Step 1: Terraform init ==="
cd "$SCRIPT_DIR/terraform"
terraform init

echo ""
echo "=== Step 2: Create ACR first (so we can push images) ==="
terraform apply \
  -target=azurerm_resource_group.rg \
  -target=azurerm_container_registry.acr \
  -target=random_string.suffix \
  -auto-approve

ACR_NAME=$(terraform output -raw acr_name)
echo "ACR: $ACR_NAME"

echo ""
echo "=== Step 3: Build & push images using local Docker ==="
cd "$SCRIPT_DIR"

ACR_SERVER="${ACR_NAME}.azurecr.io"

# Login to ACR with local Docker
az acr login --name "$ACR_NAME"

docker build -t "${ACR_SERVER}/app-1:latest" ./app_1
docker push "${ACR_SERVER}/app-1:latest"

docker build -t "${ACR_SERVER}/app-2:latest" ./app_2
docker push "${ACR_SERVER}/app-2:latest"

echo ""
echo "=== Step 4: Deploy Container Apps Environment + both apps ==="
cd "$SCRIPT_DIR/terraform"
terraform apply -auto-approve

echo ""
echo "============================================================"
echo "Deployment complete!"
echo ""
terraform output app2_url
terraform output app2_fetch_endpoint
echo ""
echo "Test inter-app communication:"
echo "  curl \$(terraform output -raw app2_fetch_endpoint)"
echo "============================================================"