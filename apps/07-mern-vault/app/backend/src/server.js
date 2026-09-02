'use strict';
/**
 * MERN Vault — Express backend
 * Reads MongoDB credentials from /vault/secrets/config.json (injected by Vault Agent)
 * Never holds static tokens or passwords in code or environment.
 */
const express    = require('express');
const mongoose   = require('mongoose');
const cors       = require('cors');
const fs         = require('fs');

const PORT        = parseInt(process.env.PORT || '3001', 10);
const SECRET_FILE = process.env.SECRET_FILE || '/vault/secrets/config.json';

function readVaultSecrets() {
  const raw = fs.readFileSync(SECRET_FILE, 'utf8');
  return JSON.parse(raw);
}

async function connectMongo(secrets) {
  const { mongo_username, mongo_password, mongo_host, mongo_port, mongo_database } = secrets;
  const uri = `mongodb://${mongo_username}:${encodeURIComponent(mongo_password)}@${mongo_host}:${mongo_port}/${mongo_database}?authSource=merndb`;
  await mongoose.connect(uri);
  console.log('Connected to MongoDB');
}

// ── Mongoose model ──────────────────────────────────────────────────────────
const itemSchema = new mongoose.Schema({
  message:   { type: String, required: true },
  createdAt: { type: Date, default: Date.now },
});
const Item = mongoose.model('Item', itemSchema);

// ── Express app ─────────────────────────────────────────────────────────────
const app = express();
app.use(cors());
app.use(express.json());

app.get('/health', (_req, res) => res.json({ status: 'healthy' }));

app.get('/api/items', async (_req, res) => {
  try {
    const items = await Item.find().sort({ createdAt: -1 }).limit(20);
    res.json(items);
  } catch (err) {
    console.error('ERROR listing items:', err.message);
    res.status(500).json({ error: 'internal error' });
  }
});

app.post('/api/items', async (req, res) => {
  const { message } = req.body;
  if (!message || typeof message !== 'string' || message.length > 256) {
    return res.status(400).json({ error: 'invalid message' });
  }
  try {
    const item = await Item.create({ message });
    res.status(201).json(item);
  } catch (err) {
    console.error('ERROR creating item:', err.message);
    res.status(500).json({ error: 'internal error' });
  }
});

// ── Start ────────────────────────────────────────────────────────────────────
(async () => {
  const secrets = readVaultSecrets();
  await connectMongo(secrets);
  app.listen(PORT, '0.0.0.0', () => console.log(`Backend listening on port ${PORT}`));
})();
