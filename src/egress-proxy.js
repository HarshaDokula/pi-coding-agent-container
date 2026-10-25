"use strict";

/**
 * egress-proxy — a zero-dependency outbound allowlist proxy.
 *
 * The pi-agent container is put on an `internal: true` Docker network when
 * EGRESS is enabled, so it cannot reach the internet directly. This sidecar is
 * the only path out: it accepts plain-HTTP proxy requests and CONNECT tunnels
 * and forwards them ONLY to hosts in EGRESS_ALLOWLIST. Every other host gets a
 * 403 and the connection is dropped (SECURITY.md, B5).
 *
 * Allowlist syntax (comma-separated):
 *   host            -> host:443
 *   host:port       -> exact host + port
 *   *.host[:port]   -> any subdomain of host
 *
 * Run:  EGRESS_ALLOWLIST="api.deepseek.com,github.com" node egress-proxy.js
 */

const http = require("http");
const net = require("net");

function parseAllowlist(raw) {
  const list = [];
  for (const entry of String(raw || "").split(",")) {
    const e = entry.trim().toLowerCase();
    if (!e) continue;
    let host = e;
    let port = 443;
    // host:port — do not split IPv6 literals (unsupported here).
    if (!e.startsWith("[")) {
      const idx = e.lastIndexOf(":");
      if (idx > 0) {
        const maybePort = Number(e.slice(idx + 1));
        if (Number.isInteger(maybePort) && maybePort > 0 && maybePort < 65536) {
          host = e.slice(0, idx);
          port = maybePort;
        }
      }
    }
    list.push({ host, port });
  }
  return list;
}

function isAllowed(allowlist, host, port) {
  const h = String(host || "").toLowerCase();
  const p = Number(port) || 443;
  for (const a of allowlist) {
    if (a.port !== p) continue;
    if (a.host === h) return true;
    if (a.host.startsWith("*.") && h.endsWith(a.host.slice(1))) return true;
  }
  return false;
}

function createProxyServer(allowlist) {
  const server = http.createServer();

  // HTTPS via CONNECT: open a raw TCP tunnel to the allowlisted target.
  server.on("connect", (req, clientSocket, head) => {
    const url = String(req.url || "");
    const idx = url.lastIndexOf(":");
    const host = idx > 0 ? url.slice(0, idx) : url;
    const port = idx > 0 ? Number(url.slice(idx + 1)) : 443;

    if (!isAllowed(allowlist, host, port)) {
      clientSocket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
      clientSocket.destroy();
      return;
    }

    const upstream = net.connect(port, host, () => {
      clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
      if (head && head.length) upstream.write(head);
      upstream.pipe(clientSocket);
      clientSocket.pipe(upstream);
    });
    upstream.on("error", () => clientSocket.destroy());
    clientSocket.on("error", () => upstream.destroy());
  });

  // Plain HTTP proxying (absolute-form request line).
  server.on("request", (req, res) => {
    let u;
    try {
      u = new URL(req.url);
    } catch {
      res.writeHead(400, { "Content-Type": "text/plain" });
      res.end("Bad Request");
      return;
    }
    const host = u.hostname;
    const port = u.port ? Number(u.port) : 80;
    if (!isAllowed(allowlist, host, port)) {
      res.writeHead(403, { "Content-Type": "text/plain" });
      res.end("Forbidden: host not in allowlist");
      return;
    }

    const upstream = http.request(
      {
        host,
        port,
        path: u.pathname + u.search,
        method: req.method,
        headers: req.headers,
      },
      (up) => {
        res.writeHead(up.statusCode || 502, up.headers);
        up.pipe(res);
      },
    );
    upstream.on("error", () => {
      res.writeHead(502, { "Content-Type": "text/plain" });
      res.end("Bad Gateway");
    });
    req.pipe(upstream);
  });

  return server;
}

if (require.main === module) {
  const allowlist = parseAllowlist(process.env.EGRESS_ALLOWLIST || "");
  const port = Number(process.env.PORT) || 8888;

  if (allowlist.length === 0) {
    console.error("egress-proxy: EGRESS_ALLOWLIST is empty — refusing to run an open proxy.");
    process.exit(1);
  }

  createProxyServer(allowlist).listen(port, () => {
    const hosts = allowlist.map((a) => `${a.host}:${a.port}`).join(",");
    console.error(`egress-proxy: listening on :${port}, allowlist=${hosts}`);
  });
}

module.exports = { parseAllowlist, isAllowed, createProxyServer };
