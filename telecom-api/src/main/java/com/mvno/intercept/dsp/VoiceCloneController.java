package com.mvno.intercept.dsp;

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

    public VoiceCloneController(final VoiceCloneDetector voiceCloneDetector) {
        this.voiceCloneDetector = voiceCloneDetector;
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

        final VoiceCloneDetector.VoiceAnalysisResult result = voiceCloneDetector.analyzePcm(pcmBytes, sampleRate);
        return ResponseEntity.ok(result);
    }
}
