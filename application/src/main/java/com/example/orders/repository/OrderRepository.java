package com.example.orders.repository;

import com.example.orders.entity.OrderEntity;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.UUID;

public interface OrderRepository
        extends JpaRepository<OrderEntity, UUID> {
}