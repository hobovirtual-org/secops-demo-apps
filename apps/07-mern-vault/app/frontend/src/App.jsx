import { useState, useEffect } from 'react';

const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3001';

export default function App() {
  const [items, setItems]     = useState([]);
  const [message, setMessage] = useState('');
  const [error, setError]     = useState('');

  async function fetchItems() {
    const res = await fetch(`${API_URL}/api/items`);
    if (!res.ok) { setError('Failed to load items'); return; }
    setItems(await res.json());
  }

  async function addItem(e) {
    e.preventDefault();
    if (!message.trim()) return;
    const res = await fetch(`${API_URL}/api/items`, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ message }),
    });
    if (!res.ok) { setError('Failed to add item'); return; }
    setMessage('');
    fetchItems();
  }

  useEffect(() => { fetchItems(); }, []);

  return (
    <div style={{ maxWidth: 600, margin: '40px auto', fontFamily: 'system-ui, sans-serif' }}>
      <h1>MERN + Vault Demo</h1>
      <p style={{ color: '#57606a', fontSize: 14 }}>
        MongoDB credentials delivered by Vault Agent Injector — no secrets in code or env vars.
      </p>
      {error && <p style={{ color: 'red' }}>{error}</p>}
      <form onSubmit={addItem} style={{ display: 'flex', gap: 8, marginBottom: 24 }}>
        <input
          type="text"
          value={message}
          maxLength={256}
          onChange={e => setMessage(e.target.value)}
          placeholder="Add a message..."
          style={{ flex: 1, padding: '8px 12px', borderRadius: 4, border: '1px solid #e5e7eb' }}
        />
        <button type="submit" style={{ padding: '8px 16px', borderRadius: 4, background: '#3b82d4', color: '#fff', border: 'none', cursor: 'pointer' }}>
          Add
        </button>
      </form>
      <ul style={{ listStyle: 'none', padding: 0 }}>
        {items.map(item => (
          <li key={item._id} style={{ padding: '10px 0', borderBottom: '1px solid #e5e7eb', fontSize: 14 }}>
            <span>{item.message}</span>
            <span style={{ float: 'right', color: '#57606a' }}>{new Date(item.createdAt).toLocaleString()}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
