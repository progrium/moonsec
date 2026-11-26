// The lossless tile layer (core/refine; spec/refine-v0.md): an OffscreenCanvas the size
// of the stream, transparent except where the core put a tile, drawn 1:1 over each
// decoded frame. The core decides what shows (`CoreSession.tilePresent`, called right
// before each frame is drawn); this only applies its ops, so the page's layer is always
// the session's. Like the native presenters (platform/client/linux), tiles are never
// baked into the video: the layer is its own image, composited in the same present.

import { TileOpKind, type TileUpdate } from "../core";

export class TileLayer {
  canvas: OffscreenCanvas | null = null;
  ctx: OffscreenCanvasRenderingContext2D | null = null;
  visible = false;
  puts = 0;
  clears = 0;

  /** Brings the layer to what shows with the frame about to be drawn. */
  apply(u: TileUpdate) {
    for (const op of u.ops) {
      if (op.kind === TileOpKind.clearAll) {
        // Also how a new stream config (size or epoch) arrives: start over at its size.
        if (!this.canvas || this.canvas.width !== u.width || this.canvas.height !== u.height) {
          this.canvas = new OffscreenCanvas(Math.max(1, u.width), Math.max(1, u.height));
          this.ctx = this.canvas.getContext("2d", { alpha: true }) as OffscreenCanvasRenderingContext2D;
        } else this.ctx!.clearRect(0, 0, u.width, u.height);
        this.clears++;
        continue;
      }
      // The core starts every layer with a clear_all; ops before one have nothing to act on.
      if (!this.ctx) continue;
      if (op.kind === TileOpKind.clear) {
        this.ctx.clearRect(op.x, op.y, op.w, op.h);
        this.clears++;
      } else if (op.kind === TileOpKind.put && op.pixels) {
        // putImageData copies the pixels (a view into wasm memory) and ignores
        // compositing: the tile replaces what was there, exactly.
        this.ctx.putImageData(new ImageData(op.pixels, op.w, op.h), op.x, op.y);
        this.puts++;
      }
    }
    this.visible = u.visible;
  }

  /** The session has no tile layer (any more): nothing to draw. */
  drop() {
    this.canvas = null;
    this.ctx = null;
    this.visible = false;
  }

  /**
   * Over the frame just drawn into `ctx` at 1:1 (frame pixels are stream pixels), with
   * no smoothing, so tiles land pixel exact. A layer of another size than the frame is
   * not drawn: the video alone is always right.
   */
  drawOver(ctx: OffscreenCanvasRenderingContext2D, width: number, height: number) {
    if (!this.visible || !this.canvas || this.canvas.width !== width || this.canvas.height !== height) return;
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(this.canvas, 0, 0);
  }
}
