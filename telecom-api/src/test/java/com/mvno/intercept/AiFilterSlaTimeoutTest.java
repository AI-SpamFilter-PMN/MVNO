package com.mvno.intercept;

import com.mvno.intercept.filter.AiFilterService;
import com.mvno.intercept.subscriber.CallInterceptRequest;
import com.mvno.intercept.subscriber.InterceptResponse;
import com.mvno.intercept.subscriber.SMSInterceptRequest;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Non-Mocked Unit Tests for Carrier SLA Timeout & Circuit Breaker Tripping
 * 
 * Verifies that RestClient socket connect/read timeouts throw RestClientException and trigger
 * immediate SLA Fail-Open fallback (allow=true), and that 3 consecutive failures open the circuit breaker for 30s.
 */
class AiFilterSlaTimeoutTest {

    private AiFilterService aiFilterService;
    private SimpleMeterRegistry meterRegistry;

    @BeforeEach
    void setUp() {
        final SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(1);
        requestFactory.setReadTimeout(1);

        final String closedPortUrl = "http://127.0.0.1:1/api/v1/classify";
        final RestClient restClient = RestClient.builder()
                .baseUrl(closedPortUrl)
                .requestFactory(requestFactory)
                .build();

        meterRegistry = new SimpleMeterRegistry();
        aiFilterService = new AiFilterService(restClient, closedPortUrl, meterRegistry);
    }

    @Test
    @DisplayName("SMS Classification Timeout -> SLA Fail-Open Fallback")
    void testSmsSlaTimeoutFallback() {
        final SMSInterceptRequest smsRequest = new SMSInterceptRequest("15551234567", "15557654321", "Test Content");
        final InterceptResponse response = aiFilterService.classifySms(smsRequest);

        assertNotNull(response);
        assertTrue(response.allow());
        assertEquals("AI filter unreachable — SLA allow", response.reason());
    }

    @Test
    @DisplayName("Voice Call Classification Timeout -> SLA Fail-Open Fallback")
    void testCallSlaTimeoutFallback() {
        final CallInterceptRequest callRequest = new CallInterceptRequest("15551234567", "15557654321", "call-timeout-001", "356938035643809");
        final InterceptResponse response = aiFilterService.classifyCall(callRequest);

        assertNotNull(response);
        assertTrue(response.allow());
        assertEquals("AI filter unreachable — SLA allow", response.reason());
    }

    @Test
    @DisplayName("Circuit Breaker Tripping After 3 Failures -> Fast Fail-Open")
    void testCircuitBreakerTripping() {
        final SMSInterceptRequest smsRequest = new SMSInterceptRequest("15551234567", "15557654321", "Test Content");

        // Failure 1 & 2 -> Network timeout unreachable
        assertEquals("AI filter unreachable — SLA allow", aiFilterService.classifySms(smsRequest).reason());
        assertEquals("AI filter unreachable — SLA allow", aiFilterService.classifySms(smsRequest).reason());

        // Failure 3 -> Trips Circuit Breaker
        assertEquals("AI filter unreachable — SLA allow", aiFilterService.classifySms(smsRequest).reason());

        // Call 4 -> Fast Fail-Open via Circuit Breaker (~0.1ms)
        final InterceptResponse response = aiFilterService.classifySms(smsRequest);
        assertTrue(response.allow());
        assertEquals("AI filter circuit open — SLA allow", response.reason());

        // Fail-open counters: 3 unreachable + 1 circuit_open
        assertEquals(3.0, meterRegistry.get("mvno.ai.failopen").tag("reason", "unreachable").counter().count());
        assertEquals(1.0, meterRegistry.get("mvno.ai.failopen").tag("reason", "circuit_open").counter().count());
    }
}
