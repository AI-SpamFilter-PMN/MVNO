package com.mvno.intercept;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * ==============================================================================
 * MVNO Telecom Interception Gateway — Main Entry Point
 * ==============================================================================
 * This Spring Boot application serves as the primary policy control, subscriber balance
 * verification, EIR IMEI tracking, and AI Spam Filter interception gateway for the MVNO network.
 * 
 * Key Responsibilities:
 * 1. Intercept SMS delivery requests from OsmoSMSC (SMPP).
 * 2. Intercept SIP Voice calls from Kamailio.
 * 3. Query subscriber prepaid balance ($1/SMS, $5/call) in SQLite WAL database.
 * 4. Call external AI Spam Filter REST API (http://ai-filter:8000/api/v1/classify).
 * 5. Provide 5-second SLA Fail-Open fallback when AI model is delayed or offline.
 */
@SpringBootApplication
public class InterceptGatewayApplication {

    public static void main(String[] args) {
        // Launches embedded Tomcat server on port 8080 using Java 25 Virtual Threads
        SpringApplication.run(InterceptGatewayApplication.class, args);
    }
}
