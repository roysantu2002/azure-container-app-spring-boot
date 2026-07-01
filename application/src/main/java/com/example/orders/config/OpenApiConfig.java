package com.example.orders.config;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.security.OAuthFlow;
import io.swagger.v3.oas.models.security.OAuthFlows;
import io.swagger.v3.oas.models.security.Scopes;
import io.swagger.v3.oas.models.security.SecurityRequirement;
import io.swagger.v3.oas.models.security.SecurityScheme;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class OpenApiConfig {

    @Value("${AZURE_TENANT_ID:common}")
    private String tenantId;

    @Value("${ENTRA_APP_CLIENT_ID:}")
    private String clientId;

    @Bean
    public OpenAPI ordersOpenAPI() {
        String authUrl = "https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/authorize";
        String tokenUrl = "https://login.microsoftonline.com/" + tenantId + "/oauth2/v2.0/token";

        return new OpenAPI()
            .info(new Info()
                .title("Orders Platform API")
                .description("Orders REST API protected by Microsoft Entra ID (OIDC)")
                .version("v1"))
            .addSecurityItem(new SecurityRequirement().addList("entra-oauth2"))
            .components(new Components()
                .addSecuritySchemes("entra-oauth2", new SecurityScheme()
                    .type(SecurityScheme.Type.OAUTH2)
                    .description("Authenticate with Microsoft Entra ID")
                    .flows(new OAuthFlows()
                        .authorizationCode(new OAuthFlow()
                            .authorizationUrl(authUrl)
                            .tokenUrl(tokenUrl)
                            .scopes(new Scopes()
                                .addString("api://" + clientId + "/Orders.Read", "Read orders")
                                .addString("api://" + clientId + "/Orders.Write", "Create/update orders")
                            )
                        )
                    )
                )
                .addSecuritySchemes("bearer-jwt", new SecurityScheme()
                    .type(SecurityScheme.Type.HTTP)
                    .scheme("bearer")
                    .bearerFormat("JWT")
                    .description("Paste a Bearer token obtained from Azure CLI or Postman")
                )
            );
    }
}