package com.mvno.intercept.filter;

import com.mvno.intercept.subscriber.CallInterceptRequest;
import com.mvno.intercept.subscriber.InterceptResponse;
import com.mvno.intercept.subscriber.SMSInterceptRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

import java.util.Map;

/**
 * <h1>AI Spam Model Proxy &amp; Carrier SLA Resilience Service</h1>
 * 
 * <p>The {@code AiFilterService} acts as the primary integration bridge between the MVNO core gateway
 * and the external AI Spam Model microservice ({@code http://ai-filter:8000/api/v1/classify}).</p>
 * 
 * <h2>System Integration &amp; REST Contract</h2>
 * <p>Proxies real-time SMS content payloads and Voice Call metadata over the container bridge network.
 * Payloads conform strictly to the schema defined in {@code docs/API_CONTRACT.md}.</p>
 * 
 * <h2>Carrier SLA &amp; Fault Tolerance Rule (Fail-Open)</h2>
 * <p>In tier-1 telecommunications networks, auxiliary security/analytics services must <b>NEVER</b> cause a
 * total service outage or block legitimate subscriber traffic during secondary system failures:</p>
 * <ul>
 *   <li><b>Circuit Breaker / SLA Fallback:</b> If the AI model container is offline, returns HTTP 5xx errors,
 *       or exceeds the 5-second socket timeout window, the exception is caught and a <b>Fail-Open decision
 *       ({@code allow: true})</b> is returned.</li>
 *   <li><b>Audit Trail:</b> SLA fallback events are logged with {@code WARN} level to trigger NOC monitoring alerts.</li>
 * </ul>
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 * @see com.mvno.intercept.subscriber.SMSInterceptRequest
 * @see com.mvno.intercept.subscriber.CallInterceptRequest
 * @see com.mvno.intercept.subscriber.InterceptResponse
 * @see com.mvno.intercept.filter.TranscriptionResult
 */
@Service
public class AiFilterService {

    private static final Logger logger = LoggerFactory.getLogger(AiFilterService.class);

    /** Injected thread-safe RestClient for outbound HTTP POST requests. */
    private final RestClient restClient;

    /** Target AI filter endpoint URL (property: {@code ai-filter.url}). Default: {@code http://ai-filter:8000/api/v1/classify}. */
    private final String baseUrl;

    /**
     * Constructs the AI Filter Proxy Service with required HTTP client dependencies.
     * 
     * @param restClient Pre-configured Spring {@link RestClient} instance with socket timeouts.
     * @param baseUrl Base URL of the external AI classification REST endpoint.
     */
    public AiFilterService(final RestClient restClient,
                           @Value("${ai-filter.url:http://ai-filter:8000/api/v1/classify}") final String baseUrl) {
        this.restClient = restClient;
        this.baseUrl = baseUrl;
    }

    /**
     * Constructs an SMS classification JSON payload and proxies it to the AI Spam Model server.
     * 
     * <p>If the AI model approves the text, returns {@code allow: true}. If flagged as spam, returns
     * {@code allow: false} with reason. On network/timeout failure, gracefully falls back to SLA allow.</p>
     * 
     * @param req The incoming SMS interception request containing sender, recipient, and text content.
     * @return An {@link InterceptResponse} containing the policy decision and reason string.
     */
    public InterceptResponse classifySms(final SMSInterceptRequest req) {
        try {
            // Build JSON payload map matching docs/API_CONTRACT.md schema
            final Map<String, Object> body = Map.of(
                "event_type", "SMS",
                "sender_msisdn", req.sender(),
                "recipient_msisdn", req.recipient(),
                "content_text", req.content(),
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            // Execute synchronous POST request to AI model server
            final TranscriptionResult result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            if (result != null) {
                return new InterceptResponse(result.allow(), result.reason());
            }
            
            // Handle null body response gracefully
            return new InterceptResponse(true, "AI filter returned empty response — SLA allow");
        } catch (final Exception e) {
            // Carrier SLA Fail-Open: Log warning and allow SMS to proceed
            logger.warn("AI filter unreachable or timed out (>5s): {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }

    /**
     * Constructs a Voice Call setup classification JSON payload and proxies it to the AI Spam Model server.
     * 
     * <p>Proxies call metadata (caller MSISDN, callee MSISDN, SIP Call-ID) to detect blacklisted robocallers.</p>
     * 
     * @param req The incoming Voice Call setup request containing caller, callee, and Call-ID metadata.
     * @return An {@link InterceptResponse} containing the call setup policy decision.
     */
    public InterceptResponse classifyCall(final CallInterceptRequest req) {
        try {
            // Build JSON payload map for call metadata matching docs/API_CONTRACT.md schema
            final Map<String, Object> body = Map.of(
                "event_type", "VOICE_CALL",
                "caller_msisdn", req.caller(),
                "callee_msisdn", req.callee(),
                "call_id", req.callId() != null ? req.callId() : "",
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            // Execute synchronous POST request to AI model server
            final TranscriptionResult result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            if (result != null) {
                return new InterceptResponse(result.allow(), result.reason());
            }

            return new InterceptResponse(true, "AI filter returned empty response — SLA allow");
        } catch (final Exception e) {
            // Carrier SLA Fail-Open: Log warning and allow call setup to proceed
            logger.warn("AI filter unreachable or timed out (>5s): {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }
}
