#!/usr/bin/env bash
#
# Deploy the ROVA backend to the always-on Mac, over Tailscale.
#
# The development Mac is closed and carried around; this one sits on power and
# a wired connection and nobody touches it. Accuracy measurement needs weeks of
# uninterrupted running, so production belongs here and nowhere else.
#
#   ./deploy/remote-deploy.sh yshop-imac
#
# The target already runs another service. This script is written to leave it
# completely alone:
#
#   * it refuses to start if its port is already taken, rather than fighting
#     for it;
#   * it creates its own PostgreSQL database and never touches an existing one;
#   * it installs under ~/rova and writes nothing outside that directory, its
#     own launchd agent, and its own log files.
#
# It is safe to run repeatedly: every step checks the current state first.

set -euo pipefail

HOST="${1:-}"
PORT="${ROVA_PORT:-3111}"
REMOTE_DIR="\$HOME/rova"
DB_NAME="rova"

if [ -z "$HOST" ]; then
  echo "usage: $0 <tailscale-host>   e.g. $0 yshop-imac" >&2
  exit 2
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The device token must carry over, or the iPhone's stored credentials stop
# matching and every request is rejected with 401. Take it from the local
# .env rather than letting an unset variable write an empty token silently.
if [ -z "${ROVA_DEVICE_TOKEN:-}" ] && [ -f "$SRC/backend/.env" ]; then
  ROVA_DEVICE_TOKEN="$(grep -E '^ROVA_DEVICE_TOKEN=' "$SRC/backend/.env" | cut -d= -f2-)"
fi
if [ -z "${ROVA_DEVICE_TOKEN:-}" ]; then
  echo "REFUSING: no ROVA_DEVICE_TOKEN found. Deploying without it would" >&2
  echo "write an empty token and lock the phone out with 401s." >&2
  exit 2
fi
say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
run() { ssh "$HOST" "$@"; }

# ---------------------------------------------------------------- 1. survey
say "Surveying $HOST (changing nothing)"

run 'bash -s' <<'PROBE'
set -u
printf 'hostname      : %s\n' "$(hostname)"
printf 'macOS         : %s\n' "$(sw_vers -productVersion)"
printf 'uptime        : %s\n' "$(uptime | sed 's/.*up //; s/,.*users.*//')"
printf 'node          : %s\n' "$(command -v node >/dev/null && node -v || echo MISSING)"
printf 'npm           : %s\n' "$(command -v npm >/dev/null && npm -v || echo MISSING)"
printf 'psql          : %s\n' "$(command -v psql >/dev/null && psql --version || echo MISSING)"
printf 'pg running    : %s\n' "$(pg_isready -q 2>/dev/null && echo yes || echo no)"
printf 'cloudflared   : %s\n' "$(command -v cloudflared >/dev/null && cloudflared --version 2>/dev/null | head -1 || echo MISSING)"
echo  'listening ports (what is already running here):'
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print "  " $1 " " $9}' | sort -u | head -20
PROBE

# ------------------------------------------------------- 2. port is ours?
say "Checking port $PORT is free"
if run "lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1"; then
  echo "REFUSING: something already listens on $PORT on $HOST." >&2
  echo "That is probably the other service. Re-run with ROVA_PORT=<free port>." >&2
  exit 1
fi
echo "port $PORT is free"

# ------------------------------------------------------------- 3. copy code
say "Copying backend source (excluding build output and secrets)"
run "mkdir -p $REMOTE_DIR"
rsync -az --delete \
  --exclude node_modules --exclude dist --exclude .env --exclude '*.log' \
  "$SRC/backend/" "$HOST:rova/backend/"
rsync -az "$SRC/data/bundle/" "$HOST:rova/data/bundle/" 2>/dev/null || true

# -------------------------------------------------------------- 4. database
say "Creating the $DB_NAME database if it does not exist"
run "bash -s" <<PGSETUP
set -eu
if psql -lqt 2>/dev/null | cut -d '|' -f1 | grep -qw "$DB_NAME"; then
  echo "database $DB_NAME already exists — leaving it alone"
else
  createdb "$DB_NAME"
  echo "created database $DB_NAME"
fi
PGSETUP

# ------------------------------------------------------ 5. secrets and build
say "Writing .env (token carried over so the iPhone keeps working)"
run "bash -s" <<ENVSETUP
set -eu
cd "$REMOTE_DIR/backend"
if [ -f .env ]; then
  echo ".env already present — keeping existing credentials"
else
  umask 077
  printf 'DATABASE_URL=postgres://%s@localhost:5432/%s\n' "\$(whoami)" "$DB_NAME" > .env
  printf 'PORT=%s\n' "$PORT" >> .env
  printf 'ROVA_DEVICE_TOKEN=%s\n' "$ROVA_DEVICE_TOKEN" >> .env
  echo "wrote .env (mode 600)"
fi
ENVSETUP

say "Installing dependencies and building"
run "cd $REMOTE_DIR/backend && npm ci --omit=dev --silent || npm install --silent"
run "cd $REMOTE_DIR/backend && npm install --silent --include=dev && npm run build"
run "cd $REMOTE_DIR/backend && npm run migrate 2>/dev/null || node dist/db/migrate.js"

say "Done. Next: restore the data dump, then install the launchd agent."

# ------------------------------------------------------- 6. restore history
# Optional: carries the measurement history across, so prediction settling and
# the accuracy sample do not restart from zero.
if [ -n "${ROVA_DUMP:-}" ] && [ -f "$ROVA_DUMP" ]; then
  say "Restoring $(du -h "$ROVA_DUMP" | cut -f1) of recorded history"
  scp -q "$ROVA_DUMP" "$HOST:/tmp/rova-db.dump"
  run "pg_restore --no-owner --no-privileges --data-only --disable-triggers \
         -d $DB_NAME /tmp/rova-db.dump 2>&1 | tail -5; rm -f /tmp/rova-db.dump"
else
  echo "(no ROVA_DUMP given — starting with an empty history)"
fi

# ------------------------------------------------------------ 7. keep it up
# The plist is generated on the target rather than shipped, because the node
# path differs between Apple Silicon and Intel Macs and the home directory is
# not this machine's. A plist with a wrong path fails at load with a generic
# I/O error that says nothing about the cause.
say "Installing the launchd agent"
run "bash -s" <<AGENT
set -eu
NODE="\$(command -v node)"
HOME_DIR="\$HOME"
LABEL="com.msgone.rova.backend"
PLIST="\$HOME/Library/LaunchAgents/\$LABEL.plist"
mkdir -p "\$HOME/Library/LaunchAgents" "\$HOME/rova/logs"

cat > "\$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>\$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>\$NODE</string>
    <string>\$HOME_DIR/rova/backend/dist/main.js</string>
  </array>
  <key>WorkingDirectory</key><string>\$HOME_DIR/rova/backend</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>\$HOME_DIR/rova/logs/backend.log</string>
  <key>StandardErrorPath</key><string>\$HOME_DIR/rova/logs/backend.err</string>
</dict></plist>
PLISTEOF

plutil -lint "\$PLIST"

# bootout then bootstrap: 'launchctl load' is deprecated and reports a bare
# "Input/output error" for anything it dislikes, including a label that is
# already registered.
launchctl bootout "gui/\$(id -u)/\$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/\$(id -u)" "\$PLIST"
launchctl kickstart -k "gui/\$(id -u)/\$LABEL"
echo "agent installed and started"
AGENT

# --------------------------------------------------------------- 8. verify
say "Verifying it is actually serving"
sleep 5
if run "curl -fsS --max-time 10 http://localhost:$PORT/health"; then
  echo
  echo "backend is up on $HOST:$PORT"
else
  echo "NOT HEALTHY — check: ssh $HOST 'tail -40 ~/rova/logs/backend.err'" >&2
  exit 1
fi
