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
 * Carrier SLA & Timeout Enforcement:
 * - Connect Timeout: Enforces strict TCP socket connect timeout (5s default).
 * - Read Timeout: Enforces response read timeout (5s default).
 * - Fail-Open Policy: Stalls throw SocketTimeoutException, triggering SLA Fail-Open fallback (allowing traffic).
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Configuration
public class RestClientConfig {

    @Value("${ai-filter.timeout-seconds:5}")
    private int timeoutSeconds;

    /**
     * Constructs and registers a RestClient bean configured with 5-second socket timeouts.
     * 
     * @return Configured RestClient instance.
     */
    @Bean
    public RestClient restClient() {
        final SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        final int timeoutMillis = (int) Duration.ofSeconds(timeoutSeconds).toMillis();
        factory.setConnectTimeout(timeoutMillis);
        factory.setReadTimeout(timeoutMillis);

        return RestClient.builder()
                .requestFactory(factory)
                .build();
    }
}
