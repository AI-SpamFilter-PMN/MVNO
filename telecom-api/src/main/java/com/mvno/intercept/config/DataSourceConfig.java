package com.mvno.intercept.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;
import javax.sql.DataSource;

/**
 * Database Data Source and JDBC Access Configuration.
 * 
 * RATIONALE: We explicitly use Spring's `JdbcTemplate` instead of an ORM (like Hibernate/JPA).
 * In high-throughput telecom signaling gateways, object-relational mapping introduces unnecessary
 * reflection, dirty-checking overhead, and heavy entity object allocations on every SIP INVITE.
 * 
 * `JdbcTemplate` operates directly on raw JDBC connections managed by HikariCP, executing lightweight
 * SQL queries against SQLite WAL mode (/etc/kamailio/kamailio.db) with sub-millisecond execution times.
 */
// `@Configuration` tells Spring's IoC container that this class contains Java-based `@Bean` factory definitions.
@Configuration
public class DataSourceConfig {

    // `@Bean` tells Spring to execute this factory method during application startup and register
    // the returned thread-safe `JdbcTemplate` instance as a managed singleton bean in the ApplicationContext.
    @Bean
    public JdbcTemplate jdbcTemplate(DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
}
