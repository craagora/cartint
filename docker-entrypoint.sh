#!/bin/sh
# Bring the SQLite schema up to date, put the proxy in front, start the
# dashboard, and start the mini-services behind it. That is what package.json's
# "start" and the dashboard's own self-healing do between them, plus the one
# piece a container needs that a developer's machine does not.
set -e

mkdir -p /app/db

# The schema. The CLI is the pinned one under /opt, called by its path: "bunx
# prisma" fetches a newer CLI from the registry whose commands have moved, and
# the copy under the app's own node_modules lacks the CLI's dependency tree.
bun /opt/prisma/node_modules/prisma/build/index.js db push \
	--schema=/app/prisma/schema.prisma --skip-generate

# The proxy, on the published port. It answers 502 until the dashboard is
# listening, which is what the wait below is for. Nothing else restarts it, so
# it restarts itself: the dashboard is PID 1 and the container's life is the
# dashboard's, but an unreachable container would be worse than a dead one.
(
	while :; do
		bun /app/docker-feed-proxy.js || true
		echo "[entrypoint] the proxy exited; starting it again"
		sleep 2
	done
) &

# The threat feed (3003) and the watchdog and scheduler (3004), started by the
# repository's own script so there is one way of starting them. It is
# idempotent, and it is the same script the dashboard runs when its System
# Status panel finds a service down, so a service that dies comes back.
#
# They wait for the dashboard first, through the proxy, which checks both. The
# watchdog runs its own health check two seconds after it starts and counts a
# failure towards restarting the app, so starting it before the server is
# listening puts a failure in the log for nothing. The wait gives up after two
# minutes and starts them anyway, because a dashboard that never answers is the
# watchdog's business.
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
