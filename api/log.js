import { PrismaClient } from '@prisma/client';

let prisma;
if (!globalThis._prisma) {
  globalThis._prisma = new PrismaClient();
}
prisma = globalThis._prisma;

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

  try {
    await prisma.log.create({
      data: {
        time,
        level,
        symbol,
        source,
        message: String(message).slice(0, 2000),
      },
    });
  } catch (e) {
    console.error('Prisma error:', e);
    return res.status(500).json({ error: 'Database error', ok: false });
  }

  return res.status(200).json({ ok: true });
}

