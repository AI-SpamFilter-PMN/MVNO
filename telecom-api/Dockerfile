FROM maven:3.9-eclipse-temurin-25 AS builder
WORKDIR /app
COPY telecom-api/pom.xml .
COPY telecom-api/src src
RUN mvn -B package -DskipTests

FROM eclipse-temurin:25-jre
WORKDIR /app
COPY --from=builder /app/target/*.jar app.jar
RUN adduser --disabled-password --gecos '' mvno \
    && mkdir -p /etc/kamailio \
    && chown mvno:mvno /etc/kamailio
USER mvno
EXPOSE 8080
ENTRYPOINT ["java", "--enable-native-access=ALL-UNNAMED", "-jar", "app.jar"]