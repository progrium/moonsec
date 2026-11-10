// A native host in the browser on one machine: starts a relay (iroh-relay with
// relay/local.toml: plain HTTP on 127.0.0.1:3340, so neither the browser nor the host
// needs a certificate) and
// serves the web client on http://127.0.0.1:8790, then prints how to start a host on it.
//
//   npm run local                                    (from web/)
//   npm run local -- --port 8790 --relay-url URL     (--relay-url: a relay that is already running)
//
// Needs `zig build web-wasm`, shim-web/build.sh, `npm run build`, and iroh-relay 1.4.1 on
// PATH (or IROH_RELAY). See web/README.md, "A native host in the browser".
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { args, root, serveWeb, start, waitFor } from "./host-lab.mjs";

const port = Number(args.port ?? 8790);
let relayUrl = args["relay-url"];
if (!relayUrl) {
  relayUrl = "http://127.0.0.1:3340";
  const relay = start("relay", process.env.IROH_RELAY ?? "iroh-relay", ["--config-path", join(root, "relay/local.toml")]);
  relay.on("exit", (code) => {
    if (code !== null) {
      console.error(`iroh-relay exited (${code}):\n${relay.log}`);
      process.exit(1);
    }
  });
  await waitFor("the relay on " + relayUrl, () => {
    try {
      execFileSync("curl", ["-sf", `${relayUrl}/ping`], { stdio: "ignore" });
      return true;
    } catch {
      return false;
    }
  });
}
const { base } = await serveWeb(port);
console.log(`relay       ${relayUrl}
web client  ${base}/client.html

Start a host on this relay (another terminal, from the repo root):

  zig-out/bin/moonsec-example-host --system --pair --relay-url ${relayUrl} --seconds 3600 --web ${base}

It prints links to open in the browser and click Connect: "pairs, then connects" the first
time (within 120 s), "once paired" after that. Keep --system: the test pattern without it
is in a codec only moonsec's native clients decode, so a browser gets no session.

Ctrl-C stops the relay and the server.`);
process.on("SIGINT", () => process.exit(0));
