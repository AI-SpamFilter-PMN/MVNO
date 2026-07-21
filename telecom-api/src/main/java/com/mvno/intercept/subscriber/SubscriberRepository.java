package com.mvno.intercept.subscriber;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import java.util.Optional;

/**
 * ==============================================================================
 * Subscriber Repository (SQLite WAL Database Access)
 * ==============================================================================
 * Executes parametrized JDBC SQL queries against the shared SQLite database
 * (/etc/kamailio/kamailio.db) to fetch subscriber balance and profile records.
 */
@Repository
public class SubscriberRepository {

    private final JdbcTemplate jdbcTemplate;

    public SubscriberRepository(JdbcTemplate jdbcTemplate) {
        this.jdbcTemplate = jdbcTemplate;
    }

    /**
     * Fetches prepaid balance for a given MSISDN.
     * 
     * @param msisdn Phone number in E.164 format.
     * @return Prepaid balance integer, or 0 if subscriber not found.
     */
    public int findBalanceByMsisdn(String msisdn) {
        String sql = "SELECT balance FROM subscriber WHERE msisdn = ?;";
        try {
            Integer balance = jdbcTemplate.queryForObject(sql, Integer.class, msisdn);
            return balance != null ? balance : 0;
        } catch (Exception e) {
            return 0; // Return 0 balance on missing record to block unknown callers
        }
    }

    /**
     * Fetches full subscriber record by MSISDN.
     */
    public Optional<Subscriber> findByMsisdn(String msisdn) {
        String sql = "SELECT username, msisdn, balance, imei FROM subscriber WHERE msisdn = ?;";
        try {
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
