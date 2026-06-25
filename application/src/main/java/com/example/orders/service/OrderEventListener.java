package com.example.orders.service;

import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Component
public class OrderEventListener {

    private static final Logger log = LoggerFactory.getLogger(OrderEventListener.class);

    @KafkaListener(topics = "order-events")
    public void onOrderEvent(ConsumerRecord<String, String> record) {
        log.info("========== RECEIVED ORDER EVENT ==========");
        log.info("  Topic     : {}", record.topic());
        log.info("  Partition : {}", record.partition());
        log.info("  Offset    : {}", record.offset());
        log.info("  Key       : {}", record.key());
        log.info("  Value     : {}", record.value());
        log.info("===========================================");
    }
}
