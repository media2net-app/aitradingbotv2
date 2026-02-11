# EA Log API – api.aitrading.software

Kleine API + dashboard om live logs van de XAUUSD_AI_EA (MT5/VPS) te ontvangen en te bekijken.

## Deploy op Vercel

1. **Repo koppelen**
   - Vercel Dashboard → New Project → Import dit project.
   - Als de repo de **parent** map is (niet alleen `ea-log-api`), zet dan **Root Directory** op `ea-log-api`.

2. **Vercel KV (Redis) toevoegen**
   - In het project: Storage → Create Database → KV (Upstash Redis).
   - Zo wordt `@vercel/kv` gekoppeld en krijg je o.a. `KV_REST_API_URL` en `KV_REST_API_TOKEN`.

3. **Domein**
   - Settings → Domains → voeg `api.aitrading.software` toe.

4. **Optioneel: API-key**
   - Settings → Environment Variables → `LOG_API_KEY` = een geheim wachtwoord.
   - In de EA vul je dan `WebLogSecret` met dezelfde waarde.

## Endpoints

- **POST /api/log** – EA stuurt hier logs naartoe (JSON body: `message`, `level`, `time`, `symbol`, `source`). Optioneel header: `X-API-Key`.
- **GET /api/logs** – Geeft de laatste logs (voor het dashboard). Query: `?limit=200`.

## Dashboard

- **https://api.aitrading.software/** of **https://api.aitrading.software/logs** – toont de live log. Vernieuwt elke 3–10 sec.

## MT5 instellen

1. **Tools → Options → Expert Advisors** → vink “Allow WebRequest for listed URL” aan.
2. Voeg toe: `https://api.aitrading.software`
3. In de EA: **WebLogUrl** = `https://api.aitrading.software/api/log`, eventueel **WebLogSecret** = je `LOG_API_KEY`.
