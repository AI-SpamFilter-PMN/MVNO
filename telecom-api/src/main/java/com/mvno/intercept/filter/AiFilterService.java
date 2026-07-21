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
 * ==============================================================================
 * AI Filter Service (HTTP Proxy to Teammate AI Model)
 * ==============================================================================
 * Proxies SMS and Voice Call interception requests to the AI Spam Filter team's REST endpoint
 * (http://ai-filter:8000/api/v1/classify).
 * 
 * Enforces a 5-second SLA socket timeout window and provides Fail-Open fallback (allow: true)
 * if the AI model is offline or experiencing heavy inference latency.
 */
@Service
public class AiFilterService {

    private static final Logger logger = LoggerFactory.getLogger(AiFilterService.class);
    private final RestClient restClient;
    private final String baseUrl;

    public AiFilterService(RestClient restClient,
                           @Value("${ai-filter.url:http://ai-filter:8000/api/v1/classify}") String baseUrl) {
        this.restClient = restClient;
        this.baseUrl = baseUrl;
    }

    /**
     * Classifies SMS content against the AI Spam Model server.
     */
    public InterceptResponse classifySms(SMSInterceptRequest req) {
        try {
            var body = Map.of(
                "event_type", "SMS",
                "sender_msisdn", req.sender(),
                "recipient_msisdn", req.recipient(),
                "content_text", req.content(),
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            var result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            if (result != null) {
                return new InterceptResponse(result.allow(), result.reason());
            }
            return new InterceptResponse(true, "AI filter returned empty response — SLA allow");
        } catch (Exception e) {
            logger.warn("AI filter unreachable or timed out (>5s): {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }

    /**
     * Classifies Voice Call metadata against the AI Spam Model server.
     */
    public InterceptResponse classifyCall(CallInterceptRequest req) {
        try {
            var body = Map.of(
                "event_type", "VOICE_CALL",
                "caller_msisdn", req.caller(),
                "callee_msisdn", req.callee(),
                "call_id", req.callId() != null ? req.callId() : "",
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            var result = restClient.post()
                    .uri(baseUrl)
                    .body(body)
                    .retrieve()
                    .body(TranscriptionResult.class);

            if (result != null) {
                return new InterceptResponse(result.allow(), result.reason());
            }
            return new InterceptResponse(true, "AI filter returned empty response — SLA allow");
        } catch (Exception e) {
            logger.warn("AI filter unreachable or timed out (>5s): {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }
}
