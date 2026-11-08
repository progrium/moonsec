// Bundles the harness page, its decode worker and audio worklet, the web client's media
// pipeline (src/media: page, worker, worklet) and the browser host (src/host) into web/dist.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";

const web = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const common = { bundle: true, format: "esm", target: "es2022", sourcemap: true, logLevel: "warning" };
await build({
  ...common,
  entryPoints: {
    harness: path.join(web, "e2e/page/harness.ts"),
    "decode-worker": path.join(web, "e2e/page/decode-worker.ts"),
    "audio-worklet": path.join(web, "e2e/page/audio-worklet.ts"),
    "client-page": path.join(web, "src/media/page.ts"),
    "media-worker": path.join(web, "src/media/worker.ts"),
    "media-worklet": path.join(web, "src/media/audio-worklet.ts"),
    "host-page": path.join(web, "src/host/page.ts"),
    host: path.join(web, "src/host/host.ts"),
    "host-worker": path.join(web, "src/host/worker.ts"),
    "host-tap": path.join(web, "src/host/tap-worklet.ts"),
  },
  outdir: path.join(web, "dist"),
});
// The browser host's page patches run as a classic script before the game's own.
await build({ ...common, format: "iife", entryPoints: { "host-patch": path.join(web, "src/host/patch.ts") }, outdir: path.join(web, "dist") });
