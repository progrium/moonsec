// S8 probe: dump VideoToolbox hardware encoder supported properties.
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
static void dump(CMVideoCodecType c, const char *name, BOOL lowlat) {
  NSMutableDictionary *spec = [@{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES} mutableCopy];
  if (lowlat) spec[(id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = @YES;
  VTCompressionSessionRef s = NULL;
  OSStatus st = VTCompressionSessionCreate(NULL,1920,1080,c,(__bridge CFDictionaryRef)spec,NULL,NULL,NULL,NULL,&s);
  printf("=== %s lowlatency=%d create=%d\n", name, lowlat, (int)st);
  if (st) return;
  CFBooleanRef hw=NULL; VTSessionCopyProperty(s,kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,NULL,&hw);
  CFStringRef eid=NULL; VTSessionCopyProperty(s,kVTCompressionPropertyKey_EncoderID,NULL,&eid);
  printf("hw=%d encoder=%s\n", hw==kCFBooleanTrue, eid?[(__bridge NSString*)eid UTF8String]:"?");
  CFDictionaryRef d=NULL; VTSessionCopySupportedPropertyDictionary(s,&d);
  NSArray *keys=[[(__bridge NSDictionary*)d allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *k in keys) printf("  %s\n",[k UTF8String]);
  VTCompressionSessionInvalidate(s); CFRelease(s);
}
int main(){ @autoreleasepool{
  dump(kCMVideoCodecType_H264,"H264",NO); dump(kCMVideoCodecType_H264,"H264",YES);
  dump(kCMVideoCodecType_HEVC,"HEVC",NO); dump(kCMVideoCodecType_HEVC,"HEVC",YES);
}}
