package com.mvno.intercept.filter;

/**
 * DTO Record representing the response from the AI Spam Filter team's model server (http://ai-filter:8000).
 * 
 * @param isSpam True if text/call is classified as spam or phishing.
 * @param confidenceScore ML model confidence score (0.0 to 1.0).
 * @param riskCategory Classification tag ("PHISHING", "SMISHING", "SPAM", "VOIP_FRAUD", "HAM").
 * @param action Interception decision ("BLOCK", "ALLOW", "FLAG").
 * @param reason Human-readable explanation for NOC audit logging.
 */
public record TranscriptionResult(
    boolean isSpam,
    double confidenceScore,
    String riskCategory,
    String action,
    String reason
) {
    public boolean allow() {
        return !"BLOCK".equalsIgnoreCase(action) && !isSpam;
    }
}
