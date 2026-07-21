package com.mvno.intercept.transcription;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.Map;

/**
 * Speech-to-Text Transcription Analytics Receiver Controller.
 * 
 * INTERFACE BOUNDARY:
 * Receives post-call speech transcription payloads, DTMF keypress events, and voice biometrics
 * generated during call processing.
 * 
 * DATA MODEL RATIONALE:
 * Java 17+ / 21 Records (`TranscriptionRequest`, `BiometricsData`, `DtmfEvent`) are used instead of traditional
 * mutable JavaBeans. Records provide immutable, thread-safe value semantics, automatic `equals()`, `hashCode()`,
 * and `toString()` implementations, and clean Jackson JSON deserialization.
 */
@RestController
@RequestMapping("/api/v1/transcriptions")
public class TranscriptionController {

    /**
     * Receives and logs post-call speech transcription and acoustic biometrics payloads.
     * 
     * @param req Request DTO containing SIP Call-ID, speech transcript, acoustic biometrics, and DTMF events.
     * @return HTTP 200 OK status confirmation map.
     */
    @PostMapping
    public ResponseEntity<Map<String, String>> receiveTranscription(@RequestBody TranscriptionRequest req) {
        return ResponseEntity.ok(Map.of("status", "received"));
    }

    /** Post-call transcription request payload record. */
    public record TranscriptionRequest(
        String callId,
        String audioFile,
        String transcript,
        BiometricsData biometrics,
        List<DtmfEvent> dtmfEvents
    ) {}

    /** Acoustic voice biometrics record (Silence ratio for robocall detection, Spectral flatness for TTS synthetic voice detection). */
    public record BiometricsData(
        double silenceRatio,
        double spectralFlatness,
        double durationSeconds
    ) {}

    /** DTMF touch-tone keypress event record. */
    public record DtmfEvent(
        int digit,
        long timestamp
    ) {}
}
