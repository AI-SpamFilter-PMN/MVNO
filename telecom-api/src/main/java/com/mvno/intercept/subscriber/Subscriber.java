package com.mvno.intercept.subscriber;

/**
 * Subscriber Profile Data Entity Record
 * 
 * Maps subscriber database row retrieved from SQLite table 'subscriber' in /etc/kamailio/kamailio.db.
 * 
 * @param username SIP Digest Authentication username.
 * @param msisdn E.164 phone number string.
 * @param balance Prepaid account currency balance ($).
 * @param imei 15-digit International Mobile Equipment Identity string.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
public record Subscriber(
    String username,
    String msisdn,
    int balance,
    String imei
) {}
