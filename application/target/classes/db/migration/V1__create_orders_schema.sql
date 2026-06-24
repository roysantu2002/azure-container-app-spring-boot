CREATE SCHEMA IF NOT EXISTS orders;

CREATE TABLE IF NOT EXISTS orders.orders
(
    id             UUID PRIMARY KEY,
    customer_name  VARCHAR(255),
    customer_email VARCHAR(255),
    product_name   VARCHAR(255),
    quantity       INTEGER,
    unit_price     NUMERIC(12,2),
    total_price    NUMERIC(12,2),
    created_at     TIMESTAMP
);