package com.example.orders.config;

import com.azure.identity.DefaultAzureCredentialBuilder;
import com.azure.core.credential.TokenCredential;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;

@Configuration
@Profile("azure-debug")
public class AzureCredentialConfig {

    @Bean
    public TokenCredential defaultAzureCredential() {
        return new DefaultAzureCredentialBuilder().build();
    }
}
