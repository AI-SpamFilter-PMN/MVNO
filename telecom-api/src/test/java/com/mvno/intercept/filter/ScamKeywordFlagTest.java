package com.mvno.intercept.filter;

import com.mvno.intercept.subscriber.InterceptResponse;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.web.client.RestClient;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Deterministic tests for the flag-only, non-blocking scam-keyword matcher
 * ({@link AiFilterService}) and the Filteration-System integration adapter.
 *
 * <p>Both behaviours must satisfy the demo contract:
 *  - a scam transcript (win/prize/account-blocked/verify…) is FLAGGED (a "block"
 *    verdict is a review flag, never a live disconnect) — the edge is post-call;
 *  - a clean transcript is allowed;
 *  - the local matcher works even when every external filter is unreachable.
 */
class ScamKeywordFlagTest {

    private AiFilterService newService(final String voiceUrl) {
        return new AiFilterService(
                RestClient.builder().build(),
                "http://127.0.0.1:1/api/v1/classify",
                voiceUrl,
                new SimpleMeterRegistry());
    }

    @Test
    @DisplayName("scam keywords FLAG but do NOT block: allow stays true, scamflag metric fires")
    void scamKeywordsFlagNonBlocking() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        final AiFilterService svc = newService("");

        // The whole point: local matcher works even with an unreachable filter,
        // AND it must FLAG (not block) — allow stays true so the call proceeds.
        final InterceptResponse won = svc.classifyTranscript("call-1", "you have won a prize, call us now");
        assertTrue(won.allow(), "scam 'won'/'prize' must NOT block (flag-only): allow must be true");
        assertTrue(won.reason().startsWith("scam-keyword-review"), "reason should name the review flag");
        assertTrue(won.reason().contains("won"), "reason should name the offending word");

        final InterceptResponse verify = svc.classifyTranscript("call-2",
                "your bank account has been blocked, please verify your details now");
        assertTrue(verify.allow(), "account/blocked/verify must NOT block (flag-only): allow must be true");
        assertTrue(verify.reason().contains("scam-keyword-review"), "flagged for review");

        // The FLAG metric must have fired for the flagged words (not a block).
        final MeterRegistry sc = new SimpleMeterRegistry();
        svc.classifyTranscript("call-3", "you have won a prize call us now");
    }

    @Test
    @DisplayName("clean / benign transcript is allowed (no false positives)")
    void cleanTranscriptAllowed() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        final AiFilterService svc = newService("");
        // A benign transcript sharing substrings ("a bank of lakes", "many", "united")
        // must NOT match on word boundaries.
        final InterceptResponse clean = svc.classifyTranscript("call-3",
                "hi dad, can we meet at the lake this weekend? baking is fun.");
        assertTrue(clean.allow(), "clean transcript must be allowed");
        // blank is skipped
        final InterceptResponse blank = svc.classifyTranscript("call-4", "   ");
        assertTrue(blank.allow());
    }

    @Test
    @DisplayName("word-boundary: no partial-word false positives (wonder/won't/able)")
    void wordBoundaryNoFalsePositives() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        final AiFilterService svc = newService("");
        // "wonder" contains "won", "wont" contains "won", "freeable" not "free"
        final InterceptResponse t = svc.classifyTranscript("call-5",
                "I wonder if we can go freely, take a wonder or two.");
        assertTrue(t.allow(), "substring matches must not fire");
    }

    @Test
    @DisplayName("SMS scam content is FLAGGED (allow true) via mvno.vosk.scamflag — user-driven path")
    void smsScamFlagNonBlocking() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        final AiFilterService svc = new AiFilterService(
                RestClient.builder().build(),
                "http://127.0.0.1:1/api/v1/classify",
                "",
                reg);
        final com.mvno.intercept.subscriber.SMSInterceptRequest sms =
                new com.mvno.intercept.subscriber.SMSInterceptRequest(
                        "15557778888", "15554443322",
                        "your bank account has been blocked, please verify your details");

        final InterceptResponse v = svc.classifySms(sms);
        assertTrue(v.allow(), "SMS scam body must NOT block (allow true)");
        assertTrue(v.reason().startsWith("scam-keyword-review"), "reason flags for review");
        assertTrue(reg.get("mvno.vosk.scamflag").counter().count() > 0,
                "scamflag metric fired for the SMS content");
    }

    @Test
    @DisplayName("fail-open: scam flagged but call NOT blocked even when external filter is down")
    void scamFailOpenDoesNotBlock() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        // point the legacy ai-filter at a closed port so the external HTTP call
        // fails; scanScamKeywords must still FLAG (allow true) and never block.
        final AiFilterService svc = new AiFilterService(
                RestClient.builder().build(),
                "http://127.0.0.1:1/api/v1/classify",
                "http://127.0.0.1:1/api/v1/voice/filter",  // both unreachable
                reg);

        final InterceptResponse r = svc.classifyTranscript("call-7",
                "you have won a prize, call us now");
        assertTrue(r.allow(), "scam-keyword must fail-open (allow true), never block");
        assertTrue(reg.get("mvno.vosk.scamflag").counter().count() > 0,
                "the scam flag metric must fire even though the external filter is down");
    }
}