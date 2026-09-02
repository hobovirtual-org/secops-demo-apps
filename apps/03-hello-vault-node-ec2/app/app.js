'use strict';
/**
 * Hello Vault — Node.js / Express
 * Authenticates to HashiCorp Vault via AWS IAM auth, reads a KV v2 secret.
 */
const express = require('express');
const vault   = require('node-vault');
const AWS     = require('aws-sdk');

const VAULT_ADDR  = process.env.VAULT_ADDR   || (() => { throw new Error('VAULT_ADDR required') })();
const VAULT_NS    = process.env.VAULT_NAMESPACE || '';
const VAULT_ROLE  = process.env.VAULT_ROLE   || (() => { throw new Error('VAULT_ROLE required') })();
const MOUNT_POINT = process.env.MOUNT_POINT  || 'secret';
const SECRET_PATH = process.env.SECRET_PATH  || 'config';
const PORT        = parseInt(process.env.PORT || '8080', 10);

const app = express();

async function readSecret() {
  const client = vault({ endpoint: VAULT_ADDR, namespace: VAULT_NS });
  // AWS IAM login — node-vault handles STS presigned URL signing
  await client.awsIamLogin({ role: VAULT_ROLE });
  const res = await client.read(`${MOUNT_POINT}/data/${SECRET_PATH}`);
  return res.data.data;
}

app.get('/', async (req, res) => {
  try {
    const data = await readSecret();
    res.json({
      status:      'ok',
      greeting:    data.greeting,
      db_username: data.db_username,
      // Never return db_password
    });
  } catch (err) {
    console.error('ERROR', err.message);
    res.status(500).json({ status: 'error', message: 'internal error' });
  }
});

app.get('/health', (_req, res) => res.json({ status: 'healthy' }));

app.listen(PORT, '127.0.0.1', () => console.log(`Listening on 127.0.0.1:${PORT}`));
