package com.mvno.intercept.transcription;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

/**
 * Speech-to-Text Transcription & Analytics REST Receiver Controller
 * 
 * Exposes REST endpoints receiving post-call speech transcripts, acoustic biometrics,
 * and DTMF keypress events.
 * 
 * Acoustic Biometrics Metrics:
 * - Silence Ratio: Evaluates pre-recorded robocall audio pauses vs human speech patterns.
 * - Spectral Flatness: Frequency distribution flatness via numpy FFT flagging synthetic TTS voice deepfakes.
 * - DTMF Keypresses: Tracks touch-tone digit sequences pressed during calls.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@RestController
@RequestMapping("/api/v1/transcriptions")
public class TranscriptionController {

    private static final Logger logger = LoggerFactory.getLogger(TranscriptionController.class);

    /**
     * Receives and processes post-call speech transcription and acoustic biometrics payloads.
     * 
     * @param req TranscriptionRequest payload record containing text, biometrics, and DTMF data.
     * @return ResponseEntity JSON status acknowledgement ("status": "received").
     */
    @PostMapping
    public ResponseEntity<Map<String, String>> receiveTranscription(@RequestBody final TranscriptionRequest req) {
        if (req == null || req.transcript() == null || req.transcript().isBlank()) {
            logger.warn("Received empty or missing speech transcript payload for callId: {}", req != null ? req.callId() : "null");
        } else {
            // Truncate transcript snippet for clean log formatting
            final String snippet = req.transcript().length() > 50 ? req.transcript().substring(0, 50) + "..." : req.transcript();
            logger.info("Received transcription payload for callId [{}]: snippet='{}', biometrics={}", req.callId(), snippet, req.biometrics());
        }
        return ResponseEntity.ok(Map.of("status", "received"));
    }

    /**
     * DTO Record representing the post-call analytics payload.
     */
    public record TranscriptionRequest(
        String callId,           // Unique SIP Call-ID string
        String audioFile,        // Original WAV audio filename in spool directory
        String transcript,       // Full Speech-to-Text transcribed string
        BiometricsData biometrics, // Acoustic biometrics metadata (silence ratio, spectral flatness)
        List<DtmfEvent> dtmfEvents // Keypress touch-tone events captured during call
    ) {}

    /**
     * DTO Record representing acoustic biometrics for robocall & synthetic voice deepfake detection.
     */
    public record BiometricsData(
        double silenceRatio,    // Silence ratio (pauses vs speech) to detect robocall bots
        double spectralFlatness,// Spectral flatness via FFT to flag synthetic TTS voice deepfakes
        double durationSeconds  // Total audio call duration in seconds
    ) {}

    /**
     * DTO Record representing in-band touch-tone keypress events.
     */
    public record DtmfEvent(
        int digit,        // Touch-tone key pressed (0-9, *, #)
        long timestamp    // Relative timestamp epoch ms when keypress occurred
    ) {}
}
