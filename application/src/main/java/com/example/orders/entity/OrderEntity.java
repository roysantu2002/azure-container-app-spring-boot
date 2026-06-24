package com.example.orders.entity;

import jakarta.persistence.*;
import lombok.Data;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@Data
@Entity
@Table(name = "orders", schema = "orders")
public class OrderEntity {

    @Id
    private UUID id;

    private String customerName;

    private String customerEmail;

    private String productName;

    private Integer quantity;

    private BigDecimal unitPrice;

    private BigDecimal totalPrice;

    private Instant createdAt;
}