package com.mvno.intercept.filter;

import com.mvno.intercept.subscriber.CallInterceptRequest;
import com.mvno.intercept.subscriber.InterceptResponse;
import com.mvno.intercept.subscriber.SMSInterceptRequest;
import io.micrometer.core.instrument.MeterRegistry;
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
    // Threshold: 3 consecutive HTTP/network failures trip the circuit breaker OPEN
    private static final int MAX_CONSECUTIVE_FAILURES = 3;

    // Circuit Breaker Duration: When open, bypass HTTP calls for 30,000ms (30 seconds)
    private static final long CIRCUIT_OPEN_DURATION_MS = 30_000L;

    private final RestClient restClient;
    private final String baseUrl;
    private final MeterRegistry meterRegistry;

    // Thread-safe atomic counters for tracking consecutive failures & circuit cooldown epoch
    private final AtomicInteger consecutiveFailures = new AtomicInteger(0);
    private final AtomicLong circuitOpenUntilEpochMs = new AtomicLong(0);

    public AiFilterService(final RestClient restClient,
                           @Value("${ai-filter.url:http://ai-filter:8000/api/v1/classify}") final String baseUrl,
                           final MeterRegistry meterRegistry) {
        this.restClient = restClient;
        this.baseUrl = baseUrl;
        this.meterRegistry = meterRegistry;
    }

    /**
     * Constructs SMS classification payload and proxies it to AI filter.
     * Enforces SLA fail-open rules if AI server is unreachable or circuit is open.
     * 
     * @param req Incoming SMS interception request.
     * @return InterceptResponse decision (allow: true/false).
     */
    public InterceptResponse classifySms(final SMSInterceptRequest req) {
        // Step 1: Fast-path check — if circuit breaker is OPEN, fail-open immediately (~0.1ms)
        if (isCircuitOpen()) {
            return failOpen("circuit_open", "AI filter circuit open — SLA allow");
        }

        try {
            // Step 2: Build JSON classification request payload for SMS
            final Map<String, Object> body = Map.of(
                "event_type", "SMS",
                "sender_msisdn", req.sender(),
                "recipient_msisdn", req.recipient(),
                "content_text", req.content(),
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            // Step 3: Execute POST request to external AI model microservice
            final TranscriptionResult result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            // Step 4: On successful response, reset consecutive failure counter to 0
            if (result != null) {
                consecutiveFailures.set(0);
                return new InterceptResponse(result.allow(), result.reason());
            }

            // Fallback for null response body
            return failOpen("empty_response", "AI filter returned empty response — SLA allow");

        } catch (final RestClientException e) {
            // Network / Timeout Exception: record failure & trigger SLA fail-open
            recordFailure(e);
            return failOpen("unreachable", "AI filter unreachable — SLA allow");

        } catch (final Exception e) {
            // Unexpected internal error: log & trigger SLA fail-open
            logger.error("Unexpected error in SMS AI classification: {}", e.getMessage(), e);
            return failOpen("internal", "Gateway internal error — SLA allow");
        }
    }

    /**
     * Constructs Voice Call classification payload and proxies it to AI filter.
     * Enforces SLA fail-open rules if AI server is unreachable or circuit is open.
     * 
     * @param req Incoming Call interception request.
     * @return InterceptResponse decision (allow: true/false).
     */
    public InterceptResponse classifyCall(final CallInterceptRequest req) {
        // Step 1: Fast-path check — if circuit breaker is OPEN, fail-open immediately (~0.1ms)
        if (isCircuitOpen()) {
            return failOpen("circuit_open", "AI filter circuit open — SLA allow");
        }

        try {
            // Step 2: Build JSON classification request payload for Voice Call
            final Map<String, Object> body = Map.of(
                "event_type", "VOICE_CALL",
                "caller_msisdn", req.caller(),
                "callee_msisdn", req.callee(),
                "call_id", req.callId() != null ? req.callId() : "",
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            // Step 3: Execute POST request to external AI model microservice
            final TranscriptionResult result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            // Step 4: On successful response, reset consecutive failure counter to 0
            if (result != null) {
                consecutiveFailures.set(0);
                return new InterceptResponse(result.allow(), result.reason());
            }

            // Fallback for null response body
            return failOpen("empty_response", "AI filter returned empty response — SLA allow");

        } catch (final RestClientException e) {
            // Network / Timeout Exception: record failure & trigger SLA fail-open
            recordFailure(e);
            return failOpen("unreachable", "AI filter unreachable — SLA allow");

        } catch (final Exception e) {
            // Unexpected internal error: log & trigger SLA fail-open
            logger.error("Unexpected error in Call AI classification: {}", e.getMessage(), e);
            return failOpen("internal", "Gateway internal error — SLA allow");
        }
    }

    /**
     * Constructs a post-call Transcript classification payload and proxies it to the AI filter.
     * Enforces SLA fail-open rules if the AI server is unreachable or the circuit is open.
     * Non-blocking by design: a post-call verdict failure only logs and never stalls the media spool loop.
     *
     * @param callId    Recording identifier (rtpengine WAV filename stem, e.g. {@code call-1785097956%40127.0.0.1-<hash>}).
     * @param transcript Vosk ASR transcribed speech text.
     * @return InterceptResponse decision (allow: true/false).
     */
    public InterceptResponse classifyTranscript(final String callId, final String transcript) {
        // Step 1: Fast-path check — if circuit breaker is OPEN, fail-open immediately (~0.1ms)
        if (isCircuitOpen()) {
            return failOpen("circuit_open", "AI filter circuit open — SLA allow");
        }

        try {
            // Step 2: Build JSON classification request payload for post-call transcript
            final Map<String, Object> body = Map.of(
                "event_type", "TRANSCRIPT",
                "call_id", callId,
                "transcript", transcript,
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            // Step 3: Execute POST request to external AI model microservice
            final TranscriptionResult result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            // Step 4: On successful response, reset consecutive failure counter to 0
            if (result != null) {
                consecutiveFailures.set(0);
                return new InterceptResponse(result.allow(), result.reason());
            }

            // Fallback for null response body
            return failOpen("empty_response", "AI filter returned empty response — SLA allow");

        } catch (final RestClientException e) {
            // Network / Timeout Exception: record failure & trigger SLA fail-open
            recordFailure(e);
            return failOpen("unreachable", "AI filter unreachable — SLA allow");

        } catch (final Exception e) {
            // Unexpected internal error: log & trigger SLA fail-open
            logger.error("Unexpected error in Transcript AI classification: {}", e.getMessage(), e);
            return failOpen("internal", "Gateway internal error — SLA allow");
        }
    }

    /**
     * Carrier SLA Fallback: Increments Prometheus counter 'mvno.ai.failopen' and returns allow: true.
     */
    private InterceptResponse failOpen(final String reason, final String message) {
        meterRegistry.counter("mvno.ai.failopen", "reason", reason).increment();
        logger.warn("AI filter SLA fail-open ({}): {}", reason, message);
        return new InterceptResponse(true, message);
    }

    /**
     * Checks whether the circuit breaker is currently in the OPEN cooldown state.
     */
    private boolean isCircuitOpen() {
        if (System.currentTimeMillis() < circuitOpenUntilEpochMs.get()) {
            logger.warn("AI filter circuit breaker OPEN — skipping HTTP call and returning SLA allow immediately.");
            return true;
        }
        return false;
    }

    /**
     * Increments consecutive failure counter and trips circuit breaker OPEN for 30s if threshold (3) is reached.
     */
    private void recordFailure(final Exception e) {
        final int failures = consecutiveFailures.incrementAndGet();
        logger.warn("AI filter connection error (consecutive failure #{}/{}): {}", failures, MAX_CONSECUTIVE_FAILURES, e.getMessage());
        if (failures >= MAX_CONSECUTIVE_FAILURES) {
            circuitOpenUntilEpochMs.set(System.currentTimeMillis() + CIRCUIT_OPEN_DURATION_MS);
            logger.error("AI filter failed {} consecutive times. Circuit breaker OPENED for 30s.", failures);
        }
    }
}
