package com.mvno.intercept;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * <h1>MVNO Telecom Interception Gateway — Main Spring Boot Entry Point</h1>
 * 
 * <p>The {@code InterceptGatewayApplication} serves as the primary bootstrap entry point
 * for the MVNO Policy & Interception Gateway service. This application bridges cellular network
 * control plane signaling (Kamailio SIP Proxy &amp; OsmoSMSC SMPP 3.4) with real-time AI content
 * evaluation engines and offline speech recognition models.</p>
 * 
 * <h2>Architectural Responsibilities</h2>
 * <ul>
 *   <li><b>IoC Container Initialization:</b> Boots Spring's {@code ApplicationContext}, scanning packages starting from {@code com.mvno.intercept}.</li>
 *   <li><b>Embedded Web Server:</b> Launches an embedded Tomcat HTTP server on port {@code 8080} configured with Java 21 Virtual Threads (JEP 444).</li>
 *   <li><b>Background Task Scheduling:</b> {@link EnableScheduling @EnableScheduling} activates background polling loops for off-heap audio ASR spool processing.</li>
 *   <li><b>Telemetry &amp; Actuator Probes:</b> Exposes Prometheus metrics at {@code /actuator/prometheus} for VictoriaMetrics scraping.</li>
 * </ul>
 * 
 * <h2>Execution Runtime</h2>
 * <ul>
 *   <li><b>Java SDK:</b> JDK 21 LTS (64-Bit Server VM).</li>
 *   <li><b>Spring Boot:</b> 3.4.3 (Jakarta EE 10 baseline).</li>
 *   <li><b>Concurrency Model:</b> Virtual Threads (Loom) — Thread per request with lock-free carrier thread multiplexing.</li>
 * </ul>
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 * @see org.springframework.boot.autoconfigure.SpringBootApplication
 * @see org.springframework.scheduling.annotation.EnableScheduling
 */
@SpringBootApplication
@EnableScheduling
public class InterceptGatewayApplication {

    /**
     * Main executable entry point invoked by the Java 21 Virtual Machine launcher.
     * 
     * <p>Executes {@link SpringApplication#run(Class, String...)}, performing Environment
     * property resolution, BeanDefinition registration, Bean instantiation, HikariCP DataSource initialization,
     * and Embedded Servlet Container startup.</p>
     * 
     * @param args Command-line arguments passed to the JVM launcher (e.g. {@code --server.port=8080}).
     */
    public static void main(final String[] args) {
        // Initialize Spring ApplicationContext, invoke initializers, and start embedded Tomcat on port 8080
        SpringApplication.run(InterceptGatewayApplication.class, args);
    }
}
