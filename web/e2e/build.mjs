// Bundles the harness page, its decode worker and audio worklet into web/dist.
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
  },
  outdir: path.join(web, "dist"),
});
