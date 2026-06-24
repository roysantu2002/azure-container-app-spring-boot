package com.example.orders.controller;

import com.example.orders.entity.OrderEntity;
import com.example.orders.repository.OrderRepository;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/orders")
public class OrderController {

    private final OrderRepository orderRepository;

    public OrderController(OrderRepository orderRepository) {
        this.orderRepository = orderRepository;
    }

    @GetMapping
    public List<OrderEntity> listOrders() {
        return orderRepository.findAll();
    }

    @GetMapping("/{id}")
    public ResponseEntity<OrderEntity> getOrder(@PathVariable UUID id) {
        return orderRepository.findById(id)
                .map(ResponseEntity::ok)
                .orElse(ResponseEntity.notFound().build());
    }

    @PostMapping
    public ResponseEntity<OrderEntity> createOrder(@RequestBody OrderEntity order) {
        order.setId(UUID.randomUUID());
        order.setCreatedAt(Instant.now());
        if (order.getQuantity() != null && order.getUnitPrice() != null) {
            order.setTotalPrice(order.getUnitPrice().multiply(BigDecimal.valueOf(order.getQuantity())));
        }
        OrderEntity saved = orderRepository.save(order);
        return ResponseEntity.status(201).body(saved);
    }
}