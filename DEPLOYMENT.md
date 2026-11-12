# DEPLOYMENT

> **The iPhone app does not need any of this.** It ships with the transit
> network and calls İETT directly. Deploy the backend only if you want
> continuous position history and measured ETA accuracy.

---

## What was actually verified on this Mac

| Step | Result |
|---|---|
| `createdb rova` on Homebrew PostgreSQL 16.15 | ✅ |
| `npx ts-node src/db/migrate.ts` | ✅ 12 tables created |
| `npx ts-node src/db/seed.ts` | ✅ 15 141 stops · 782 lines · 2 876 patterns · 128 559 route stops · 134 293 trips |
| `npx ts-node src/main.ts` | ✅ listening on `:3111` |
| `GET /health` | ✅ |
| `GET /health/detail` | ✅ reported `146: valid=2 stale=0 healthy=true` from live İETT data |
| `GET /v1/lines/146/vehicles` | ✅ returned real vehicles A-1539 and B-1887 |
| `GET /v1/stops/177182/arrivals` | ✅ returned a real ETA (25.4 min, medium confidence) |
| Auth without token | ✅ 401 |
| `npm test` | ✅ 28/28 |
| `ROVA_LIVE_TESTS=1 npx jest live` | ✅ 6/6 against api.ibb.gov.tr |

**Not verified:** Docker (not installed on this machine) and remote server
deployment (no server credentials were available, and none were invented).
The Compose and nginx files below are written and reviewed but have not been
run.

---

## Local (what is running now)

```bash
cd backend
cp .env.example .env
# generate the private device token
printf 'ROVA_DEVICE_TOKEN=%s\n' "$(openssl rand -hex 32)" >> .env

createdb rova
npm install
set -a; . ./.env; set +a

npx ts-node src/db/migrate.ts            # schema
npx ts-node src/db/seed.ts               # network from the iOS bundle
npm run start:dev                        # or: npm run build && npm start
```

Check it:

```bash
curl -s localhost:3111/health
curl -s localhost:3111/health/detail | python3 -m json.tool
curl -s -H "Authorization: Bearer $ROVA_DEVICE_TOKEN" \
  localhost:3111/v1/lines/146/vehicles | python3 -m json.tool
```

### Keeping it running after you close the terminal

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.msgone.rova.backend.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.msgone.rova.backend</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/node</string>
    <string>/Users/mohammed/Projects/ROVA/backend/dist/main.js</string>
  </array>
  <key>WorkingDirectory</key><string>/Users/mohammed/Projects/ROVA/backend</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/rova-backend.log</string>
  <key>StandardErrorPath</key><string>/tmp/rova-backend.err</string>
</dict></plist>
PLIST

cd backend && npm run build
launchctl load ~/Library/LaunchAgents/com.msgone.rova.backend.plist
```

`dist/main.js` reads `.env` through `@nestjs/config`, so no environment needs
to be injected into the plist. Nothing secret appears in it.

---

## Reaching the Mac from the phone over mobile data (what is running now)

The iPhone on 5G cannot see `localhost` on the Mac. `cloudflared` publishes it
at an HTTPS address with no account, no router changes, no port forwarding and
without exposing the home IP:

```bash
cloudflared tunnel --no-autoupdate --url http://localhost:3111
tools/rova-url.sh          # prints the current URL and checks it answers
```

Verified on 2026-11-12 through the public URL: `/health` answered, an
unauthorised `/v1` request was refused with **401**, `POST /v1/watch/142ES`
added a line that was not configured, and `/v1/lines/142ES/vehicles` returned
three real vehicles 53 s old.

**The hostname is assigned per cloudflared session**, so it changes if
cloudflared restarts. Run `tools/rova-url.sh` and paste the new one into
ROVA → Settings → ROVA backend. Nothing breaks meanwhile: the app falls back
to calling İETT directly whenever the backend is unreachable.

### Keeping both alive across reboots

`deploy/launchd/` holds the two agents. They are **not installed** — installing
a login agent was outside what this session was permitted to do, so it is your
call:

```bash
cp deploy/launchd/com.msgone.rova.{backend,tunnel}.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.msgone.rova.backend.plist
launchctl load ~/Library/LaunchAgents/com.msgone.rova.tunnel.plist
```

Until then both run as plain background processes and stop at logout or
restart; restart them with the commands under *Local*, above.

### Why the phone uses the backend at all

İETT allows ~100 requests an hour **per caller**. With the backend as that
caller, the watched line is refreshed at the source's own 60 s cadence and the
phone reads from the backend every 20 s at no quota cost. `POST /v1/watch/:line`
is how the app says which line matters; everything else drops to one refresh
every 7 minutes, which keeps the total near 86/hour.

---

## Server, with Docker

Docker is **not installed on this Mac**; install Docker Desktop or run these
on a Linux host.

```bash
export POSTGRES_PASSWORD=$(openssl rand -hex 24)
cp backend/.env.example backend/.env
printf 'ROVA_DEVICE_TOKEN=%s\n' "$(openssl rand -hex 32)" >> backend/.env

docker compose up -d --build
docker compose exec api node dist/db/migrate.js
docker compose exec api node dist/db/seed.js /app/bundle/rova-transit.sqlite
curl -s localhost:3111/health/detail | python3 -m json.tool
```

The API is bound to `127.0.0.1` on purpose. Put nginx in front of it.

### TLS and reverse proxy

```bash
sudo cp deploy/nginx-rova.conf /etc/nginx/sites-available/rova
sudo ln -s /etc/nginx/sites-available/rova /etc/nginx/sites-enabled/rova
sudo certbot certonly --nginx -d rova.example.com
sudo nginx -t && sudo systemctl reload nginx
```

Then in the ROVA app: **Settings → ROVA backend → `https://rova.example.com`**.

Do not expose the API over plain HTTP. The device token is a bearer
credential; `NSAppTransportSecurity` in `Info.plist` permits cleartext only
for `localhost`.

---

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `NODE_ENV` | `development` | `production` refuses to start if demo mode is on |
| `PORT` | `3111` | 3000 is commonly taken on a dev Mac |
| `DATABASE_URL` | — | required |
| `ROVA_DEVICE_TOKEN` | — | required for `/v1`; `openssl rand -hex 32` |
| `IETT_FLEET_URL` | official URL | |
| `IETT_NETWORK_URL` | official URL | |
| `IETT_HOURLY_LIMIT` | `40` | stays under İETT's 100/h, shared with the phone |
| `INGEST_ENABLED` | `false` | see below |
| `INGEST_LINES` | `146,142,142A` | round-robin poll list |
| `POSITION_HISTORY_HOURS` | `72` | retention for raw fixes |
| `ROVA_DEMO_MODE` | `false` | development only; refused in production |

### Why ingestion is off by default

İETT allows 100 requests per hour **per caller**. A phone at home and a
backend on the same network share one public IP and therefore one quota.
Exceeding it produces a `Policy Falsified` fault and live tracking stops for
everyone behind that address — this happened during development and is
documented in [DATA_SOURCES.md](DATA_SOURCES.md).

Set `INGEST_ENABLED=true` only when the backend runs somewhere the phone does
not — a VPS, for example — or when you want accuracy measurement badly enough
to give the server the budget.

---

## Backups

```bash
pg_dump -Fc rova > rova-$(date +%F).dump          # local
docker compose exec -T db pg_dump -U rova -Fc rova > rova-$(date +%F).dump
```

`vehicle_position_history` is the only table that grows; retention keeps it
at roughly 72 hours of distinct fixes for the ingested lines.

---

## Upgrading the transit network

İBB republishes the GTFS export a few times a year.

```bash
# refresh data/raw and data/gtfs-iett (see tools/ for the download URLs)
python3 tools/build_bundle.py
cd ios && xcodegen generate && xcodebuild ... # rebuild and reinstall the app
cd backend && npx ts-node src/db/seed.ts      # and reseed the server
```
