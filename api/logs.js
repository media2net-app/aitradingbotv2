import { kv } from '@vercel/kv';

const LOG_KEY = 'ea-logs';
const DEFAULT_LIMIT = 200;

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Cache-Control', 'no-store, max-age=0');

  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const limit = Math.min(parseInt(req.query?.limit, 10) || DEFAULT_LIMIT, 500);

  try {
    const raw = await kv.lrange(LOG_KEY, 0, limit - 1);
    const logs = raw
      .map((s) => {
        try {
          return JSON.parse(s);
        } catch {
          return { time: '', level: 'info', message: s, symbol: '', source: '' };
        }
      })
      .filter(Boolean);
    return res.status(200).json({ logs });
  } catch (e) {
    console.error('KV error:', e);
    return res.status(500).json({ logs: [], error: 'Storage error' });
  }
}

