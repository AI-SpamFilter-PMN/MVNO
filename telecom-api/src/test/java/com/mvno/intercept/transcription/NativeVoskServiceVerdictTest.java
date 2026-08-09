package com.mvno.intercept.transcription;

import com.mvno.intercept.filter.AiFilterService;
import com.mvno.intercept.subscriber.InterceptResponse;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.web.client.RestClient;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Deterministic tests for the post-call transcript verdict wiring in NativeVoskService:
 * a fixed-verdict AiFilterService substitute drives classifyAndRecord() and asserts the
 * mvno.vosk.classified / mvno.vosk.blocked counters for both verdict branches.
 */
class NativeVoskServiceVerdictTest {

    /** Fake classifier returning a fixed verdict without any HTTP call. */
    private static final class FixedVerdictAiFilterService extends AiFilterService {
        private final boolean allow;
        private final String reason;

        FixedVerdictAiFilterService(final boolean allow, final String reason) {
            super(RestClient.create(), "http://127.0.0.1:1/api/v1/classify", new SimpleMeterRegistry());
            this.allow = allow;
            this.reason = reason;
        }

        @Override
        public InterceptResponse classifyTranscript(final String callId, final String transcript) {
            return new InterceptResponse(allow, reason);
        }
    }

    private NativeVoskService newService(final MeterRegistry reg, final boolean allow, final String reason) {
        return new NativeVoskService(
                "/nonexistent-spool", "/nonexistent-vosk-model",
                new FixedVerdictAiFilterService(allow, reason), reg);
    }

    @Test
    @DisplayName("Blocked transcript verdict increments classified + blocked + flagged")
    void blockedVerdictIncrementsBlockedCounter() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        final NativeVoskService service = newService(reg, false, "Spam (phishing phrase detected)");

        service.classifyAndRecord("call-1785097956%40127.0.0.1-abc123.wav",
                "claim your free prize now");

        assertEquals(1.0, reg.get("mvno.vosk.classified").counter().count());
        assertEquals(1.0, reg.get("mvno.vosk.blocked").counter().count());
        // Flag-for-review semantics: every blocked verdict is also a review flag
        assertEquals(1.0, reg.get("mvno.vosk.flagged").counter().count());
    }

    @Test
    @DisplayName("Allowed transcript verdict increments classified but never blocked/flagged")
    void allowedVerdictDoesNotIncrementBlocked() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        final NativeVoskService service = newService(reg, true, "Clean content");

        service.classifyAndRecord("call-1785097956%40127.0.0.1-def456.wav",
                "hello, how are you today");

        assertEquals(1.0, reg.get("mvno.vosk.classified").counter().count());
        assertEquals(0.0, reg.get("mvno.vosk.blocked").counter().count());
        assertEquals(0.0, reg.get("mvno.vosk.flagged").counter().count());
    }

    @Test
    @DisplayName("Blank transcript is skipped — no classification counters")
    void blankTranscriptIsSkipped() {
        final MeterRegistry reg = new SimpleMeterRegistry();
        final NativeVoskService service = newService(reg, false, "irrelevant");

        service.classifyAndRecord("call-1785097956%40127.0.0.1-ghi789.wav", "  ");

        assertEquals(0.0, reg.get("mvno.vosk.classified").counter().count());
        assertEquals(0.0, reg.get("mvno.vosk.blocked").counter().count());
        assertEquals(0.0, reg.get("mvno.vosk.flagged").counter().count());
    }
}
