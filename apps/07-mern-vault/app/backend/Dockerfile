FROM registry.redhat.io/ubi9/nodejs-20-minimal:latest

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src/ ./src/

USER 1001
ENV PORT=3001
EXPOSE 3001
CMD ["node", "src/server.js"]
