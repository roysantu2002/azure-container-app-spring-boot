INSERT INTO orders.orders (id, customer_name, customer_email, product_name, quantity, unit_price, total_price, created_at)
VALUES
    ('a1b2c3d4-e5f6-7890-abcd-ef1234567890', 'Priya Sharma', 'priya@example.com', 'Wireless Keyboard', 2, 1499.99, 2999.98, NOW()),
    ('b2c3d4e5-f6a7-8901-bcde-f12345678901', 'Rahul Verma', 'rahul@example.com', 'USB-C Hub', 1, 2999.00, 2999.00, NOW()),
    ('c3d4e5f6-a7b8-9012-cdef-123456789012', 'Anita Desai', 'anita@example.com', 'Mechanical Keyboard', 3, 4500.00, 13500.00, NOW()),
    ('d4e5f6a7-b8c9-0123-defa-234567890123', 'Vikram Singh', 'vikram@example.com', 'Monitor Stand', 1, 1899.50, 1899.50, NOW()),
    ('e5f6a7b8-c9d0-1234-efab-345678901234', 'Meera Patel', 'meera@example.com', 'Webcam HD', 2, 3200.00, 6400.00, NOW());