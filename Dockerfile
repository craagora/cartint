# CARTINT as a container: the Next.js standalone build on Bun, the two
# mini-services beside it, and the SQLite database on a volume so it survives a
# restart.
#
# Two stages. The first installs every dependency and builds; the second keeps
# the standalone output, the Prisma schema, the Prisma CLI and the
# mini-services, and nothing else.
#
# All three processes run in this one container because the app is written that
# way and cannot be split without changing it: the System Status panel probes
# http://localhost:3003/health and http://localhost:3004/health by those exact
# names, the scraper posts to THREAT_FEED_URL whose default is localhost:3003,
# and mini-services/start-services.sh (which the dashboard runs itself when it
# finds a service down) starts them as local processes.

FROM oven/bun:1 AS build
WORKDIR /app

# Dependencies first, so a change to the source does not refetch them.
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile

COPY . .
# The client has to be generated before the build: next build imports it.
RUN bunx prisma generate && bun run build

FROM oven/bun:1 AS runtime
WORKDIR /app
ENV NODE_ENV=production
# The database lives on the volume, never in the image layer.
ENV DATABASE_URL=file:/app/db/custom.db
# The standalone server binds process.env.HOSTNAME, and Docker sets HOSTNAME to
# the container id, so without this line the server answers on the container's
# own address and NOTHING on 127.0.0.1: the healthcheck below, the watchdog's
# ping and the status panel's probes would all fail while the app was serving
# traffic perfectly well through the published port.
ENV HOSTNAME=0.0.0.0
# The two mini-services, as this container addresses them. 127.0.0.1 rather
# than localhost on purpose: the standalone server listens on IPv4 only, and a
# resolver that answers localhost with ::1 first would make the watchdog think
# the dashboard was down. Both are overridable.
ENV NEXT_URL=http://127.0.0.1:3000
ENV THREAT_FEED_URL=http://127.0.0.1:3003

# lsof is what start-services.sh asks whether a mini-service is already
# listening. Without it the check reads as "not running" and every self-heal
# starts a second copy that then fails to bind.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends lsof \
	&& rm -rf /var/lib/apt/lists/*

COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
COPY --from=build /app/prisma ./prisma
COPY --from=build /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=build /app/node_modules/@prisma ./node_modules/@prisma

# The mini-services, with the threat feed's own dependency installed from its
# own lockfile rather than copied, for the reason given below.
COPY --from=build /app/mini-services ./mini-services
WORKDIR /app/mini-services/threat-feed-service
RUN bun install --frozen-lockfile
WORKDIR /app

# The Prisma CLI, pinned to the version this app was built against, installed
# in a directory of its own.
#
# Two things learned the hard way, both of which killed the container on its
# first start:
#   - "bunx prisma" does NOT use the copy in node_modules. It fetches the
#     newest CLI from the registry, whose commands have moved, and answers
#     "db push" with "No command registered for push".
#   - copying node_modules/prisma alone is not enough either: the CLI has its
#     own dependency tree (@prisma/config wants "effect"), so it must be
#     installed rather than copied out of another stage.
# Installing it under /opt keeps it away from the standalone bundle's own
# package.json, which is the server's and should stay untouched.
WORKDIR /opt/prisma
RUN bun add --exact prisma@6.19.2
WORKDIR /app

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh && mkdir -p /app/db

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bun", "server.js"]
