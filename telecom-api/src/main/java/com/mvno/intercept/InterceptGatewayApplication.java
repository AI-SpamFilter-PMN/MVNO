package com.mvno.intercept;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * MVNO Telecom Interception Gateway Main Entry Point.
 * 
 * `@SpringBootApplication` enables Spring Boot auto-configuration, component scanning
 * across package `com.mvno.intercept`, and configuration bean registration.
 */
@SpringBootApplication
public class InterceptGatewayApplication {

    public static void main(String[] args) {
        // Boots the Spring IoC ApplicationContext container and launches embedded Tomcat on port 8080
        SpringApplication.run(InterceptGatewayApplication.class, args);
    }
}
