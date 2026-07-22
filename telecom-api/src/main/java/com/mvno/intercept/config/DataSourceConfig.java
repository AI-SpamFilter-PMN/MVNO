package com.mvno.intercept.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

import javax.sql.DataSource;

/**
 * <h1>Database Access &amp; JDBC Template Factory Configuration</h1>
 * 
 * <p>Configures low-level, high-performance database connectivity for the interception gateway.
 * Interacts directly with the shared SQLite Write-Ahead Logging (WAL) database located at
 * {@code /etc/kamailio/kamailio.db}.</p>
 * 
 * <h2>Design Rationale: Direct JDBC vs. ORM (JPA/Hibernate)</h2>
 * <p>In telecom control-plane gateways processing high-concurrency SIP {@code INVITE} and SMPP
 * {@code submit_sm} requests, object-relational mapping (ORM) introduces severe performance bottlenecks:</p>
 * <ul>
 *   <li><b>Reflection Overhead:</b> Entity reflection and dynamic proxying add millisecond delays to real-time call setup.</li>
 *   <li><b>Dirty Checking &amp; L1/L2 Cache:</b> Unnecessary object lifecycle tracking increases GC pressure under Virtual Threads.</li>
 *   <li><b>Lock Contention:</b> ORM session management conflicts with SQLite's single-writer concurrency model.</li>
 * </ul>
 * 
 * <p>By utilizing Spring's lightweight {@link JdbcTemplate}, SQL execution is direct, deterministic,
 * and completes in sub-millisecond time frames without reflection or ORM proxy overhead.</p>
 * 
 * <h2>SQLite WAL (Write-Ahead Logging) Concurrency</h2>
 * <ul>
 *   <li><b>Concurrent Reads:</b> Multiple Spring Boot virtual threads can execute SELECT queries simultaneously without blocking Kamailio's SIP workers.</li>
 *   <li><b>Single Writer:</b> SQLite serializes writes to the WAL file, eliminating table-level database locks.</li>
 * </ul>
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 * @see org.springframework.jdbc.core.JdbcTemplate
 * @see javax.sql.DataSource
 */
@Configuration
public class DataSourceConfig {

    /**
     * Constructs and registers a thread-safe {@link JdbcTemplate} singleton bean in the Spring ApplicationContext.
     * 
     * <p>The generated {@code JdbcTemplate} wraps the auto-configured HikariCP {@link DataSource},
     * enabling parameterized SQL query execution, result-set mapping, and automatic JDBC Exception
     * translation into Spring's {@code DataAccessException} hierarchy.</p>
     * 
     * @param dataSource The primary HikariCP connection pool {@link DataSource} injected by Spring Boot auto-configuration.
     * @return A fully initialized, thread-safe {@link JdbcTemplate} ready for subscriber database operations.
     */
    @Bean
    public JdbcTemplate jdbcTemplate(final DataSource dataSource) {
        // Instantiate lightweight JdbcTemplate wrapping HikariCP connection pool
        return new JdbcTemplate(dataSource);
    }
}
