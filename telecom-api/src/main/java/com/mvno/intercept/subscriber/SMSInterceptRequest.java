package com.mvno.intercept.subscriber;

/**
 * <h1>SMS Interception Request DTO Record</h1>
 * 
 * <p>Immutable Java 21 Record mapping incoming HTTP POST requests sent by OsmoSMSC / ESME client to
 * {@code POST /api/v1/intercept/sms}.</p>

 * <h2>JSON Body Mapping Schema</h2>
 * <pre>{@code
 * {
 *   "sender": "15551234567",
 *   "recipient": "15557654321",
 *   "content": "Your security code is 948210"
 * }
 * }</pre>
 * 
 * @param sender Originating ESME / 5G UE E.164 MSISDN phone number string (e.g. "15551234567").
 * @param recipient Target MSISDN phone number string (e.g. "15557654321").
 * @param content Text payload body submitted via SMPP 3.4 {@code submit_sm} PDU or 5G SMS-over-NAS.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public record SMSInterceptRequest(
    String sender,
    String recipient,
    String content
) {}
