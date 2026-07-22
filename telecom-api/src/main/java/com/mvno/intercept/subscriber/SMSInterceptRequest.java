package com.mvno.intercept.subscriber;

/**
 * SMS Interception Request DTO Record
 * 
 * Maps incoming HTTP POST requests from OsmoSMSC / ESME client to POST /api/v1/intercept/sms.
 * 
 * @param sender Originating E.164 MSISDN phone number string (e.g. "15551234567").
 * @param recipient Target MSISDN phone number string (e.g. "15557654321").
 * @param content Text payload body submitted via SMPP 3.4 submit_sm PDU or 5G SMS-over-NAS.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public record SMSInterceptRequest(
    String sender,
    String recipient,
    String content
) {}
