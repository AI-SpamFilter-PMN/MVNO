package com.mvno.intercept.subscriber;

/**
 * <h1>Interception Policy Response DTO Record</h1>
 * 
 * <p>Immutable Java 21 Record representing policy decisions returned by the Spring Boot gateway to Kamailio
 * and OsmoSMSC in response to HTTP interception queries.</p>
 * 
 * <h2>JSON Output Schema</h2>
 * <pre>{@code
 * {
 *   "allow": true,
 *   "reason": "Subscriber balance valid and AI approved"
 * }
 * }</pre>
 * 
 * @param allow Boolean decision flag ({@code true} to forward call/SMS, {@code false} to reject/drop).
 * @param reason Human-readable diagnostic reason string (e.g. "Prepaid balance exhausted", "EIR: SIM swap detected").
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public record InterceptResponse(
    boolean allow,
    String reason
) {}
