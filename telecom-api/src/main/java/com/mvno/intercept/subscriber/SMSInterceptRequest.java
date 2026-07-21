package com.mvno.intercept.subscriber;

/**
 * DTO Record representing an incoming SMS Interception request from OsmoSMSC.
 * 
 * @param sender Originating E.164 phone number (MSISDN).
 * @param recipient Destination E.164 phone number (MSISDN).
 * @param content Text body of the SMS message.
 */
public record SMSInterceptRequest(
    String sender,
    String recipient,
    String content
) {}
