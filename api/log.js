import { kv } from '@vercel/kv';

const LOG_KEY = 'ea-logs';
const MAX_LOGS = 500;

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');
}

export default async function handler(req, res) {
  cors(res);
  if (req.method === 'OPTIONS') return res.status(204).end();

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const apiKey = process.env.LOG_API_KEY;
  if (apiKey && apiKey.length > 0) {
    const incoming = req.headers['x-api-key'] || req.query?.key || '';
    if (incoming !== apiKey) {
      return res.status(401).json({ error: 'Invalid or missing API key' });
    }
  }

  let body;
  try {
    body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
  } catch {
    return res.status(400).json({ error: 'Invalid JSON body' });
  }

  const message = body.message ?? body.msg ?? '';
  const level = (body.level || 'info').toLowerCase();
  const time = body.time || new Date().toISOString();
  const symbol = body.symbol ?? '';
  const source = body.source ?? 'XAUUSD_AI_EA';

  const entry = JSON.stringify({
    time,
    level,
    symbol,
    source,
    message: String(message).slice(0, 2000),
  });

  try {
    await kv.lpush(LOG_KEY, entry);
    await kv.ltrim(LOG_KEY, 0, MAX_LOGS - 1);
  } catch (e) {
    console.error('KV error:', e);
    return res.status(500).json({ error: 'Storage error', ok: false });
  }

  return res.status(200).json({ ok: true });
}

