// pxpipe-desktop.mjs — a long-lived `pxpipe warp` for the Claude desktop app.
//
// The desktop app pins ANTHROPIC_BASE_URL, so pxpipe's base-URL proxy never sees
// its traffic. What it does honour is HTTPS_PROXY + NODE_EXTRA_CA_CERTS in the
// env block of ~/.claude/settings.json (approach from DivyeshPatro/pxpipe-windows).
// This process is that HTTPS proxy: built from pxpipe's own warp modules, it
// decrypts api.anthropic.com only, re-points /v1/messages at the pxpipe proxy,
// and tunnels every other host untouched. The CA is trusted by Claude Code
// processes only (NODE_EXTRA_CA_CERTS) — nothing enters the Windows trust store.
//
// It also keeps the pxpipe proxy itself running: started if absent, restarted
// if it exits. A second instance exits 0 at once (port taken).
//
// Usage: node pxpipe-desktop.mjs            run the proxy (foreground)
//        node pxpipe-desktop.mjs --ca-path  print the CA file to trust, then exit

import { createServer, get } from "node:http";
import { spawn, execSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const CONNECT_PORT = Number(process.env.TW_PXPIPE_CONNECT_PORT || 47822);
const PXPIPE_PORT = 47821;
const RESTART_DELAY_MS = 5000;

const pxpipeRoot = process.env.TW_PXPIPE_ROOT
  || join(execSync("npm root -g", { encoding: "utf8" }).trim(), "pxpipe-proxy");
const warp = (file) => import(pathToFileURL(join(pxpipeRoot, "dist", "warp", file)).href);
const { CertificateAuthority } = await warp("ca.js");
const { createWarpHandlers } = await warp("connect.js");
const { parseRoute } = await warp("route.js");

const ca = CertificateAuthority.loadOrCreate(join(homedir(), ".pxpipe"));
if (process.argv.includes("--ca-path")) {
  console.log(ca.certPath);
  process.exit(0);
}

const log = (msg) => console.log(`[${new Date().toISOString()}] ${msg}`);

const pxpipeUp = () => new Promise((resolve) => {
  const req = get({ host: "127.0.0.1", port: PXPIPE_PORT, path: "/", timeout: 2000 }, (res) => {
    res.resume();
    resolve(res.statusCode === 200);
  });
  req.on("error", () => resolve(false)).on("timeout", () => { req.destroy(); resolve(false); });
});

// The pxpipe proxy: reuse a running one, else run it as our child and bring it
// back if it dies — a dead proxy would stall every Claude Code session.
async function superviseProxy() {
  if (await pxpipeUp()) {
    setTimeout(superviseProxy, RESTART_DELAY_MS * 6);
    return;
  }
  log("starting pxpipe proxy");
  const child = spawn("pxpipe", [], { shell: true, stdio: "inherit" });
  child.on("exit", (code) => {
    log(`pxpipe proxy exited (${code}); restarting in ${RESTART_DELAY_MS / 1000}s`);
    setTimeout(superviseProxy, RESTART_DELAY_MS);
  });
}

const handlers = createWarpHandlers({
  routes: [parseRoute(`api.anthropic.com/v1/messages*=http://127.0.0.1:${PXPIPE_PORT}`)],
  ca,
  onDivert: (host, path, target) => log(`routing ${host}${path} → ${target}`),
});
const server = createServer(handlers.handleAbsoluteForm);
server.on("connect", handlers.handleConnect);
server.on("error", (err) => {
  if (err.code === "EADDRINUSE") {
    log(`port ${CONNECT_PORT} already in use — another instance is running`);
    process.exit(0);
  }
  throw err;
});
server.listen(CONNECT_PORT, "127.0.0.1", () => {
  log(`desktop proxy on http://127.0.0.1:${CONNECT_PORT} → pxpipe :${PXPIPE_PORT} (CA ${ca.certPath})`);
  superviseProxy();
});
