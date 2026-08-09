package com.mvno.intercept.filter;

import com.mvno.intercept.subscriber.InterceptResponse;
import com.sun.net.httpserver.HttpServer;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.web.client.RestClient;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Unit-tests the Filteration-System integration contract fix using a real
 * lightweight on-JVM HTTP server to capture the exact request body.
 *
 * The real contract for {@code POST /api/v1/voice/filter} is
 * {@code {callerId: <MSISDN>, receiverId: <MSISDN>, transcript}}.
 *
 * Proves that when the calling/callee MSISDNs ARE bound at the call site, the
 * body carries the REAL subscriber MSISDNs (callerId=caller MSISDN,
 * receiverId=callee MSISDN) — NOT the recording hash and NOT a fabricated
 * empty receiverId.
 */
class FilterationVoiceBodyTest {

    private HttpServer server;
    private final AtomicReference<String> capturedBody = new AtomicReference<>();
    private final AtomicReference<String> capturedPath = new AtomicReference<>();
    private String voiceFilterUrl;
    private String legacyUrl;
    private final AtomicReference<String> response = new AtomicReference<>(
            "{\"isMalicious\":false,\"action\":\"ALLOW_CALL\"}");

    @BeforeEach
    void startServer() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/api/v1/voice/filter", exchange -> {
            capturedPath.set(exchange.getRequestURI().getPath());
            capturedBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] resp = response.get().getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, resp.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(resp);
            }
        });
        // Legacy ai-filter contract fallback -> respond ALLOW (only reached if voice filter fails)
        server.createContext("/api/v1/classify", exchange -> {
            byte[] resp = "{\"allow\":true,\"reason\":\"legacy allow\"}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, resp.length);
            try (OutputStream os = exchange.getResponseBody()) {
                os.write(resp);
            }
        });
        server.start();
        final int port = server.getAddress().getPort();
        voiceFilterUrl = "http://127.0.0.1:" + port + "/api/v1/voice/filter";
        legacyUrl = "http://127.0.0.1:" + port + "/api/v1/classify";
    }

    @AfterEach
    void stopServer() {
        if (server != null) {
            server.stop(0);
        }
    }

    private AiFilterService service(final String vf) {
        return new AiFilterService(RestClient.builder().baseUrl(legacyUrl).build(), legacyUrl, vf,
                new SimpleMeterRegistry());
    }

    @Test
    @DisplayName("tryVoiceFilter sends {callerId:MSISDN, receiverId:MSISDN, transcript} when identities are bound")
    void sendsRealMsisdnsInVoiceFilterBody() throws Exception {
        final AiFilterService svc = service(voiceFilterUrl);

        final InterceptResponse r = svc.classifyTranscript(
                "call-1785097956%127.0.0.1-abc123",   // recording id (hash) — must NOT leak
                "hello, how is the weather today",     // clean transcript (no scam keyword)
                "15551234567",                         // caller MSISDN
                "15557654321");                        // callee MSISDN

        assertNotNull(r, "reachable Filteration-System must yield a verdict");
        assertTrue(r.allow(), "ALLOW_CALL -> allow must be true");
        assertEquals("/api/v1/voice/filter", capturedPath.get(),
                "the voice-filter endpoint must be targeted");

        final String body = capturedBody.get();
        assertNotNull(body, "the voice filter must have received a body");
        assertTrue(body.contains("\"callerId\":\"15551234567\""),
                "callerId must be the CALLING MSISDN, got: " + body);
        assertTrue(body.contains("\"receiverId\":\"15557654321\""),
                "receiverId must be the CALLED MSISDN, got: " + body);
        assertTrue(body.contains("\"transcript\":\"hello, how is the weather today\""),
                "transcript must be present, got: " + body);
        assertFalse(body.contains("call-1785097956"),
                "the recording hash must never be sent as callerId, got: " + body);
    }

    @Test
    @DisplayName("spool-only path (no MSISDN) sends empty identities, never a fabricated hash")
    void spoolOnlyPathDoesNotFabricateIdentities() {
        final AiFilterService svc = service(voiceFilterUrl);

        // The two-arg classifyTranscript has no MSISDN (rtpengine spool names carry
        // none). It must pass EMPTY callerId/receiverId (honest absence) — NOT the
        // recording id as a fake callerId.
        final InterceptResponse r = svc.classifyTranscript(
                "call-1785097956%127.0.0.1-abc123",
                "hello, how is the weather today");

        assertNotNull(r);
        final String body = capturedBody.get();
        assertNotNull(body, "spool-only path still consults the voice filter");
        assertTrue(body.contains("\"callerId\":\"\""),
                "callerId must be empty when unknown (not a hash), got: " + body);
        assertTrue(body.contains("\"receiverId\":\"\""),
                "receiverId must be empty when unknown, got: " + body);
        assertFalse(body.contains("call-1785097956"),
                "the recording hash must never leak into callerId, got: " + body);
    }

    @Test
    @DisplayName("malicious Filteration-System verdict maps to blocked (allow=false)")
    void maliciousVerdictBlocks() {
        response.set("{\"isMalicious\":true,\"action\":\"DROP_CALL\"}");
        final InterceptResponse r = service(voiceFilterUrl).classifyTranscript(
                "call-x", "some content", "15551234567", "15557654321");
        assertNotNull(r);
        assertFalse(r.allow(), "DROP_CALL verdict must block (allow=false)");
        assertEquals("DROP_CALL", r.reason());
    }

    @Test
    @DisplayName("scam-flagged transcript is still forwarded to Filteration-System, whose DROP_CALL decides")
    void scamFlagIsForwardedToDeciderAndDeciderWins() {
        response.set("{\"isMalicious\":true,\"action\":\"DROP_CALL\"}");

        // A scam transcript ("you have won a prize, call us now") must be FLAGGED
        // by the local matcher but still forwarded to the Filteration-System, which
        // is the authority that decides who gets blocked. Its DROP_CALL must win.
        final InterceptResponse r = service(voiceFilterUrl).classifyTranscript(
                "call-flag-1",
                "you have won a prize, call us now", // scam keyword -> flag, forward
                "15551234567",
                "15557654321");

        assertNotNull(r);
        assertEquals("/api/v1/voice/filter", capturedPath.get(),
                "the scam-flagged transcript MUST reach the Filteration-System decider");
        assertFalse(r.allow(), "decider's DROP_CALL must block (allow=false)");
        assertEquals("DROP_CALL", r.reason(), "decider verdict is authoritative for flagged calls");
    }

    @Test
    @DisplayName("unreachable Filteration-System falls back to fail-open, never blocks a live call")
    void unreachableFallsBackToLegacyContract() throws Exception {
        // Point voice-filter at a closed port: tryVoiceFilter null + legacy ai-filter
        // (also on closed port) fails -> fail-open allow=true, never blocks the call.
        final Path tmp = Files.createTempFile("closed", ".sock");
        tmp.toFile().deleteOnExit();
        final String closedVoice = "http://127.0.0.1:1/api/v1/voice/filter";
        final AiFilterService svc = new AiFilterService(
                RestClient.builder().build(), "http://127.0.0.1:1/api/v1/classify",
                closedVoice, new SimpleMeterRegistry());

        final InterceptResponse r = svc.classifyTranscript("call-y", "some transcript",
                "15551234567", "15557654321");
        assertNotNull(r);
        assertTrue(r.allow(), "both filters down must fail-open (SLA allow), never block a live call");
    }
}