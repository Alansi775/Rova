#!/bin/bash
# Prints the backend's current public URL, and checks that it answers.
#
# The quick tunnel's hostname is assigned per cloudflared session, so it
# changes if cloudflared restarts. If it has changed, paste the new URL into
# ROVA: Settings → ROVA backend. The app keeps working regardless — it falls
# back to calling İETT directly whenever the backend is unreachable.
URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/rova-tunnel.log | tail -1)
if [ -z "$URL" ]; then
  echo "No tunnel URL found. Is cloudflared running?  pgrep -fl cloudflared"
  exit 1
fi
echo "$URL"
printf 'health: '
curl -s -m 10 "$URL/health" || echo "(no answer)"
echo
