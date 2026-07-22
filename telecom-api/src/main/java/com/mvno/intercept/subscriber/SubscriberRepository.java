package com.mvno.intercept.subscriber;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.util.Optional;

/**
 * <h1>Subscriber Persistent Data Access Repository</h1>
 * 
 * <p>The {@code SubscriberRepository} executes SQL queries against the shared SQLite Write-Ahead Logging (WAL)
 * database file located at {@code /etc/kamailio/kamailio.db}.</p>
 * 
 * <h2>SQLite WAL Concurrency &amp; Thread Safety</h2>
 * <p>Under SQLite Write-Ahead Logging mode, multiple Spring Boot virtual threads execute read queries simultaneously
 * without locking Kamailio's SIP worker processes. All SQL statements use parameterized placeholders ({@code WHERE msisdn = ?})
 * to eliminate SQL injection vulnerabilities.</p>
 * 
 * <h2>Fail-Closed Security Strategy</h2>
 * <p>If a subscriber query fails or returns no record, the repository defaults to returning 0 balance (Fail-Closed)
 * to prevent unbilled or unauthenticated network usage.</p>
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 * @see org.springframework.jdbc.core.JdbcTemplate
 */
@Repository
public class SubscriberRepository {

    private final JdbcTemplate jdbcTemplate;

    /**
     * Constructs the repository wrapping the configured {@link JdbcTemplate}.
     * 
     * @param jdbcTemplate Spring JDBC Template bean instance.
     */
    public SubscriberRepository(final JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /**
     * Queries the prepaid account balance for a given subscriber phone number.
     * 
     * @param msisdn E.164 formatted phone number string (e.g. "15551234567").
     * @return Account balance integer ($), or 0 if subscriber does not exist.
     */
    public int findBalanceByMsisdn(final String msisdn) {
        final String sql = "SELECT balance FROM subscriber WHERE msisdn = ?;";
        try {
            final Integer balance = jdbcTemplate.queryForObject(sql, Integer.class, msisdn);
            return balance != null ? balance : 0;
        } catch (final Exception e) {
            // Fail-Closed default: Return 0 balance on missing records or query failure
            return 0;
        }
    }

    /**
     * Retrieves full subscriber account profile mapped directly to a {@link Subscriber} Java Record.
     * 
     * @param msisdn E.164 formatted phone number string.
     * @return Optional containing the {@link Subscriber} record if found, or {@link Optional#empty()}.
     */
    public Optional<Subscriber> findByMsisdn(final String msisdn) {
        final String sql = "SELECT username, msisdn, balance, imei FROM subscriber WHERE msisdn = ?;";
        try {
            // Functional RowMapper lambda mapping ResultSet columns directly to immutable Record fields
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
