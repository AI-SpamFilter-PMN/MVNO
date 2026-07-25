package com.mvno.intercept.subscriber;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.EmptyResultDataAccessException;
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
 * Resilience Strategy:
 * Distinguishes non-existent subscriber records (returns 0 / Optional.empty) from database IO/lock errors.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Repository
public class SubscriberRepository {

    private static final Logger logger = LoggerFactory.getLogger(SubscriberRepository.class);
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
        if (msisdn == null || msisdn.isBlank()) {
            return 0;
        }
        final String sql = "SELECT balance FROM subscriber WHERE msisdn = ?;";
        try {
            final Integer balance = jdbcTemplate.queryForObject(sql, Integer.class, msisdn);
            return balance != null ? balance : 0;
        } catch (final EmptyResultDataAccessException e) {
            logger.debug("Subscriber record not found for MSISDN: {}", msisdn);
            return 0;
        } catch (final Exception e) {
            logger.error("Database access error querying balance for MSISDN {}: {}", msisdn, e.getMessage());
            // Return 0 as fail-closed default on database lock/connection error to prevent unbilled usage
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
        if (msisdn == null || msisdn.isBlank()) {
            return Optional.empty();
        }
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
        } catch (final EmptyResultDataAccessException e) {
            return Optional.empty();
        } catch (final Exception e) {
            logger.error("Database access error querying subscriber profile for MSISDN {}: {}", msisdn, e.getMessage());
            return Optional.empty();
        }
    }
}
