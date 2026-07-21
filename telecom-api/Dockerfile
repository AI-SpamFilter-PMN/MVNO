# Multi-stage build for Spring Boot Interception Gateway using Java 21 LTS
FROM maven:3.9.9-eclipse-temurin-21 AS builder
WORKDIR /app
COPY pom.xml .
COPY src src
RUN mvn -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=builder /app/target/*.jar app.jar
RUN adduser --disabled-password --gecos '' mvno
USER mvno
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]