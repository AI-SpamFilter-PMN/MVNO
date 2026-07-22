package com.mvno.intercept.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

import javax.sql.DataSource;

/**
 * Database Access & JDBC Template Factory Configuration
 * 
 * Interacts directly with the shared SQLite Write-Ahead Logging (WAL) database at /etc/kamailio/kamailio.db.
 * 
 * Design Rationale (Direct JDBC vs. ORM):
 * In high-concurrency telecom signaling gateways, ORM (Hibernate/JPA) introduces reflection and proxy overhead.
 * Direct JdbcTemplate queries execute in sub-millisecond frames without dirty-checking or L1/L2 cache overhead.
 * 
 * SQLite WAL Mode:
 * - Concurrent Reads: Multiple Virtual Threads execute SELECTs simultaneously without blocking Kamailio.
 * - Single Writer: SQLite serializes WAL writes, avoiding table locks.
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@Configuration
public class DataSourceConfig {

    /**
     * Constructs and registers a thread-safe JdbcTemplate bean in the Spring context.
     * 
     * @param dataSource HikariCP connection pool DataSource.
     * @return Initialized JdbcTemplate instance.
     */
    @Bean
    public JdbcTemplate jdbcTemplate(final DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
}
