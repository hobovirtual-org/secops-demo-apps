# ── Build stage ────────────────────────────────────────────────────────────
FROM registry.redhat.io/ubi9/openjdk-21:latest AS builder

WORKDIR /build
COPY pom.xml .
COPY src ./src
RUN mvn -q package -DskipTests

# ── Runtime stage ──────────────────────────────────────────────────────────
FROM registry.redhat.io/ubi9/openjdk-21-runtime:latest

WORKDIR /app
COPY --from=builder /build/target/hello-vault-*.jar app.jar

USER 1001

ENV SERVER_PORT=8080
EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
