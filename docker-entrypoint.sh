#!/bin/sh
# Bring the SQLite schema up to date, start the dashboard, and start the
# mini-services behind it. That is what package.json's "start" and the
# dashboard's own self-healing do between them; this is the same thing inside a
# container.
set -e

mkdir -p /app/db

# The schema. The CLI is the pinned one under /opt, called by its path: "bunx
# prisma" fetches a newer CLI from the registry whose commands have moved, and
# the copy under the app's own node_modules lacks the CLI's dependency tree.
bun /opt/prisma/node_modules/prisma/build/index.js db push \
	--schema=/app/prisma/schema.prisma --skip-generate

# The threat feed (3003) and the watchdog and scheduler (3004), started by the
# repository's own script so there is one way of starting them. It is
# idempotent, and it is the same script the dashboard runs when its System
# Status panel finds a service down, so a service that dies comes back.
#
# They wait for the dashboard first. The watchdog runs its own health check two
# seconds after it starts and counts a failure towards restarting the app, so
# starting it before the server is listening puts a failure in the log for
# nothing. The wait gives up after two minutes and starts them anyway, because
# a dashboard that never answers is the watchdog's business.
(
	i=0
	while [ "$i" -lt 120 ]; do
		if bun -e "fetch('http://127.0.0.1:3000/api/stats').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
			break
		fi
		i=$((i + 1))
		sleep 1
	done
	bash /app/mini-services/start-services.sh || echo "[entrypoint] mini-services did not all start; the dashboard will retry"
) &

exec "$@"
