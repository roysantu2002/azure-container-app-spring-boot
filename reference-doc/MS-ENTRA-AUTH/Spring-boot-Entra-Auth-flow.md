# Spring Boot + Entra ID Authentication Flow

## How Spring Boot Manages the Auth Flow — From Startup to Request Handling

---

## 1. Startup Phase (when you run `mvn spring-boot:run`)

```
mvn spring-boot:run
    │
    ▼
Spring Boot reads application.yml + application-entra.yml
    │
    ▼
Finds spring-boot-starter-security on classpath
    → Auto-configures Spring Security filter chain
    │
    ▼
Finds spring-boot-starter-oauth2-resource-server on classpath
    → Auto-configures JWT decoder
    │
    ▼
Reads issuer-uri: https://login.microsoftonline.com/<tenant>/v2.0
    │
    ▼
Fetches Microsoft's OIDC discovery document (one-time, at startup):
    GET https://login.microsoftonline.com/<tenant>/v2.0/.well-known/openid-configuration
    │
    Response contains:
    ├── jwks_uri: https://login.microsoftonline.com/<tenant>/discovery/v2.0/keys
    ├── issuer: https://login.microsoftonline.com/<tenant>/v2.0
    └── supported algorithms: RS256
    │
    ▼
Fetches JWKS (JSON Web Key Set) — Microsoft's public signing keys
    These are RSA public keys used to verify JWT signatures
    (cached in memory, refreshed periodically)
    │
    ▼
Loads SecurityConfig.java
    → Registers the filter chain with URL rules and role mappings
    → Registers custom 401/403 JSON error handlers
    │
    ▼
App is ready. Every incoming HTTP request now passes through
the security filter chain BEFORE reaching any controller.
```

### What Happens Under the Hood at Startup

| Step | What Spring Boot Does | Why |
|------|----------------------|-----|
| Classpath scan | Detects `spring-boot-starter-security` JAR | Triggers security auto-configuration |
| Auto-config | Creates `SecurityFilterChain` from `SecurityConfig.java` | Registers URL rules and JWT validation |
| OIDC discovery | Fetches `.well-known/openid-configuration` from Microsoft | Learns where to get signing keys, what issuer to expect |
| JWKS fetch | Downloads Microsoft's public RSA keys | These keys verify JWT signatures — proves tokens are genuine |
| Filter registration | Inserts security filters into Tomcat's filter chain | Every HTTP request passes through these filters first |

---

## 2. Request Flow (every API call)

```
curl -H "Authorization: Bearer eyJhbG..." http://localhost:8080/api/v1/orders
    │
    ▼
┌── Tomcat receives HTTP request ────────────────────────────────┐
│                                                                 │
│  Servlet Filter Chain (runs in order, before any controller):   │
│                                                                 │
│  ┌─ Filter 1: SecurityContextPersistenceFilter ──────────┐     │
│  │  Creates empty SecurityContext (stateless = no session) │     │
│  └───────────────────────────────────────────────────────┘     │
│                         │                                       │
│                         ▼                                       │
│  ┌─ Filter 2: BearerTokenAuthenticationFilter ───────────┐     │
│  │                                                        │     │
│  │  1. Extracts "Bearer eyJhbG..." from Authorization     │     │
│  │     header                                             │     │
│  │     • No header? → Skip, leave as anonymous            │     │
│  │                                                        │     │
│  │  2. Passes token to JwtDecoder                         │     │
│  │     JwtDecoder does:                                   │     │
│  │                                                        │     │
│  │     a. Base64-decode the 3 JWT segments:               │     │
│  │        HEADER.PAYLOAD.SIGNATURE                        │     │
│  │        ┌─────────────────────────────────────┐         │     │
│  │        │ Header:  {"alg":"RS256","kid":"..."}│         │     │
│  │        │ Payload: {"aud":"api://...",        │         │     │
│  │        │           "iss":"https://login...", │         │     │
│  │        │           "roles":["Order.Reader"], │         │     │
│  │        │           "exp":1719388800}         │         │     │
│  │        │ Signature: <binary RSA signature>   │         │     │
│  │        └─────────────────────────────────────┘         │     │
│  │                                                        │     │
│  │     b. Look up the signing key by "kid" from           │     │
│  │        the cached JWKS (Microsoft's public keys)       │     │
│  │                                                        │     │
│  │     c. Verify RSA signature using that public key      │     │
│  │        → Proves token was issued by Microsoft,         │     │
│  │          not forged                                    │     │
│  │                                                        │     │
│  │     d. Validate claims:                                │     │
│  │        • iss matches issuer-uri in yml? ✓              │     │
│  │        • aud matches api://<app-id>?    ✓              │     │
│  │        • exp > current time?            ✓              │     │
│  │        Any fail → 401 Unauthorized                     │     │
│  │                                                        │     │
│  │  3. Passes decoded JWT to JwtAuthenticationConverter   │     │
│  │     (our custom bean in SecurityConfig):               │     │
│  │                                                        │     │
│  │     Reads "roles" claim: ["Order.Reader"]              │     │
│  │     Adds prefix: → APPROLE_Order.Reader                │     │
│  │     Creates: JwtAuthenticationToken with               │     │
│  │       principal = JWT                                  │     │
│  │       authorities = [APPROLE_Order.Reader]             │     │
│  │                                                        │     │
│  │  4. Stores in SecurityContext                          │     │
│  └────────────────────────────────────────────────────────┘     │
│                         │                                       │
│                         ▼                                       │
│  ┌─ Filter 3: AuthorizationFilter ──────────────────────┐      │
│  │                                                       │      │
│  │  Matches request against rules from SecurityConfig:   │      │
│  │                                                       │      │
│  │  GET /api/v1/orders/**                                │      │
│  │    → requires APPROLE_Order.Reader or .Admin          │      │
│  │                                                       │      │
│  │  User has: [APPROLE_Order.Reader]                     │      │
│  │  Match? YES → proceed                                 │      │
│  │                                                       │      │
│  │  If NO match → 403 Forbidden JSON response            │      │
│  └───────────────────────────────────────────────────────┘      │
│                         │                                       │
│                         ▼                                       │
│  ┌─ DispatcherServlet ──────────────────────────────────┐      │
│  │  Routes to OrderController.getAllOrders()              │      │
│  │  Controller runs normally — no security code needed    │      │
│  │  Returns List<OrderEntity> as JSON                    │      │
│  └───────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. The Three Possible Outcomes

### 3a. No Token → 401 Unauthorized

```
curl http://localhost:8080/api/v1/orders

    Filter 2: No Authorization header found
    → AnonymousAuthenticationFilter sets anonymous context
    → Filter 3: Anonymous user does not have APPROLE_Order.Reader
    → Custom authenticationEntryPoint returns:

    HTTP 401
    {
      "status": 401,
      "error": "Unauthorized",
      "message": "Missing or invalid Bearer token. Authenticate via Microsoft Entra ID.",
      "path": "/api/v1/orders"
    }
```

### 3b. Valid Token, Wrong Role → 403 Forbidden

```
curl -H "Authorization: Bearer <token-with-Order.Reader-role>" \
     -X POST http://localhost:8080/api/v1/orders

    Filter 2: Token valid ✓
    → Authorities: [APPROLE_Order.Reader]
    Filter 3: POST /api/v1/orders requires APPROLE_Order.Writer or .Admin
    → User has Order.Reader, NOT Writer or Admin
    → Custom accessDeniedHandler returns:

    HTTP 403
    {
      "status": 403,
      "error": "Forbidden",
      "message": "You do not have the required role to access this resource.",
      "path": "/api/v1/orders"
    }
```

### 3c. Valid Token, Correct Role → 200 OK

```
curl -H "Authorization: Bearer <token-with-Order.Reader-role>" \
     http://localhost:8080/api/v1/orders

    Filter 2: Token valid ✓
    → Authorities: [APPROLE_Order.Reader]
    Filter 3: GET /api/v1/orders requires Order.Reader or Admin
    → User has Order.Reader ✓
    → DispatcherServlet → OrderController.getAllOrders()

    HTTP 200
    [
      {"id": "...", "customerName": "...", "productName": "...", ...}
    ]
```

---

## 4. Where Each Piece Lives in Our Codebase

| File | Role in the Auth Flow |
|------|-----------------------|
| `pom.xml` | Brings in `spring-boot-starter-security` + `oauth2-resource-server` (triggers auto-config) |
| `application-entra.yml` | Configures `issuer-uri` and `audiences` (tells Spring where to validate tokens) |
| `SecurityConfig.java` | Defines URL → role mapping rules, custom error handlers, JWT role extraction |
| `LocalSecurityConfig.java` | Disables all security for `local` profile (dev without Entra) |
| `OpenApiConfig.java` | Configures Swagger UI with OAuth2 "Authorize" button |
| `OrderController.java` | **No security code** — just business logic. Security is handled before it's called |

---

## 5. Key Concepts

### Your App Never Sees Passwords

The entire auth process is:

1. **Microsoft Entra ID** authenticates the user and issues a signed JWT
2. **Spring Security** validates the JWT signature using Microsoft's public keys (fetched once at startup)
3. **Your controller** just receives already-authenticated, already-authorized requests

### Nothing Is Stored Server-Side

The token contains everything (roles, user info, expiry). That's why `SessionCreationPolicy.STATELESS` is set — no HTTP sessions, no cookies, no server-side state. Each request is independently validated by its token.

### Asymmetric Cryptography (RSA) — No Shared Secrets

Microsoft signs tokens with a **private key** (only they have it). Your app downloads the matching **public key** from the JWKS endpoint. If the signature matches, the token is genuine. This is why no shared secret is needed between your app and Microsoft.

```
Microsoft Entra ID                     Your Spring Boot App
┌──────────────────┐                  ┌──────────────────────┐
│                  │                  │                      │
│  Private Key 🔒  │── signs JWT ──→ │  Public Key 🔓       │
│  (secret, never  │                  │  (downloaded from    │
│   leaves Azure)  │                  │   JWKS endpoint)     │
│                  │                  │                      │
│                  │                  │  Verifies signature  │
│                  │                  │  = token is genuine  │
└──────────────────┘                  └──────────────────────┘
```

### Token Expiry and Refresh

- Access tokens are short-lived (typically 60-90 minutes)
- After expiry, the client must get a new token from Entra ID
- Your app does NOT refresh tokens — it only validates them
- The JWKS keys are cached and auto-refreshed by Spring Security

---

## 6. Adding a New Controller — What You Need to Do

When you add a new controller (e.g., `CustomerController`), you only need to update `SecurityConfig.java`:

```java
// In SecurityConfig.java, add rules for the new endpoints:
.authorizeHttpRequests(auth -> auth
    .requestMatchers("/actuator/**").permitAll()
    .requestMatchers("/swagger-ui/**", ...).permitAll()

    // Existing order rules
    .requestMatchers(HttpMethod.GET, "/api/v1/orders/**")
        .hasAnyAuthority("APPROLE_Order.Reader", "APPROLE_Order.Admin")
    .requestMatchers(HttpMethod.POST, "/api/v1/orders/**")
        .hasAnyAuthority("APPROLE_Order.Writer", "APPROLE_Order.Admin")

    // NEW: Customer endpoint rules
    .requestMatchers(HttpMethod.GET, "/api/v1/customers/**")
        .hasAnyAuthority("APPROLE_Customer.Reader", "APPROLE_Customer.Admin")
    .requestMatchers(HttpMethod.POST, "/api/v1/customers/**")
        .hasAnyAuthority("APPROLE_Customer.Writer", "APPROLE_Customer.Admin")

    .anyRequest().authenticated()
)
```

The new `CustomerController` itself needs **zero** security code. The filter chain handles everything centrally.

> **Remember:** If you add new roles (e.g., `Customer.Reader`), you also need to define them as App Roles in the Entra ID App Registration (Portal or Terraform) and assign them to users.