package com.mvno.intercept.filter;

/**
 * <h1>AI Classification Result DTO Record</h1>
 * 
 * <p>Immutable Java 21 Record mapping JSON response payloads received from the external AI Spam Model server
 * ({@code POST http://ai-filter:8000/api/v1/classify}).</p>
 * 
 * <h2>JSON Response Mapping Schema</h2>
 * <pre>{@code
 * {
 *   "allow": true,
 *   "reason": "Clean message content"
 * }
 * }</pre>
 * 
 * @param allow Boolean flag indicating whether the message/call is permitted ({@code true}) or blocked ({@code false}).
 * @param reason Human-readable diagnostic description of the classification decision (e.g. "Spam content detected").
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public record TranscriptionResult(
    boolean allow,
    String reason
) {}
