package com.mvno.intercept.subscriber;

/**
 * Interception Policy Response DTO Record
 * 
 * Policy decision JSON returned to Kamailio and OsmoSMSC:
 * { "allow": true, "reason": "Prepaid balance valid" }
 * 
 * @param allow Decision flag (true to forward, false to drop).
 * @param reason Diagnostic description string.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public record InterceptResponse(
    boolean allow,
    String reason
) {}
