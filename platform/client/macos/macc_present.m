// moonsec macOS client: Metal present (macc.h).
//
// Decoded frames are IOSurface-backed NV12 CVPixelBuffers. CVMetalTextureCache wraps
// their two planes as R8 and RG8 textures without a copy; a fragment shader converts
// to RGB (matrix and range from the buffer) into the target, letterboxed. The target
// is the window's CAMetalLayer drawable, a detached CAMetalLayer's drawable, or an
// offscreen texture. The overlay is a BGRA texture drawn 1:1 over the top-left corner.
//
// Latency: the layer keeps two drawables (the fewest Core Animation allows) and
// nextDrawable is the wait for a free one, like DXGI's waitable object on Windows.
// Lowest-latency mode turns display sync off (frames are shown as soon as they are
// composited, tearing allowed on displays that do it); smooth mode turns it on.
//
// The shaders are compiled from source when the presenter is created, so the build
// needs no Metal toolchain.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "macc.h"
#include "macc_internal.h"

enum { OVERLAY_W = 1024, OVERLAY_H = 512 };

static NSString *const shader_source = @"#include <metal_stdlib>\n"
                                        "using namespace metal;\n"
                                        "struct VOut { float4 pos [[position]]; float2 uv; };\n"
                                        "vertex VOut vs(uint vid [[vertex_id]], constant float2 &uvscale [[buffer(0)]]) {\n"
                                        "  float2 p = float2((vid << 1) & 2, vid & 2);\n"
                                        "  VOut o;\n"
                                        "  o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);\n"
                                        "  o.uv = p * uvscale;\n"
                                        "  return o;\n"
                                        "}\n"
                                        "struct Conv { float4 r; float4 g; float4 b; };\n"
                                        "fragment float4 fs_nv12(VOut in [[stage_in]], texture2d<float> ty [[texture(0)]],\n"
                                        "                        texture2d<float> tuv [[texture(1)]], sampler s [[sampler(0)]],\n"
                                        "                        constant Conv &m [[buffer(0)]]) {\n"
                                        "  float4 yuv = float4(ty.sample(s, in.uv).r, tuv.sample(s, in.uv).rg, 1.0);\n"
                                        "  return float4(saturate(float3(dot(m.r, yuv), dot(m.g, yuv), dot(m.b, yuv))), 1.0);\n"
                                        "}\n"
                                        "fragment float4 fs_overlay(VOut in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
                                        "                           sampler s [[sampler(0)]]) {\n"
                                        "  return float4(t.sample(s, in.uv).rgb, 1.0);\n"
                                        "}\n";

typedef struct {
    float r[4], g[4], b[4];
} conv;

// Rows that take (Y, Cb, Cr, 1) as sampled (0..1) to R, G, B.
static conv conversion(uint32_t matrix, int full_range) {
    float kr = 0.2126f, kb = 0.0722f;
    if (matrix == MACC_MATRIX_BT601) {
        kr = 0.299f;
        kb = 0.114f;
    } else if (matrix == MACC_MATRIX_BT2020) {
        kr = 0.2627f;
        kb = 0.0593f;
    }
    float kg = 1.0f - kr - kb;
    float sy = full_range ? 1.0f : 255.0f / 219.0f, oy = full_range ? 0.0f : 16.0f / 255.0f;
    float sc = full_range ? 1.0f : 255.0f / 224.0f, oc = 128.0f / 255.0f;
    float rcr = 2.0f * (1.0f - kr), bcb = 2.0f * (1.0f - kb);
    float gcb = -2.0f * (1.0f - kb) * kb / kg, gcr = -2.0f * (1.0f - kr) * kr / kg;
    conv c = {
        {sy, 0, rcr * sc, -sy * oy - rcr * sc * oc},
        {sy, gcb * sc, gcr * sc, -sy * oy - (gcb + gcr) * sc * oc},
        {sy, bcb * sc, 0, -sy * oy - bcb * sc * oc},
    };
    return c;
}

@interface MaccPresenterObj : NSObject {
  @public
    id<MTLDevice> dev;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> nv12_ps, overlay_ps;
    id<MTLSamplerState> linear, nearest;
    CVMetalTextureCacheRef cache;
    macc_window *win;
    CAMetalLayer *layer;
    id<MTLTexture> offscreen;
    uint32_t width, height;
    uint32_t flags, mode;
    // Held between draw and present.
    id<CAMetalDrawable> drawable;
    id<MTLTexture> target;
    id<MTLCommandBuffer> last_cb;
    // Two overlay textures, alternated so an update never writes one the GPU may be reading.
    id<MTLTexture> overlay_tex[2];
    int overlay_cur;
    uint32_t overlay_w, overlay_h;
    char name[128];
}
@end

@implementation MaccPresenterObj
- (void)dealloc {
    if (last_cb) [last_cb waitUntilCompleted];
    if (cache) CFRelease(cache);
}
@end

static MaccPresenterObj *P(macc_presenter *p) {
    return (__bridge MaccPresenterObj *)(void *)p;
}

static void apply_layer_mode(MaccPresenterObj *p) {
    p->layer.displaySyncEnabled = p->mode == MACC_PRESENT_SMOOTH;
}

macc_status macc_presenter_create(macc_window *win, uint32_t w, uint32_t h, uint32_t flags, macc_presenter **out) {
    *out = NULL;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return MACC_E_NO_DEVICE;
        MaccPresenterObj *p = [MaccPresenterObj new];
        p->dev = dev;
        p->queue = [dev newCommandQueue];
        p->win = win;
        p->flags = flags;
        p->mode = MACC_PRESENT_LOWEST_LATENCY;
        snprintf(p->name, sizeof p->name, "%s", dev.name.UTF8String ? dev.name.UTF8String : "?");

        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:shader_source options:nil error:&err];
        if (!lib) {
            NSLog(@"moonsec: Metal shader compile failed: %@", err);
            return MACC_E_METAL;
        }
        id<MTLFunction> vs = [lib newFunctionWithName:@"vs"];
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = vs;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        d.fragmentFunction = [lib newFunctionWithName:@"fs_nv12"];
        p->nv12_ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        d.fragmentFunction = [lib newFunctionWithName:@"fs_overlay"];
        p->overlay_ps = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        if (!p->nv12_ps || !p->overlay_ps) {
            NSLog(@"moonsec: Metal pipeline failed: %@", err);
            return MACC_E_METAL;
        }
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
        p->linear = [dev newSamplerStateWithDescriptor:sd];
        sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
        p->nearest = [dev newSamplerStateWithDescriptor:sd];

        CVReturn cr = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, dev, NULL, &p->cache);
        if (cr != kCVReturnSuccess) return cr;

        MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                       width:OVERLAY_W
                                                                                      height:OVERLAY_H
                                                                                   mipmapped:NO];
        od.usage = MTLTextureUsageShaderRead;
        od.storageMode = MTLStorageModeManaged;
        for (int i = 0; i < 2; i++) p->overlay_tex[i] = [dev newTextureWithDescriptor:od];

        if (win) {
            p->layer = macc_window_layer(win);
            macc_window_size(win, &p->width, &p->height);
        } else {
            p->width = w ? w : 1280;
            p->height = h ? h : 720;
            if (flags & MACC_PRESENTER_DETACHED_LAYER) {
                p->layer = [CAMetalLayer layer];
                p->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            } else {
                MTLTextureDescriptor *td =
                    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                       width:p->width
                                                                      height:p->height
                                                                   mipmapped:NO];
                td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModePrivate;
                p->offscreen = [dev newTextureWithDescriptor:td];
            }
        }
        if (p->layer) {
            CAMetalLayer *l = p->layer;
            uint32_t pw = p->width, ph = p->height;
            int readback = (flags & MACC_PRESENTER_READBACK) != 0;
            macc_on_main(^{
              l.device = dev;
              l.pixelFormat = MTLPixelFormatBGRA8Unorm;
              l.framebufferOnly = !readback;
              l.maximumDrawableCount = 2;
              l.allowsNextDrawableTimeout = YES;
              l.presentsWithTransaction = NO;
              l.drawableSize = CGSizeMake(pw, ph);
            });
            apply_layer_mode(p);
            if (win) macc_window_take_size_change(win);
        }
        *out = (__bridge_retained macc_presenter *)p;
        return MACC_OK;
    }
}

void macc_presenter_destroy(macc_presenter *pr) {
    if (!pr) return;
    CFBridgingRelease(pr); // drops the reference create handed out
}

const char *macc_presenter_device_name(macc_presenter *p) {
    return P(p)->name;
}

int macc_presenter_uses_layer(macc_presenter *p) {
    return P(p)->layer != nil;
}

void macc_presenter_size(macc_presenter *p, uint32_t *w, uint32_t *h) {
    *w = P(p)->width;
    *h = P(p)->height;
}

void macc_presenter_set_mode(macc_presenter *pr, uint32_t mode) {
    MaccPresenterObj *p = P(pr);
    if (p->mode == mode) return;
    p->mode = mode;
    if (p->layer) apply_layer_mode(p);
}

void macc_presenter_sync_size(macc_presenter *pr) {
    MaccPresenterObj *p = P(pr);
    if (!p->win || !macc_window_take_size_change(p->win)) return;
    macc_window_size(p->win, &p->width, &p->height);
    p->layer.drawableSize = CGSizeMake(p->width, p->height);
}

macc_status macc_presenter_set_overlay(macc_presenter *pr, const uint32_t *pixels, uint32_t w, uint32_t h,
                                       uint32_t stride) {
    MaccPresenterObj *p = P(pr);
    if (!pixels || w == 0 || h == 0) {
        p->overlay_w = p->overlay_h = 0;
        return MACC_OK;
    }
    if (w > OVERLAY_W) w = OVERLAY_W;
    if (h > OVERLAY_H) h = OVERLAY_H;
    p->overlay_cur ^= 1;
    [p->overlay_tex[p->overlay_cur] replaceRegion:MTLRegionMake2D(0, 0, w, h)
                                      mipmapLevel:0
                                        withBytes:pixels
                                      bytesPerRow:(NSUInteger)stride * 4];
    p->overlay_w = w;
    p->overlay_h = h;
    return MACC_OK;
}

static macc_status acquire_target(MaccPresenterObj *p) {
    if (p->target) return MACC_OK;
    if (p->offscreen) {
        p->target = p->offscreen;
        return MACC_OK;
    }
    id<CAMetalDrawable> d = [p->layer nextDrawable];
    if (!d) return MACC_E_TIMEOUT;
    p->drawable = d;
    p->target = d.texture;
    return MACC_OK;
}

macc_status macc_presenter_draw(macc_presenter *pr, const macc_frame *frame, uint32_t timeout_ms) {
    (void)timeout_ms; // nextDrawable's own timeout (1 s) applies
    MaccPresenterObj *p = P(pr);
    @autoreleasepool {
        macc_status st = acquire_target(p);
        if (st != MACC_OK) return st;
        id<MTLTexture> target = p->target;

        CVMetalTextureRef tex_y = NULL, tex_uv = NULL;
        CVPixelBufferRef pb = frame ? (CVPixelBufferRef)frame->pixel_buffer : NULL;
        if (pb) {
            if (CVPixelBufferGetPlaneCount(pb) != 2) return MACC_E_UNSUPPORTED;
            size_t w0 = CVPixelBufferGetWidthOfPlane(pb, 0), h0 = CVPixelBufferGetHeightOfPlane(pb, 0);
            size_t w1 = CVPixelBufferGetWidthOfPlane(pb, 1), h1 = CVPixelBufferGetHeightOfPlane(pb, 1);
            CVReturn r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, p->cache, pb, NULL,
                                                                   MTLPixelFormatR8Unorm, w0, h0, 0, &tex_y);
            if (r == kCVReturnSuccess)
                r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, p->cache, pb, NULL,
                                                              MTLPixelFormatRG8Unorm, w1, h1, 1, &tex_uv);
            if (r != kCVReturnSuccess) {
                if (tex_y) CFRelease(tex_y);
                return r;
            }
        }

        id<MTLCommandBuffer> cb = [p->queue commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        double tw = (double)target.width, th = (double)target.height;

        if (pb) {
            double fw = frame->width ? frame->width : (double)CVPixelBufferGetWidth(pb);
            double fh = frame->height ? frame->height : (double)CVPixelBufferGetHeight(pb);
            double scale = fmin(tw / fw, th / fh);
            double vw = floor(fw * scale + 0.5), vh = floor(fh * scale + 0.5);
            [enc setViewport:(MTLViewport){floor((tw - vw) / 2), floor((th - vh) / 2), vw, vh, 0, 1}];
            [enc setRenderPipelineState:p->nv12_ps];
            // Sample only the display (clean) area of the buffer.
            float uvscale[2] = {(float)(fw / (double)CVPixelBufferGetWidth(pb)),
                                (float)(fh / (double)CVPixelBufferGetHeight(pb))};
            [enc setVertexBytes:uvscale length:sizeof uvscale atIndex:0];
            conv c = conversion(macc_matrix_of(pb), CVPixelBufferGetPixelFormatType(pb) ==
                                                             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            [enc setFragmentBytes:&c length:sizeof c atIndex:0];
            [enc setFragmentTexture:CVMetalTextureGetTexture(tex_y) atIndex:0];
            [enc setFragmentTexture:CVMetalTextureGetTexture(tex_uv) atIndex:1];
            [enc setFragmentSamplerState:p->linear atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        if (p->overlay_w && p->overlay_h) {
            double ow = fmin(p->overlay_w, tw), oh = fmin(p->overlay_h, th);
            [enc setViewport:(MTLViewport){0, 0, ow, oh, 0, 1}];
            [enc setRenderPipelineState:p->overlay_ps];
            float uvscale[2] = {(float)(ow / OVERLAY_W), (float)(oh / OVERLAY_H)};
            [enc setVertexBytes:uvscale length:sizeof uvscale atIndex:0];
            [enc setFragmentTexture:p->overlay_tex[p->overlay_cur] atIndex:0];
            [enc setFragmentSamplerState:p->nearest atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [enc endEncoding];

        if (pb) {
            // The textures (and the frame's buffer) stay alive until the GPU is done
            // with them, whatever the caller does with the frame after present.
            CVPixelBufferRetain(pb);
            [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
              (void)b;
              CFRelease(tex_y);
              CFRelease(tex_uv);
              CVPixelBufferRelease(pb);
            }];
        }
        [cb commit];
        p->last_cb = cb;
        return MACC_OK;
    }
}

macc_status macc_presenter_present(macc_presenter *pr, uint64_t *presented_ns) {
    MaccPresenterObj *p = P(pr);
    *presented_ns = 0;
    if (!p->target) return MACC_E_INVALID;
    @autoreleasepool {
        if (!p->drawable) {
            // Offscreen: "presented" when the GPU finished drawing.
            [p->last_cb waitUntilCompleted];
            p->target = nil;
            *presented_ns = macc_now_ns();
            return p->last_cb.status == MTLCommandBufferStatusError ? MACC_E_METAL : MACC_OK;
        }
        id<CAMetalDrawable> d = p->drawable;
        p->drawable = nil;
        p->target = nil;
        __block double shown = 0;
        dispatch_semaphore_t sem = NULL;
        if (p->mode == MACC_PRESENT_SMOOTH) {
            sem = dispatch_semaphore_create(0);
            [d addPresentedHandler:^(id<MTLDrawable> dr) {
              shown = dr.presentedTime;
              dispatch_semaphore_signal(sem);
            }];
        }
        id<MTLCommandBuffer> cb = [p->queue commandBuffer];
        [cb presentDrawable:d];
        [cb commit];
        [cb waitUntilScheduled];
        if (sem) dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
        *presented_ns = shown > 0 ? macc_seconds_to_ns(shown) : macc_now_ns();
        if (p->last_cb.status == MTLCommandBufferStatusError) return MACC_E_METAL;
        return MACC_OK;
    }
}

macc_status macc_presenter_read_pixel(macc_presenter *pr, uint32_t x, uint32_t y, uint32_t *out) {
    MaccPresenterObj *p = P(pr);
    *out = 0;
    id<MTLTexture> t = p->target;
    if (!t || x >= t.width || y >= t.height) return MACC_E_INVALID;
    if (t.framebufferOnly) return MACC_E_UNSUPPORTED;
    @autoreleasepool {
        id<MTLBuffer> buf = [p->dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [p->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:t
                         sourceSlice:0
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(x, y, 0)
                          sourceSize:MTLSizeMake(1, 1, 1)
                            toBuffer:buf
                   destinationOffset:0
              destinationBytesPerRow:4
            destinationBytesPerImage:4];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status == MTLCommandBufferStatusError) return MACC_E_METAL;
        const uint8_t *b = buf.contents; // B, G, R, A
        *out = ((uint32_t)b[3] << 24) | ((uint32_t)b[2] << 16) | ((uint32_t)b[1] << 8) | b[0];
        return MACC_OK;
    }
}
