import { createRequire } from "node:module";
import http from "node:http";

const require = createRequire(import.meta.url);
const { parseAllowlist, isAllowed, createProxyServer } = require("../src/egress-proxy.js");

let pass = 0;
let fail = 0;

function ok(desc, cond) {
  if (cond) {
    console.log(`PASS  ${desc}`);
    pass++;
  } else {
    console.log(`FAIL  ${desc}`);
    fail++;
  }
}

// --- allowlist parsing ------------------------------------------------------
{
  const a = parseAllowlist("api.deepseek.com, github.com:8443, *.githubusercontent.com");
  ok("parses bare host to port 443", a.length === 3 && a[0].host === "api.deepseek.com" && a[0].port === 443);
  ok("parses host:port", a[1].host === "github.com" && a[1].port === 8443);
  ok("parses wildcard host", a[2].host === "*.githubusercontent.com" && a[2].port === 443);
  ok("ignores empty entries", parseAllowlist(", ,").length === 0);
}

// --- allowlist matching ------------------------------------------------------
{
  const a = parseAllowlist("api.deepseek.com, github.com, *.githubusercontent.com");
  ok("exact host+default port allowed", isAllowed(a, "api.deepseek.com", 443));
  ok("exact host wrong port denied", !isAllowed(a, "api.deepseek.com", 80));
  ok("unknown host denied", !isAllowed(a, "evil.example.com", 443));
  ok("subdomain wildcard allowed", isAllowed(a, "raw.githubusercontent.com", 443));
  ok("bare domain not covered by wildcard", !isAllowed(a, "githubusercontent.com", 443));
  ok("case-insensitive host match", isAllowed(a, "API.DEEPSEEK.COM", 443));
}

// --- plain HTTP forward + deny (end-to-end over localhost) ------------------
async function withServer(server) {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return port;
}

function request(port, path) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: "127.0.0.1", port, path, method: "GET" },
      (res) => {
        let body = "";
        res.on("data", (c) => (body += c));
        res.on("end", () => resolve({ status: res.statusCode, body }));
      },
    );
    req.on("error", reject);
    req.end();
  });
}

{
  // Mock upstream target.
  const target = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("hello from target");
  });
  const targetPort = await withServer(target);

  // Proxy that allows only the mock target.
  const proxy = createProxyServer(parseAllowlist(`127.0.0.1:${targetPort}`));
  const proxyPort = await withServer(proxy);

  const allowed = await request(proxyPort, `http://127.0.0.1:${targetPort}/`);
  ok("forwards allowlisted plain HTTP", allowed.status === 200 && allowed.body === "hello from target");

  const denied = await request(proxyPort, "http://evil.example.com/");
  ok("denies non-allowlisted host with 403", denied.status === 403);

  proxy.close();
  target.close();
}

console.log();
console.log(`egress-proxy tests: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
