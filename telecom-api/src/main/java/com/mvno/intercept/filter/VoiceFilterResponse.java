package com.mvno.intercept.filter;

/**
 * Integration DTO for the Filteration-System voice classifier contract.
 *
 * <p>Maps the external {@code Filteration-System} response shape
 * {@code { "isMalicious": boolean, "action": "DROP_CALL"|"ALLOW_CALL" }}
 * into MVNO's internal {@code InterceptResponse} worldview.
 *
 * @param isMalicious True if the external decider flagged the call as malicious.
 * @param action       External action token (DROP_CALL / ALLOW_CALL).
 */
public record VoiceFilterResponse(
    boolean isMalicious,
    String action
) {}