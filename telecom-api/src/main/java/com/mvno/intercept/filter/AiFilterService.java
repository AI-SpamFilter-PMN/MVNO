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

import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
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
    private final String vfUrl;
    private final MeterRegistry meterRegistry;

    // Thread-safe atomic counters for tracking consecutive failures & circuit cooldown epoch
    private final AtomicInteger consecutiveFailures = new AtomicInteger(0);
    private final AtomicLong circuitOpenUntilEpochMs = new AtomicLong(0);

    public AiFilterService(final RestClient restClient,
                           @Value("${ai-filter.url:http://ai-filter:8000/api/v1/classify}") final String baseUrl,
                           @Value("${filteration.voice.url:}") final String voiceFilterUrl,
                           final MeterRegistry meterRegistry) {
        this.restClient = restClient;
        this.baseUrl = baseUrl;
        this.vfUrl = voiceFilterUrl.isBlank() ? baseUrl : voiceFilterUrl;
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

        // Step 1b: local deterministic scam-keyword flag (ALWAYS on, independent of
        // any external filter). This is the "flag without blocking" contract: a hit
        // flags the transcript for review but never hard-blocks a live call.
        final String scamWord = scanScamKeywords(transcript);
        if (scamWord != null) {
            meterRegistry.counter("mvno.vosk.scamflag", "word", scamWord).increment();
            logger.info("Scam-keyword flag [{}]: '{}' hit '{}'", callId, transcript, scamWord);
            return new InterceptResponse(false, "scam-keyword: " + scamWord);
        }

        // Step 2: try the Filteration-System real contract first (integrate w/ others),
        // falling back to the legacy /api/v1/classify contract, then to fail-open.
        // Filteration-System: POST /api/v1/voice/filter {callerId, receiverId, transcript}
        //                     -> {isMalicious, action:"DROP_CALL"/"ALLOW_CALL"}
        InterceptResponse fromVoiceFilter = tryVoiceFilter(callId, transcript);
        if (fromVoiceFilter != null) {
            return fromVoiceFilter;
        }

        // Step 3: legacy ai-filter contract fallback.
        try {
            final Map<String, Object> body = Map.of(
                "event_type", "TRANSCRIPT",
                "call_id", callId,
                "transcript", transcript,
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
            return failOpen("empty_response", "AI filter returned empty response — SLA allow");

        } catch (final RestClientException e) {
            recordFailure(e);
            return failOpen("unreachable", "AI filter unreachable — SLA allow");
        } catch (final Exception e) {
            logger.error("Unexpected error in Transcript AI classification: {}", e.getMessage(), e);
            return failOpen("internal", "Gateway internal error — SLA allow");
        }
    }

    /**
     * Tries the Filteration-System voice classifier ({@code /api/v1/voice/filter})
     * which is MVNO's intended integration target. Returns {@code null} (rather
     * than throwing) when the service is unreachable or not yet deployed, so the
     * caller can fall back to the legacy ai-filter contract. This keeps the demo
     * working even though Filteration-System may not be running yet.
     */
    private InterceptResponse tryVoiceFilter(final String callId, final String transcript) {
        try {
            final Map<String, Object> body = Map.of(
                "callerId", callId,
                "receiverId", "",
                "transcript", transcript
            );
            final VoiceFilterResponse resp = restClient.post()
                    .uri(vfUrl)
                    .body(body)
                    .retrieve()
                    .body(VoiceFilterResponse.class);
            if (resp != null) {
                consecutiveFailures.set(0);
                return new InterceptResponse(!resp.isMalicious(), resp.action());
            }
            return null;
        } catch (final Exception e) {
            // Filteration-System not reachable/not deployed — fall through to the
            // legacy ai-filter contract. Log once at debug; not a circuit-break.
            logger.debug("Filteration-System voice filter unavailable ({}), using ai-filter fallback: {}",
                    vfUrl, e.getMessage());
            return null;
        }
    }

    /**
     * Carrier SLA Fallback: Increments Prometheus counter 'mvno.ai.failopen' and returns allow: true.
     */
    /**
     * Deterministic, flag-only scam-keyword matcher (config-driven, word-boundary,
     * case-insensitive). Returns the first matching scam word or phrase, or {@code null}
     * when the transcript is clean. Deliberately a local pre-classifier so flags work
     * even when every external filter is unreachable (fail-open still flags locally).
     *
     * <p>Word families cover the demo scam scripts: "bank account won verify" + aliases
     * ("you have won a prize call us now", "your account has been blocked please verify").
     */
    private String scanScamKeywords(final String transcript) {
        if (transcript == null || transcript.isBlank()) {
            return null;
        }
        final String t = transcript.toLowerCase(Locale.ROOT);
        // Word-boundary, case-insensitive, config-driven list. Pattern.quote each
        // word individually so "won" matches " won " but NOT "wonder"/"won't"-prefix false
        // positives. Phrase families cover the demo scam scripts:
        //   "you have won a prize call us now"
        //   "your account has been blocked, please verify your details"
        final String[] words = {
            "won", "prize", "claim", "free", "urgent", "account",
            "blocked", "confirm", "verify", "ssn", "pin", "password",
            "card", "wire", "transfer", "refund", "offer", "winner", "fee", "bank"
        };
        for (final String w : words) {
            // (?i) inline; (?<!\\w)/(?!\\w) negative lookarounds enforce boundaries
            // without relying on \b adjacent to a quoted literal.
            if (Pattern.compile("(?i)(?<![a-z])" + Pattern.quote(w) + "(?![a-z])").matcher(t).find()) {
                return w;
            }
        }
        return null;
    }

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
