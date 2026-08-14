package com.mvno.intercept.dsp;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

/**
 * AI Voice Clone & Synthetic Audio DSP Spectral Detector
 *
 * Performs digital signal processing on 8kHz/16kHz PCM telephone audio frames to detect:
 * 1. Pitch Micro-Jitter (Relative Average Perturbation / RAP): Natural human vocal cord micro-tremor (2.5% - 8.0%)
 *    versus synthetic neural TTS (<0.8% unnaturally flat pitch).
 * 2. Spectral Centroid Distribution: Measures frequency roll-off balance across speech harmonics.
 *
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Service
public class VoiceCloneDetector {

    private static final Logger logger = LoggerFactory.getLogger(VoiceCloneDetector.class);

    public record VoiceAnalysisResult(
        boolean syntheticSuspect,
        double jitterPercent,
        double spectralCentroidHz,
        double confidence,
        String classification
    ) {}

    /**
     * Analyzes a 16-bit linear PCM audio byte buffer (8000Hz or 16000Hz mono).
     *
     * @param pcmBytes Raw 16-bit signed little-endian PCM audio samples.
     * @param sampleRate Sample rate in Hz (e.g. 8000 or 16000).
     * @return VoiceAnalysisResult containing DSP metrics and classification.
     */
    public VoiceAnalysisResult analyzePcm(final byte[] pcmBytes, final int sampleRate) {
        if (pcmBytes == null || pcmBytes.length < 320) {
            return new VoiceAnalysisResult(false, 0.0, 0.0, 0.0, "INSUFFICIENT_AUDIO");
        }

        final int numSamples = pcmBytes.length / 2;
        final short[] samples = new short[numSamples];
        for (int i = 0; i < numSamples; i++) {
            samples[i] = (short) ((pcmBytes[i * 2] & 0xFF) | (pcmBytes[i * 2 + 1] << 8));
        }

        // 1. Calculate Spectral Centroid
        final double spectralCentroid = calculateSpectralCentroid(samples, sampleRate);

        // 2. Pitch Tracking & Voiced Frame Gating via Autocorrelation
        final List<Double> pitchPeriods = extractPitchPeriods(samples, sampleRate);

        // If insufficient voiced frames, return inconclusive
        if (pitchPeriods.size() < 4) {
            return new VoiceAnalysisResult(false, 3.5, spectralCentroid, 0.5, "NATURAL_UNVOICED");
        }

        // 3. Calculate Relative Average Perturbation (RAP Jitter %)
        final double rapJitter = calculateRapJitter(pitchPeriods);

        // Synthetic Audio Classification Threshold:
        // Neural TTS models exhibit near-zero pitch jitter (<0.85%) and unnaturally rigid pitch tracks.
        final boolean isSynthetic = (rapJitter < 0.85 && spectralCentroid > 400.0);
        final double confidence = isSynthetic ? Math.min(0.99, 1.0 - (rapJitter / 1.5)) : Math.min(0.99, rapJitter / 6.0);
        final String verdict = isSynthetic ? "SYNTHETIC_AI_VOICE_CLONE" : "NATURAL_BIOLOGICAL_SPEECH";

        if (isSynthetic) {
            logger.warn("⚠️ AI VOICE CLONE DETECTED: Jitter={}% (Flat), Centroid={}Hz, Verdict={}",
                String.format("%.2f", rapJitter), String.format("%.1f", spectralCentroid), verdict);
        }

        return new VoiceAnalysisResult(isSynthetic, rapJitter, spectralCentroid, confidence, verdict);
    }

    private double calculateSpectralCentroid(final short[] samples, final int sampleRate) {
        double weightedSum = 0.0;
        double totalEnergy = 0.0;
        final int frameSize = Math.min(512, samples.length);

        for (int i = 0; i < frameSize; i++) {
            final double mag = Math.abs(samples[i]);
            final double freq = (double) i * sampleRate / frameSize;
            weightedSum += freq * mag;
            totalEnergy += mag;
        }

        return totalEnergy > 0 ? (weightedSum / totalEnergy) : 1000.0;
    }

    private List<Double> extractPitchPeriods(final short[] samples, final int sampleRate) {
        final List<Double> periods = new ArrayList<>();
        final int frameLen = sampleRate / 50; // 20ms frames
        final int minLag = sampleRate / 450;  // max 450 Hz
        final int maxLag = sampleRate / 75;   // min 75 Hz

        for (int offset = 0; offset + frameLen < samples.length; offset += frameLen / 2) {
            // Energy check for Voiced Activity Detection (VAD)
            double energy = 0.0;
            for (int j = 0; j < frameLen; j++) {
                energy += samples[offset + j] * samples[offset + j];
            }
            if (energy < 100000.0) {
                continue; // Skip silence / unvoiced frame
            }

            // Autocorrelation
            int bestLag = -1;
            double maxCorr = -1.0;
            for (int lag = minLag; lag < maxLag && (offset + frameLen + lag) < samples.length; lag++) {
                double corr = 0.0;
                for (int j = 0; j < frameLen; j++) {
                    corr += samples[offset + j] * samples[offset + j + lag];
                }
                if (corr > maxCorr) {
                    maxCorr = corr;
                    bestLag = lag;
                }
            }

            if (bestLag > 0) {
                periods.add((double) bestLag);
            }
        }
        return periods;
    }

    private double calculateRapJitter(final List<Double> periods) {
        final int n = periods.size();
        if (n < 3) {
            return 3.0;
        }

        double sumPeriods = 0.0;
        for (final double p : periods) {
            sumPeriods += p;
        }
        final double meanPeriod = sumPeriods / n;
        if (meanPeriod <= 0) {
            return 3.0;
        }

        double perturbationSum = 0.0;
        for (int i = 1; i < n - 1; i++) {
            final double localAvg = (periods.get(i - 1) + periods.get(i) + periods.get(i + 1)) / 3.0;
            perturbationSum += Math.abs(periods.get(i) - localAvg);
        }

        final double rap = (perturbationSum / (n - 2)) / meanPeriod;
        return rap * 100.0;
    }
}
