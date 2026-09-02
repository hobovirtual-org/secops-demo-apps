# ── Build stage ────────────────────────────────────────────────────────────
FROM registry.redhat.io/ubi9/go-toolset:latest AS builder

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o hello-vault-go .

# ── Runtime stage ──────────────────────────────────────────────────────────
FROM registry.redhat.io/ubi9/ubi-minimal:latest

WORKDIR /app
COPY --from=builder /build/hello-vault-go .

USER 1001

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["./hello-vault-go"]
