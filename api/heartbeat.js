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
    body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
  } catch {
    return res.status(400).json({ error: 'Invalid JSON body' });
  }

  const accountId = Number(body.accountId) || 0;
  const hostname = String(body.hostname || 'unknown').slice(0, 255);
  if (!accountId) {
    return res.status(400).json({ error: 'accountId required' });
  }

  const serverName = body.serverName != null ? String(body.serverName).slice(0, 255) : null;
  const balance = Number(body.balance) || 0;
  const equity = Number(body.equity) || balance;
  const margin = Number(body.margin) || 0;
  const freeMargin = Number(body.freeMargin) || 0;
  const openTrades = Array.isArray(body.openTrades) ? body.openTrades : [];
  const floatingProfit = Number(body.floatingProfit) ?? 0;

  try {
    await prisma.connection.upsert({
      where: {
        accountId_hostname: { accountId, hostname },
      },
      create: {
        accountId,
        hostname,
        serverName,
        balance,
        equity,
        margin,
        freeMargin,
        openTradesCount: openTrades.length,
        floatingProfit,
        openTrades,
        lastSeen: new Date(),
      },
      update: {
        serverName,
        balance,
        equity,
        margin,
        freeMargin,
        openTradesCount: openTrades.length,
        floatingProfit,
        openTrades,
        lastSeen: new Date(),
      },
    });
    return res.status(200).json({ ok: true });
  } catch (e) {
    console.error('Heartbeat error:', e);
    return res.status(500).json({ error: 'Database error', ok: false });
  }
}
