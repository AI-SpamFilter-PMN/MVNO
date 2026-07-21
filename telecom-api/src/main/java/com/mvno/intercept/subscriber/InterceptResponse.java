package com.mvno.intercept.subscriber;

/**
 * DTO Record representing the final interception policy response returned to Kamailio or OsmoSMSC.
 * 
 * @param allow True if the call/SMS is permitted; false if blocked.
 * @param reason Human-readable explanation for audit logging (e.g. "Prepaid balance exhausted", "SLA allow").
 */
public record InterceptResponse(
    boolean allow,
    String reason
) {}
