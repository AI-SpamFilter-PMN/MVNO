package com.mvno.intercept.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;
import java.time.Duration;

/**
 * ==============================================================================
 * HTTP RestClient Configuration (AI Model Gateway Proxy)
 * ==============================================================================
 * Configures the Spring RestClient bean used by AiFilterService to proxy SMS and Call
 * interception requests to the AI Spam Filter team's server (http://ai-filter:8000).
 * 
 * Enforces a 5-second socket timeout to accommodate slow CPU-bound AI model inference.
 */
@Configuration
public class RestClientConfig {

    @Value("${ai-filter.timeout-seconds:5}")
    private int timeoutSeconds;

    @Bean
    public RestClient restClient() {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        // Set connection and read timeouts to 5 seconds
        factory.setConnectTimeout((int) Duration.ofSeconds(timeoutSeconds).toMillis());
        factory.setReadTimeout((int) Duration.ofSeconds(timeoutSeconds).toMillis());

        return RestClient.builder()
                .requestFactory(factory)
                .build();
    }
}
