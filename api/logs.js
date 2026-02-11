import { PrismaClient } from '@prisma/client';

let prisma;
if (!globalThis._prisma) {
  globalThis._prisma = new PrismaClient();
}
prisma = globalThis._prisma;

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
    const rows = await prisma.log.findMany({
      orderBy: { id: 'desc' },
      take: limit,
    });
    const logs = rows.map((r) => ({
      time: r.createdAt?.toISOString?.() || r.createdAt,
      level: r.level,
      symbol: r.symbol,
      source: r.source,
      message: r.message,
    }));
    return res.status(200).json({ logs });
  } catch (e) {
    console.error('Prisma error:', e);
    return res.status(500).json({ logs: [], error: 'Database error' });
  }
}

