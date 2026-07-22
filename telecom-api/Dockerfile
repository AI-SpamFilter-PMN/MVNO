# ==============================================================================
# MVNO Interception Gateway — Spring Boot Java 21 Multi-Stage Dockerfile
# ==============================================================================
# Multi-Stage Build Strategy:
# Stage 1 (Builder): Uses Maven 3.9 + Temurin JDK 21 to compile Java sources and
#                    package the executable fat-JAR (-DskipTests for speed).
# Stage 2 (Runtime): Uses minimal Temurin JRE 21 runtime image with unprivileged
#                    'mvno' user account for rootless execution security.
# ==============================================================================

# STAGE 1: Build & Package
FROM maven:3.9.9-eclipse-temurin-21 AS builder
WORKDIR /app
COPY pom.xml .
COPY src src
RUN mvn -B package -DskipTests

# STAGE 2: Minimal Runtime Container
FROM eclipse-temurin:21-jre
WORKDIR /app

# Copy compiled fat-JAR artifact from Stage 1
COPY --from=builder /app/target/*.jar app.jar

# Security: Create non-root user 'mvno' and enforce unprivileged execution
RUN adduser --disabled-password --gecos '' mvno
USER mvno

# Expose Spring Boot HTTP Server port (Actuator & REST API)
EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]