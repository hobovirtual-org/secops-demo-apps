# ── Build stage ────────────────────────────────────────────────────────────
FROM registry.redhat.io/ubi9/nodejs-20-minimal:latest AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# ── Runtime stage (serve built files) ─────────────────────────────────────
FROM registry.redhat.io/ubi9/nodejs-20-minimal:latest

WORKDIR /app
COPY --from=builder /app/dist ./dist

# Simple static server
RUN npm install -g serve@14

USER 1001
ENV PORT=3000
EXPOSE 3000
CMD ["serve", "-s", "dist", "-l", "3000"]
