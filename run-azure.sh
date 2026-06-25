#!/bin/bash
# Run against AZURE PostgreSQL using az login credentials
# Prerequisites: az login

# Load env vars for this command only (no export = no leak)
set -a
source "$(dirname "$0")/.env.azure-debug"
set +a

cd "$(dirname "$0")/application"
mvn spring-boot:run
