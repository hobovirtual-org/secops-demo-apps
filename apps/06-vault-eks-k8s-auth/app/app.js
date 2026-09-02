'use strict';
/**
 * Hello Vault — Node.js on EKS with Vault Agent Injector
 * The secret is pre-populated by Vault Agent at /vault/secrets/config.json
 * This app simply reads that file — no SDK or auth code needed!
 */
const http = require('http');
const fs   = require('fs');

const PORT        = parseInt(process.env.PORT || '8080', 10);
const SECRET_FILE = process.env.SECRET_FILE || '/vault/secrets/config.json';

function readSecret() {
  const raw = fs.readFileSync(SECRET_FILE, 'utf8');
  return JSON.parse(raw);
}

const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');

  if (req.url === '/health') {
    res.writeHead(200);
    res.end(JSON.stringify({ status: 'healthy' }));
    return;
  }

  try {
    const data = readSecret();
    res.writeHead(200);
    res.end(JSON.stringify({
      status:      'ok',
      greeting:    data.greeting,
      db_username: data.db_username,
      // Never return db_password
    }));
  } catch (err) {
    console.error('ERROR reading secret file:', err.message);
    res.writeHead(500);
    res.end(JSON.stringify({ status: 'error', message: 'internal error' }));
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`Listening on 127.0.0.1:${PORT}`);
  console.log(`Reading secrets from ${SECRET_FILE}`);
});
