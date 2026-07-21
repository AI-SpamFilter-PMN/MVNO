package com.mvno.intercept.subscriber;

/**
 * DTO Record representing an incoming Voice Call Interception request from Kamailio.
 * 
 * @param caller Calling party E.164 phone number (MSISDN).
 * @param callee Called party E.164 phone number (MSISDN).
 * @param callId Unique SIP Call-ID string.
 * @param imei Optional hardware IMEI identifier reported by 5G gNB / EIR.
 */
public record CallInterceptRequest(
    String caller,
    String callee,
    String callId,
    String imei
) {}
