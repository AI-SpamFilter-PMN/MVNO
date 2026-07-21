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
 * AI Spam Model Integration & SLA Fallback Proxy Service.
 * 
 * ARCHITECTURE BOUNDARY:
 * Proxies incoming SMS and Voice Call interception events to the external AI Spam Model server
 * (`POST http://ai-filter:8000/api/v1/classify`) built by teammates Ahmed Omar & Mahmoud Salah.
 * 
 * RESILIENCE & SLA CARRIER RULE:
 * In telecommunications, a failure in a secondary AI filtering subsystem must NEVER cause a carrier
 * outage or drop legitimate subscriber phone calls/SMS. If the AI model server is offline, returns an HTTP
 * error, or exceeds the 5-second socket timeout window, the try/catch block intercepts the exception and
 * gracefully returns a **Fail-Open decision (`allow: true`)**.
 */
// `@Service` marks this business logic class as a Spring-managed service bean in the ApplicationContext.
@Service
public class AiFilterService {

    private static final Logger logger = LoggerFactory.getLogger(AiFilterService.class);
    private final RestClient restClient;
    private final String baseUrl;

    // `@Value` injects the configured property value directly into the constructor parameter with a fallback default.
    public AiFilterService(RestClient restClient,
                           @Value("${ai-filter.url:http://ai-filter:8000/api/v1/classify}") String baseUrl) {
        this.restClient = restClient;
        this.baseUrl = baseUrl;
    }

    /**
     * Constructs the classification payload for an SMS event and proxies it to the AI Spam Filter server.
     * 
     * @param req Incoming SMS interception request DTO.
     * @return InterceptResponse indicating whether the SMS is allowed or blocked.
     */
    public InterceptResponse classifySms(SMSInterceptRequest req) {
        try {
            // Immutable Map.of() constructs the JSON body matching docs/API_CONTRACT.md schema
            var body = Map.of(
                "event_type", "SMS",
                "sender_msisdn", req.sender(),
                "recipient_msisdn", req.recipient(),
                "content_text", req.content(),
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            // Execute POST request over HTTP bridge network to ai-filter:8000
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
            // Catch connection failure, 5xx server error, or 5s socket timeout
            logger.warn("AI filter unreachable or timed out (>5s): {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }

    /**
     * Constructs the classification payload for a Voice Call event and proxies it to the AI Spam Filter server.
     * 
     * @param req Incoming Call interception request DTO.
     * @return InterceptResponse indicating whether call setup is allowed or blocked.
     */
    public InterceptResponse classifyCall(CallInterceptRequest req) {
        try {
            // Immutable Map.of() constructs the call metadata JSON body matching docs/API_CONTRACT.md schema
            var body = Map.of(
                "event_type", "VOICE_CALL",
                "caller_msisdn", req.caller(),
                "callee_msisdn", req.callee(),
                "call_id", req.callId() != null ? req.callId() : "",
                "timestamp_epoch_ms", System.currentTimeMillis()
            );

            // Execute POST request over HTTP bridge network to ai-filter:8000
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
            // Catch connection failure, 5xx server error, or 5s socket timeout
            logger.warn("AI filter unreachable or timed out (>5s): {}. Falling back to SLA allow.", e.getMessage());
            return new InterceptResponse(true, "AI filter unreachable — SLA allow");
        }
    }
}
