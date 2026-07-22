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
 * AI Spam Model Proxy & Carrier SLA Resilience Service
 * 
 * Integration bridge proxying real-time SMS content and Voice Call metadata to the external
 * AI Spam Model microservice (http://ai-filter:8000/api/v1/classify).
 * 
 * Carrier SLA Rules (Fail-Open):
 * In telecommunications, auxiliary AI/analytics failures must never cause carrier downtime.
 * If the AI filter is offline, errors, or times out (>5s), the exception is caught and an
 * SLA Fail-Open decision (allow: true) is returned.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Service
public class AiFilterService {

    private static final Logger logger = LoggerFactory.getLogger(AiFilterService.class);
    private final RestClient restClient;
    private final String baseUrl;

    public AiFilterService(final RestClient restClient,
                           @Value("${ai-filter.url:http://ai-filter:8000/api/v1/classify}") final String baseUrl) {
        this.restClient = restClient;
        this.baseUrl = baseUrl;
    }

    /**
     * Constructs SMS classification payload and proxies it to AI filter.
     * On network/timeout error, gracefully falls back to SLA allow.
     * 
     * @param req Incoming SMS interception request.
     * @return InterceptResponse decision.
     */
    public InterceptResponse classifySms(final SMSInterceptRequest req) {
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
                return new InterceptResponse(result.allow(), result.reason());
            }
            return new InterceptResponse(true, "AI filter returned empty response — SLA allow");
        } catch (final Exception e) {
            logger.warn("AI filter unreachable or timed out (>5s): {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }

    /**
     * Constructs Voice Call classification payload and proxies it to AI filter.
     * 
     * @param req Incoming Call interception request.
     * @return InterceptResponse decision.
     */
    public InterceptResponse classifyCall(final CallInterceptRequest req) {
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
                return new InterceptResponse(result.allow(), result.reason());
            }
            return new InterceptResponse(true, "AI filter returned empty response — SLA allow");
        } catch (final Exception e) {
            logger.warn("AI filter unreachable or timed out (>5s): {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }
}
