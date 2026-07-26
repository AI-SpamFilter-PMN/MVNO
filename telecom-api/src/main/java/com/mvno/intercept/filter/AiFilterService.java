package com.mvno.intercept.filter;

import com.mvno.intercept.subscriber.CallInterceptRequest;
import com.mvno.intercept.subscriber.InterceptResponse;
import com.mvno.intercept.subscriber.SMSInterceptRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * AI Spam Model Proxy, Carrier SLA Resilience & Circuit Breaker Service
 * 
 * Integration bridge proxying real-time SMS content and Voice Call metadata to the external
 * AI Spam Model microservice (http://ai-filter:8000/api/v1/classify).
 * 
 * Telecom SOTA Resilience Rules:
 * 1. Split Timeouts: 1s Connect Timeout + 5s Read Timeout.
 * 2. In-Memory Circuit Breaker: After 3 consecutive network/timeout failures, the circuit breaker opens for 30s.
 *    While open, requests fail-open immediately (~0.1ms) with "AI filter circuit open — SLA allow" to prevent call setup delays.
 * 3. Carrier SLA Fallback (Fail-Open): Auxiliary AI failures never block subscriber traffic.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Service
public class AiFilterService {

    private static final Logger logger = LoggerFactory.getLogger(AiFilterService.class);
    private static final int MAX_CONSECUTIVE_FAILURES = 3;
    private static final long CIRCUIT_OPEN_DURATION_MS = 30_000L;

    private final RestClient restClient;
    private final String baseUrl;
    private final AtomicInteger consecutiveFailures = new AtomicInteger(0);
    private final AtomicLong circuitOpenUntilEpochMs = new AtomicLong(0);

    public AiFilterService(final RestClient restClient,
                           @Value("${ai-filter.url:http://ai-filter:8000/api/v1/classify}") final String baseUrl) {
        this.restClient = restClient;
        this.baseUrl = baseUrl;
    }

    /**
     * Constructs SMS classification payload and proxies it to AI filter.
     * 
     * @param req Incoming SMS interception request.
     * @return InterceptResponse decision.
     */
    public InterceptResponse classifySms(final SMSInterceptRequest req) {
        if (isCircuitOpen()) {
            return new InterceptResponse(true, "AI filter circuit open — SLA allow");
        }

        try {
            final Map<String, Object> body = Map.of(
                "event_type", "SMS",
                "sender_msisdn", req.sender(),
                "recipient_msisdn", req.recipient(),
                "content_text", req.content(),
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            final TranscriptionResult result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            if (result != null) {
                consecutiveFailures.set(0);
                return new InterceptResponse(result.allow(), result.reason());
            }
            return new InterceptResponse(true, "AI filter returned empty response — SLA allow");
        } catch (final RestClientException e) {
            recordFailure(e);
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        } catch (final Exception e) {
            logger.error("Unexpected error in SMS AI classification: {}", e.getMessage(), e);
            return new InterceptResponse(true, "Gateway internal error — SLA allow");
        }
    }

    /**
     * Constructs Voice Call classification payload and proxies it to AI filter.
     * 
     * @param req Incoming Call interception request.
     * @return InterceptResponse decision.
     */
    public InterceptResponse classifyCall(final CallInterceptRequest req) {
        if (isCircuitOpen()) {
            return new InterceptResponse(true, "AI filter circuit open — SLA allow");
        }

        try {
            final Map<String, Object> body = Map.of(
                "event_type", "VOICE_CALL",
                "caller_msisdn", req.caller(),
                "callee_msisdn", req.callee(),
                "call_id", req.callId() != null ? req.callId() : "",
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            final TranscriptionResult result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            if (result != null) {
                consecutiveFailures.set(0);
                return new InterceptResponse(result.allow(), result.reason());
            }
            return new InterceptResponse(true, "AI filter returned empty response — SLA allow");
        } catch (final RestClientException e) {
            recordFailure(e);
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        } catch (final Exception e) {
            logger.error("Unexpected error in Call AI classification: {}", e.getMessage(), e);
            return new InterceptResponse(true, "Gateway internal error — SLA allow");
        }
    }

    private boolean isCircuitOpen() {
        if (System.currentTimeMillis() < circuitOpenUntilEpochMs.get()) {
            logger.warn("AI filter circuit breaker OPEN — skipping HTTP call and returning SLA allow immediately.");
            return true;
        }
        return false;
    }

    private void recordFailure(final Exception e) {
        final int failures = consecutiveFailures.incrementAndGet();
        logger.warn("AI filter connection error (consecutive failure #{}/{}): {}", failures, MAX_CONSECUTIVE_FAILURES, e.getMessage());
        if (failures >= MAX_CONSECUTIVE_FAILURES) {
            circuitOpenUntilEpochMs.set(System.currentTimeMillis() + CIRCUIT_OPEN_DURATION_MS);
            logger.error("AI filter failed {} consecutive times. Circuit breaker OPENED for 30s.", failures);
        }
    }
}
