// Bundles the harness page, its decode worker and audio worklet, and the web client's
// media pipeline (src/media: page, worker, worklet) into web/dist.
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
  },
  outdir: path.join(web, "dist"),
});
