package com.example.orders.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.Statement;

import org.springframework.kafka.core.KafkaTemplate;

@Component
public class StartupInfoLogger {

    private static final Logger log = LoggerFactory.getLogger(StartupInfoLogger.class);

    private final DataSource dataSource;
    private final KafkaTemplate<String, Object> kafkaTemplate;

    @Value("${spring.profiles.active:unknown}")
    private String activeProfile;

    @Value("${server.port:8080}")
    private String serverPort;

    @Value("${api.base-path:/api/v1}")
    private String apiBasePath;

    @Value("${spring.kafka.bootstrap-servers:not configured}")
    private String kafkaBootstrapServers;

    public StartupInfoLogger(DataSource dataSource, KafkaTemplate<String, Object> kafkaTemplate) {
        this.dataSource = dataSource;
        this.kafkaTemplate = kafkaTemplate;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void logConnectionInfo() {
        try (Connection conn = dataSource.getConnection()) {
            DatabaseMetaData meta = conn.getMetaData();
            String url = meta.getURL();
            String user = meta.getUserName();

            String host = extractHost(url);
            boolean isAzure = host.contains("azure.com");
            String dbName = extractDbName(url);
            String recordCount = getRecordCount(conn);

            log.info("");
            log.info("=========================================================");
            log.info("  APPLICATION STARTED SUCCESSFULLY");
            log.info("=========================================================");
            log.info("  Profile        : {}", activeProfile);
            log.info("  API Base       : http://localhost:{}{}", serverPort, apiBasePath);
            log.info("---------------------------------------------------------");
            log.info("  DB Connection  : {}", isAzure ? "*** AZURE POSTGRESQL ***" : "*** LOCAL POSTGRESQL ***");
            log.info("  DB Host        : {}", host);
            log.info("  DB Name        : {}", dbName);
            log.info("  DB User        : {}", user);
            log.info("  DB Version     : {} {}", meta.getDatabaseProductName(), meta.getDatabaseProductVersion());
            log.info("  Auth Method    : {}", isAzure ? "Entra ID Token (via DefaultAzureCredential)" : "Password");
            log.info("  SSL            : {}", url != null && url.contains("sslmode=require") ? "Enabled" : "Disabled");
            log.info("  Orders Count   : {}", recordCount);
            log.info("---------------------------------------------------------");
            boolean isEventHubs = kafkaBootstrapServers.contains("servicebus.windows.net");
            log.info("  Kafka Broker   : {}", isEventHubs ? "*** AZURE EVENT HUBS ***" : kafkaBootstrapServers);
            log.info("  Bootstrap      : {}", kafkaBootstrapServers);
            log.info("  Auth Method    : {}", isEventHubs ? "OAUTHBEARER (via DefaultAzureCredential)" : "PLAINTEXT");
            log.info("---------------------------------------------------------");
            log.info("  Endpoints:");
            log.info("    GET  http://localhost:{}{}/orders", serverPort, apiBasePath);
            log.info("    GET  http://localhost:{}{}/orders/{{id}}", serverPort, apiBasePath);
            log.info("    POST http://localhost:{}{}/orders", serverPort, apiBasePath);
            log.info("    GET  http://localhost:{}/actuator/health", serverPort);
            log.info("=========================================================");
            log.info("");

        } catch (Exception e) {
            log.error("");
            log.error("=========================================================");
            log.error("  DATABASE CONNECTION FAILED");
            log.error("=========================================================");
            log.error("  Profile : {}", activeProfile);
            log.error("  Error   : {}", e.getMessage());
            log.error("=========================================================");
            log.error("");
        }
    }

    private String extractHost(String url) {
        if (url == null || !url.contains("//")) return "unknown";
        String host = url.substring(url.indexOf("//") + 2);
        if (host.contains(":")) host = host.substring(0, host.indexOf(":"));
        else if (host.contains("/")) host = host.substring(0, host.indexOf("/"));
        return host;
    }

    private String extractDbName(String url) {
        if (url == null) return "unknown";
        try {
            String afterHost = url.substring(url.indexOf("//") + 2);
            String path = afterHost.substring(afterHost.indexOf("/") + 1);
            if (path.contains("?")) path = path.substring(0, path.indexOf("?"));
            return path;
        } catch (Exception e) {
            return "unknown";
        }
    }

    private String getRecordCount(Connection conn) {
        try (Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT count(*) FROM orders.orders")) {
            if (rs.next()) return String.valueOf(rs.getInt(1));
        } catch (Exception e) {
            return "N/A (table may not exist)";
        }
        return "N/A";
    }
}
