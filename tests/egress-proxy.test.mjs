import { createRequire } from "node:module";
import http from "node:http";

const require = createRequire(import.meta.url);
const {
  MODES,
  parseMode,
  parseAllowlist,
  isAllowed,
  isPublicAddress,
  isBlockedHostname,
  authorize,
  createProxyServer,
} = require("../src/egress-proxy.js");

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

// --- mode parsing -----------------------------------------------------------
ok("defaults to allowlist mode", parseMode(undefined) === MODES.ALLOWLIST);
ok("parses research mode", parseMode("research") === MODES.RESEARCH);
ok("parses research mode case-insensitively", parseMode(" RESEARCH ") === MODES.RESEARCH);
ok("unknown mode falls back to allowlist", parseMode("yolo") === MODES.ALLOWLIST);

// --- allowlist parsing ------------------------------------------------------
{
  const a = parseAllowlist("api.deepseek.com, github.com:8443, *.githubusercontent.com");
  ok("parses bare host to port 443", a.length === 3 && a[0].host === "api.deepseek.com" && a[0].port === 443);
  ok("parses host:port", a[1].host === "github.com" && a[1].port === 8443);
  ok("parses wildcard host", a[2].host === "*.githubusercontent.com" && a[2].port === 443);
  ok("ignores empty entries", parseAllowlist(", ,").length === 0);
}

// --- allowlist matching -----------------------------------------------------
{
  const a = parseAllowlist("api.deepseek.com, github.com, *.githubusercontent.com");
  ok("exact host+default port allowed", isAllowed(a, "api.deepseek.com", 443));
  ok("exact host wrong port denied", !isAllowed(a, "api.deepseek.com", 80));
  ok("unknown host denied", !isAllowed(a, "evil.example.com", 443));
  ok("subdomain wildcard allowed", isAllowed(a, "raw.githubusercontent.com", 443));
  ok("bare domain not covered by wildcard", !isAllowed(a, "githubusercontent.com", 443));
  ok("case-insensitive host match", isAllowed(a, "API.DEEPSEEK.COM", 443));
}

// --- address classification (SSRF guard) -----------------------------------
for (const ip of [
  "127.0.0.1",
  "10.1.2.3",
  "172.16.5.4",
  "172.31.255.1",
  "192.168.1.1",
  "169.254.169.254", // cloud metadata
  "100.64.0.1", // CGNAT
  "0.0.0.0",
  "224.0.0.1",
  "255.255.255.255",
  "192.0.2.10",
  "198.51.100.7",
  "203.0.113.9",
  "::1",
  "::",
  "fc00::1",
  "fd12:3456::1",
  "fe80::1",
  "ff02::1",
  "::ffff:127.0.0.1",
  "::ffff:169.254.169.254",
]) {
  ok(`non-public address blocked: ${ip}`, !isPublicAddress(ip));
}
for (const ip of ["1.1.1.1", "8.8.8.8", "104.18.32.7", "2606:4700:4700::1111", "::ffff:1.1.1.1"]) {
  ok(`public address allowed: ${ip}`, isPublicAddress(ip));
}
ok("garbage is not an address", !isPublicAddress("not-an-ip"));

// --- blocked hostnames ------------------------------------------------------
for (const h of [
  "localhost",
  "api.localhost",
  "printer.local",
  "db.internal",
  "host.docker.internal",
  "gateway.docker.internal",
  "metadata.google.internal",
  "instance-data",
]) {
  ok(`blocked hostname: ${h}`, isBlockedHostname(h));
}
ok("normal hostname not blocked", !isBlockedHostname("api.deepseek.com"));

// --- authorize(): the decision table ---------------------------------------
const publicResolver = async () => [{ address: "1.1.1.1", family: 4 }];
const privateResolver = async () => [{ address: "10.0.0.5", family: 4 }];
const mixedResolver = async () => [
  { address: "1.1.1.1", family: 4 },
  { address: "10.0.0.5", family: 4 },
];
const failingResolver = async () => {
  throw new Error("ENOTFOUND");
};

// allowlist mode
ok(
  "allowlist: allowlisted host allowed",
  (await authorize({ allowlist: parseAllowlist("api.deepseek.com"), mode: MODES.ALLOWLIST, host: "api.deepseek.com", port: 443, resolve: publicResolver })).allowed,
);
ok(
  "allowlist: unknown host denied",
  !(await authorize({ allowlist: parseAllowlist("api.deepseek.com"), mode: MODES.ALLOWLIST, host: "example.com", port: 443, resolve: publicResolver })).allowed,
);

// research mode
ok(
  "research: arbitrary public host allowed",
  (await authorize({ allowlist: [], mode: MODES.RESEARCH, host: "news.ycombinator.com", port: 443, resolve: publicResolver })).allowed,
);
ok(
  "research: private address denied",
  !(await authorize({ allowlist: [], mode: MODES.RESEARCH, host: "internal.example.com", port: 443, resolve: privateResolver })).allowed,
);
ok(
  "research: mixed public+private denied",
  !(await authorize({ allowlist: [], mode: MODES.RESEARCH, host: "rebind.example.com", port: 443, resolve: mixedResolver })).allowed,
);
ok(
  "research: DNS failure denied",
  !(await authorize({ allowlist: [], mode: MODES.RESEARCH, host: "nope.example.com", port: 443, resolve: failingResolver })).allowed,
);
ok(
  "research: metadata IP literal denied",
  !(await authorize({ allowlist: [], mode: MODES.RESEARCH, host: "169.254.169.254", port: 80, resolve: publicResolver })).allowed,
);
ok(
  "research: localhost denied",
  !(await authorize({ allowlist: [], mode: MODES.RESEARCH, host: "localhost", port: 443, resolve: privateResolver })).allowed,
);
ok(
  "research: non-web port denied",
  !(await authorize({ allowlist: [], mode: MODES.RESEARCH, host: "example.com", port: 8080, resolve: publicResolver })).allowed,
);
ok(
  "research: allowlisted non-web port still allowed",
  (await authorize({ allowlist: parseAllowlist("github.com:22"), mode: MODES.RESEARCH, host: "github.com", port: 22, resolve: publicResolver })).allowed,
);

// --- end-to-end over localhost ---------------------------------------------
async function withServer(server) {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return port;
}

function request(port, path) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path, method: "GET" }, (res) => {
      let body = "";
      res.on("data", (c) => (body += c));
      res.on("end", () => resolve({ status: res.statusCode, body }));
    });
    req.on("error", reject);
    req.end();
  });
}

// Issue a CONNECT request through the proxy and report the status line only.
function connect(port, target) {
  return new Promise((resolve) => {
    const req = http.request({ host: "127.0.0.1", port, method: "CONNECT", path: target });
    req.on("connect", (res) => {
      res.socket?.destroy();
      resolve({ status: res.statusCode });
    });
    req.on("response", (res) => {
      res.destroy();
      resolve({ status: res.statusCode });
    });
    req.on("error", () => resolve({ status: 0 }));
    req.end();
  });
}

{
  const target = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("hello from target");
  });
  const targetPort = await withServer(target);

  // Allowlist mode: only the mock target is permitted.
  const allowProxy = createProxyServer(parseAllowlist(`127.0.0.1:${targetPort}`));
  const allowPort = await withServer(allowProxy);

  const allowed = await request(allowPort, `http://127.0.0.1:${targetPort}/`);
  ok("allowlist: forwards allowlisted plain HTTP", allowed.status === 200 && allowed.body === "hello from target");
  ok("allowlist: denies non-allowlisted host", (await request(allowPort, "http://evil.example.com/")).status === 403);
  ok("allowlist: allows CONNECT to allowlisted host", (await connect(allowPort, `127.0.0.1:${targetPort}`)).status === 200);
  ok("allowlist: denies CONNECT to non-allowlisted host", (await connect(allowPort, "evil.example.com:443")).status === 403);
  ok("allowlist: denies CONNECT on non-allowlisted port", (await connect(allowPort, `127.0.0.1:${targetPort + 1}`)).status === 403);
  allowProxy.close();

  // Research mode: loopback must still be refused (SSRF guard), while a
  // "public" host resolved by the stub resolver goes through.
  const researchProxy = createProxyServer([], { mode: "research", resolve: publicResolver });
  const researchPort = await withServer(researchProxy);

  ok("research: loopback CONNECT denied", (await connect(researchPort, "127.0.0.1:443")).status === 403);
  ok("research: localhost CONNECT denied", (await connect(researchPort, "localhost:443")).status === 403);

  const researchTarget = createProxyServer([], { mode: "research", resolve: privateResolver });
  const researchTargetPort = await withServer(researchTarget);
  ok("research: host resolving private denied", (await connect(researchTargetPort, "internal.example.com:443")).status === 403);
  researchTarget.close();

  researchProxy.close();
  target.close();
}

console.log();
console.log(`egress-proxy tests: ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
