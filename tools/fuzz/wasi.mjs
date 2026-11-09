// Runs a wasm32-wasi test binary under Node's WASI (used by `zig build fuzz-wasm`).
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";
import { argv, exit } from "node:process";

const wasi = new WASI({ version: "preview1", args: [argv[2]], env: {}, returnOnExit: true });
const mod = await WebAssembly.compile(await readFile(argv[2]));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
exit(wasi.start(inst));
