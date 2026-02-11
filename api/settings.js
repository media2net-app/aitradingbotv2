import { PrismaClient } from '@prisma/client';

const SETTING_ID = 1;
let prisma;
if (!globalThis._prisma) {
  globalThis._prisma = new PrismaClient();
}
prisma = globalThis._prisma;

const defaults = {
  id: SETTING_ID,
  riskPercent: 2,
  minConfidence: 70,
  placeTestTrade: false,
  useTrailingStop: true,
  atrSLFactor: 2.5,
  baseRR: 2,
  tradingEnabled: true,
};

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-API-Key');
}

export default async function handler(req, res) {
  cors(res);
  if (req.method === 'OPTIONS') return res.status(204).end();

  if (req.method === 'GET') {
    try {
      let row = await prisma.setting.findUnique({ where: { id: SETTING_ID } });
      if (!row) {
        row = await prisma.setting.create({ data: defaults });
      }
      return res.status(200).json({
        riskPercent: row.riskPercent,
        minConfidence: row.minConfidence,
        placeTestTrade: row.placeTestTrade,
        useTrailingStop: row.useTrailingStop,
        atrSLFactor: row.atrSLFactor,
        baseRR: row.baseRR,
        tradingEnabled: row.tradingEnabled !== false,
        updatedAt: row.updatedAt?.toISOString?.() || row.updatedAt,
      });
    } catch (e) {
      console.error('Settings GET error:', e);
      // Return 200 with defaults so command center keeps working; add warning for debugging
      const msg = e?.message || String(e);
      return res.status(200).json({
        ...defaults,
        tradingEnabled: true,
        updatedAt: new Date().toISOString(),
        _warning: 'Database error: ' + msg + '. Run: npx prisma db push',
      });
    }
  }

  if (req.method === 'POST') {
    let body;
    try {
      body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body || {};
    } catch {
      return res.status(400).json({ error: 'Invalid JSON' });
    }
    const data = {
      riskPercent: typeof body.riskPercent === 'number' ? body.riskPercent : parseFloat(body.riskPercent) || defaults.riskPercent,
      minConfidence: typeof body.minConfidence === 'number' ? body.minConfidence : parseFloat(body.minConfidence) || defaults.minConfidence,
      placeTestTrade: Boolean(body.placeTestTrade),
      useTrailingStop: body.useTrailingStop !== false,
      atrSLFactor: typeof body.atrSLFactor === 'number' ? body.atrSLFactor : parseFloat(body.atrSLFactor) || defaults.atrSLFactor,
      baseRR: typeof body.baseRR === 'number' ? body.baseRR : parseFloat(body.baseRR) || defaults.baseRR,
      tradingEnabled: body.tradingEnabled !== false,
    };
    try {
      const row = await prisma.setting.upsert({
        where: { id: SETTING_ID },
        create: { id: SETTING_ID, ...data },
        update: data,
      });
      return res.status(200).json({
        ok: true,
        riskPercent: row.riskPercent,
        minConfidence: row.minConfidence,
        placeTestTrade: row.placeTestTrade,
        useTrailingStop: row.useTrailingStop,
        atrSLFactor: row.atrSLFactor,
        baseRR: row.baseRR,
        tradingEnabled: row.tradingEnabled !== false,
        updatedAt: row.updatedAt?.toISOString?.() || row.updatedAt,
      });
    } catch (e) {
      console.error('Settings POST error:', e);
      const msg = e?.message || String(e);
      return res.status(500).json({
        error: 'Database error',
        details: msg,
        hint: 'Ensure DATABASE_URL is set and run: npx prisma db push',
      });
    }
  }

  return res.status(405).json({ error: 'Method not allowed' });
}
