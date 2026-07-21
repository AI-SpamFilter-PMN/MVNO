package com.mvno.intercept.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;
import javax.sql.DataSource;

/**
 * ==============================================================================
 * Database & JDBC Configuration
 * ==============================================================================
 * Configures the JdbcTemplate instance used to query subscriber records, prepaid
 * balances, and blacklist rules in SQLite WAL mode (/etc/kamailio/kamailio.db).
 */
@Configuration
public class DataSourceConfig {

    @Bean
    public JdbcTemplate jdbcTemplate(DataSource dataSource) {
        // JdbcTemplate provides thread-safe, high-concurrency SQL execution over HikariCP
        return new JdbcTemplate(dataSource);
    }
}
