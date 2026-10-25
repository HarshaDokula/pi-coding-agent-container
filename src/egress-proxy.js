"use strict";

/**
 * egress-proxy — outbound proxy with an allowlist and an optional research mode.
 *
 * The pi-agent container runs on an `internal: true` Docker network when egress
 * control is enabled, so it has no direct route to the internet. This sidecar is
 * the only path out. It accepts plain-HTTP proxy requests and CONNECT tunnels.
 *
 * Modes (EGRESS_MODE):
 *   allowlist  (default)  forward only to hosts in EGRESS_ALLOWLIST.
 *   research              allowlist, plus any public host on port 80/443.
 *                          SSRF guard: private, loopback, link-local, CGNAT,
 *                          multicast and metadata addresses are refused, so the
 *                          agent cannot pivot to the Docker host, other
 *                          containers, or cloud metadata services.
 *
 * What research mode does NOT do: it cannot inspect CONNECT tunnels, so it
 * cannot restrict methods or payloads. A host on the public internet can still
 * receive whatever the agent sends it. See SECURITY.md (B5).
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
const dns = require("dns");

const MODES = { ALLOWLIST: "allowlist", RESEARCH: "research" };

function parseMode(raw) {
  const m = String(raw || "").trim().toLowerCase();
  if (m === MODES.RESEARCH) return MODES.RESEARCH;
  return MODES.ALLOWLIST;
}

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

/** Hostnames that must never be reached, whatever DNS says. */
const BLOCKED_HOSTNAMES = [
  /^localhost$/,
  /\.localhost$/,
  /\.local$/,
  /\.internal$/,
  /^metadata$/,
  /^metadata\./,
  /^instance-data$/,
  /(^|\.)docker\.internal$/,
  /^kubernetes\.default$/,
];

function isBlockedHostname(host) {
  const h = String(host || "").toLowerCase().replace(/\.$/, "");
  return BLOCKED_HOSTNAMES.some((re) => re.test(h));
}

/** True only for publicly routable unicast addresses. */
function isPublicAddress(addr) {
  const ip = String(addr || "").toLowerCase();

  // IPv4-mapped IPv6 (::ffff:1.2.3.4) — judge the embedded v4 address.
  const mapped = ip.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return isPublicAddress(mapped[1]);

  if (net.isIPv4(ip)) {
    const [a, b] = ip.split(".").map(Number);
    if (a === 0) return false; // 0.0.0.0/8
    if (a === 10) return false; // RFC1918
    if (a === 127) return false; // loopback
    if (a === 169 && b === 254) return false; // link-local + cloud metadata
    if (a === 172 && b >= 16 && b <= 31) return false; // RFC1918
    if (a === 100 && b >= 64 && b <= 127) return false; // CGNAT
    if (a === 192 && b === 168) return false; // RFC1918
    if (a === 192 && b === 0) return false; // 192.0.0/24 + 192.0.2/24
    if (a === 198 && (b === 18 || b === 19)) return false; // benchmarking
    if (a === 198 && b === 51) return false; // TEST-NET-2
    if (a === 203 && b === 0) return false; // TEST-NET-3
    if (a === 255) return false; // broadcast
    if (a >= 224) return false; // multicast + reserved
    return true;
  }

  if (net.isIPv6(ip)) {
    const first = ip.split(":")[0] || "";
    if (ip === "::" || ip === "::1") return false;
    const head = parseInt(first || "0", 16);
    if ((head & 0xfe00) === 0xfc00) return false; // fc00::/7 unique-local
    if ((head & 0xffc0) === 0xfe80) return false; // fe80::/10 link-local
    if ((head & 0xff00) === 0xff00) return false; // ff00::/8 multicast
    if (ip.startsWith("64:ff9b:") || ip.startsWith("2002:")) return false; // NAT64/6to4
    return true;
  }

  return false; // not an address at all
}

const log = (decision, host, port, reason) => {
  const suffix = reason ? ` (${reason})` : "";
  console.error(`egress-proxy: ${decision} ${host}:${port}${suffix}`);
};

/**
 * Decide whether a connection is permitted.
 * `resolve` is injectable so tests do not need DNS.
 * Resolves to { allowed: true } or { allowed: false, reason }.
 */
async function authorize({ allowlist, mode, host, port, resolve = dns.promises.lookup }) {
  if (isAllowed(allowlist, host, port)) return { allowed: true };

  if (mode !== MODES.RESEARCH) {
    return { allowed: false, reason: "not in EGRESS_ALLOWLIST" };
  }

  // Research mode: public web only. Anything else is an SSRF risk.
  if (port !== 80 && port !== 443) {
    return { allowed: false, reason: "research mode allows 80/443 only" };
  }
  if (isBlockedHostname(host)) {
    return { allowed: false, reason: "blocked hostname" };
  }
  if (net.isIP(host)) {
    return isPublicAddress(host)
      ? { allowed: true }
      : { allowed: false, reason: "non-public address" };
  }

  let addresses;
  try {
    addresses = await resolve(host, { all: true });
  } catch {
    return { allowed: false, reason: "DNS resolution failed" };
  }
  if (!Array.isArray(addresses) || addresses.length === 0) {
    return { allowed: false, reason: "DNS resolution failed" };
  }
  for (const entry of addresses) {
    const address = typeof entry === "string" ? entry : entry.address;
    if (!isPublicAddress(address)) {
      return { allowed: false, reason: `resolves to non-public address ${address}` };
    }
  }
  return { allowed: true };
}

function createProxyServer(allowlist, options = {}) {
  const mode = parseMode(options.mode);
  const resolve = options.resolve || dns.promises.lookup;
  const server = http.createServer();

  // HTTPS via CONNECT: open a raw TCP tunnel to the permitted target.
  server.on("connect", (req, clientSocket, head) => {
    const url = String(req.url || "");
    const idx = url.lastIndexOf(":");
    const host = idx > 0 ? url.slice(0, idx) : url;
    const port = idx > 0 ? Number(url.slice(idx + 1)) : 443;

    authorize({ allowlist, mode, host, port, resolve }).then((verdict) => {
      if (!verdict.allowed) {
        log("DENY", host, port, verdict.reason);
        clientSocket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
        clientSocket.destroy();
        return;
      }
      log("ALLOW", host, port, mode === MODES.RESEARCH ? "research" : undefined);

      const upstream = net.connect(port, host, () => {
        clientSocket.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        if (head && head.length) upstream.write(head);
        upstream.pipe(clientSocket);
        clientSocket.pipe(upstream);
      });
      upstream.on("error", () => clientSocket.destroy());
      clientSocket.on("error", () => upstream.destroy());
    });
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

    authorize({ allowlist, mode, host, port, resolve }).then((verdict) => {
      if (!verdict.allowed) {
        log("DENY", host, port, verdict.reason);
        res.writeHead(403, { "Content-Type": "text/plain" });
        res.end("Forbidden: host not allowed");
        return;
      }
      log("ALLOW", host, port, mode === MODES.RESEARCH ? "research" : undefined);

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
  });

  return server;
}

if (require.main === module) {
  const allowlist = parseAllowlist(process.env.EGRESS_ALLOWLIST || "");
  const mode = parseMode(process.env.EGRESS_MODE);
  const port = Number(process.env.PORT) || 8888;

  if (allowlist.length === 0 && mode !== MODES.RESEARCH) {
    console.error("egress-proxy: EGRESS_ALLOWLIST is empty — refusing to run an open proxy.");
    process.exit(1);
  }

  createProxyServer(allowlist, { mode }).listen(port, () => {
    const hosts = allowlist.map((a) => `${a.host}:${a.port}`).join(",") || "(none)";
    console.error(`egress-proxy: listening on :${port}, mode=${mode}, allowlist=${hosts}`);
    if (mode === MODES.RESEARCH) {
      console.error(
        "egress-proxy: research mode — arbitrary public hosts on 80/443 are reachable; " +
          "private/link-local/metadata addresses are refused.",
      );
    }
  });
}

module.exports = {
  MODES,
  parseMode,
  parseAllowlist,
  isAllowed,
  isPublicAddress,
  isBlockedHostname,
  authorize,
  createProxyServer,
};
