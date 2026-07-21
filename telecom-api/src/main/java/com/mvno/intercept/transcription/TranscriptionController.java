package com.mvno.intercept.transcription;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.Map;

/**
 * ==============================================================================
 * Vosk STT Speech Transcription Receiver Controller
 * ==============================================================================
 * Receives offline speech-to-text transcriptions, DTMF keypress events, and voice
 * biometrics (silence ratio, spectral flatness) from the background vosk-worker container.
 */
@RestController
@RequestMapping("/api/v1/transcriptions")
public class TranscriptionController {

    @PostMapping
    public ResponseEntity<Map<String, String>> receiveTranscription(@RequestBody TranscriptionRequest req) {
        // Logs and processes post-call transcription analytics
        return ResponseEntity.ok(Map.of("status", "received"));
    }

    public record TranscriptionRequest(
        String callId,
        String audioFile,
        String transcript,
        BiometricsData biometrics,
        List<DtmfEvent> dtmfEvents
    ) {}

    public record BiometricsData(
        double silenceRatio,
        double spectralFlatness,
        double durationSeconds
    ) {}

    public record DtmfEvent(
        int digit,
        long timestamp
    ) {}
}
