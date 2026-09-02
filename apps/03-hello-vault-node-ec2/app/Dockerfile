FROM registry.redhat.io/ubi9/nodejs-20-minimal:latest

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY app.js .

USER 1001

ENV PORT=8080
EXPOSE 8080

CMD ["node", "app.js"]
