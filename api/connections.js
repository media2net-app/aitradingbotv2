import { PrismaClient } from '@prisma/client';

let prisma;
if (!globalThis._prisma) {
  globalThis._prisma = new PrismaClient();
}
prisma = globalThis._prisma;

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
}

export default async function handler(req, res) {
  cors(res);
  if (req.method === 'OPTIONS') return res.status(204).end();

  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const maxAgeMinutes = Math.min(parseInt(req.query.maxAge, 10) || 60, 1440);
    const since = new Date(Date.now() - maxAgeMinutes * 60 * 1000);

    const list = await prisma.connection.findMany({
      where: { lastSeen: { gte: since } },
      orderBy: { lastSeen: 'desc' },
    });

    const connections = list.map((c) => ({
      id: c.id,
      accountId: c.accountId,
      hostname: c.hostname,
      serverName: c.serverName,
      balance: c.balance,
      equity: c.equity,
      margin: c.margin,
      freeMargin: c.freeMargin,
      openTradesCount: c.openTradesCount,
      floatingProfit: c.floatingProfit,
      openTrades: c.openTrades,
      lastSeen: c.lastSeen?.toISOString?.() || c.lastSeen,
    }));

    return res.status(200).json({ connections });
  } catch (e) {
    console.error('Connections GET error:', e);
    return res.status(500).json({ connections: [] });
  }
}
