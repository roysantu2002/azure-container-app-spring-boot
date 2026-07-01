# Microsoft Entra ID + OIDC Authentication Guide

## Orders Platform - Adding Auth Layer with Microsoft Entra ID (Azure AD)

This guide covers end-to-end steps to protect the Orders Platform Spring Boot application using **Microsoft Entra ID** (formerly Azure AD) with **OpenID Connect (OIDC)**. Each step is tagged with its execution method:

- **[TERRAFORM]** - Can be automated via Terraform
- **[PORTAL]** - Must be done manually in Azure Portal
- **[CODE]** - Changes required in the Spring Boot application

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1 - Entra ID App Registration](#3-phase-1---entra-id-app-registration)
4. [Phase 2 - Configure API Permissions & Scopes](#4-phase-2---configure-api-permissions--scopes)
5. [Phase 3 - Spring Boot Application Changes](#5-phase-3---spring-boot-application-changes)
6. [Phase 4 - Terraform Automation](#6-phase-4---terraform-automation)
7. [Phase 5 - Testing & Validation](#7-phase-5---testing--validation)
8. [Phase 6 - Production Hardening](#8-phase-6---production-hardening)
9. [Automation Summary Matrix](#9-automation-summary-matrix)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Architecture Overview

### Current State (No Auth)

```
Client --> GET /api/v1/orders --> OrderController --> Database
                (PUBLIC - no auth)
```

### Target State (Entra ID + OIDC)

```
Client --> Entra ID (login) --> Access Token (JWT)
       --> GET /api/v1/orders [Authorization: Bearer <token>]
       --> Spring Security (validate JWT, check roles/scopes)
       --> OrderController --> Database
```

### Authentication Flow (Authorization Code + PKCE)

```
1. User/Client requests access
2. Redirect to Microsoft login (login.microsoftonline.com)
3. User authenticates with Entra ID credentials
4. Entra ID issues authorization code
5. Application exchanges code for ID Token + Access Token
6. Access Token (JWT) is sent with each API request
7. Spring Security validates the JWT signature, issuer, audience, and expiry
8. If valid, request proceeds to the controller
```

### Key Components

| Component | Purpose |
|-----------|---------|
| **Entra ID Tenant** | Identity provider (IdP) |
| **App Registration (API)** | Represents the Orders Platform backend |
| **App Registration (Client)** | Represents frontend/Postman/CLI clients |
| **Spring Security OAuth2 Resource Server** | Validates JWT tokens on the API side |
| **App Roles / Scopes** | Define what authenticated users can do |

---

## 2. Prerequisites

- Azure subscription with Entra ID (Azure AD) tenant
- `az` CLI installed and authenticated (`az login`)
- Tenant ID, Subscription ID available
- Existing Orders Platform application running (Spring Boot 3.5, Java 21)
- Terraform >= 1.5 (for automation steps)
- Postman or `curl` for testing

### Gather Tenant Information

```bash
# Get your Tenant ID
az account show --query tenantId -o tsv

# Get your Subscription ID
az account show --query id -o tsv

# Get your Entra ID domain
az rest --method get --url 'https://graph.microsoft.com/v1.0/domains' --query 'value[?isDefault].id' -o tsv
```

---

## 3. Phase 1 - Entra ID App Registration

### Step 1.1: Register the Backend API Application **[TERRAFORM]**

This creates an App Registration that represents the Orders Platform API.

**What it does:** Registers the application in Entra ID so it can validate incoming JWT tokens.

**Via Azure CLI (for understanding):**

> **Important:** Entra ID requires identifier URIs to contain the app's own Application (client) ID, a tenant-verified domain, or the tenant ID. You cannot use an arbitrary string like `api://orders-platform-api`. This is a two-step process: create the app first, then set the identifier URI.

```bash
# Step A: Create the app registration (without identifier URI)
APP_ID=$(az ad app create \
  --display-name "orders-platform-api" \
  --sign-in-audience "AzureADMyOrg" \
  --query appId -o tsv)

echo "API App ID: $APP_ID"

# Step B: Set the identifier URI using the generated App ID
az ad app update \
  --id $APP_ID \
  --identifier-uris "api://$APP_ID"

# Step C: Create the Service Principal (CRITICAL)
az ad sp create --id $APP_ID
```

> **CRITICAL: Do not skip Step C.** The `az ad app create` command only creates the App Registration object. It does **not** create a Service Principal. Without a Service Principal, the app will **not appear** under "My APIs" in the Portal when other apps try to add API permissions. This was a real issue we encountered -- see [Troubleshooting: "My APIs" shows empty](#my-apis-shows-no-results-in-portal) for details.

**Via Azure Portal (if manual):**

1. Go to **Azure Portal** > **Microsoft Entra ID** > **App registrations**
2. Click **+ New registration**
3. Name: `orders-platform-api`
4. Supported account types: **Accounts in this organizational directory only (Single tenant)**
5. Redirect URI: Leave blank (this is a backend API, not a frontend)
6. Click **Register**
7. Note down the **Application (client) ID** and **Directory (tenant) ID**

### Step 1.2: Set the Application ID URI **[TERRAFORM]**

1. In the App Registration, go to **Expose an API**
2. Click **Set** next to Application ID URI
3. Accept the default `api://<Application-ID>` or set it to `api://<your-app-id>`
4. Click **Save**

> **Note:** The default suggestion `api://<Application-ID>` is the recommended format and will work without any verified domain requirements.

### Step 1.3: Register the Client Application (for Postman/Frontend) **[TERRAFORM]**

This creates a separate App Registration for clients that will call the API.

**Via Azure CLI:**

```bash
# Create the client app registration
CLIENT_APP_ID=$(az ad app create \
  --display-name "orders-platform-client" \
  --sign-in-audience "AzureADMyOrg" \
  --web-redirect-uris "http://localhost:8080/login/oauth2/code/azure" "https://oauth.pstmn.io/v1/callback" \
  --query appId -o tsv)

echo "Client App ID: $CLIENT_APP_ID"

# Create the Service Principal for the client app
az ad sp create --id $CLIENT_APP_ID
```

> **Remember:** Always create a Service Principal after `az ad app create`. Without it, the app exists only as a registration and cannot be used for authentication or discovered by other apps.

**Via Azure Portal:**

1. Go to **App registrations** > **+ New registration**
2. Name: `orders-platform-client`
3. Supported account types: **Accounts in this organizational directory only**
4. Redirect URI:
   - Platform: **Web**
   - URI: `http://localhost:8080/login/oauth2/code/azure`
5. Click **Register**
6. Add additional redirect URI for Postman: `https://oauth.pstmn.io/v1/callback`

### Step 1.4: Create Client Secret for the Client App **[PORTAL]**

> **Why manual?** Client secrets are sensitive credentials. Terraform can create them, but the secret value is only shown once and storing it in Terraform state is a security risk. Best practice is to create manually and store in Azure Key Vault.

1. In the **orders-platform-client** App Registration
2. Go to **Certificates & secrets** > **Client secrets**
3. Click **+ New client secret**
4. Description: `orders-platform-client-secret`
5. Expiry: Choose based on your rotation policy (recommended: 6 months)
6. Click **Add**
7. **IMMEDIATELY copy the secret value** - it will not be shown again
8. Store it securely in Azure Key Vault or your secrets manager

```bash
# Alternatively via CLI (secret value shown only once):
az ad app credential reset \
  --id <CLIENT_APP_ID> \
  --display-name "orders-platform-client-secret" \
  --years 1
```

---

## 4. Phase 2 - Configure API Permissions & Scopes

### Step 2.1: Define API Scopes (Permissions) on the Backend App **[TERRAFORM]**

Scopes define what actions clients can perform.

1. Go to **orders-platform-api** > **Expose an API**
2. Click **+ Add a scope**
3. Add the following scopes:

| Scope Name | Display Name | Description | Who Can Consent |
|------------|-------------|-------------|-----------------|
| `Orders.Read` | Read Orders | Allows reading order data | Admins and users |
| `Orders.Write` | Write Orders | Allows creating/updating orders | Admins only |

**For each scope:**
- Scope name: `Orders.Read` (or `Orders.Write`)
- Who can consent: **Admins and users** (or **Admins only** for write)
- Admin consent display name: e.g., "Read Orders"
- Admin consent description: e.g., "Allows the application to read order data"
- State: **Enabled**

### Step 2.2: Define App Roles **[TERRAFORM]**

App Roles provide role-based access control (RBAC).

1. Go to **orders-platform-api** > **App roles**
2. Click **+ Create app role**
3. Add:

| Role | Display Name | Value | Description | Allowed Members |
|------|-------------|-------|-------------|-----------------|
| Order Reader | Order Reader | `Order.Reader` | Can view orders | Users/Groups |
| Order Writer | Order Writer | `Order.Writer` | Can create/update orders | Users/Groups |
| Order Admin | Order Admin | `Order.Admin` | Full access to orders | Users/Groups |

### Step 2.3: Grant API Permissions to the Client App **[TERRAFORM]**

> **Prerequisite:** The `orders-platform-api` app **must** have a Service Principal created (Step 1.1, Step C) before this step. If you created the app via CLI without `az ad sp create`, the API will not appear under "My APIs" in the Portal. Run `az ad sp create --id <API_APP_ID>` first.

1. Go to **orders-platform-client** > **API permissions**
2. Click **+ Add a permission**
3. Select **My APIs** > **orders-platform-api**
4. Select **Delegated permissions**
5. Check `Orders.Read` and `Orders.Write`
6. Click **Add permissions**

**Via Azure CLI (alternative):**

```bash
# Get the API app's service principal object ID
API_SP_ID=$(az ad sp show --id $APP_ID --query id -o tsv)

# Add delegated permission for Orders.Read scope
az ad app permission add \
  --id $CLIENT_APP_ID \
  --api $APP_ID \
  --api-permissions "<ORDERS_READ_SCOPE_ID>=Scope <ORDERS_WRITE_SCOPE_ID>=Scope"
```

> **Tip:** To find scope IDs, run: `az ad app show --id $APP_ID --query "api.oauth2PermissionScopes[].{name:value, id:id}" -o table`

### Step 2.4: Grant Admin Consent **[PORTAL]**

> **Why manual?** Admin consent is a privileged operation that requires Global Administrator or Application Administrator role. It should be a deliberate, audited action.

1. In **orders-platform-client** > **API permissions**
2. Click **Grant admin consent for [Your Tenant]**
3. Confirm by clicking **Yes**
4. Verify that all permissions show a green checkmark under "Status"

### Step 2.5: Assign Users/Groups to App Roles **[PORTAL]**

> **Why manual?** User and group assignments are organizational decisions that should be reviewed by an administrator. They may require coordination with HR/directory teams.

1. Go to **Microsoft Entra ID** > **Enterprise applications**
2. Find **orders-platform-api**
3. Go to **Users and groups** > **+ Add user/group**
4. Select the user(s) or group(s)
5. Assign the appropriate role (Order.Reader, Order.Writer, or Order.Admin)
6. Click **Assign**

---

## 5. Phase 3 - Spring Boot Application Changes

### Step 3.1: Add Spring Security Dependencies **[CODE]**

Add the following dependencies to `application/pom.xml`:

```xml
<!-- Spring Security Core -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-security</artifactId>
</dependency>

<!-- OAuth2 Resource Server (JWT validation) -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-oauth2-resource-server</artifactId>
</dependency>

<!-- Microsoft Entra ID (Azure AD) Spring Boot Starter -->
<dependency>
    <groupId>com.azure.spring</groupId>
    <artifactId>spring-cloud-azure-starter-active-directory</artifactId>
</dependency>
```

> Note: `spring-cloud-azure-starter-active-directory` is already covered by the existing Spring Cloud Azure BOM (`spring-cloud-azure-dependencies:5.21.0`) in the pom.xml.

### Step 3.2: Configure Application Properties **[CODE]**

Add the following to `application/src/main/resources/application.yml`:

```yaml
spring:
  cloud:
    azure:
      active-directory:
        enabled: true
        credential:
          client-id: ${AZURE_CLIENT_ID}
          client-secret: ${AZURE_CLIENT_SECRET:}
        profile:
          tenant-id: ${AZURE_TENANT_ID}
        app-id-uri: api://${AZURE_CLIENT_ID}
```

> **Note:** The `app-id-uri` must match the identifier URI set on the App Registration. Since Entra ID requires the format `api://<Application-ID>`, we use the `AZURE_CLIENT_ID` environment variable here.

Add a new profile file `application/src/main/resources/application-entra.yml`:

```yaml
spring:
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri: https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0
          audiences: api://${AZURE_CLIENT_ID}

  cloud:
    azure:
      active-directory:
        enabled: true
        credential:
          client-id: ${AZURE_CLIENT_ID}
          client-secret: ${AZURE_CLIENT_SECRET:}
        profile:
          tenant-id: ${AZURE_TENANT_ID}
        app-id-uri: api://${AZURE_CLIENT_ID}

logging:
  level:
    org.springframework.security: DEBUG
    com.azure.spring: DEBUG
```

For the **local** profile, disable security so local development is not disrupted. Add to `application-local.yml`:

```yaml
spring:
  cloud:
    azure:
      active-directory:
        enabled: false
  security:
    oauth2:
      resourceserver:
        jwt:
          issuer-uri:
```

### Step 3.3: Create Security Configuration Class **[CODE]**

Create `application/src/main/java/com/example/orders/config/SecurityConfig.java`:

```java
package com.example.orders.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.JwtGrantedAuthoritiesConverter;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
@EnableWebSecurity
@EnableMethodSecurity
@Profile("!local")
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())  // Stateless API, no CSRF needed
            .sessionManagement(session ->
                session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                // Public endpoints (health checks, actuator)
                .requestMatchers("/actuator/**").permitAll()
                .requestMatchers("/error").permitAll()

                // Order endpoints - require authentication
                .requestMatchers(HttpMethod.GET, "/api/v1/orders/**")
                    .hasAnyAuthority("APPROLE_Order.Reader", "APPROLE_Order.Admin")
                .requestMatchers(HttpMethod.POST, "/api/v1/orders/**")
                    .hasAnyAuthority("APPROLE_Order.Writer", "APPROLE_Order.Admin")

                // All other requests require authentication
                .anyRequest().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter()))
            );

        return http.build();
    }

    @Bean
    public JwtAuthenticationConverter jwtAuthenticationConverter() {
        JwtGrantedAuthoritiesConverter grantedAuthoritiesConverter =
            new JwtGrantedAuthoritiesConverter();
        // Entra ID puts roles in the "roles" claim
        grantedAuthoritiesConverter.setAuthoritiesClaimName("roles");
        grantedAuthoritiesConverter.setAuthorityPrefix("APPROLE_");

        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(grantedAuthoritiesConverter);
        return converter;
    }
}
```

### Step 3.4: Create Local Security Configuration (No Auth for Dev) **[CODE]**

Create `application/src/main/java/com/example/orders/config/LocalSecurityConfig.java`:

```java
package com.example.orders.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.web.SecurityFilterChain;

@Configuration
@EnableWebSecurity
@Profile("local")
public class LocalSecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .authorizeHttpRequests(auth -> auth
                .anyRequest().permitAll()
            );
        return http.build();
    }
}
```

### Step 3.5: URL-based vs Method-Level Security — How It Works **[CODE]**

#### How the Protection Actually Works

The security is enforced by the **Spring Security filter chain** in `SecurityConfig.java`, **before** the request ever reaches the controller. Here is the request flow:

```
Request: GET /api/v1/orders  (with or without Authorization header)
    │
    ▼
┌── Spring Security Filter Chain (SecurityConfig.java) ──────────┐
│                                                                 │
│  1. Check Authorization header                                  │
│     Missing/invalid → 401 JSON response (never reaches          │
│                        controller)                               │
│                                                                 │
│  2. Validate JWT token:                                         │
│     • Signature verified via Microsoft JWKS endpoint            │
│     • Issuer must be login.microsoftonline.com/<tenant>/v2.0    │
│     • Audience must be api://<app-id>                           │
│     • Token must not be expired                                 │
│     Any check fails → 401                                       │
│                                                                 │
│  3. Extract roles from JWT "roles" claim:                       │
│     ["Order.Reader"] → granted authority: APPROLE_Order.Reader  │
│                                                                 │
│  4. Match request URL + HTTP method against rules:              │
│     GET  /api/v1/orders/** → APPROLE_Order.Reader or .Admin     │
│     POST /api/v1/orders/** → APPROLE_Order.Writer or .Admin     │
│     No matching role → 403 JSON response                        │
│                                                                 │
│  5. All checks pass → request proceeds to controller            │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
  OrderController.getAllOrders()  ← no security code here
```

#### What We Implemented: URL-Based Security (Recommended)

All access rules are defined centrally in `SecurityConfig.java`:

```java
.authorizeHttpRequests(auth -> auth
    .requestMatchers("/actuator/**").permitAll()
    .requestMatchers("/swagger-ui/**", ...).permitAll()

    .requestMatchers(HttpMethod.GET, "/api/v1/orders/**")
        .hasAnyAuthority("APPROLE_Order.Reader", "APPROLE_Order.Admin")
    .requestMatchers(HttpMethod.POST, "/api/v1/orders/**")
        .hasAnyAuthority("APPROLE_Order.Writer", "APPROLE_Order.Admin")

    .anyRequest().authenticated()
)
```

The controller remains **unchanged** — no security annotations needed:

```java
@GetMapping
public List<OrderEntity> getAllOrders() {
    return orderRepository.findAll();  // security already enforced
}
```

#### Alternative: Method-Level Security with @PreAuthorize (Optional)

You **can** add `@PreAuthorize` annotations directly on controller methods instead. This is useful when:
- URL patterns don't map cleanly to permissions (e.g., same URL, different logic)
- You want the security rule visible right next to the business logic
- You have complex authorization logic (e.g., checking ownership)

```java
@GetMapping
@PreAuthorize("hasAnyAuthority('APPROLE_Order.Reader', 'APPROLE_Order.Admin')")
public List<OrderEntity> getAllOrders() {
    return orderRepository.findAll();
}
```

> **Important:** Do NOT use both URL-based and method-level security for the same endpoint. It creates duplicate checks and makes the security rules harder to reason about. Pick one approach.

#### Comparison

| Aspect | URL-Based (what we did) | Method-Level (@PreAuthorize) |
|--------|------------------------|------------------------------|
| **Rules location** | Single file (`SecurityConfig.java`) | Scattered across controllers |
| **Easy to audit** | Yes — one place to review | No — must check every method |
| **Controller changes** | None required | Annotations on every method |
| **Best for** | REST APIs with clear URL patterns | Complex per-method logic |
| **Our recommendation** | **Use this** for the Orders API | Use when URL patterns aren't sufficient |

### Step 3.6: Add CORS Configuration (if needed) **[CODE]**

If a frontend SPA will call the API, add CORS support in `SecurityConfig.java`:

```java
import org.springframework.web.cors.CorsConfiguration;
import org.springframework.web.cors.CorsConfigurationSource;
import org.springframework.web.cors.UrlBasedCorsConfigurationSource;

// Inside SecurityConfig class, add to securityFilterChain:
//   .cors(cors -> cors.configurationSource(corsConfigurationSource()))

@Bean
public CorsConfigurationSource corsConfigurationSource() {
    CorsConfiguration config = new CorsConfiguration();
    config.setAllowedOrigins(List.of(
        "http://localhost:3000",      // React dev server
        "http://localhost:4200"       // Angular dev server
    ));
    config.setAllowedMethods(List.of("GET", "POST", "PUT", "DELETE", "OPTIONS"));
    config.setAllowedHeaders(List.of("Authorization", "Content-Type"));
    config.setAllowCredentials(true);

    UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
    source.registerCorsConfiguration("/api/**", config);
    return source;
}
```

### Step 3.7: Add Environment Variables to `.env.azure-debug` **[CODE]**

```bash
# --- Entra ID / OIDC Authentication ---
AZURE_TENANT_ID=<your-tenant-id>
AZURE_CLIENT_ID=<orders-platform-api-app-id>
AZURE_CLIENT_SECRET=<client-secret-if-needed>
```

### Step 3.8: Update `run-azure.sh` Script **[CODE]**

Update the script to use the `entra` profile alongside `azure-debug`:

```bash
#!/bin/bash
set -a
source .env.azure-debug
set +a
cd application && SPRING_PROFILES_ACTIVE=azure-debug,entra mvn spring-boot:run
```

---

## 6. Phase 4 - Terraform Automation

### Step 4.1: Create Entra ID Terraform Configuration **[TERRAFORM]**

Create `terraform/entra-auth.tf`:

```hcl
# ============================================================
# Microsoft Entra ID - App Registrations for Orders Platform
# ============================================================

# Required provider
terraform {
  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47"
    }
  }
}

data "azuread_client_config" "current" {}

# -------------------------------------------------------
# Backend API App Registration
# -------------------------------------------------------
resource "azuread_application" "orders_api" {
  display_name     = "${var.project_name}-api"
  sign_in_audience = "AzureADMyOrg"

  # NOTE: identifier_uris cannot use an arbitrary string.
  # Entra ID requires: api://<app-client-id>, a verified domain, or tenant ID.
  # We set it after creation using azuread_application_identifier_uri below.

  api {
    requested_access_token_version = 2

    # Scope: Orders.Read
    oauth2_permission_scope {
      admin_consent_description  = "Allow the application to read orders"
      admin_consent_display_name = "Read Orders"
      enabled                    = true
      id                         = random_uuid.scope_orders_read.result
      type                       = "User"
      value                      = "Orders.Read"
    }

    # Scope: Orders.Write
    oauth2_permission_scope {
      admin_consent_description  = "Allow the application to create and update orders"
      admin_consent_display_name = "Write Orders"
      enabled                    = true
      id                         = random_uuid.scope_orders_write.result
      type                       = "Admin"
      value                      = "Orders.Write"
    }
  }

  # App Role: Order.Reader
  app_role {
    allowed_member_types = ["User"]
    description          = "Can view orders"
    display_name         = "Order Reader"
    enabled              = true
    id                   = random_uuid.role_order_reader.result
    value                = "Order.Reader"
  }

  # App Role: Order.Writer
  app_role {
    allowed_member_types = ["User"]
    description          = "Can create and update orders"
    display_name         = "Order Writer"
    enabled              = true
    id                   = random_uuid.role_order_writer.result
    value                = "Order.Writer"
  }

  # App Role: Order.Admin
  app_role {
    allowed_member_types = ["User"]
    description          = "Full access to orders"
    display_name         = "Order Admin"
    enabled              = true
    id                   = random_uuid.role_order_admin.result
    value                = "Order.Admin"
  }

  tags = ["orders-platform", var.environment]
}

resource "azuread_service_principal" "orders_api" {
  client_id                    = azuread_application.orders_api.client_id
  app_role_assignment_required = true

  tags = ["orders-platform", var.environment]
}

# Set the identifier URI using the auto-generated client_id
resource "azuread_application_identifier_uri" "orders_api_uri" {
  application_id = azuread_application.orders_api.id
  identifier_uri = "api://${azuread_application.orders_api.client_id}"
}

# -------------------------------------------------------
# Client App Registration (for Postman / Frontend)
# -------------------------------------------------------
resource "azuread_application" "orders_client" {
  display_name     = "${var.project_name}-client"
  sign_in_audience = "AzureADMyOrg"

  web {
    redirect_uris = [
      "http://localhost:8080/login/oauth2/code/azure",
      "https://oauth.pstmn.io/v1/callback"
    ]
  }

  required_resource_access {
    resource_app_id = azuread_application.orders_api.client_id

    resource_access {
      id   = random_uuid.scope_orders_read.result
      type = "Scope"
    }

    resource_access {
      id   = random_uuid.scope_orders_write.result
      type = "Scope"
    }
  }

  tags = ["orders-platform", var.environment]
}

resource "azuread_service_principal" "orders_client" {
  client_id = azuread_application.orders_client.client_id
  tags      = ["orders-platform", var.environment]
}

# -------------------------------------------------------
# Random UUIDs for Scopes and Roles
# -------------------------------------------------------
resource "random_uuid" "scope_orders_read" {}
resource "random_uuid" "scope_orders_write" {}
resource "random_uuid" "role_order_reader" {}
resource "random_uuid" "role_order_writer" {}
resource "random_uuid" "role_order_admin" {}

# -------------------------------------------------------
# Outputs
# -------------------------------------------------------
output "orders_api_app_id" {
  description = "Application (client) ID of the Orders API"
  value       = azuread_application.orders_api.client_id
}

output "orders_api_object_id" {
  description = "Object ID of the Orders API app registration"
  value       = azuread_application.orders_api.object_id
}

output "orders_client_app_id" {
  description = "Application (client) ID of the Orders Client"
  value       = azuread_application.orders_client.client_id
}

output "tenant_id" {
  description = "Azure AD Tenant ID"
  value       = data.azuread_client_config.current.tenant_id
}
```

### Step 4.2: Add AzureAD Provider to `providers.tf` **[TERRAFORM]**

```hcl
provider "azuread" {
  tenant_id = var.tenant_id
}
```

### Step 4.3: Add Variables to `variables.tf` **[TERRAFORM]**

```hcl
variable "tenant_id" {
  description = "Azure AD Tenant ID"
  type        = string
}
```

---

## 7. Phase 5 - Testing & Validation

### Step 5.1: Get an Access Token via Azure CLI

```bash
# Login to Azure
az login

# Get token for the Orders API (replace <API_APP_ID> with your actual App ID)
az account get-access-token \
  --resource api://<API_APP_ID> \
  --query accessToken -o tsv
```

### Step 5.2: Test with curl

```bash
# Set the token (replace <API_APP_ID> with your actual App ID)
TOKEN=$(az account get-access-token --resource api://<API_APP_ID> --query accessToken -o tsv)

# Test GET orders (requires Order.Reader or Order.Admin role)
curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/v1/orders

# Test POST order (requires Order.Writer or Order.Admin role)
curl -X POST http://localhost:8080/api/v1/orders \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "customerName": "Test User",
    "customerEmail": "test@example.com",
    "productName": "Widget",
    "quantity": 5,
    "unitPrice": 10.00
  }'

# Test without token (should get 401 Unauthorized)
curl -v http://localhost:8080/api/v1/orders
```

### Step 5.3: Test with Postman

1. Open Postman, create a new request
2. Go to **Authorization** tab
3. Type: **OAuth 2.0**
4. Configure:
   - Grant Type: **Authorization Code**
   - Auth URL: `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/authorize`
   - Access Token URL: `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token`
   - Client ID: `<orders-platform-client App ID>`
   - Client Secret: `<client secret>`
   - Scope: `api://<API_APP_ID>/Orders.Read api://<API_APP_ID>/Orders.Write`
   - Callback URL: `https://oauth.pstmn.io/v1/callback`
5. Click **Get New Access Token**
6. Login with your Entra ID credentials
7. Use the token to call the API

### Step 5.4: Decode and Inspect the JWT

```bash
# Decode the JWT payload (middle segment)
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | python3 -m json.tool
```

**Expected claims in the token:**

```json
{
  "aud": "api://<API_APP_ID>",
  "iss": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "roles": ["Order.Reader"],
  "scp": "Orders.Read Orders.Write",
  "sub": "<user-object-id>",
  "name": "User Name",
  "preferred_username": "user@domain.com"
}
```

---

## 8. Phase 6 - Production Hardening

### Step 8.1: Token Validation Checklist

Ensure your configuration validates:

- [x] **Issuer** (`iss`): Must be `https://login.microsoftonline.com/<tenant-id>/v2.0`
- [x] **Audience** (`aud`): Must be `api://<API_APP_ID>`
- [x] **Expiry** (`exp`): Token must not be expired
- [x] **Signature**: Validated against Microsoft's JWKS endpoint
- [x] **Roles/Scopes**: Appropriate for the endpoint being accessed

### Step 8.2: Enable HTTPS in Production **[CODE]**

```yaml
# application-prod.yml
server:
  ssl:
    enabled: true
    key-store: classpath:keystore.p12
    key-store-type: PKCS12
    key-store-password: ${SSL_KEYSTORE_PASSWORD}
```

### Step 8.3: Rate Limiting & Abuse Prevention **[CODE]**

Consider adding:
- Rate limiting (e.g., Bucket4j or Spring Cloud Gateway)
- Request size limits
- Audit logging for authentication events

### Step 8.4: Secret Rotation Policy **[PORTAL]**

1. Set up Key Vault to store client secrets
2. Configure secret rotation alerts (expiry notification at 30 days)
3. Use Managed Identity where possible to avoid secrets entirely

### Step 8.5: Conditional Access Policies **[PORTAL]**

> **Why manual?** Conditional Access policies are security-critical organizational policies that should be set by security administrators with full understanding of the impact.

1. Go to **Entra ID** > **Security** > **Conditional Access**
2. Create policies such as:
   - Require MFA for all users accessing the Orders API
   - Block access from non-compliant devices
   - Restrict access to specific IP ranges / named locations

---

## 9. Automation Summary Matrix

| Step | Description | Method | Reason |
|------|-------------|--------|--------|
| 1.1 | Register Backend API App | **TERRAFORM** | Repeatable, version-controlled |
| 1.2 | Set Application ID URI | **TERRAFORM** | Part of app registration |
| 1.3 | Register Client App | **TERRAFORM** | Repeatable, version-controlled |
| 1.4 | Create Client Secret | **PORTAL** | Security - secret shown once, store in Key Vault |
| 2.1 | Define API Scopes | **TERRAFORM** | Part of app registration config |
| 2.2 | Define App Roles | **TERRAFORM** | Part of app registration config |
| 2.3 | Grant API Permissions | **TERRAFORM** | Declarative resource access |
| 2.4 | Grant Admin Consent | **PORTAL** | Requires admin privilege, audit trail needed |
| 2.5 | Assign Users to Roles | **PORTAL** | Organizational decision, varies per environment |
| 3.1 | Add Maven Dependencies | **CODE** | Application code change |
| 3.2 | Configure application.yml | **CODE** | Application code change |
| 3.3 | SecurityConfig class | **CODE** | Application code change |
| 3.4 | LocalSecurityConfig class | **CODE** | Application code change |
| 3.5 | Controller annotations | **CODE** | Application code change |
| 3.6 | CORS configuration | **CODE** | Application code change |
| 3.7 | Environment variables | **CODE** | Application code change |
| 3.8 | Update run script | **CODE** | Application code change |
| 4.1-4.3 | Terraform files | **TERRAFORM** | Infrastructure as code |
| 8.4 | Secret Rotation Policy | **PORTAL** | Security policy, manual oversight |
| 8.5 | Conditional Access | **PORTAL** | Security policy, organizational scope |

### Summary Counts

| Method | Count | Notes |
|--------|-------|-------|
| **TERRAFORM** | 8 steps | App registrations, scopes, roles, permissions |
| **PORTAL** | 4 steps | Secrets, admin consent, user assignments, security policies |
| **CODE** | 8 steps | Spring Boot security layer implementation |

---

## 10. Troubleshooting

### Common Issues

**0. "My APIs" Shows No Results in Portal**

This was an actual issue we encountered during setup. When navigating to **orders-platform-client** > **API permissions** > **Add a permission** > **My APIs**, the list was empty even though `orders-platform-api` had scopes defined.

**Root Cause:** `az ad app create` only creates the App Registration object in Entra ID. It does **not** create a Service Principal (Enterprise Application). The Portal's "My APIs" tab only lists apps that have a Service Principal.

**Fix:**
```bash
# Create the missing service principal for the API app
az ad sp create --id <API_APP_ID>
```

After running this, refresh the Portal and the API app will appear under "My APIs".

**Prevention:** Always run `az ad sp create` immediately after `az ad app create`. In Terraform, always pair `azuread_application` with `azuread_service_principal`:
```hcl
resource "azuread_application" "api" {
  display_name = "orders-platform-api"
}

# Without this, the app won't appear in Portal's "My APIs"
resource "azuread_service_principal" "api" {
  client_id = azuread_application.api.client_id
}
```

---

**1. AADSTS65001 - "User or administrator has not consented" (Azure CLI)**

When running `az account get-access-token --scope api://<API_APP_ID>/.default`, you get:
```
AADSTS65001: The user or administrator has not consented to use the application
with ID '04b07795-8ddb-461a-bbee-02f9e1bf7b46' named 'Microsoft Azure CLI'.
```

**Root Cause:** The Azure CLI is a first-party Microsoft app. It needs consent to access your custom API's scopes. The error tells you to re-login with the scope so consent can be granted interactively.

**Fix:**
```bash
az logout
az login --tenant "<TENANT_ID>" --scope "api://<API_APP_ID>/.default"
```

This opens a browser consent prompt. After consenting, the CLI can request tokens for your API.

---

**2. AADSTS650057 - "Invalid resource / not listed in requested permissions"**

After the consent login, you still get:
```
AADSTS650057: Invalid resource. The client has requested access to a resource
which is not listed in the requested permissions in the client's application registration.
Client app ID: 04b07795-8ddb-461a-bbee-02f9e1bf7b46 (Microsoft Azure CLI).
List of valid resources from app registration: .
```

**Root Cause:** Even though the API has scopes defined, the Azure CLI (`04b07795-...`) is not listed as an authorized client for those scopes. Entra ID rejects the request because the CLI has no permission grant to access the API.

**Fix:** Pre-authorize the Azure CLI as a known client application on the API registration:
```bash
# Get the API app's object ID (not client ID)
API_OBJECT_ID=$(az ad app show --id <API_APP_ID> --query id -o tsv)

# Get your scope IDs
az ad app show --id <API_APP_ID> --query "api.oauth2PermissionScopes[].{value:value, id:id}" -o table

# Pre-authorize Azure CLI for all scopes
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/$API_OBJECT_ID" \
  --headers "Content-Type=application/json" \
  --body '{
    "api": {
      "preAuthorizedApplications": [
        {
          "appId": "04b07795-8ddb-461a-bbee-02f9e1bf7b46",
          "delegatedPermissionIds": ["<ORDERS_READ_SCOPE_ID>", "<ORDERS_WRITE_SCOPE_ID>"]
        }
      ]
    }
  }'
```

After this, re-login and get a token:
```bash
az login --tenant "<TENANT_ID>" --scope "api://<API_APP_ID>/.default"
TOKEN=$(az account get-access-token --scope api://<API_APP_ID>/.default --query accessToken -o tsv)
```

**For Terraform**, add pre-authorized clients in `entra-auth.tf`:
```hcl
resource "azuread_application_pre_authorized" "azure_cli" {
  application_id       = azuread_application.orders_api.id
  authorized_client_id = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"  # Azure CLI
  permission_ids       = [
    random_uuid.scope_orders_read.result,
    random_uuid.scope_orders_write.result
  ]
}
```

---

**3. Database/Kafka Connection Failure After Adding Entra Auth**

After adding Entra OIDC config, the app fails to connect to Azure PostgreSQL or Event Hubs with connection errors or SASL auth failures.

**Root Cause:** Setting `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` as environment variables causes `DefaultAzureCredential` to attempt **service principal authentication** instead of using your `az login` session. The Entra app registration (used for OIDC) has no access to PostgreSQL or Event Hubs, so connections fail.

**Fix:** Use **separate environment variables** for the Entra OIDC config vs the Azure infrastructure credential:

| Variable | Purpose | Used By |
|----------|---------|---------|
| `ENTRA_APP_CLIENT_ID` | Orders API app registration | OIDC / JWT validation |
| `ENTRA_APP_CLIENT_SECRET` | Orders API client secret | OIDC / JWT validation |
| `AZURE_CLIENT_ID` | Managed Identity / Service Principal | DefaultAzureCredential (DB, Kafka) |

In `.env.azure-debug`, do NOT set `AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` to the Entra app values:
```bash
# WRONG - breaks database auth
export AZURE_CLIENT_ID=<entra-app-id>

# CORRECT - separate vars for OIDC
export ENTRA_APP_CLIENT_ID=<entra-app-id>
export ENTRA_APP_CLIENT_SECRET=<entra-secret>
```

In `application-entra.yml`, reference the `ENTRA_APP_` vars:
```yaml
spring:
  cloud:
    azure:
      active-directory:
        credential:
          client-id: ${ENTRA_APP_CLIENT_ID}
          client-secret: ${ENTRA_APP_CLIENT_SECRET:}
```

---

**4. Blank Page / Empty 401 Response in Browser**

Accessing `http://localhost:8080/api/v1/orders` in a browser shows a blank page with no error message.

**Root Cause:** Spring Security's default OAuth2 resource server returns `401 Unauthorized` with an empty body and `WWW-Authenticate: Bearer` header. Browsers display this as a blank page.

**Fix:** Add custom `authenticationEntryPoint` and `accessDeniedHandler` in `SecurityConfig.java` to return JSON error responses. See Step 3.3 in the guide -- the updated `SecurityConfig` includes handlers that return:
```json
{
  "status": 401,
  "error": "Unauthorized",
  "message": "Missing or invalid Bearer token. Authenticate via Microsoft Entra ID.",
  "path": "/api/v1/orders",
  "timestamp": "2026-06-26T06:10:00Z"
}
```

---

**5. 401 Unauthorized - "Invalid token"**
- Verify the token audience matches `api://<API_APP_ID>`
- Check that the issuer URI includes `/v2.0` (v2.0 endpoint)
- Ensure the token has not expired

**6. 403 Forbidden - "Insufficient privileges"**
- Verify the user has been assigned the correct App Role
- Check that admin consent has been granted
- Decode the JWT and verify the `roles` claim contains the expected role

**7. AADSTS650051 - "Application needs a permission"**
- Admin consent has not been granted for the required scopes
- Go to Portal > App Registration > API Permissions > Grant admin consent

**8. AADSTS700016 - "Application not found in tenant"**
- The client ID or tenant ID is incorrect in your configuration
- Verify the values in `.env.azure-debug`

**9. Local development broken after adding security**
- Ensure `SPRING_PROFILES_ACTIVE=local` is set for local development
- Verify `LocalSecurityConfig` is active and permits all requests
- Check that `@Profile("!local")` is on the main `SecurityConfig`

**10. CORS errors from frontend**
- Add the frontend origin to the CORS configuration
- Ensure `Authorization` is in the allowed headers
- Verify `allowCredentials` is set to `true`

**11. IP Firewall - Database "Connect timed out"**
- Azure PostgreSQL firewall may not have your current IP
- ISPs rotate IPs frequently; a rule from yesterday may be stale
- Check: `curl -s -4 ifconfig.me` and compare with firewall rules
- Fix: `az postgres flexible-server firewall-rule create --resource-group <rg> --server-name <server> --name "MyIP" --start-ip-address <your-ip> --end-ip-address <your-ip>`

### Useful Debug Commands

```bash
# Check current Azure login
az account show

# List App Registrations
az ad app list --display-name "orders-platform" --query "[].{Name:displayName, AppId:appId}" -o table

# Check assigned roles for a user
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/<sp-object-id>/appRoleAssignedTo" \
  --query "value[].{User:principalDisplayName, Role:appRoleId}"

# Validate a JWT token manually
curl https://login.microsoftonline.com/<tenant-id>/discovery/v2.0/keys
```

---

## Next Steps

After reviewing this guide:

1. **Review and approve** the steps and role definitions
2. **Decide** which scopes/roles match your access control needs
3. **Implement Phase 3** (Spring Boot code changes) first for local testing
4. **Run Terraform** (Phase 4) to provision Entra ID resources
5. **Test end-to-end** (Phase 5) with real tokens
6. **Harden for production** (Phase 6)