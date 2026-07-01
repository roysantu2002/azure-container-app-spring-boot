#!/usr/bin/env bash

#
# Deploy Infrastructure + Applications
#
# Steps:
#   1. Terraform Init
#   2. Create Resource Group + ACR
#   3. Build AMD64 Docker Images
#   4. Push Images to ACR
#   5. Deploy Remaining Infrastructure
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"

################################################################################
# Helpers
################################################################################

print_step() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: '$1' is not installed."
        exit 1
    }
}

################################################################################
# Verify prerequisites
################################################################################

require_command az
require_command terraform
require_command docker

################################################################################
# Terraform Init
################################################################################

print_step "Step 1 - Terraform Init"

cd "$TF_DIR"

terraform init

################################################################################
# Create Resource Group + ACR
################################################################################

print_step "Step 2 - Create Resource Group + Azure Container Registry"

terraform apply \
    -target=random_string.suffix \
    -target=azurerm_resource_group.rg \
    -target=azurerm_container_registry.acr \
    -auto-approve

ACR_NAME=$(terraform output -raw acr_name)
ACR_SERVER="${ACR_NAME}.azurecr.io"

echo
echo "ACR Name   : ${ACR_NAME}"
echo "ACR Server : ${ACR_SERVER}"

################################################################################
# Login
################################################################################

print_step "Step 3 - Login to Azure Container Registry"

az acr login --name "${ACR_NAME}"

################################################################################
# Docker Buildx
################################################################################

print_step "Step 4 - Configure Docker Buildx"

if ! docker buildx inspect amd64-builder >/dev/null 2>&1; then
    docker buildx create \
        --name amd64-builder \
        --driver docker-container \
        --use
fi

docker buildx use amd64-builder
docker buildx inspect --bootstrap

################################################################################
# Build app-1
################################################################################

print_step "Step 5 - Build and Push app-1"

docker buildx build \
    --platform linux/amd64 \
    --tag "${ACR_SERVER}/app-1:latest" \
    --push \
    "${SCRIPT_DIR}/app_1"

################################################################################
# Build app-2
################################################################################

print_step "Step 6 - Build and Push app-2"

docker buildx build \
    --platform linux/amd64 \
    --tag "${ACR_SERVER}/app-2:latest" \
    --push \
    "${SCRIPT_DIR}/app_2"

################################################################################
# Deploy Infrastructure
################################################################################

print_step "Step 7 - Deploy Container Apps"

cd "$TF_DIR"

terraform apply -auto-approve

################################################################################
# Outputs
################################################################################

print_step "Deployment Complete"

echo
echo "Application URLs"
echo "----------------"

terraform output app1_url || true
terraform output app2_url || true

echo
echo "Inter-App Endpoint"
echo "------------------"

terraform output app2_fetch_endpoint || true

echo
FETCH_ENDPOINT=$(terraform output -raw app2_fetch_endpoint 2>/dev/null || true)

if [[ -n "${FETCH_ENDPOINT}" ]]; then
    echo "Test with:"
    echo
    echo "curl ${FETCH_ENDPOINT}"
fi

echo
echo "Done."