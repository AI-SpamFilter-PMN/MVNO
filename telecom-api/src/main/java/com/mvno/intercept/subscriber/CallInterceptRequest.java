package com.mvno.intercept.subscriber;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Voice Call Interception Request DTO Record
 * 
 * Maps incoming HTTP POST requests sent by Kamailio SIP Proxy to POST /api/v1/intercept/call.
 * 
 * @param caller Originating party E.164 phone number string (e.g. "15551234567").
 * @param callee Terminating party E.164 phone number string (e.g. "15557654321").
 * @param callId Unique SIP header Call-ID identifying the dialog transaction.
 * @param imei 15-digit International Mobile Equipment Identity hardware serial string (optional).
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public record CallInterceptRequest(
    String caller,
    String callee,
    @JsonProperty("call_id") String callId,
    String imei
) {}
