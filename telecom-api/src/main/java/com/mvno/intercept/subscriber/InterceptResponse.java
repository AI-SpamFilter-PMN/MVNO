package com.mvno.intercept.subscriber;

import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Interception Policy Response DTO Record
 * 
 * Policy decision JSON returned to Kamailio and OsmoSMSC:
 * { "allow": true, "reason": "Prepaid balance valid" }
 * 
 * @param allow Decision flag (true to forward, false to drop).
 * @param reason Diagnostic description string.
 * @param voiceAuthenticity Optional DSP voice authenticity advisory payload.
 * 
 * @author MVNO Core Engineering Team
 * @version 2.0.0
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record InterceptResponse(
    boolean allow,
    String reason,
    @JsonProperty("voice_authenticity")
    VoiceAuthenticityDto voiceAuthenticity
) {
    public InterceptResponse(boolean allow, String reason) {
        this(allow, reason, null);
    }

    public record VoiceAuthenticityDto(
        String classification,
        @JsonProperty("advisory_only")
        boolean advisoryOnly,
        @JsonProperty("dsp_metrics")
        DspMetricsDto dspMetrics
    ) {}

    public record DspMetricsDto(
        @JsonProperty("jitter_pct")
        double jitterPct,
        @JsonProperty("spectral_centroid_hz")
        double spectralCentroidHz,
        @JsonProperty("spectral_flatness")
        double spectralFlatness,
        @JsonProperty("pitch_std_dev")
        double pitchStdDev
    ) {}
}
