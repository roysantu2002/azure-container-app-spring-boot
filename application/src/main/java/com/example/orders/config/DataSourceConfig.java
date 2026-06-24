package com.example.orders.config;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import javax.sql.DataSource;

@Configuration
public class DataSourceConfig {

    @Bean
    public DataSource dataSource(
            AzureTokenProvider tokenProvider) {

        String host =
                System.getenv("POSTGRES_HOST");

        String db =
                System.getenv("POSTGRES_DB");

        String username =
                System.getenv("POSTGRES_MI_USER");

        HikariConfig config =
                new HikariConfig();

        config.setDriverClassName(
                "org.postgresql.Driver");

        config.setJdbcUrl(
                String.format(
                       "jdbc:postgresql://%s:5432/%s?sslmode=require",
                        host,
                        db));

        config.setUsername(username);

        config.setPassword(
                tokenProvider.getToken());

        config.setMaximumPoolSize(5);

        return new HikariDataSource(config);
    }
}