// NSPasteboard clipboard backend (macOS): the general pasteboard's string type, with
// changeCount for change detection. C ABI for platform/clipboard/macos.zig.
#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

long msc_pb_change_count(void) {
    @autoreleasepool {
        return (long)[[NSPasteboard generalPasteboard] changeCount];
    }
}

// Copies the pasteboard's text as UTF-8 into a malloc'd buffer (*out, *len; free with
// msc_pb_free). Returns 1 with text, 0 when the pasteboard holds no text.
int msc_pb_read_text(char **out, size_t *len) {
    @autoreleasepool {
        NSString *s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        if (s == nil) return 0;
        const char *u = [s UTF8String];
        if (u == NULL) return 0;
        size_t n = strlen(u);
        char *b = malloc(n + 1);
        if (b == NULL) return -1;
        memcpy(b, u, n + 1);
        *out = b;
        *len = n;
        return 1;
    }
}

// Replaces the pasteboard's contents with UTF-8 text. Returns 1 on success.
int msc_pb_write_text(const char *text, size_t len) {
    @autoreleasepool {
        NSString *s = [[NSString alloc] initWithBytes:text length:len encoding:NSUTF8StringEncoding];
        if (s == nil) return 0;
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        BOOL ok = [pb setString:s forType:NSPasteboardTypeString];
#if !__has_feature(objc_arc)
        [s release];
#endif
        return ok ? 1 : 0;
    }
}

void msc_pb_free(char *p) { free(p); }
