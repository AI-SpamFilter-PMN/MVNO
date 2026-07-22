package com.mvno.intercept.filter;

/**
 * AI Classification Result DTO Record
 * 
 * Immutable Record mapping JSON response payloads received from the AI Spam Model server:
 * { "allow": true, "reason": "Clean message content" }
 * 
 * @param allow True if allowed, false if blocked.
 * @param reason Diagnostic description of decision.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public record TranscriptionResult(
    boolean allow,
    String reason
) {}
