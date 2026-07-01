# Application Working Flow — Spring Boot + PostgreSQL Deep Dive

> Based entirely on this orders-service application. No generic filler.

---

## Part 1: What Happens When the App Starts

When you run `java -jar app.jar` (or the container starts), here's the exact sequence:

```
JVM starts
  |
  v
SpringApplication.run(OrdersApplication.class)
  |
  v
Spring scans com.example.orders.* for @Component, @Entity, @Repository, @Controller
  |
  v
Reads application.yml — builds DataSource config
  |
  v
HikariCP creates connection pool to PostgreSQL
  (url, username, auth plugin from application.yml)
  |
  v
Flyway runs BEFORE Hibernate/JPA initializes
  |-- Connects to PostgreSQL using the same DataSource
  |-- Looks at flyway_schema_history table (creates it if missing)
  |-- Compares db/migration/V*.sql files against what's already applied
  |-- Runs any NEW migrations in version order
  |-- Records each migration in flyway_schema_history
  |
  v
Hibernate/JPA initializes
  |-- ddl-auto: none — Hibernate does NOT touch the schema
  |-- Scans @Entity classes, builds internal metadata
  |-- Maps OrderEntity fields to orders.orders table columns
  |
  v
Spring creates OrderRepository bean (auto-implemented by Spring Data JPA)
  |
  v
Spring creates OrderController bean (injects OrderRepository via constructor)
  |
  v
Embedded Tomcat starts on port 8080
  |
  v
Actuator health endpoints become available
  /actuator/health/liveness  → returns UP (app process is alive)
  /actuator/health/readiness → returns UP (app can serve traffic, DB connected)
  |
  v
App is ready to serve requests
```

---

## Part 2: The Database Connection — Exactly How It Works

### 2.1 The JDBC URL Breakdown

From `application.yml` line 7:
```
jdbc:postgresql://${POSTGRES_HOST:localhost}:5432/${POSTGRES_DB:ordersdb}
  ?sslmode=require
  &authenticationPluginClassName=com.azure.identity.extensions.jdbc.postgresql.AzurePostgresqlAuthenticationPlugin
```

Piece by piece:

| Part | What It Does |
|---|---|
| `jdbc:postgresql://` | Use PostgreSQL JDBC driver |
| `${POSTGRES_HOST:localhost}` | Read env var `POSTGRES_HOST`, fallback to `localhost` for local dev |
| `:5432` | Standard PostgreSQL port |
| `/${POSTGRES_DB:ordersdb}` | Connect to database `ordersdb` |
| `sslmode=require` | Encrypt the connection (mandatory for Azure PG) |
| `authenticationPluginClassName=...` | Instead of sending a password, use Azure's auth plugin to get an AAD token |

### 2.2 Authentication Flow (Passwordless)

```
App needs a DB connection
  |
  v
HikariCP calls the PostgreSQL JDBC driver
  |
  v
JDBC driver sees authenticationPluginClassName in URL
  |
  v
AzurePostgresqlAuthenticationPlugin activates
  |
  v
Plugin reads AZURE_CLIENT_ID env var → knows which Managed Identity to use
  |
  v
Plugin calls Azure Instance Metadata Service (IMDS) at 169.254.169.254
  |-- This endpoint is only available INSIDE Azure (Container Apps, VMs, etc.)
  |-- Requests an OAuth2 token for the "https://ossrdbms-aad.database.windows.net" resource
  |
  v
Azure returns a short-lived JWT token (~1 hour)
  |
  v
Plugin sends this token AS the password to PostgreSQL
  |
  v
PostgreSQL server validates the token against Entra ID
  |-- Checks: is this token from my tenant?
  |-- Checks: does a role named "orders-service-identity" exist?
  |-- Checks: is that role linked to this AAD principal?
  |
  v
Connection established. No password stored anywhere.
```

**Token refresh:** HikariCP's `max-lifetime: 1800000` (30 min) means connections are recycled before the 1-hour token expires. When a new connection is created, the plugin fetches a fresh token automatically.

### 2.3 HikariCP Connection Pool

From `application.yml` lines 14-19:

```yaml
hikari:
  maximum-pool-size: 5      # max 5 simultaneous DB connections
  minimum-idle: 2            # keep at least 2 connections warm
  idle-timeout: 30000        # close idle connections after 30 seconds
  connection-timeout: 30000  # fail if can't get a connection in 30 seconds
  max-lifetime: 1800000      # recycle connections every 30 minutes
```

Why this matters:
- PostgreSQL has a per-server connection limit (typically 100 for B_Standard_B2ms)
- Each Container App replica uses up to 5 connections
- With `max_replicas: 3`, max total = 15 connections
- `minimum-idle: 2` means the app pre-opens 2 connections at startup — this is when you see `HikariPool-1 - Start completed` in logs

---

## Part 3: Flyway Migrations — The Core Concept

### 3.1 What Flyway Does

Flyway manages your database schema via versioned SQL files. It is the ONLY thing that changes the database structure. Hibernate does NOT touch the schema (`ddl-auto: none`).

### 3.2 The Migration Files in This App

```
application/src/main/resources/db/migration/
  V1__create_orders_schema.sql    ← creates schema + table
  V2__seed_orders_data.sql        ← inserts 5 sample rows
```

**Naming convention is strict:**

```
V1__create_orders_schema.sql
│ │  │
│ │  └── description (underscores for spaces)
│ └───── double underscore separator (REQUIRED)
└─────── V + version number
```

- `V` = versioned migration (runs once, never again)
- Number must be unique and increasing
- Double underscore `__` separates version from description
- `.sql` extension

### 3.3 How Flyway Decides What to Run

On every app startup:

```
Flyway connects to PostgreSQL
  |
  v
Checks: does table "orders"."flyway_schema_history" exist?
  |
  +--> NO:  Creates it. All migrations are "new".
  |
  +--> YES: Reads it. Gets list of already-applied versions.
  |
  v
Scans classpath:db/migration for V*.sql files
  |
  v
Compares:
  Files on disk: V1, V2
  Already applied: V1, V2  →  nothing to run
  Already applied: V1      →  runs V2
  Already applied: (none)  →  runs V1, then V2
  |
  v
For each new migration:
  1. Executes the SQL
  2. Records in flyway_schema_history: version, description, checksum, timestamp
  3. If SQL fails → migration stops, app fails to start
```

### 3.4 The flyway_schema_history Table

This is what it looks like inside PostgreSQL:

```sql
SELECT version, description, success FROM orders.flyway_schema_history;
```

```
version | description           | success
--------+-----------------------+--------
1       | create orders schema  | t
2       | seed orders data      | t
```

**Critical rule:** Once a migration is applied, you MUST NOT edit that file. Flyway checksums each file. If you change a previously-applied migration, the app will crash on startup with:

```
FlywayValidateException: Migration checksum mismatch for migration version 1
```

### 3.5 Flyway Configuration in This App

From `application.yml` lines 32-36:

```yaml
flyway:
  enabled: true                        # Flyway runs on startup
  locations: classpath:db/migration    # where to find SQL files
  schemas: orders                      # Flyway manages the "orders" schema
  default-schema: orders               # flyway_schema_history lives in "orders" schema
```

The `schemas: orders` setting means Flyway will CREATE the `orders` schema if it doesn't exist (before running any migration). This is why the MI needs `CREATE ON DATABASE` privilege.

---

## Part 4: JPA/Hibernate — How the Code Maps to the Database

### 4.1 The Entity

`OrderEntity.java` maps a Java class to a database table:

```java
@Entity                                    // This is a JPA entity
@Table(name = "orders", schema = "orders") // Maps to table "orders" in schema "orders"
public class OrderEntity {

    @Id
    private UUID id;                       // PRIMARY KEY column "id"

    private String customerName;           // column "customer_name" (auto snake_case)
    private String customerEmail;          // column "customer_email"
    private String productName;            // column "product_name"
    private Integer quantity;              // column "quantity"
    private BigDecimal unitPrice;          // column "unit_price"
    private BigDecimal totalPrice;         // column "total_price"
    private Instant createdAt;             // column "created_at"
}
```

**Java → SQL column name mapping:**
Spring Boot auto-converts camelCase to snake_case. `customerName` → `customer_name`. This is the default `SpringPhysicalNamingStrategy`.

**Java → SQL type mapping:**

| Java Type | PostgreSQL Type |
|---|---|
| `UUID` | `UUID` |
| `String` | `VARCHAR(255)` |
| `Integer` | `INTEGER` |
| `BigDecimal` | `NUMERIC(12,2)` |
| `Instant` | `TIMESTAMP` |

### 4.2 The Repository

`OrderRepository.java`:

```java
public interface OrderRepository extends JpaRepository<OrderEntity, UUID> {
}
```

This single interface gives you all of these methods for free (no implementation needed):

| Method | Generated SQL |
|---|---|
| `findAll()` | `SELECT * FROM orders.orders` |
| `findById(UUID id)` | `SELECT * FROM orders.orders WHERE id = ?` |
| `save(entity)` | `INSERT INTO orders.orders (...) VALUES (...)` (new) or `UPDATE orders.orders SET ... WHERE id = ?` (existing) |
| `deleteById(UUID id)` | `DELETE FROM orders.orders WHERE id = ?` |
| `count()` | `SELECT count(*) FROM orders.orders` |
| `existsById(UUID id)` | `SELECT count(*) > 0 FROM orders.orders WHERE id = ?` |

Spring Data JPA generates the implementation class at runtime. You never write SQL for basic CRUD.

### 4.3 How `save()` Knows INSERT vs UPDATE

When you call `orderRepository.save(entity)`:
1. Spring checks if the `@Id` field is `null` → `INSERT` (new entity)
2. If `@Id` is non-null → checks if it exists in DB → `INSERT` if not found, `UPDATE` if found

In this app, the controller sets `order.setId(UUID.randomUUID())` before saving, so `save()` always does `INSERT` for new orders.

### 4.4 Why `ddl-auto: none`

```yaml
jpa:
  hibernate:
    ddl-auto: none
```

Options are: `none`, `validate`, `update`, `create`, `create-drop`.

This app uses `none` because Flyway manages the schema. If you set `update`, Hibernate would try to ALTER tables on startup — conflicting with Flyway and potentially destructive. **Always use `none` with Flyway.**

---

## Part 5: The Controller — HTTP Request to Database and Back

### 5.1 Request Flow

```
Client sends: GET /api/v1/orders
  |
  v
Tomcat receives HTTP request on port 8080
  |
  v
Spring DispatcherServlet routes to OrderController.listOrders()
  (matched by api.base-path prefix "/api/v1" + @RequestMapping("/orders") + @GetMapping)
  |
  v
Controller calls orderRepository.findAll()
  |
  v
Spring Data JPA generates: SELECT * FROM orders.orders
  |
  v
HikariCP provides a connection from the pool
  |
  v
PostgreSQL executes query, returns rows
  |
  v
Hibernate maps each row → OrderEntity object
  (customer_name column → customerName field, etc.)
  |
  v
Controller returns List<OrderEntity>
  |
  v
Spring's Jackson serializer converts to JSON
  (customerName field → "customerName" in JSON)
  |
  v
HTTP 200 response with JSON body
```

### 5.2 The Three Endpoints

**GET /api/v1/orders** — List all

```
Request:  GET /api/v1/orders
Response: 200 OK
Body:     [{"id":"a1b2...","customerName":"Priya Sharma",...}, ...]
```

No business logic. Straight `findAll()`.

**GET /api/v1/orders/{id}** — Get one

```
Request:  GET /api/v1/orders/a1b2c3d4-e5f6-7890-abcd-ef1234567890
Response: 200 OK + order JSON   (if found)
          404 Not Found         (if not found)
```

Uses `Optional` pattern: `findById()` returns `Optional<OrderEntity>`. The `.map(ResponseEntity::ok).orElse(ResponseEntity.notFound().build())` handles both cases in one line.

**POST /api/v1/orders** — Create new

```
Request:  POST /api/v1/orders
Body:     {"customerName":"Test","customerEmail":"t@t.com","productName":"Laptop","quantity":2,"unitPrice":50000}
Response: 201 Created
Body:     {"id":"<generated-uuid>","customerName":"Test",...,"totalPrice":100000,...}
```

The controller:
1. Generates a UUID
2. Sets `createdAt` to now
3. Calculates `totalPrice = unitPrice * quantity`
4. Saves to DB
5. Returns 201 with the saved entity

---

## Part 6: The `@Data` Annotation (Lombok)

`OrderEntity` uses `@Data` from Lombok. At compile time, Lombok generates:

- `getId()`, `setId()` for every field
- `equals()` and `hashCode()` based on all fields
- `toString()`
- A required-args constructor

This is why the controller can call `order.setId(...)`, `order.getQuantity()`, etc. without you writing those methods. The generated code exists in the compiled `.class` file, not in source.

---

## Part 7: Actuator Health Probes

From `application.yml` lines 44-51:

```yaml
management:
  endpoint:
    health:
      probes:
        enabled: true       # exposes /actuator/health/liveness and /readiness
  endpoints:
    web:
      exposure:
        include: health,info  # only expose health and info (not all actuator endpoints)
```

**How the probes work with Container Apps:**

```
Container starts
  |
  v
ACA waits 30 seconds (liveness initial_delay)
  |
  v
ACA calls GET /actuator/health/liveness every 30 seconds
  |-- Returns 200 → container is alive
  |-- Returns non-200 three times → ACA kills and restarts the container
  |
  v
ACA waits 20 seconds (readiness initial_delay)
  |
  v
ACA calls GET /actuator/health/readiness every 10 seconds
  |-- Returns 200 → ACA routes traffic to this replica
  |-- Returns non-200 → ACA stops routing traffic (but doesn't kill)
```

**Readiness includes DB health.** If HikariCP can't connect to PostgreSQL, the readiness probe returns DOWN and ACA stops sending traffic. This is why DB connection issues cause the app to appear "down" even though the process is running.

---

## Part 8: How to Add New Features to This App

This is the exact workflow for extending the application. Follow this order every time.

### Step-by-Step: Adding a New Feature

**Example: Adding a "products" resource with its own table.**

---

### Step 1: Create the Migration SQL

Create a new file with the NEXT version number:

```
application/src/main/resources/db/migration/V3__create_products_table.sql
```

```sql
CREATE TABLE IF NOT EXISTS orders.products (
    id          UUID PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    description TEXT,
    price       NUMERIC(12,2) NOT NULL,
    stock       INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMP
);
```

Rules:
- Version number must be higher than any existing migration (V3, V4, ...)
- Never edit V1 or V2 — they're already applied
- Use the `orders` schema (table name = `orders.products`)
- Always use `IF NOT EXISTS` for safety

### Step 2: Create the Entity

Create `application/src/main/java/com/example/orders/entity/ProductEntity.java`:

```java
package com.example.orders.entity;

import jakarta.persistence.*;
import lombok.Data;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@Data
@Entity
@Table(name = "products", schema = "orders")
public class ProductEntity {

    @Id
    private UUID id;

    @Column(nullable = false)
    private String name;

    private String description;

    @Column(nullable = false)
    private BigDecimal price;

    @Column(nullable = false)
    private Integer stock;

    @Column(nullable = false)
    private Instant createdAt;

    private Instant updatedAt;
}
```

Checklist:
- `@Table(schema = "orders")` — must match the schema in your migration
- Field names in camelCase → columns will be snake_case
- Java types must match SQL types (see mapping table in Part 4)

### Step 3: Create the Repository

Create `application/src/main/java/com/example/orders/repository/ProductRepository.java`:

```java
package com.example.orders.repository;

import com.example.orders.entity.ProductEntity;
import org.springframework.data.jpa.repository.JpaRepository;
import java.util.UUID;

public interface ProductRepository extends JpaRepository<ProductEntity, UUID> {

    // Custom query methods — Spring Data generates SQL from the method name:
    // List<ProductEntity> findByName(String name);
    // List<ProductEntity> findByPriceGreaterThan(BigDecimal price);
    // List<ProductEntity> findByStockLessThan(Integer stock);
    // Optional<ProductEntity> findByNameIgnoreCase(String name);
}
```

**Method name → SQL generation rules:**

| Method Name | Generated SQL WHERE clause |
|---|---|
| `findByName(String)` | `WHERE name = ?` |
| `findByPriceLessThan(BigDecimal)` | `WHERE price < ?` |
| `findByNameContaining(String)` | `WHERE name LIKE '%?%'` |
| `findByStockGreaterThanOrderByNameAsc(int)` | `WHERE stock > ? ORDER BY name ASC` |
| `findByCustomerNameAndProductName(String, String)` | `WHERE customer_name = ? AND product_name = ?` |

You never write SQL. Just name the method correctly.

### Step 4: Create the Controller

Create `application/src/main/java/com/example/orders/controller/ProductController.java`:

```java
package com.example.orders.controller;

import com.example.orders.entity.ProductEntity;
import com.example.orders.repository.ProductRepository;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/products")
public class ProductController {

    private final ProductRepository productRepository;

    public ProductController(ProductRepository productRepository) {
        this.productRepository = productRepository;
    }

    @GetMapping
    public List<ProductEntity> listProducts() {
        return productRepository.findAll();
    }

    @GetMapping("/{id}")
    public ResponseEntity<ProductEntity> getProduct(@PathVariable UUID id) {
        return productRepository.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @PostMapping
    public ResponseEntity<ProductEntity> createProduct(@RequestBody ProductEntity product) {
        product.setId(UUID.randomUUID());
        product.setCreatedAt(Instant.now());
        ProductEntity saved = productRepository.save(product);
        return ResponseEntity.status(201).body(saved);
    }
}
```

### Step 5: Build and Deploy

```bash
cd application
mvn clean package -DskipTests
# Flyway runs on startup, creates the new table automatically
```

That's it. On next deploy, Flyway sees V3 is new, runs it, creates the `products` table. The app starts serving `/api/v1/products` endpoints (the `/api/v1` prefix is applied automatically via `api.base-path` in `application.yml`).

---

### Common Modifications (With Examples From This App)

#### Adding a Column to an Existing Table

**Migration (V3__add_status_to_orders.sql):**
```sql
ALTER TABLE orders.orders ADD COLUMN status VARCHAR(50) DEFAULT 'PENDING';
```

**Update Entity — add the field to OrderEntity.java:**
```java
private String status;
```

That's it. No other changes needed. `findAll()` and `findById()` will automatically include the new column.

#### Adding a Relationship Between Tables

**Migration (V4__add_order_items.sql):**
```sql
CREATE TABLE IF NOT EXISTS orders.order_items (
    id         UUID PRIMARY KEY,
    order_id   UUID NOT NULL REFERENCES orders.orders(id),
    product_id UUID NOT NULL,
    quantity   INTEGER NOT NULL,
    price      NUMERIC(12,2) NOT NULL
);
```

**New Entity:**
```java
@Entity
@Table(name = "order_items", schema = "orders")
public class OrderItemEntity {
    @Id
    private UUID id;

    @ManyToOne
    @JoinColumn(name = "order_id", nullable = false)
    private OrderEntity order;

    private UUID productId;
    private Integer quantity;
    private BigDecimal price;
}
```

**Add to existing OrderEntity:**
```java
@OneToMany(mappedBy = "order", cascade = CascadeType.ALL, fetch = FetchType.LAZY)
private List<OrderItemEntity> items;
```

#### Adding a Custom SQL Query

When method-name-based queries aren't enough, use `@Query`:

```java
public interface OrderRepository extends JpaRepository<OrderEntity, UUID> {

    // JPQL (Java Persistence Query Language — uses entity/field names, not table/column names)
    @Query("SELECT o FROM OrderEntity o WHERE o.totalPrice > :minPrice ORDER BY o.createdAt DESC")
    List<OrderEntity> findExpensiveOrders(@Param("minPrice") BigDecimal minPrice);

    // Native SQL (uses actual table/column names)
    @Query(value = "SELECT * FROM orders.orders WHERE created_at > NOW() - INTERVAL '7 days'",
           nativeQuery = true)
    List<OrderEntity> findRecentOrders();
}
```

#### Adding Input Validation

Add `spring-boot-starter-validation` to pom.xml, then annotate the entity:

```java
@Column(nullable = false)
@NotBlank(message = "Customer name is required")
private String customerName;

@Email(message = "Invalid email format")
private String customerEmail;

@Min(value = 1, message = "Quantity must be at least 1")
private Integer quantity;
```

Controller: change `@RequestBody` to `@Valid @RequestBody`:

```java
@PostMapping
public ResponseEntity<ProductEntity> createProduct(@Valid @RequestBody ProductEntity product) {
```

---

## Part 9: Project File Structure — What Goes Where

```
application/
├── pom.xml                                          ← dependencies + build config
├── Dockerfile                                       ← how to containerize
└── src/main/
    ├── java/com/example/orders/
    │   ├── OrdersApplication.java                   ← entry point (don't touch)
    │   ├── controller/
    │   │   └── OrderController.java                 ← HTTP endpoints
    │   ├── entity/
    │   │   └── OrderEntity.java                     ← Java ↔ DB table mapping
    │   └── repository/
    │       └── OrderRepository.java                 ← DB access interface
    └── resources/
        ├── application.yml                          ← all configuration
        └── db/migration/
            ├── V1__create_orders_schema.sql          ← schema migration
            └── V2__seed_orders_data.sql              ← data migration
```

**When adding a new feature, you touch:**

| What | File(s) |
|---|---|
| New table | `db/migration/V{next}__description.sql` |
| Alter existing table | `db/migration/V{next}__description.sql` |
| New entity | `entity/NewEntity.java` |
| New CRUD endpoints | `repository/NewRepository.java` + `controller/NewController.java` |
| New field on existing entity | Edit existing entity + new migration for the column |
| Business logic | Create `service/NewService.java` (injected into controller) |
| Config changes | `application.yml` |
| New dependency | `pom.xml` |

---

## Part 10: Common Patterns You'll Need Next

### Service Layer (when controller logic gets complex)

The current app puts logic directly in the controller. For real apps, add a service layer:

```
Controller → Service → Repository
(HTTP)       (logic)    (DB)
```

```java
@Service
public class OrderService {
    private final OrderRepository orderRepository;

    public OrderService(OrderRepository orderRepository) {
        this.orderRepository = orderRepository;
    }

    public OrderEntity createOrder(OrderEntity order) {
        order.setId(UUID.randomUUID());
        order.setCreatedAt(Instant.now());
        order.setStatus("PENDING");
        if (order.getQuantity() != null && order.getUnitPrice() != null) {
            order.setTotalPrice(order.getUnitPrice().multiply(BigDecimal.valueOf(order.getQuantity())));
        }
        return orderRepository.save(order);
    }
}
```

Controller becomes thin:
```java
@PostMapping
public ResponseEntity<OrderEntity> createOrder(@RequestBody OrderEntity order) {
    return ResponseEntity.status(201).body(orderService.createOrder(order));
}
```

### Exception Handling

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(EntityNotFoundException.class)
    public ResponseEntity<Map<String, String>> handleNotFound(EntityNotFoundException ex) {
        return ResponseEntity.status(404).body(Map.of("error", ex.getMessage()));
    }
}
```

### Pagination

```java
// Controller
@GetMapping
public Page<OrderEntity> listOrders(
        @RequestParam(defaultValue = "0") int page,
        @RequestParam(defaultValue = "20") int size) {
    return orderRepository.findAll(PageRequest.of(page, size, Sort.by("createdAt").descending()));
}
```

Returns: `{"content":[...], "totalElements":5, "totalPages":1, "number":0}`

---

## Part 11: The Build → Deploy → Run Cycle

```
You write code
  |
  v
mvn clean package                     ← compiles Java, runs Flyway tests, creates JAR
  |                                      target/orders-service-1.0.0.jar
  v
docker build -t orders-service .      ← copies JAR into container image
  |
  v
docker push to ACR                    ← stores image in Azure Container Registry
  |
  v
az containerapp update --image ...    ← tells Container App to use new image
  |
  v
ACA pulls image from ACR (using MI + AcrPull role)
  |
  v
Container starts → Spring Boot → Flyway → Hibernate → Tomcat → ready
  |
  v
ACA health probes pass → traffic routes to new revision
```

**GitHub Actions automates steps 2-5.** You just push code to `main`.

---

## Quick Reference: "I Want to..."

| I want to... | Do this |
|---|---|
| Add a new table | Create `V{n}__name.sql` + Entity + Repository + Controller |
| Add a column | Create `V{n}__name.sql` with ALTER TABLE + add field to Entity |
| Add an API endpoint | Add method to existing Controller |
| Add business logic | Create a Service class, inject into Controller |
| Add a query that method names can't express | Use `@Query` in Repository |
| Add pagination | Use `PageRequest.of()` with `findAll(Pageable)` |
| Add input validation | Add `spring-boot-starter-validation` + `@Valid` + field annotations |
| Change DB connection settings | Edit `application.yml` under `spring.datasource` |
| See what SQL Hibernate generates | Set `show-sql: true` in `application.yml` |
| Run Flyway migrations locally | Just start the app — Flyway runs on startup |
| Check which migrations have been applied | `SELECT * FROM orders.flyway_schema_history;` in psql |