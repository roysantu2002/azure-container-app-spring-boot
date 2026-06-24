package com.example.orders.config;

import com.azure.core.credential.AccessToken;
import com.azure.core.credential.TokenRequestContext;
import com.azure.identity.DefaultAzureCredential;
import com.azure.identity.DefaultAzureCredentialBuilder;
import org.springframework.stereotype.Component;

@Component
public class AzureTokenProvider {

    private static final String SCOPE =
            "https://ossrdbms-aad.database.windows.net/.default";

    public String getToken() {

        DefaultAzureCredential credential =
                new DefaultAzureCredentialBuilder()
                        .managedIdentityClientId(
                                System.getenv("AZURE_CLIENT_ID"))
                        .build();

        AccessToken token =
                credential.getToken(
                                new TokenRequestContext()
                                        .addScopes(SCOPE))
                        .block();

        return token.getToken();
    }
}