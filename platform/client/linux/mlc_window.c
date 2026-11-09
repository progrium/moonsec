/* Wayland window, EGL context and the GLES 3 presenter (see mlc.h). */
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <wayland-client.h>
#include <wayland-egl.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <va/va.h>
#include <va/va_drmcommon.h>

#include "mlc_internal.h"
#include "protocol/xdg-shell-client-protocol.h"
#include "protocol/tearing-control-v1-client-protocol.h"

/* ------------------------------------------------------------------------ */
/* Errors */

static _Thread_local char last_error[512];

const char *mlc_last_error(void) { return last_error; }

int mlc_fail(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(last_error, sizeof last_error, fmt, ap);
    va_end(ap);
    fprintf(stderr, "client_linux: %s\n", last_error);
    return code;
}

void mlc_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "client_linux: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

/* ------------------------------------------------------------------------ */
/* Window state */

struct mlc_window {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct xdg_wm_base *wm_base;
    struct wl_seat *seat;
    struct wl_keyboard *keyboard;
    struct wp_tearing_control_manager_v1 *tearing_mgr;
    struct wp_tearing_control_v1 *tearing;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct wl_egl_window *egl_window;

    EGLDisplay egl_display;
    EGLContext egl_context;
    EGLSurface egl_surface;
    PFNEGLCREATEIMAGEKHRPROC create_image;
    PFNEGLDESTROYIMAGEKHRPROC destroy_image;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target_texture;
    int has_dmabuf;
    char renderer[128];

    /* Size: what we asked for, and what the compositor configured (0: our choice). */
    uint32_t want_w, want_h;
    uint32_t width, height;
    int configured;
    int forced;
    int mode;
    int swap_interval;

    atomic_int closed;
    atomic_int focused;
    atomic_int has_keyboard;

    /* GL objects. */
    GLuint prog_yuv, prog_rgb;
    GLint yuv_tex[3], yuv_layout, yuv_matrix, yuv_offset, yuv_rect, yuv_transfer;
    /* 10-bit planes reduced to 8 for upload (GLES 3.0 has no 16-bit normalized textures). */
    uint8_t *scratch;
    size_t scratch_len;
    GLint rgb_tex, rgb_rect, rgb_blend;
    GLuint tex[3];
    GLuint overlay_tex;
    uint32_t overlay_w, overlay_h;
    int overlay_on;
    GLuint vao;
};

/* ------------------------------------------------------------------------ */
/* Wayland listeners */

static void wm_ping(void *data, struct xdg_wm_base *b, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_listener = {.ping = wm_ping};

static void xdg_surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
    mlc_window *w = data;
    xdg_surface_ack_configure(s, serial);
    w->configured = 1;
}
static const struct xdg_surface_listener xdg_surface_listener = {.configure = xdg_surface_configure};

static void toplevel_configure(void *data, struct xdg_toplevel *t, int32_t width, int32_t height, struct wl_array *states) {
    (void)t;
    (void)states;
    mlc_window *w = data;
    w->forced = width > 0 && height > 0;
    uint32_t nw = width > 0 ? (uint32_t)width : w->want_w;
    uint32_t nh = height > 0 ? (uint32_t)height : w->want_h;
    if (nw != w->width || nh != w->height) {
        w->width = nw;
        w->height = nh;
        if (w->egl_window) wl_egl_window_resize(w->egl_window, (int)nw, (int)nh, 0, 0);
    }
}
static void toplevel_close(void *data, struct xdg_toplevel *t) {
    (void)t;
    mlc_window *w = data;
    atomic_store(&w->closed, 1);
}
static void toplevel_bounds(void *data, struct xdg_toplevel *t, int32_t width, int32_t height) {
    (void)data, (void)t, (void)width, (void)height;
}
static void toplevel_caps(void *data, struct xdg_toplevel *t, struct wl_array *caps) {
    (void)data, (void)t, (void)caps;
}
static const struct xdg_toplevel_listener toplevel_listener = {
    .configure = toplevel_configure,
    .close = toplevel_close,
    .configure_bounds = toplevel_bounds,
    .wm_capabilities = toplevel_caps,
};

static void kb_keymap(void *data, struct wl_keyboard *k, uint32_t format, int32_t fd, uint32_t size) {
    (void)data, (void)k, (void)format, (void)size;
    close(fd);
}
static void kb_enter(void *data, struct wl_keyboard *k, uint32_t serial, struct wl_surface *s, struct wl_array *keys) {
    (void)k, (void)serial, (void)keys;
    mlc_window *w = data;
    if (s == w->surface) atomic_store(&w->focused, 1);
}
static void kb_leave(void *data, struct wl_keyboard *k, uint32_t serial, struct wl_surface *s) {
    (void)k, (void)serial;
    mlc_window *w = data;
    if (s == w->surface) atomic_store(&w->focused, 0);
}
static void kb_key(void *data, struct wl_keyboard *k, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)data, (void)k, (void)serial, (void)time, (void)key, (void)state;
}
static void kb_mods(void *data, struct wl_keyboard *k, uint32_t serial, uint32_t d, uint32_t l, uint32_t lk, uint32_t g) {
    (void)data, (void)k, (void)serial, (void)d, (void)l, (void)lk, (void)g;
}
static void kb_repeat(void *data, struct wl_keyboard *k, int32_t rate, int32_t delay) {
    (void)data, (void)k, (void)rate, (void)delay;
}
static const struct wl_keyboard_listener kb_listener = {
    .keymap = kb_keymap,
    .enter = kb_enter,
    .leave = kb_leave,
    .key = kb_key,
    .modifiers = kb_mods,
    .repeat_info = kb_repeat,
};

static void seat_caps(void *data, struct wl_seat *seat, uint32_t caps) {
    mlc_window *w = data;
    int kb = (caps & WL_SEAT_CAPABILITY_KEYBOARD) != 0;
    if (kb && !w->keyboard) {
        w->keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(w->keyboard, &kb_listener, w);
        atomic_store(&w->focused, 0);
    } else if (!kb && w->keyboard) {
        wl_keyboard_release(w->keyboard);
        w->keyboard = NULL;
    }
    atomic_store(&w->has_keyboard, kb);
}
static void seat_name(void *data, struct wl_seat *seat, const char *name) {
    (void)data, (void)seat, (void)name;
}
static const struct wl_seat_listener seat_listener = {.capabilities = seat_caps, .name = seat_name};

static void reg_global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
    mlc_window *w = data;
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        w->compositor = wl_registry_bind(r, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
        w->wm_base = wl_registry_bind(r, name, &xdg_wm_base_interface, version < 5 ? version : 5);
        xdg_wm_base_add_listener(w->wm_base, &wm_listener, w);
    } else if (strcmp(iface, wl_seat_interface.name) == 0 && !w->seat) {
        w->seat = wl_registry_bind(r, name, &wl_seat_interface, version < 5 ? version : 5);
        wl_seat_add_listener(w->seat, &seat_listener, w);
    } else if (strcmp(iface, wp_tearing_control_manager_v1_interface.name) == 0) {
        w->tearing_mgr = wl_registry_bind(r, name, &wp_tearing_control_manager_v1_interface, 1);
    }
}
static void reg_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void)data, (void)r, (void)name;
}
static const struct wl_registry_listener reg_listener = {.global = reg_global, .global_remove = reg_remove};

/* ------------------------------------------------------------------------ */
/* GL */

static const char *vs_src =
    "#version 300 es\n"
    "uniform vec4 rect;\n" /* x0, y0, x1, y1 in clip space */
    "out vec2 uv;\n"
    "void main() {\n"
    "  vec2 c = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));\n"
    "  uv = vec2(c.x, 1.0 - c.y);\n"
    "  gl_Position = vec4(mix(rect.xy, rect.zw, c), 0.0, 1.0);\n"
    "}\n";

/* layout 0: NV12 (tex0 Y, tex1 UV); 1: three planes, I420 or I444 (tex0 Y, tex1 U,
 * tex2 V; the chroma textures' size sets the subsampling).
 * transfer 1: the RGB is PQ-encoded BT.2020 (HDR10). This SDR presenter tone-maps it:
 * ST 2084 to cd/m², SDR reference white at 203 cd/m² (ITU-R BT.2408) as 1.0, BT.2020 to
 * BT.709 primaries, highlights above 0.8 rolled off towards 1.0 by the brightest channel
 * (hue kept), then a 2.2 gamma for the display. */
static const char *fs_yuv_src =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform sampler2D tex0, tex1, tex2;\n"
    "uniform int layout_;\n"
    "uniform int transfer_;\n"
    "uniform mat3 matrix;\n"
    "uniform vec3 offset;\n"
    "in vec2 uv;\n"
    "out vec4 color;\n"
    "const mat3 bt2020_to_709 = mat3(1.6605, -0.1246, -0.0182, -0.5876, 1.1329, -0.1006, -0.0728, -0.0083, 1.1187);\n"
    "vec3 pq_eotf(vec3 e) {\n" /* 0..1 of 10000 cd/m2 */
    "  vec3 p = pow(max(e, 0.0), vec3(1.0 / 78.84375));\n"
    "  return pow(max(p - 0.8359375, 0.0) / (18.8515625 - 18.6875 * p), vec3(1.0 / 0.1593017578125));\n"
    "}\n"
    "void main() {\n"
    "  vec3 yuv;\n"
    "  yuv.x = texture(tex0, uv).r;\n"
    "  if (layout_ == 0) yuv.yz = texture(tex1, uv).rg;\n"
    "  else yuv.yz = vec2(texture(tex1, uv).r, texture(tex2, uv).r);\n"
    "  vec3 rgb = clamp(matrix * (yuv - offset), 0.0, 1.0);\n"
    "  if (transfer_ == 1) {\n"
    "    vec3 lin = max(bt2020_to_709 * (pq_eotf(rgb) * (10000.0 / 203.0)), 0.0);\n"
    "    float m = max(max(lin.r, lin.g), lin.b);\n"
    "    const float k = 0.8;\n"
    "    if (m > k) lin *= (k + (1.0 - k) * (1.0 - exp(-(m - k) / (1.0 - k)))) / m;\n"
    "    rgb = pow(clamp(lin, 0.0, 1.0), vec3(1.0 / 2.2));\n"
    "  }\n"
    "  color = vec4(rgb, 1.0);\n"
    "}\n";

/* BGRA bytes uploaded as RGBA: swizzle back. `blend` keeps alpha (the overlay). */
static const char *fs_rgb_src =
    "#version 300 es\n"
    "precision mediump float;\n"
    "uniform sampler2D tex0;\n"
    "uniform int blend;\n"
    "in vec2 uv;\n"
    "out vec4 color;\n"
    "void main() {\n"
    "  vec4 t = texture(tex0, uv).bgra;\n"
    "  color = blend == 1 ? t : vec4(t.rgb, 1.0);\n"
    "}\n";

static GLuint compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, sizeof log, NULL, log);
        mlc_fail(MLC_E_FAIL, "shader: %s", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static GLuint link_program(const char *fs_src) {
    GLuint vs = compile(GL_VERTEX_SHADER, vs_src);
    GLuint fs = compile(GL_FRAGMENT_SHADER, fs_src);
    if (!vs || !fs) return 0;
    GLuint p = glCreateProgram();
    glAttachShader(p, vs);
    glAttachShader(p, fs);
    glLinkProgram(p);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetProgramInfoLog(p, sizeof log, NULL, log);
        mlc_fail(MLC_E_FAIL, "link: %s", log);
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

static int make_current(mlc_window *w) {
    if (eglGetCurrentContext() == w->egl_context) return MLC_OK;
    if (!eglMakeCurrent(w->egl_display, w->egl_surface, w->egl_surface, w->egl_context))
        return mlc_fail(MLC_E_FAIL, "eglMakeCurrent: 0x%x", eglGetError());
    eglSwapInterval(w->egl_display, w->swap_interval);
    return MLC_OK;
}

static int gl_init(mlc_window *w) {
    w->prog_yuv = link_program(fs_yuv_src);
    w->prog_rgb = link_program(fs_rgb_src);
    if (!w->prog_yuv || !w->prog_rgb) return MLC_E_FAIL;
    static const char *names[3] = {"tex0", "tex1", "tex2"};
    for (int i = 0; i < 3; i++) w->yuv_tex[i] = glGetUniformLocation(w->prog_yuv, names[i]);
    w->yuv_layout = glGetUniformLocation(w->prog_yuv, "layout_");
    w->yuv_transfer = glGetUniformLocation(w->prog_yuv, "transfer_");
    w->yuv_matrix = glGetUniformLocation(w->prog_yuv, "matrix");
    w->yuv_offset = glGetUniformLocation(w->prog_yuv, "offset");
    w->yuv_rect = glGetUniformLocation(w->prog_yuv, "rect");
    w->rgb_tex = glGetUniformLocation(w->prog_rgb, "tex0");
    w->rgb_rect = glGetUniformLocation(w->prog_rgb, "rect");
    w->rgb_blend = glGetUniformLocation(w->prog_rgb, "blend");
    glGenTextures(3, w->tex);
    glGenTextures(1, &w->overlay_tex);
    GLuint all[4] = {w->tex[0], w->tex[1], w->tex[2], w->overlay_tex};
    for (int i = 0; i < 4; i++) {
        glBindTexture(GL_TEXTURE_2D, all[i]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, i == 3 ? GL_NEAREST : GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
    glGenVertexArrays(1, &w->vao);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    return glGetError() == GL_NO_ERROR ? MLC_OK : mlc_fail(MLC_E_FAIL, "GL setup failed");
}

static int has_ext(const char *list, const char *name) {
    if (!list) return 0;
    size_t n = strlen(name);
    for (const char *p = list; (p = strstr(p, name)) != NULL; p += n)
        if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0)) return 1;
    return 0;
}

/* ------------------------------------------------------------------------ */
/* Create / destroy */

int mlc_window_create(uint32_t width, uint32_t height, const char *title, mlc_window **out) {
    *out = NULL;
    if (!getenv("WAYLAND_DISPLAY") && !getenv("WAYLAND_SOCKET"))
        return mlc_fail(MLC_E_NODEVICE, "no Wayland display ($WAYLAND_DISPLAY unset)");
    mlc_window *w = calloc(1, sizeof *w);
    if (!w) return MLC_E_NOMEM;
    w->want_w = w->width = width;
    w->want_h = w->height = height;
    w->swap_interval = 0;
    atomic_store(&w->focused, 1);
    int rc = MLC_E_FAIL;

    w->display = wl_display_connect(NULL);
    if (!w->display) {
        rc = mlc_fail(MLC_E_NODEVICE, "wl_display_connect: %s", strerror(errno));
        goto fail;
    }
    w->registry = wl_display_get_registry(w->display);
    wl_registry_add_listener(w->registry, &reg_listener, w);
    wl_display_roundtrip(w->display);
    wl_display_roundtrip(w->display); /* seat capabilities */
    if (!w->compositor || !w->wm_base) {
        rc = mlc_fail(MLC_E_NODEVICE, "compositor lacks wl_compositor or xdg_wm_base");
        goto fail;
    }

    w->surface = wl_compositor_create_surface(w->compositor);
    w->xdg_surface = xdg_wm_base_get_xdg_surface(w->wm_base, w->surface);
    xdg_surface_add_listener(w->xdg_surface, &xdg_surface_listener, w);
    w->toplevel = xdg_surface_get_toplevel(w->xdg_surface);
    xdg_toplevel_add_listener(w->toplevel, &toplevel_listener, w);
    xdg_toplevel_set_title(w->toplevel, title ? title : "moonsec");
    xdg_toplevel_set_app_id(w->toplevel, "moonsec");
    if (w->tearing_mgr) w->tearing = wp_tearing_control_manager_v1_get_tearing_control(w->tearing_mgr, w->surface);
    wl_surface_commit(w->surface);
    while (!w->configured && wl_display_dispatch(w->display) >= 0) {
    }
    if (!w->configured) {
        rc = mlc_fail(MLC_E_FAIL, "no xdg_surface configure");
        goto fail;
    }

    /* EGL on the Wayland display. */
    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    w->egl_display = get_platform_display ? get_platform_display(EGL_PLATFORM_WAYLAND_KHR, w->display, NULL) : eglGetDisplay((EGLNativeDisplayType)w->display);
    EGLint major = 0, minor = 0;
    if (w->egl_display == EGL_NO_DISPLAY || !eglInitialize(w->egl_display, &major, &minor)) {
        rc = mlc_fail(MLC_E_NODEVICE, "eglInitialize: 0x%x", eglGetError());
        goto fail;
    }
    eglBindAPI(EGL_OPENGL_ES_API);
    static const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 0, EGL_NONE,
    };
    EGLConfig cfg;
    EGLint ncfg = 0;
    if (!eglChooseConfig(w->egl_display, cfg_attr, &cfg, 1, &ncfg) || ncfg < 1) {
        rc = mlc_fail(MLC_E_NODEVICE, "no GLES 3 RGB888 EGL config");
        goto fail;
    }
    static const EGLint ctx_attr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE};
    w->egl_context = eglCreateContext(w->egl_display, cfg, EGL_NO_CONTEXT, ctx_attr);
    if (w->egl_context == EGL_NO_CONTEXT) {
        rc = mlc_fail(MLC_E_NODEVICE, "eglCreateContext: 0x%x", eglGetError());
        goto fail;
    }
    w->egl_window = wl_egl_window_create(w->surface, (int)w->width, (int)w->height);
    w->egl_surface = eglCreateWindowSurface(w->egl_display, cfg, (EGLNativeWindowType)w->egl_window, NULL);
    if (w->egl_surface == EGL_NO_SURFACE) {
        rc = mlc_fail(MLC_E_FAIL, "eglCreateWindowSurface: 0x%x", eglGetError());
        goto fail;
    }
    if ((rc = make_current(w)) != MLC_OK) goto fail;

    const char *exts = eglQueryString(w->egl_display, EGL_EXTENSIONS);
    w->create_image = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
    w->destroy_image = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
    w->image_target_texture = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    w->has_dmabuf = has_ext(exts, "EGL_EXT_image_dma_buf_import") && w->create_image && w->destroy_image && w->image_target_texture;
    snprintf(w->renderer, sizeof w->renderer, "%s", (const char *)glGetString(GL_RENDERER));

    if ((rc = gl_init(w)) != MLC_OK) goto fail;
    mlc_log("window %ux%u on %s, EGL %d.%d, %s, dma-buf import %s, tearing control %s", w->width, w->height,
            getenv("WAYLAND_DISPLAY") ? getenv("WAYLAND_DISPLAY") : "wayland", major, minor, w->renderer,
            w->has_dmabuf ? "yes" : "no", w->tearing ? "yes" : "no");
    mlc_window_set_mode(w, MLC_PRESENT_LOWEST_LATENCY);
    /* Release the context: the present thread makes it current. */
    eglMakeCurrent(w->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    *out = w;
    return MLC_OK;

fail:
    mlc_window_destroy(w);
    return rc;
}

void mlc_window_destroy(mlc_window *w) {
    if (!w) return;
    if (w->egl_display != EGL_NO_DISPLAY && w->egl_display) {
        if (w->egl_context && eglMakeCurrent(w->egl_display, w->egl_surface, w->egl_surface, w->egl_context)) {
            glDeleteTextures(3, w->tex);
            glDeleteTextures(1, &w->overlay_tex);
            if (w->prog_yuv) glDeleteProgram(w->prog_yuv);
            if (w->prog_rgb) glDeleteProgram(w->prog_rgb);
            if (w->vao) glDeleteVertexArrays(1, &w->vao);
        }
        eglMakeCurrent(w->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (w->egl_surface) eglDestroySurface(w->egl_display, w->egl_surface);
        if (w->egl_context) eglDestroyContext(w->egl_display, w->egl_context);
        eglTerminate(w->egl_display);
    }
    if (w->egl_window) wl_egl_window_destroy(w->egl_window);
    if (w->tearing) wp_tearing_control_v1_destroy(w->tearing);
    if (w->toplevel) xdg_toplevel_destroy(w->toplevel);
    if (w->xdg_surface) xdg_surface_destroy(w->xdg_surface);
    if (w->surface) wl_surface_destroy(w->surface);
    if (w->keyboard) wl_keyboard_release(w->keyboard);
    if (w->seat) wl_seat_destroy(w->seat);
    if (w->tearing_mgr) wp_tearing_control_manager_v1_destroy(w->tearing_mgr);
    if (w->wm_base) xdg_wm_base_destroy(w->wm_base);
    if (w->compositor) wl_compositor_destroy(w->compositor);
    if (w->registry) wl_registry_destroy(w->registry);
    if (w->display) {
        wl_display_flush(w->display);
        wl_display_disconnect(w->display);
    }
    free(w->scratch);
    free(w);
}

/* ------------------------------------------------------------------------ */
/* Events and state */

int mlc_window_dispatch(mlc_window *w) {
    if (atomic_load(&w->closed)) return MLC_E_CLOSED;
    /* Read whatever arrived without blocking, then dispatch it. */
    while (wl_display_prepare_read(w->display) != 0) {
        if (wl_display_dispatch_pending(w->display) < 0) goto broken;
    }
    if (wl_display_flush(w->display) < 0 && errno != EAGAIN) {
        wl_display_cancel_read(w->display);
        goto broken;
    }
    struct pollfd pfd = {.fd = wl_display_get_fd(w->display), .events = POLLIN};
    if (poll(&pfd, 1, 0) > 0) {
        if (wl_display_read_events(w->display) < 0) goto broken;
    } else {
        wl_display_cancel_read(w->display);
    }
    if (wl_display_dispatch_pending(w->display) < 0) goto broken;
    return atomic_load(&w->closed) ? MLC_E_CLOSED : MLC_OK;
broken:
    atomic_store(&w->closed, 1);
    return mlc_fail(MLC_E_CLOSED, "Wayland connection lost: %s", strerror(wl_display_get_error(w->display)));
}

int mlc_window_closed(const mlc_window *w) { return atomic_load(&w->closed); }

int mlc_window_focused(const mlc_window *w) {
    return !atomic_load(&w->has_keyboard) || atomic_load(&w->focused);
}

void mlc_window_set_fullscreen(mlc_window *w, int on) {
    if (on)
        xdg_toplevel_set_fullscreen(w->toplevel, NULL);
    else
        xdg_toplevel_unset_fullscreen(w->toplevel);
    wl_surface_commit(w->surface);
    wl_display_flush(w->display);
}

int mlc_window_set_mode(mlc_window *w, int mode) {
    w->mode = mode;
    w->swap_interval = mode == MLC_PRESENT_SMOOTH ? 1 : 0;
    if (eglGetCurrentContext() == w->egl_context) eglSwapInterval(w->egl_display, w->swap_interval);
    if (w->tearing)
        wp_tearing_control_v1_set_presentation_hint(w->tearing, mode == MLC_PRESENT_SMOOTH ? WP_TEARING_CONTROL_V1_PRESENTATION_HINT_VSYNC : WP_TEARING_CONTROL_V1_PRESENTATION_HINT_ASYNC);
    return MLC_OK;
}

void mlc_window_resize(mlc_window *w, uint32_t width, uint32_t height) {
    w->want_w = width;
    w->want_h = height;
    /* The compositor's size wins while it sets one (maximized, fullscreen, tiled). */
    if (w->forced) return;
    if (width != w->width || height != w->height) {
        w->width = width;
        w->height = height;
        wl_egl_window_resize(w->egl_window, (int)width, (int)height, 0, 0);
    }
}

void mlc_window_size(const mlc_window *w, uint32_t *width, uint32_t *height) {
    *width = w->width;
    *height = w->height;
}

int mlc_window_has_dmabuf(const mlc_window *w) { return w->has_dmabuf; }
const char *mlc_window_renderer(const mlc_window *w) { return w->renderer; }

/* ------------------------------------------------------------------------ */
/* Drawing */

static void upload(GLuint tex, GLenum internal, GLenum format, uint32_t w, uint32_t h, const uint8_t *data, uint32_t stride, uint32_t bpp) {
    glBindTexture(GL_TEXTURE_2D, tex);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, (GLint)(stride / bpp));
    glTexImage2D(GL_TEXTURE_2D, 0, (GLint)internal, (GLsizei)w, (GLsizei)h, 0, format, GL_UNSIGNED_BYTE, data);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
}

/* Uploads a plane of 16-bit words as 8-bit: `comps` samples per texel, the value in the
 * low `bits` bits (yuv4xxp10le) or, with `msb`, the top bits (P010). */
static int upload16(mlc_window *w, GLuint tex, GLenum internal, GLenum format, uint32_t width, uint32_t height, const uint8_t *data, uint32_t stride, uint32_t comps, int msb, uint32_t bits) {
    size_t row = (size_t)width * comps, need = row * height;
    if (need > w->scratch_len) {
        uint8_t *p = realloc(w->scratch, need);
        if (!p) return MLC_E_NOMEM;
        w->scratch = p;
        w->scratch_len = need;
    }
    unsigned shift = msb ? 8 : bits - 8;
    for (uint32_t y = 0; y < height; y++) {
        const uint16_t *src = (const uint16_t *)(data + (size_t)y * stride);
        uint8_t *dst = w->scratch + (size_t)y * row;
        for (size_t x = 0; x < row; x++) {
            /* Round, and keep 1023 at 255. */
            unsigned v = (src[x] + (msb ? 0x80u : (1u << (shift - 1)))) >> shift;
            dst[x] = (uint8_t)(v > 255 ? 255 : v);
        }
    }
    upload(tex, internal, format, width, height, w->scratch, (uint32_t)row, comps);
    return MLC_OK;
}

/* Fit the picture inside the window, keeping its aspect; clip-space rect. */
static void letterbox(const mlc_window *w, uint32_t fw, uint32_t fh, float rect[4]) {
    float ww = (float)w->width, wh = (float)w->height;
    float sx = 1.0f, sy = 1.0f;
    if (fw && fh && ww > 0 && wh > 0) {
        float fa = (float)fw / (float)fh, wa = ww / wh;
        if (fa > wa)
            sy = wa / fa;
        else
            sx = fa / wa;
    }
    /* Snap to whole pixels so a 1:1 picture lands on pixel centres. */
    float pw = (float)(int)(sx * ww + 0.5f), ph = (float)(int)(sy * wh + 0.5f);
    float x0 = (float)(int)((ww - pw) / 2), y0 = (float)(int)((wh - ph) / 2);
    rect[0] = x0 / ww * 2 - 1;
    rect[1] = 1 - (y0 + ph) / wh * 2;
    rect[2] = (x0 + pw) / ww * 2 - 1;
    rect[3] = 1 - y0 / wh * 2;
}

static int draw_dmabuf(mlc_window *w, const mlc_frame *f, EGLImageKHR images[2]);

/* Column-major YUV -> RGB for the shader, after subtracting `offset`. */
static void yuv_matrix(const mlc_frame *f, float m[9], float off[3]) {
    float ys, cs;
    if (f->full_range) {
        ys = 1.0f;
        cs = 1.0f;
        off[0] = 0.0f;
    } else {
        ys = 255.0f / 219.0f;
        cs = 255.0f / 224.0f;
        off[0] = 16.0f / 255.0f;
    }
    off[1] = off[2] = 128.0f / 255.0f;
    float kr = f->bt2020 ? 0.2627f : f->bt709 ? 0.2126f : 0.299f;
    float kb = f->bt2020 ? 0.0593f : f->bt709 ? 0.0722f : 0.114f;
    float kg = 1.0f - kr - kb;
    /* R = Y + 2(1-kr) V; G = Y - 2 kb (1-kb)/kg U - 2 kr (1-kr)/kg V; B = Y + 2(1-kb) U */
    float rv = 2 * (1 - kr), gu = -2 * kb * (1 - kb) / kg, gv = -2 * kr * (1 - kr) / kg, bu = 2 * (1 - kb);
    /* columns: Y, U, V */
    m[0] = ys, m[1] = ys, m[2] = ys;
    m[3] = 0, m[4] = gu * cs, m[5] = bu * cs;
    m[6] = rv * cs, m[7] = gv * cs, m[8] = 0;
}

int mlc_window_draw(mlc_window *w, const mlc_frame *f) {
    int rc = make_current(w);
    if (rc) return rc;
    glViewport(0, 0, (GLsizei)w->width, (GLsizei)w->height);
    glDisable(GL_BLEND);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindVertexArray(w->vao);
    EGLImageKHR images[2] = {EGL_NO_IMAGE_KHR, EGL_NO_IMAGE_KHR};

    if (f && f->kind != MLC_FRAME_NONE) {
        float rect[4];
        letterbox(w, f->width, f->height, rect);
        uint32_t cw = (f->width + 1) / 2, ch = (f->height + 1) / 2;
        if (f->kind == MLC_FRAME_I444) cw = f->width, ch = f->height;
        int deep = f->bit_depth > 8;
        switch (f->kind) {
        case MLC_FRAME_NV12:
        case MLC_FRAME_P010:
        case MLC_FRAME_I420:
        case MLC_FRAME_I444:
        case MLC_FRAME_VAAPI: {
            if (f->kind == MLC_FRAME_NV12) {
                upload(w->tex[0], GL_R8, GL_RED, f->width, f->height, f->planes[0], f->strides[0], 1);
                upload(w->tex[1], GL_RG8, GL_RG, cw, ch, f->planes[1], f->strides[1], 2);
            } else if (f->kind == MLC_FRAME_P010) {
                if ((rc = upload16(w, w->tex[0], GL_R8, GL_RED, f->width, f->height, f->planes[0], f->strides[0], 1, 1, 10)) ||
                    (rc = upload16(w, w->tex[1], GL_RG8, GL_RG, cw, ch, f->planes[1], f->strides[1], 2, 1, 10)))
                    return rc;
            } else if (f->kind == MLC_FRAME_I420 || f->kind == MLC_FRAME_I444) {
                for (int i = 0; i < 3; i++) {
                    uint32_t pw = i ? cw : f->width, ph = i ? ch : f->height;
                    if (deep) {
                        if ((rc = upload16(w, w->tex[i], GL_R8, GL_RED, pw, ph, f->planes[i], f->strides[i], 1, 0, f->bit_depth))) return rc;
                    } else {
                        upload(w->tex[i], GL_R8, GL_RED, pw, ph, f->planes[i], f->strides[i], 1);
                    }
                }
            } else if ((rc = draw_dmabuf(w, f, images)) != MLC_OK) {
                return rc;
            }
            glUseProgram(w->prog_yuv);
            for (int i = 0; i < 3; i++) {
                glActiveTexture(GL_TEXTURE0 + i);
                glBindTexture(GL_TEXTURE_2D, w->tex[i]);
                glUniform1i(w->yuv_tex[i], i);
            }
            float m[9], off[3];
            yuv_matrix(f, m, off);
            glUniform1i(w->yuv_layout, f->kind == MLC_FRAME_I420 || f->kind == MLC_FRAME_I444 ? 1 : 0);
            glUniform1i(w->yuv_transfer, f->transfer == MLC_TRANSFER_PQ ? 1 : 0);
            glUniformMatrix3fv(w->yuv_matrix, 1, GL_FALSE, m);
            glUniform3fv(w->yuv_offset, 1, off);
            glUniform4fv(w->yuv_rect, 1, rect);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            glActiveTexture(GL_TEXTURE0);
            break;
        }
        case MLC_FRAME_BGRA:
            upload(w->tex[0], GL_RGBA8, GL_RGBA, f->width, f->height, f->planes[0], f->strides[0], 4);
            glUseProgram(w->prog_rgb);
            glActiveTexture(GL_TEXTURE0);
            glBindTexture(GL_TEXTURE_2D, w->tex[0]);
            glUniform1i(w->rgb_tex, 0);
            glUniform1i(w->rgb_blend, 0);
            glUniform4fv(w->rgb_rect, 1, rect);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
            break;
        default:
            return mlc_fail(MLC_E_UNSUPPORTED, "frame kind %u", f->kind);
        }
    }

    for (int i = 0; i < 2; i++)
        if (images[i] != EGL_NO_IMAGE_KHR) w->destroy_image(w->egl_display, images[i]);
    GLenum err = glGetError();
    return err == GL_NO_ERROR ? MLC_OK : mlc_fail(MLC_E_FAIL, "draw: GL error 0x%x", err);
}

int mlc_window_draw_overlay(mlc_window *w) {
    if (!w->overlay_on || !w->overlay_w || !w->overlay_h) return MLC_OK;
    int rc = make_current(w);
    if (rc) return rc;
    glBindVertexArray(w->vao);
    {
        float ww = (float)w->width, wh = (float)w->height;
        float ow = (float)(w->overlay_w < w->width ? w->overlay_w : w->width);
        float oh = (float)(w->overlay_h < w->height ? w->overlay_h : w->height);
        float rect[4] = {-1, 1 - oh / wh * 2, -1 + ow / ww * 2, 1};
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(w->prog_rgb);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, w->overlay_tex);
        glUniform1i(w->rgb_tex, 0);
        glUniform1i(w->rgb_blend, 1);
        glUniform4fv(w->rgb_rect, 1, rect);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glDisable(GL_BLEND);
    }
    GLenum err = glGetError();
    return err == GL_NO_ERROR ? MLC_OK : mlc_fail(MLC_E_FAIL, "overlay: GL error 0x%x", err);
}

int mlc_window_set_overlay(mlc_window *w, const uint32_t *pixels, uint32_t width, uint32_t height, uint32_t stride) {
    if (!pixels || !width || !height) {
        w->overlay_on = 0;
        return MLC_OK;
    }
    int rc = make_current(w);
    if (rc) return rc;
    upload(w->overlay_tex, GL_RGBA8, GL_RGBA, width, height, (const uint8_t *)pixels, stride * 4, 4);
    w->overlay_w = width;
    w->overlay_h = height;
    w->overlay_on = 1;
    return glGetError() == GL_NO_ERROR ? MLC_OK : mlc_fail(MLC_E_FAIL, "overlay upload failed");
}

int mlc_window_present(mlc_window *w) {
    int rc = make_current(w);
    if (rc) return rc;
    if (!eglSwapBuffers(w->egl_display, w->egl_surface)) {
        EGLint e = eglGetError();
        if (e == EGL_BAD_SURFACE || e == EGL_BAD_NATIVE_WINDOW) atomic_store(&w->closed, 1);
        return mlc_fail(e == EGL_CONTEXT_LOST ? MLC_E_NODEVICE : MLC_E_FAIL, "eglSwapBuffers: 0x%x", e);
    }
    return MLC_OK;
}

int mlc_window_read(mlc_window *w, uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint8_t *out, uint32_t stride) {
    int rc = make_current(w);
    if (rc) return rc;
    if (x + width > w->width || y + height > w->height) return mlc_fail(MLC_E_FAIL, "read outside the window");
    /* GL rows run bottom-up; read each row into place, RGBA -> BGRA. */
    for (uint32_t r = 0; r < height; r++) {
        uint8_t *row = out + (size_t)r * stride;
        glReadPixels((GLint)x, (GLint)(w->height - 1 - (y + r)), (GLsizei)width, 1, GL_RGBA, GL_UNSIGNED_BYTE, row);
        for (uint32_t i = 0; i < width; i++) {
            uint8_t t = row[4 * i];
            row[4 * i] = row[4 * i + 2];
            row[4 * i + 2] = t;
        }
    }
    return glGetError() == GL_NO_ERROR ? MLC_OK : mlc_fail(MLC_E_FAIL, "glReadPixels failed");
}

/* ------------------------------------------------------------------------ */
/* VAAPI surfaces as dma-buf EGLImages: one R8 image for luma, one GR88 for chroma. */

#ifndef DRM_FORMAT_MOD_INVALID
#define DRM_FORMAT_MOD_INVALID ((1ULL << 56) - 1)
#endif

static int draw_dmabuf(mlc_window *w, const mlc_frame *f, EGLImageKHR images[2]) {
    if (!w->has_dmabuf) return mlc_fail(MLC_E_UNSUPPORTED, "EGL has no dma-buf import");
    VADisplay dpy = f->va_display;
    VASurfaceID surf = f->va_surface;
    VADRMPRIMESurfaceDescriptor desc;
    memset(&desc, 0, sizeof desc);
    VAStatus st = vaSyncSurface(dpy, surf);
    if (st != VA_STATUS_SUCCESS) return mlc_fail(MLC_E_FAIL, "vaSyncSurface: %s", vaErrorStr(st));
    st = vaExportSurfaceHandle(dpy, surf, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                               VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS, &desc);
    if (st != VA_STATUS_SUCCESS) return mlc_fail(MLC_E_FAIL, "vaExportSurfaceHandle: %s", vaErrorStr(st));
    int rc = MLC_OK;
    if (desc.num_layers < 2) {
        rc = mlc_fail(MLC_E_UNSUPPORTED, "VAAPI surface has %u layers (want NV12 as two)", desc.num_layers);
        goto out;
    }
    for (uint32_t i = 0; i < 2; i++) {
        uint32_t obj = desc.layers[i].object_index[0];
        uint64_t mod = desc.objects[obj].drm_format_modifier;
        EGLint attr[32];
        int n = 0;
        attr[n++] = EGL_WIDTH, attr[n++] = (EGLint)(i == 0 ? f->width : (f->width + 1) / 2);
        attr[n++] = EGL_HEIGHT, attr[n++] = (EGLint)(i == 0 ? f->height : (f->height + 1) / 2);
        attr[n++] = EGL_LINUX_DRM_FOURCC_EXT, attr[n++] = (EGLint)desc.layers[i].drm_format;
        attr[n++] = EGL_DMA_BUF_PLANE0_FD_EXT, attr[n++] = desc.objects[obj].fd;
        attr[n++] = EGL_DMA_BUF_PLANE0_OFFSET_EXT, attr[n++] = (EGLint)desc.layers[i].offset[0];
        attr[n++] = EGL_DMA_BUF_PLANE0_PITCH_EXT, attr[n++] = (EGLint)desc.layers[i].pitch[0];
        if (mod != DRM_FORMAT_MOD_INVALID) {
            attr[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, attr[n++] = (EGLint)(mod & 0xffffffff);
            attr[n++] = EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, attr[n++] = (EGLint)(mod >> 32);
        }
        attr[n++] = EGL_NONE;
        images[i] = w->create_image(w->egl_display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attr);
        if (images[i] == EGL_NO_IMAGE_KHR) {
            rc = mlc_fail(MLC_E_FAIL, "eglCreateImageKHR (dma-buf layer %u): 0x%x", i, eglGetError());
            goto out;
        }
        glBindTexture(GL_TEXTURE_2D, w->tex[i]);
        w->image_target_texture(GL_TEXTURE_2D, images[i]);
    }
out:
    for (uint32_t i = 0; i < desc.num_objects; i++) close(desc.objects[i].fd);
    return rc;
}
