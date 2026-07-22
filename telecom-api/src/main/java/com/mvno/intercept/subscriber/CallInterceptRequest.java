package com.mvno.intercept.subscriber;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * <h1>Voice Call Interception Request DTO Record</h1>
 * 
 * <p>Immutable Java 21 Record mapping incoming HTTP POST requests sent by Kamailio SIP Proxy to
 * {@code POST /api/v1/intercept/call}.</p>

 * <h2>JSON Body Mapping Schema</h2>
 * <pre>{@code
 * {
 *   "caller": "15551234567",
 *   "callee": "15557654321",
 *   "call_id": "84739281-kamailio-sip-id",
 *   "imei": "356938035643809"
 * }
 * }</pre>
 * 
 * @param caller Originating party E.164 phone number string (e.g. "15551234567").
 * @param callee Terminating party E.164 phone number string (e.g. "15557654321").
 * @param callId Unique SIP header {@code Call-ID} identifying the dialog transaction.
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
