package com.mvno.intercept.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import java.time.Duration;

/**
 * <h1>Outbound HTTP Client Factory Configuration</h1>
 * 
 * <p>Configures Spring Boot 3.4's synchronous {@link RestClient} for executing outbound REST HTTP queries
 * to the external AI Spam Model classification server ({@code http://ai-filter:8000/api/v1/classify}).</p>

 * <h2>Design &amp; Timeout Tuning</h2>
 * <p>Modern Spring Boot 3.x introduces {@code RestClient} as the fluent, synchronous replacement for legacy
 * {@code RestTemplate}. Under Java 21 Virtual Threads, blocking HTTP client operations park the virtual thread
 * without pinning the underlying OS carrier thread.</p>
 * 
 * <h2>Carrier SLA &amp; Timeout Enforcement</h2>
 * <ul>
 *   <li><b>Connect Timeout:</b> Enforces strict TCP socket connection timeout (5 seconds default).</li>
 *   <li><b>Read Timeout:</b> Enforces HTTP payload response read timeout (5 seconds default).</li>
 *   <li><b>Fail-Open Policy:</b> If the AI model stutters or fails to respond within the timeout window,
 *       a {@link java.net.SocketTimeoutException} is thrown, triggering SLA Fail-Open fallback (allowing the call/SMS).</li>
 * </ul>
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 * @see org.springframework.web.client.RestClient
 * @see org.springframework.http.client.SimpleClientHttpRequestFactory
 */
@Configuration
public class RestClientConfig {

    /** Timeout duration in seconds injected from {@code application.yml} (property: {@code ai-filter.timeout-seconds}). Default: 5. */
    @Value("${ai-filter.timeout-seconds:5}")
    private int timeoutSeconds;

    /**
     * Constructs and registers a pre-configured {@link RestClient} bean with strict TCP connection and socket read timeouts.
     * 
     * @return A thread-safe {@link RestClient} instance configured for HTTP communications with the AI Spam Filter container.
     */
    @Bean
    public RestClient restClient() {
        // SimpleClientHttpRequestFactory provides raw JDK HttpURLConnection socket configuration
        final SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        
        // Convert timeout seconds into milliseconds for low-level socket timeouts
        final int timeoutMillis = (int) Duration.ofSeconds(timeoutSeconds).toMillis();
        factory.setConnectTimeout(timeoutMillis);
        factory.setReadTimeout(timeoutMillis);

        // Build fluent RestClient instance using custom request factory
        return RestClient.builder()
                .requestFactory(factory)
                .build();
    }
}
