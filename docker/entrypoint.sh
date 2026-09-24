#!/bin/sh
# Starts the web app, its two mini-services and the proxy in one container.
# If any of them exits, the container exits, so the platform restarts it.
set -eu

cd /app
mkdir -p db
export DATABASE_URL="file:/app/db/custom.db"

# Create or update the SQLite schema. Safe to run on every start.
bun /opt/prisma-cli/node_modules/prisma/build/index.js db push --schema prisma/schema.prisma --skip-generate

(cd mini-services/threat-feed-service && exec bun index.ts) &
(cd mini-services/watchdog-scheduler && exec bun index.ts) &
(HOSTNAME=127.0.0.1 PORT=3000 NODE_ENV=production exec bun server.js) &
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

trap 'kill 0' TERM INT
# wait -n is not in every sh; poll instead.
while :; do
  for pid in $(jobs -p); do
    kill -0 "$pid" 2>/dev/null || { echo "a process exited, stopping" >&2; kill 0; exit 1; }
  done
  sleep 5
done
