package com.mvno.intercept;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/**
 * MVNO Telecom Interception Gateway — Main Spring Boot Entry Point
 * 
 * Bridges cellular network control plane signaling (Kamailio SIP Proxy & OsmoSMSC SMPP 3.4)
 * with real-time AI content evaluation engines and offline speech recognition models.
 * 
 * Architectural Responsibilities:
 * - IoC Container: Boots Spring ApplicationContext, scanning com.mvno.intercept.
 * - Embedded Server: Launches Tomcat HTTP server on port 8080 with Java 21 Virtual Threads (JEP 444).
 * - Scheduling: @EnableScheduling activates background polling loops for audio ASR spool processing.
 * - Telemetry: Exposes Prometheus metrics at /actuator/prometheus for VictoriaMetrics.
 * 
 * Execution Runtime:
 * - Java SDK: JDK 21 LTS
 * - Spring Boot: 3.4.3
 * - Concurrency: Virtual Threads (Loom)
 * 
 * @author MVNO Core Engineering Team
 * @version 1.0.0
 */
@SpringBootApplication
@EnableScheduling
public class InterceptGatewayApplication {

    /**
     * Main entry point invoked by JVM launcher.
     * Starts Spring ApplicationContext and embedded Tomcat on port 8080.
     * 
     * @param args Command-line arguments.
     */
    public static void main(final String[] args) {
        SpringApplication.run(InterceptGatewayApplication.class, args);
    }
}
