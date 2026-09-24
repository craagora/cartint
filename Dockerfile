# CARTINT in one image: the Next.js app, the threat-feed and watchdog
# mini-services, and a small Caddy proxy that puts them on one port (8080).
# State (the SQLite database and saved AI settings) lives in /app/db.

FROM oven/bun:1-debian AS build
WORKDIR /app
COPY package.json bun.lock ./
COPY prisma ./prisma
RUN bun install --frozen-lockfile
COPY . .
RUN bunx prisma generate && bun run build
# The Prisma CLI, same version as the app's, on its own so the runtime image
# does not need the whole build tree to run prisma db push at start.
RUN v=$(bun -e 'console.log(require("./node_modules/prisma/package.json").version)') \
 && mkdir -p /opt/prisma-cli && cd /opt/prisma-cli && echo '{}' > package.json \
 && bun add "prisma@$v"
RUN cd mini-services/threat-feed-service && bun install --frozen-lockfile --production \
 && cd ../watchdog-scheduler && bun install --production

FROM caddy:2 AS caddy

FROM oven/bun:1-debian
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
COPY docker/Caddyfile /etc/caddy/Caddyfile
COPY docker/entrypoint.sh /usr/local/bin/cartint-start
# The standalone server with its traced node_modules, then static files.
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/mini-services ./mini-services
COPY --from=build /opt/prisma-cli /opt/prisma-cli
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1
VOLUME /app/db
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD bun -e "fetch('http://127.0.0.1:8080/').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["/usr/local/bin/cartint-start"]
