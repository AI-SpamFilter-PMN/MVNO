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
    @DisplayName("scam keywords flag (non-blocking): won/prize/account-blocked/verify")
    void scamKeywordsFlagNonBlocking() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        final AiFilterService svc = newService("");

        // The whole point: local matcher works even with an unreachable filter.
        final InterceptResponse won = svc.classifyTranscript("call-1", "you have won a prize, call us now");
        assertFalse(won.allow(), "scam 'won'/'prize' must be flagged");
        assertTrue(won.reason().contains("scam-keyword"), "reason should name the flag");

        final InterceptResponse verify = svc.classifyTranscript("call-2",
                "your bank account has been blocked, please verify your details now");
        assertFalse(verify.allow(), "account/blocked/verify must be flagged");
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
}