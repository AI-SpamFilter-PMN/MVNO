package com.mvno.intercept.subscriber;

/**
 * Subscriber Profile Domain Record.
 * 
 * @param username SIP/SMPP authentication username.
 * @param msisdn Phone number in E.164 format.
 * @param balance Prepaid balance in currency units ($).
 * @param imei Registered hardware IMEI number.
 */
public record Subscriber(
    String username,
    String msisdn,
    int balance,
    String imei
) {}
