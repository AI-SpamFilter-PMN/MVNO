package com.mvno.intercept.subscriber;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.Optional;

/**
 * Subscriber Persistent Data Access Repository
 * 
 * Executes SQL queries against shared SQLite Write-Ahead Logging (WAL) database (/etc/kamailio/kamailio.db).
 * 
 * Concurrency & Security:
 * SQLite WAL mode allows concurrent virtual thread reads without blocking Kamailio.
 * All SQL statements use parameterized placeholders (WHERE msisdn = ?) to eliminate SQL injection.
 * 
 * Fail-Closed Strategy:
 * If a query fails or returns no record, defaults to 0 balance (Fail-Closed) to prevent unbilled usage.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Repository
public class SubscriberRepository {

    private final JdbcTemplate jdbcTemplate;

    public SubscriberRepository(final JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /**
     * Queries prepaid account balance for a given subscriber phone number.
     * 
     * @param msisdn E.164 phone number string (e.g. "15551234567").
     * @return Balance integer ($), or 0 if missing.
     */
    public int findBalanceByMsisdn(final String msisdn) {
        final String sql = "SELECT balance FROM subscriber WHERE msisdn = ?;";
        try {
            final Integer balance = jdbcTemplate.queryForObject(sql, Integer.class, msisdn);
            return balance != null ? balance : 0;
        } catch (final Exception e) {
            return 0;
        }
    }

    /**
     * Retrieves subscriber account profile mapped directly to a Subscriber Record.
     * 
     * @param msisdn E.164 phone number string.
     * @return Optional containing Subscriber record if found.
     */
    public Optional<Subscriber> findByMsisdn(final String msisdn) {
        final String sql = "SELECT username, msisdn, balance, imei FROM subscriber WHERE msisdn = ?;";
        try {
            final Subscriber sub = jdbcTemplate.queryForObject(sql, (rs, rowNum) ->
                new Subscriber(
                    rs.getString("username"),
                    rs.getString("msisdn"),
                    rs.getInt("balance"),
                    rs.getString("imei")
                ), msisdn);
            return Optional.ofNullable(sub);
        } catch (final Exception e) {
            return Optional.empty();
        }
    }
}
