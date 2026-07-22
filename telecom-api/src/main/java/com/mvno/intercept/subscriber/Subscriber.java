package com.mvno.intercept.subscriber;

/**
 * <h1>Subscriber Profile Data Entity Record</h1>
 * 
 * <p>Immutable Java 21 Record mapping a single subscriber account row retrieved from SQLite database
 * table {@code subscriber} in {@code /etc/kamailio/kamailio.db}.</p>
 * 
 * <h2>SQLite Schema Definition</h2>
 * <pre>{@code
 * CREATE TABLE subscriber (
 *     id INTEGER PRIMARY KEY AUTOINCREMENT,
 *     username VARCHAR(64) NOT NULL DEFAULT '',
 *     domain VARCHAR(64) NOT NULL DEFAULT '',
 *     password VARCHAR(64) NOT NULL DEFAULT '',
 *     ha1 VARCHAR(128) NOT NULL DEFAULT '',
 *     ha1b VARCHAR(128) NOT NULL DEFAULT '',
 *     msisdn TEXT UNIQUE,
 *     balance INTEGER DEFAULT 100,
 *     imei TEXT,
 *     imsi TEXT,
 *     blocked INTEGER DEFAULT 0
 * );
 * }</pre>
 * 
 * @param username SIP Digest Authentication username string (e.g. "15551234567").
 * @param msisdn E.164 phone number string.
 * @param balance Prepaid account currency balance ($).
 * @param imei 15-digit International Mobile Equipment Identity hardware serial number string.
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
