package com.mvno.intercept.dsp;

import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Base64;
import java.util.Map;

/**
 * AI Voice Clone & Synthetic Audio DSP REST Controller
 */
@RestController
@RequestMapping("/api/v1/intercept/dsp")
public class VoiceCloneController {

    private final VoiceCloneDetector voiceCloneDetector;
    private final MeterRegistry meterRegistry;

    public VoiceCloneController(final VoiceCloneDetector voiceCloneDetector, final MeterRegistry meterRegistry) {
        this.voiceCloneDetector = voiceCloneDetector;
        this.meterRegistry = meterRegistry;
    }

    @PostMapping("/voice-clone")
    public ResponseEntity<VoiceCloneDetector.VoiceAnalysisResult> analyzeVoice(
            @RequestBody final Map<String, Object> req) {
        final String base64Pcm = (String) req.getOrDefault("pcm_base64", "");
        final int sampleRate = (int) req.getOrDefault("sample_rate", 8000);

        byte[] pcmBytes = new byte[0];
        if (!base64Pcm.isBlank()) {
            try {
                pcmBytes = Base64.getDecoder().decode(base64Pcm);
            } catch (final Exception ignored) {}
        }

        final String msisdn = (String) req.getOrDefault("msisdn", req.getOrDefault("caller", "unknown"));
        final String imei = (String) req.getOrDefault("imei", "unknown");

        final VoiceCloneDetector.VoiceAnalysisResult result = voiceCloneDetector.analyzePcm(pcmBytes, sampleRate);
        meterRegistry.counter("mvno.voice.clone.flagged", "classification", result.classification()).increment();
        meterRegistry.counter("mvno.dsp.robotic_flagged",
            "verdict", result.classification(),
            "msisdn", msisdn,
            "imei", imei
        ).increment();
        return ResponseEntity.ok(result);
    }
}
