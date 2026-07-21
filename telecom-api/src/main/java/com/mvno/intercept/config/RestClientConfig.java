package com.mvno.intercept.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;
import java.time.Duration;

/**
 * Spring RestClient Configuration for Outbound AI Spam Filter Queries.
 * 
 * RATIONALE: Modern Spring Boot 3.x / 4.x introduces `RestClient` as the synchronous HTTP client
 * replacing legacy `RestTemplate`. We configure an underlying `SimpleClientHttpRequestFactory`
 * to enforce strict TCP connection and socket read timeouts.
 * 
 * TIMEOUT TUNING: Set to 5 seconds by default (`ai-filter.timeout-seconds`). If the AI Spam Model
 * server stalls or takes longer than 5 seconds, the HTTP request aborts, throwing a SocketTimeoutException,
 * which triggers Carrier SLA Fail-Open fallback (`allow: true`).
 */
// `@Configuration` designates this class as a Spring IoC configuration bean factory.
@Configuration
public class RestClientConfig {

    // `@Value` injects externalized property values from application.yml (or environment variables)
    // syntax `${property.path:default_value}` sets a fallback default of 5 seconds if unspecified.
    @Value("${ai-filter.timeout-seconds:5}")
    private int timeoutSeconds;

    // `@Bean` registers the customized, timeout-enforced RestClient instance in the Spring ApplicationContext.
    @Bean
    public RestClient restClient() {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        
        // Convert seconds to milliseconds for low-level socket connection and read timeouts
        factory.setConnectTimeout((int) Duration.ofSeconds(timeoutSeconds).toMillis());
        factory.setReadTimeout((int) Duration.ofSeconds(timeoutSeconds).toMillis());

        return RestClient.builder()
                .requestFactory(factory)
                .build();
    }
}
