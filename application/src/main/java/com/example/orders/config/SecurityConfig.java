package com.example.orders.config;

import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpMethod;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.JwtGrantedAuthoritiesConverter;
import org.springframework.security.web.SecurityFilterChain;

import java.time.Instant;
import java.util.Map;

@Configuration
@EnableWebSecurity
@EnableMethodSecurity
@Profile("!local")
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            .csrf(csrf -> csrf.disable())
            .sessionManagement(session ->
                session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
            .authorizeHttpRequests(auth -> auth
                // Public endpoints (health checks, actuator, swagger)
                .requestMatchers("/actuator/**").permitAll()
                .requestMatchers("/error").permitAll()
                .requestMatchers("/swagger-ui/**", "/swagger-ui.html",
                    "/v3/api-docs/**", "/v3/api-docs.yaml").permitAll()

                // Order endpoints - require authentication and roles
                .requestMatchers(HttpMethod.GET, "/api/v1/orders/**")
                    .hasAnyAuthority("APPROLE_Order.Reader", "APPROLE_Order.Admin")
                .requestMatchers(HttpMethod.POST, "/api/v1/orders/**")
                    .hasAnyAuthority("APPROLE_Order.Writer", "APPROLE_Order.Admin")

                // All other requests require authentication
                .anyRequest().authenticated()
            )
            .oauth2ResourceServer(oauth2 -> oauth2
                .jwt(jwt -> jwt.jwtAuthenticationConverter(jwtAuthenticationConverter()))
                .authenticationEntryPoint((request, response, authException) -> {
                    response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
                    response.setContentType(MediaType.APPLICATION_JSON_VALUE);
                    new ObjectMapper().writeValue(response.getOutputStream(), Map.of(
                        "status", 401,
                        "error", "Unauthorized",
                        "message", "Missing or invalid Bearer token. Authenticate via Microsoft Entra ID.",
                        "path", request.getRequestURI(),
                        "timestamp", Instant.now().toString()
                    ));
                })
                .accessDeniedHandler((request, response, accessDeniedException) -> {
                    response.setStatus(HttpServletResponse.SC_FORBIDDEN);
                    response.setContentType(MediaType.APPLICATION_JSON_VALUE);
                    new ObjectMapper().writeValue(response.getOutputStream(), Map.of(
                        "status", 403,
                        "error", "Forbidden",
                        "message", "You do not have the required role to access this resource.",
                        "path", request.getRequestURI(),
                        "timestamp", Instant.now().toString()
                    ));
                })
            );

        return http.build();
    }

    @Bean
    public JwtAuthenticationConverter jwtAuthenticationConverter() {
        JwtGrantedAuthoritiesConverter grantedAuthoritiesConverter =
            new JwtGrantedAuthoritiesConverter();
        // Entra ID puts roles in the "roles" claim
        grantedAuthoritiesConverter.setAuthoritiesClaimName("roles");
        grantedAuthoritiesConverter.setAuthorityPrefix("APPROLE_");

        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(grantedAuthoritiesConverter);
        return converter;
    }
}