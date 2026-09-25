// The container's front door, so the live threat feed reaches the browser.
//
// src/hooks/use-threat-stream.ts connects straight to http://localhost:3003
// only when the page is served from localhost:3000, and otherwise to
// "/?XTransformPort=3003". socket.io reads that as the page's own origin with
// its default path, so the browser's requests arrive here as
// /socket.io/?XTransformPort=3003&EIO=4&transport=polling. Behind anything but
// a proxy that knows what to do with them they reach Next.js, which knows
// nothing about them, and the dashboard's badge reads OFFLINE forever.
//
// So: /socket.io/ and anything naming ?XTransformPort=3003 go to the threat
// feed, ?XTransformPort=3004 goes to the watchdog, and everything else goes to
// the dashboard. Nothing in the app changes, and the developer's own
// localhost:3000 checkout is untouched, because there the hook never asks for
// any of this.
//
// It is deliberately the only thing in front of Next.js. It adds no caching,
// no rewriting and no TLS: whatever a platform's own ingress does stays its
// business.

const LISTEN = Number(process.env.PROXY_PORT || 3000);
const APP = `http://127.0.0.1:${process.env.APP_PORT || 3100}`;
const FEED = `http://127.0.0.1:${process.env.FEED_PORT || 3003}`;
const FEED_WS = FEED.replace("http://", "ws://");
const FEED_PATH = "/socket.io/";

// The app's own convention for reaching a mini-service through the page's
// origin, as ?XTransformPort=<port>. The hook uses it for the feed today, and
// the System Status panel's ports are the only two that may ever be named, so
// they are the only two allowed: forwarding to whatever port a query asks for
// would make this an open door onto the container's localhost.
const BY_QUERY = new Map([
	["3003", FEED],
	["3004", `http://127.0.0.1:${process.env.WATCHDOG_PORT || 3004}`],
]);

// upstreamFor returns the base URL a request goes to, and whether it is the
// feed (the only one worth relaying a websocket for).
function upstreamFor(url) {
	const asked = BY_QUERY.get(url.searchParams.get("XTransformPort") || "");
	if (asked) return { base: asked, feed: asked === FEED };
	if (url.pathname.startsWith(FEED_PATH)) return { base: FEED, feed: true };
	return { base: APP, feed: false };
}

// Headers that belong to one hop and must not be forwarded, plus the two that
// describe a body this process did not encode: fetch decodes the upstream
// response, so passing its content-encoding and content-length on would
// describe the bytes wrongly.
const HOP = new Set([
	"connection",
	"keep-alive",
	"proxy-authenticate",
	"proxy-authorization",
	"te",
	"trailer",
	"transfer-encoding",
	"upgrade",
	"content-encoding",
	"content-length",
]);

function forwardHeaders(req, url) {
	const h = new Headers();
	for (const [k, v] of req.headers) {
		if (!HOP.has(k.toLowerCase())) h.set(k, v);
	}
	// identity, so the upstream does not compress a body this process would
	// then hand on decoded.
	h.set("accept-encoding", "identity");
	h.set("x-forwarded-host", req.headers.get("host") || url.host);
	h.set("x-forwarded-proto", url.protocol.replace(":", ""));
	return h;
}

function responseHeaders(res) {
	const h = new Headers();
	for (const [k, v] of res.headers) {
		if (!HOP.has(k.toLowerCase())) h.set(k, v);
	}
	return h;
}

const server = Bun.serve({
	port: LISTEN,
	hostname: "0.0.0.0",
	// A long poll is held open for as long as the feed's pingInterval, and a
	// websocket for as long as the page is open, so neither may time out.
	idleTimeout: 0,
	async fetch(req, srv) {
		const url = new URL(req.url);
		const { base, feed: toFeed } = upstreamFor(url);

		if (toFeed && (req.headers.get("upgrade") || "").toLowerCase() === "websocket") {
			const target = FEED_WS + url.pathname + url.search;
			const protocol = req.headers.get("sec-websocket-protocol") || undefined;
			if (srv.upgrade(req, { data: { target, protocol } })) return undefined;
			return new Response("websocket upgrade failed", { status: 400 });
		}

		const init = {
			method: req.method,
			headers: forwardHeaders(req, url),
			redirect: "manual",
		};
		if (req.method !== "GET" && req.method !== "HEAD") {
			init.body = req.body;
			init.duplex = "half"; // stream the body rather than reading it first
		}
		try {
			const res = await fetch(base + url.pathname + url.search, init);
			return new Response(res.body, {
				status: res.status,
				statusText: res.statusText,
				headers: responseHeaders(res),
			});
		} catch (e) {
			// The dashboard is not listening yet, or has stopped. Say which one,
			// because a 502 from a proxy nobody knew was there is a bad hour.
			const who = base === APP ? "dashboard" : base === FEED ? "threat feed" : "watchdog";
			return new Response(`${who} is not answering: ${e.message}\n`, {
				status: 502,
				headers: { "content-type": "text/plain" },
			});
		}
	},
	websocket: {
		open(ws) {
			// Bun delivers frames from the browser as soon as the socket is
			// open, which can be before the feed's side is, so they queue.
			ws.data.queue = [];
			const up = new WebSocket(ws.data.target, ws.data.protocol);
			up.binaryType = "arraybuffer";
			ws.data.up = up;
			up.onopen = () => {
				for (const m of ws.data.queue) up.send(m);
				ws.data.queue = null;
			};
			up.onmessage = (ev) => ws.send(ev.data);
			up.onclose = (ev) => ws.close(ev.code >= 1000 && ev.code <= 4999 ? ev.code : 1011, ev.reason);
			up.onerror = () => ws.close(1011, "threat feed websocket failed");
		},
		message(ws, message) {
			const up = ws.data.up;
			if (!up || up.readyState !== WebSocket.OPEN) {
				if (ws.data.queue) ws.data.queue.push(message);
				return;
			}
			up.send(message);
		},
		close(ws) {
			try {
				ws.data.up?.close();
			} catch {}
		},
	},
});

console.log(
	`[proxy] listening on ${server.port}: ${FEED_PATH} and ?XTransformPort=3003 to ${FEED}, ` +
		`?XTransformPort=3004 to the watchdog, everything else to ${APP}`,
);
