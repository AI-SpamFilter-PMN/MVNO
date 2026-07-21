package com.mvno.intercept.subscriber;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import java.util.Optional;

/**
 * Subscriber Data Access Repository.
 * 
 * DESIGN RATIONALE:
 * Interacts directly with the shared SQLite WAL (Write-Ahead Logging) database (/etc/kamailio/kamailio.db).
 * SQLite WAL mode allows concurrent read operations across multiple threads while writes occur.
 * 
 * SECURITY: All queries use parameterized placeholders (`WHERE msisdn = ?`) to prevent SQL injection.
 * If a subscriber lookup fails or returns empty, the repository defaults to 0 balance (Fail-Closed)
 * to prevent unauthorized or unbilled network traffic.
 */
// `@Repository` marks this data access bean and enables Spring's automatic JDBC DataAccessException translation.
@Repository
public class SubscriberRepository {

    private final JdbcTemplate jdbcTemplate;

    public SubscriberRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /**
     * Queries the prepaid account balance for a given phone number.
     * 
     * @param msisdn E.164 formatted phone number string (e.g. "15551234567").
     * @return Prepaid account balance in currency units ($), or 0 if subscriber does not exist.
     */
    public int findBalanceByMsisdn(String msisdn) {
        String sql = "SELECT balance FROM subscriber WHERE msisdn = ?;";
        try {
            Integer balance = jdbcTemplate.queryForObject(sql, Integer.class, msisdn);
            return balance != null ? balance : 0;
        } catch (Exception e) {
            // Fail-Secure default: Return 0 balance on missing records to block unauthenticated callers
            return 0;
        }
    }

    /**
     * Fetches complete subscriber profile record mapped to a Java Record instance.
     * 
     * @param msisdn E.164 formatted phone number string.
     * @return Optional containing Subscriber record if found, or Optional.empty().
     */
    public Optional<Subscriber> findByMsisdn(String msisdn) {
        String sql = "SELECT username, msisdn, balance, imei FROM subscriber WHERE msisdn = ?;";
        try {
            // Functional RowMapper lambda mapping JDBC ResultSet directly into immutable Subscriber record
            Subscriber sub = jdbcTemplate.queryForObject(sql, (rs, rowNum) ->
                new Subscriber(
                    rs.getString("username"),
                    rs.getString("msisdn"),
                    rs.getInt("balance"),
                    rs.getString("imei")
                ), msisdn);
            return Optional.ofNullable(sub);
        } catch (Exception e) {
            return Optional.empty();
        }
    }
}
