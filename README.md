# Command center – api.aitrading.software

Centraal dashboard voor de XAUUSD_AI_EA: welke VPS/account verbonden is, balance/equity/open trades, en **AI trading AAN/UIT** vanaf de website.

## Projectstructuur

- `api/log.js` – POST logs van de EA.
- `api/logs.js` – GET laatste logs.
- `api/settings.js` – GET/POST instellingen (incl. **tradingEnabled** = AI aan/uit).
- `api/heartbeat.js` – POST account + posities van de EA (VPS/account/balance/trades).
- `api/connections.js` – GET lijst verbonden VPS/accounts.
- `public/index.html` – **Command center**: verbindingen, toggle AI trading, live log.
- `public/settings.html` – Instellingen (incl. AI trading aan/uit).
- `XAUUSD_AI_EA.mq5` – EA met WebLog, web settings en heartbeat.

## Deploy op Vercel

1. **Repo koppelen**
   - Vercel Dashboard → New Project → Import deze repo (`aitradingbotv2`).
   - **Geen** Root Directory instellen (root van de repo gebruiken).

2. **Database (Prisma/Postgres)**
   - Zet **DATABASE_URL** in Environment Variables (bijv. Prisma Accelerate URL).
   - Lokaal eenmalig: `npx prisma db push` om tabellen (Log, Setting, Connection) aan te maken.

3. **Domein**
   - Settings → Domains → voeg `api.aitrading.software` toe.

4. **Optioneel: API-key**
   - Settings → Environment Variables → `LOG_API_KEY` = een geheim wachtwoord.
   - In de EA vul je dan `WebLogSecret` met dezelfde waarde.

## Endpoints

- **POST /api/log** – EA stuurt hier logs naartoe (JSON body: `message`, `level`, `time`, `symbol`, `source`). Optioneel header: `X-API-Key`.
- **GET /api/logs** – Laatste logs (dashboard). Query: `?limit=200`.
- **GET /api/settings** – Instellingen voor de EA. **POST /api/settings** – Opslaan (vanaf /settings).

## Dashboard

- **https://api.aitrading.software/** of **https://api.aitrading.software/logs** – toont de live log. Vernieuwt elke 3–10 sec.

## MT5 instellen

1. **Tools → Options → Expert Advisors** → vink “Allow WebRequest for listed URL” aan.
2. Voeg toe: `https://api.aitrading.software`
3. **UseWebSettings = true** → EA haalt instellingen (en **tradingEnabled**) van /api/settings.
4. **UseWebHeartbeat = true** en **WebHeartbeatUrl** = `https://api.aitrading.software/api/heartbeat` → account + posities in command center.

