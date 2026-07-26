package com.mvno.intercept.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import java.time.Duration;

/**
 * Outbound HTTP Client Factory Configuration
 * 
 * Configures Spring Boot 3.4 RestClient for outbound HTTP REST queries to the external
 * AI Spam Model server (http://ai-filter:8000/api/v1/classify).
 * 
 * Carrier SLA & Split Timeout Enforcement:
 * - Connect Timeout: 1,000ms (1s default) — fails fast on unreachable host.
 * - Read Timeout: 5,000ms (5s default) — window for AI model inference prediction.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Configuration
public class RestClientConfig {

    @Value("${ai-filter.connect-timeout-seconds:1}")
    private int connectTimeoutSeconds;

    @Value("${ai-filter.read-timeout-seconds:5}")
    private int readTimeoutSeconds;

    /**
     * Constructs and registers a RestClient bean configured with split connect & read timeouts.
     * 
     * @return Configured RestClient instance.
     */
    @Bean
    public RestClient restClient() {
        final SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout((int) Duration.ofSeconds(connectTimeoutSeconds).toMillis());
        factory.setReadTimeout((int) Duration.ofSeconds(readTimeoutSeconds).toMillis());

        return RestClient.builder()
                .requestFactory(factory)
                .build();
    }
}
