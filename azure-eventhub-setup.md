# Azure Event Hubs (Kafka) — Portal Setup Guide

## Step 1: Create Event Hubs Namespace

1. Go to **Azure Portal** > search **"Event Hubs"** > click **Create**
2. Fill in:

| Field | Value |
|-------|-------|
| Subscription | Your subscription |
| Resource Group | `rg-orders-dev` (same as PostgreSQL) |
| Namespace Name | `evhns-orders-dev` |
| Location | `Canada Central` (same region as your other resources) |
| Pricing Tier | **Standard** (Basic doesn't support Kafka) |
| Throughput Units | 1 (sufficient for dev) |
| Enable Kafka | **Checked** (Standard tier enables this automatically) |

3. Click **Review + Create** > **Create**

---

## Step 2: Create an Event Hub (Kafka Topic)

1. Once the namespace is created, go to **`evhns-orders-dev`** resource
2. Left menu > **Event Hubs** > click **+ Event Hub**
3. Fill in:

| Field | Value |
|-------|-------|
| Name | `order-events` |
| Partition Count | 2 |
| Message Retention | 1 day |
| Cleanup Policy | Delete |

4. Click **Create**

---

## Step 3: Grant Managed Identity Access (for deployed ACA app)

This is the same `orders-service-identity` used for PostgreSQL.

1. Stay in **`evhns-orders-dev`** namespace
2. Left menu > **Access control (IAM)** > click **+ Add** > **Add role assignment**
3. **Role tab**: Search for **`Azure Event Hubs Data Sender`** > select it > **Next**
4. **Members tab**:
   - Assign access to: **Managed identity**
   - Click **+ Select members**
   - Subscription: yours
   - Managed identity: **User-assigned managed identity**
   - Select: **`orders-service-identity`**
   - Click **Select**
5. Click **Review + assign**

---

## Step 4: Grant YOUR AAD User Access (for local dev with `az login`)

Same namespace, repeat the role assignment for yourself:

1. **`evhns-orders-dev`** > **Access control (IAM)** > **+ Add** > **Add role assignment**
2. **Role tab**: **`Azure Event Hubs Data Sender`** > **Next**
3. **Members tab**:
   - Assign access to: **User, group, or service principal**
   - Click **+ Select members**
   - Search for your email (e.g. `roysantu2002@gmail.com`)
   - Select it > **Select**
4. Click **Review + assign**

---

## Step 5: Verify the Kafka Endpoint

1. Go to **`evhns-orders-dev`** > **Overview**
2. Look for **Host name**: `evhns-orders-dev.servicebus.windows.net`
3. The Kafka bootstrap server will be: **`evhns-orders-dev.servicebus.windows.net:9093`**

This is the value you'll put in `KAFKA_BOOTSTRAP_SERVERS`.

---

## How It Maps to What You Did for PostgreSQL

| Step | PostgreSQL | Event Hubs (Kafka) |
|------|-----------|-------------------|
| **Service** | `pg-orders-dev` (Flexible Server) | `evhns-orders-dev` (Namespace) |
| **Auth method** | Entra ID (AAD) | Entra ID (AAD) |
| **MI role** | PostgreSQL Entra admin | `Azure Event Hubs Data Sender` |
| **Dev user role** | PostgreSQL AAD user | `Azure Event Hubs Data Sender` |
| **Local auth** | `az login` → DefaultAzureCredential | `az login` → OAUTHBEARER callback (same credential) |
| **Deployed auth** | Managed Identity → token | Managed Identity → token |

Same identity, same `az login`, no passwords for either service.