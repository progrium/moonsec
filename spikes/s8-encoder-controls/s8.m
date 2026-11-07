// S8 spike: VideoToolbox hardware encoder controls needed by moonsec.
//   bitrate  : change AverageBitRate/DataRateLimits mid-stream, check for IDR + size response
//   irefresh : IntraRefreshFrames (private) / MaxRefreshFrameIntervalDuration, check for IDR-free stream + recovery SEI
//   ltr      : EnableLTR + ack tokens + ForceLTRRefresh after simulated loss, verified by decoding
// Build: clang -O2 -fobjc-arc -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo s8.m -o s8
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#include <mach/mach_time.h>
#include <sys/resource.h>

#define W 1920
#define H 1080
#define FPS 60
#define MAXF 2000

typedef struct {
  CMSampleBufferRef sb; size_t bytes; int sync; int ltrToken; int hasToken;
  double latms; char nals[128];
} Out;

static Out outs[MAXF];
static uint64_t submitT[MAXF];
static dispatch_semaphore_t sem;
static int hevc;
static mach_timebase_info_data_t tb;
static double ms(uint64_t a, uint64_t b){ return (double)(b-a)*tb.numer/tb.denom/1e6; }

static void describeNALs(CMSampleBufferRef sb, char *buf, size_t n) {
  CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
  size_t len=0; char *p=NULL; CMBlockBufferGetDataPointer(bb,0,NULL,&len,&p);
  // need contiguous copy
  uint8_t *d = malloc(len); CMBlockBufferCopyDataBytes(bb,0,len,d);
  size_t off=0; buf[0]=0;
  while (off+4<=len) {
    uint32_t l=(d[off]<<24)|(d[off+1]<<16)|(d[off+2]<<8)|d[off+3]; off+=4;
    if (off+l>len||l==0) break;
    uint8_t *u=d+off; char tmp[24];
    if (!hevc) {
      int t=u[0]&0x1f;
      if (t==6) snprintf(tmp,sizeof tmp,"SEI(%d),",u[1]);
      else snprintf(tmp,sizeof tmp,"%d,",t);
    } else {
      int t=(u[0]>>1)&0x3f;
      if (t==39||t==40) snprintf(tmp,sizeof tmp,"SEI%d(%d),",t,u[2]);
      else snprintf(tmp,sizeof tmp,"%d,",t);
    }
    if (strlen(buf)+strlen(tmp)<n) strcat(buf,tmp);
    off+=l;
  }
  free(d);
}

static void cb(void *ref, void *frameRef, OSStatus st, VTEncodeInfoFlags fl, CMSampleBufferRef sb) {
  int i=(int)(intptr_t)frameRef; uint64_t now=mach_absolute_time();
  Out *o=&outs[i]; memset(o,0,sizeof *o); o->latms=ms(submitT[i],now);
  if (st||!sb) { fprintf(stderr,"frame %d err=%d flags=%u\n",i,(int)st,fl); o->bytes=0; dispatch_semaphore_signal(sem); return; }
  CFRetain(sb); o->sb=sb; o->bytes=CMSampleBufferGetTotalSampleSize(sb);
  CFArrayRef a=CMSampleBufferGetSampleAttachmentsArray(sb,false);
  CFDictionaryRef d=a&&CFArrayGetCount(a)?CFArrayGetValueAtIndex(a,0):NULL;
  o->sync = !(d && CFDictionaryGetValue(d,kCMSampleAttachmentKey_NotSync)==kCFBooleanTrue);
  CFNumberRef tok=d?CFDictionaryGetValue(d,kVTSampleAttachmentKey_RequireLTRAcknowledgementToken):NULL;
  if (tok){ CFNumberGetValue(tok,kCFNumberIntType,&o->ltrToken); o->hasToken=1; }
  describeNALs(sb,o->nals,sizeof o->nals);
  dispatch_semaphore_signal(sem);
}

static CVPixelBufferPoolRef pool;
static CVPixelBufferRef frame(int t) {
  CVPixelBufferRef pb; CVPixelBufferPoolCreatePixelBuffer(NULL,pool,&pb);
  CVPixelBufferLockBaseAddress(pb,0);
  uint8_t *y=CVPixelBufferGetBaseAddressOfPlane(pb,0); size_t ys=CVPixelBufferGetBytesPerRowOfPlane(pb,0);
  uint8_t *uv=CVPixelBufferGetBaseAddressOfPlane(pb,1); size_t uvs=CVPixelBufferGetBytesPerRowOfPlane(pb,1);
  uint32_t r=0x9e3779b9u*(t+1);
  for (int j=0;j<H;j++){ uint8_t *row=y+j*ys; for (int i=0;i<W;i++){
    r^=r<<13; r^=r>>17; r^=r<<5;
    int v=(((i+3*t)>>3)^((j+t)>>3))*7 & 0xff;
    int bx=(t*9)%W, by=(t*5)%H; if (i>bx&&i<bx+300&&j>by&&j<by+200) v=255-v;
    v += (int)(r&15)-8; row[i]= v<0?0:v>255?255:v; } }
  for (int j=0;j<H/2;j++){ uint8_t *row=uv+j*uvs; for (int i=0;i<W;i+=2){ row[i]=(i/4+t)&0xff; row[i+1]=(j/2+2*t)&0xff; } }
  CVPixelBufferUnlockBaseAddress(pb,0);
  return pb;
}

static VTCompressionSessionRef mk(int lowlat, NSDictionary *extra) {
  NSMutableDictionary *spec=[@{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES} mutableCopy];
  if (lowlat) spec[(id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl]=@YES;
  VTCompressionSessionRef s=NULL;
  OSStatus st=VTCompressionSessionCreate(NULL,W,H,hevc?kCMVideoCodecType_HEVC:kCMVideoCodecType_H264,(__bridge CFDictionaryRef)spec,NULL,NULL,cb,NULL,&s);
  if (st){ printf("create failed %d\n",(int)st); exit(1); }
  CFStringRef eid=NULL; VTSessionCopyProperty(s,kVTCompressionPropertyKey_EncoderID,NULL,&eid);
  printf("# encoder=%s\n",[(__bridge NSString*)eid UTF8String]);
  NSDictionary *base=@{
    (id)kVTCompressionPropertyKey_RealTime:@YES,
    (id)kVTCompressionPropertyKey_AllowFrameReordering:@NO,
    (id)kVTCompressionPropertyKey_ExpectedFrameRate:@FPS,
    (id)kVTCompressionPropertyKey_MaxKeyFrameInterval:@100000,
    (id)kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration:@100000,
    (id)kVTCompressionPropertyKey_AverageBitRate:@20000000,
    (id)kVTCompressionPropertyKey_ProfileLevel:(hevc?(id)kVTProfileLevel_HEVC_Main_AutoLevel:(id)kVTProfileLevel_H264_High_AutoLevel),
  };
  for (id k in base){ OSStatus e=VTSessionSetProperty(s,(__bridge CFStringRef)k,(__bridge CFTypeRef)base[k]); if(e) printf("# set %s -> %d\n",[k UTF8String],(int)e); }
  for (id k in extra){ OSStatus e=VTSessionSetProperty(s,(__bridge CFStringRef)k,(__bridge CFTypeRef)extra[k]); printf("# set %s=%s -> %d\n",[k UTF8String],[[extra[k] description] UTF8String],(int)e);
    CFTypeRef v=NULL; OSStatus g=VTSessionCopyProperty(s,(__bridge CFStringRef)k,NULL,&v); printf("#   readback %d %s\n",(int)g,v?[[(__bridge id)v description] UTF8String]:"(null)"); }
  VTCompressionSessionPrepareToEncodeFrames(s);
  return s;
}

static void enc(VTCompressionSessionRef s, int i, NSDictionary *opts) {
  CVPixelBufferRef pb=frame(i);
  submitT[i]=mach_absolute_time();
  OSStatus st=VTCompressionSessionEncodeFrame(s,pb,CMTimeMake(i,FPS),CMTimeMake(1,FPS),(__bridge CFDictionaryRef)opts,(void*)(intptr_t)i,NULL);
  CVPixelBufferRelease(pb);
  if (st){ printf("encode %d err %d\n",i,(int)st); outs[i].bytes=0; return; }
  dispatch_semaphore_wait(sem,DISPATCH_TIME_FOREVER);
}

static void row(int i){ Out *o=&outs[i]; printf("%4d %8zu %s lat=%.2fms %s%s\n",i,o->bytes,o->sync?"SYNC":"    ",o->latms,o->hasToken?"ltr-token ":"",o->nals); }
static double avgk(int a,int b){ double s=0; for(int i=a;i<b;i++) s+=outs[i].bytes; return s/(b-a)*8*FPS/1e6; }
static int countSync(int a,int b){ int c=0; for(int i=a;i<b;i++) c+=outs[i].sync; return c; }
static size_t maxb(int a,int b){ size_t m=0; for(int i=a;i<b;i++) if(outs[i].bytes>m)m=outs[i].bytes; return m; }

// ---------------- tests ----------------
static void t_bitrate(int lowlat, int useLimits) {
  VTCompressionSessionRef s=mk(lowlat,@{});
  int N=360;
  for (int i=0;i<N;i++){
    if (i==120||i==240||i==300) {
      int br = i==120?4000000 : i==240?30000000 : 8000000;
      OSStatus e=VTSessionSetProperty(s,kVTCompressionPropertyKey_AverageBitRate,(__bridge CFTypeRef)@(br));
      OSStatus e2=0;
      if (useLimits) e2=VTSessionSetProperty(s,kVTCompressionPropertyKey_DataRateLimits,(__bridge CFArrayRef)@[@(br/8*1.5/ FPS * 2),@(2.0/FPS)]);
      printf("# frame %d set AverageBitRate=%d -> %d%s%d\n",i,br,(int)e,useLimits?" DataRateLimits -> ":"",useLimits?(int)e2:0);
    }
    enc(s,i,nil);
  }
  for (int i=115;i<130;i++) row(i);
  for (int i=236;i<246;i++) row(i);
  printf("RESULT bitrate lowlat=%d limits=%d sync_after_0=%d | Mbps 60-120=%.1f 125-240=%.1f 245-300=%.1f 305-360=%.1f | frames-to-settle-after-120: ",
    lowlat,useLimits,countSync(1,N),avgk(60,120),avgk(125,240),avgk(245,300),avgk(305,360));
  // settle: first frame after 120 whose 10-frame avg within 30% of 4 Mbps
  for (int i=120;i<230;i++){ if (fabs(avgk(i,i+10)-4.0)<1.2){ printf("%d",i-120); break; } }
  double lat=0; for(int i=1;i<N;i++) lat+=outs[i].latms; printf(" | mean lat %.2fms\n",lat/(N-1));
  VTCompressionSessionInvalidate(s); CFRelease(s);
}

static void t_irefresh(int lowlat, NSDictionary *extra) {
  VTCompressionSessionRef s=mk(lowlat,extra);
  int N=240; for (int i=0;i<N;i++) enc(s,i,nil);
  for (int i=0;i<8;i++) row(i);
  for (int i=58;i<64;i++) row(i);
  // look for recovery point SEI / non-IDR sync / periodic size spikes
  int sei=0; for(int i=1;i<N;i++) if (strstr(outs[i].nals,"SEI")) sei++;
  double mean=0; for(int i=10;i<N;i++) mean+=outs[i].bytes; mean/=N-10;
  printf("RESULT irefresh lowlat=%d %s sync_after_0=%d frames_with_SEI=%d frame0=%zu mean=%.0f max(10..)=%zu peak/mean=%.2f\n",
    lowlat,[[extra description] stringByReplacingOccurrencesOfString:@"\n" withString:@""].UTF8String,countSync(1,N),sei,outs[0].bytes,mean,maxb(10,N),maxb(10,N)/mean);
  VTCompressionSessionInvalidate(s); CFRelease(s);
}

// ----- decoder for LTR verification -----
static uint64_t decHash[MAXF]; static int decStatus[MAXF];
static void dcb(void *r, void *fr, OSStatus st, VTDecodeInfoFlags f, CVImageBufferRef img, CMTime pts, CMTime dur){
  int i=(int)(intptr_t)fr; decStatus[i]=st; decHash[i]=0;
  if (!img) return;
  CVPixelBufferLockBaseAddress(img,kCVPixelBufferLock_ReadOnly);
  uint8_t *y=CVPixelBufferGetBaseAddressOfPlane(img,0); size_t ys=CVPixelBufferGetBytesPerRowOfPlane(img,0);
  uint64_t h=1469598103934665603ull; for(int j=0;j<H;j++) for(int x=0;x<W;x+=4){ h^=y[j*ys+x]; h*=1099511628211ull; }
  CVPixelBufferUnlockBaseAddress(img,kCVPixelBufferLock_ReadOnly);
  decHash[i]=h;
}
static void decode(int N, int lostA, int lostB, uint64_t *hashes, int *stat) {
  CMFormatDescriptionRef fd=CMSampleBufferGetFormatDescription(outs[0].sb);
  VTDecompressionOutputCallbackRecord r={dcb,NULL};
  VTDecompressionSessionRef d; OSStatus st=VTDecompressionSessionCreate(NULL,fd,NULL,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)},&r,&d);
  if (st){ printf("dec create %d\n",(int)st); exit(1); }
  for (int i=0;i<N;i++){ decStatus[i]=-1; decHash[i]=0;
    if (i>=lostA&&i<lostB) continue;
    if (!outs[i].sb) continue;
    VTDecodeInfoFlags fl; OSStatus e=VTDecompressionSessionDecodeFrame(d,outs[i].sb,0,(void*)(intptr_t)i,&fl);
    if (e) decStatus[i]=e;
    VTDecompressionSessionWaitForAsynchronousFrames(d);
  }
  memcpy(hashes,decHash,sizeof(uint64_t)*N); memcpy(stat,decStatus,sizeof(int)*N);
  VTDecompressionSessionInvalidate(d); CFRelease(d);
}

static void t_ltr(int doRefresh, int ackDelay) {
  VTCompressionSessionRef s=mk(1,@{(id)kVTCompressionPropertyKey_EnableLTR:@YES});
  int N=240, LA=100, LB=105, DETECT=LB+ackDelay; // frames LA..LB-1 lost; loss detected at DETECT
  int tokens=0; NSMutableArray *pendingAck=[NSMutableArray array];
  int refreshFrame=-1;
  for (int i=0;i<N;i++){
    // client acks tokens of frames received (i - ackDelay), skipping lost and the corrupted frames until refresh
    NSMutableDictionary *opts=[NSMutableDictionary dictionary];
    int j=i-ackDelay;
    if (j>=0 && outs[j].hasToken) {
      int corrupt = (j>=LA && (refreshFrame<0 || j<refreshFrame));
      if (!corrupt) [pendingAck addObject:@(outs[j].ltrToken)];
    }
    if (pendingAck.count){ opts[(id)kVTEncodeFrameOptionKey_AcknowledgedLTRTokens]=[pendingAck copy]; [pendingAck removeAllObjects]; }
    if (doRefresh && i==DETECT){ opts[(id)kVTEncodeFrameOptionKey_ForceLTRRefresh]=@YES; refreshFrame=i; }
    enc(s,i,opts.count?opts:nil);
    if (outs[i].hasToken) tokens++;
  }
  printf("# lost %d..%d, detect/refresh at %d (refresh=%d), ack delay %d frames\n",LA,LB-1,DETECT,doRefresh,ackDelay);
  for (int i=0;i<4;i++) row(i);
  for (int i=LA-2;i<DETECT+4;i++) row(i);
  static uint64_t hA[MAXF],hB[MAXF]; static int sA[MAXF],sB[MAXF];
  decode(N,0,0,hA,sA); decode(N,LA,getenv("S8SKIPCORRUPT")?DETECT:LB,hB,sB);
  if (getenv("S8DBG")) for (int i=LA-2;i<LA+30;i++) printf("dbg %d A=%d B=%d eq=%d\n",i,sA[i],sB[i],hA[i]==hB[i]);
  int firstMatch=-1, mismatchAfter=0, decErr=0;
  for (int i=LB;i<N;i++){ if (sB[i]!=0) decErr++; if (hA[i]==hB[i]) { if(firstMatch<0) firstMatch=i; } else if (firstMatch>=0) mismatchAfter++; }
  int fullMatch=1; for(int i=0;i<N;i++) if(i<LA||i>=LB) if(hA[i]!=hB[i] && i<LA) fullMatch=0;
  printf("RESULT ltr refresh=%d ackDelay=%d tokens=%d sync_after_0=%d refresh_frame_bytes=%zu mean_P=%.0f frame0=%zu | lossy-decode: dec_errors_after_loss=%d first_bitexact_frame=%d mismatches_after_that=%d prefix_ok=%d\n",
    doRefresh,ackDelay,tokens,countSync(1,N),doRefresh?outs[DETECT].bytes:0,
    ({double m=0; for(int i=20;i<LA;i++) m+=outs[i].bytes; m/(LA-20);}),outs[0].bytes,decErr,firstMatch,mismatchAfter,fullMatch);
  for (int i=0;i<N;i++) if(outs[i].sb){CFRelease(outs[i].sb); outs[i].sb=NULL;}
  VTCompressionSessionInvalidate(s); CFRelease(s);
}

int main(int argc, char **argv){ @autoreleasepool{
  mach_timebase_info(&tb); sem=dispatch_semaphore_create(0);
  if (argc<3){ fprintf(stderr,"usage: s8 h264|hevc bitrate|bitrate-ll|bitrate-limits|bitrate-ll-limits|irefresh-*|ltr|ltr-norefresh [arg]\n"); return 2; }
  hevc=!strcmp(argv[1],"hevc");
  CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),(id)kCVPixelBufferWidthKey:@W,(id)kCVPixelBufferHeightKey:@H,(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&pool);
  const char *t=argv[2]; int arg=argc>3?atoi(argv[3]):0;
  struct rusage r0,r1; getrusage(RUSAGE_SELF,&r0);
  if (!strcmp(t,"bitrate")) t_bitrate(0,0);
  else if (!strcmp(t,"bitrate-ll")) t_bitrate(1,0);
  else if (!strcmp(t,"bitrate-limits")) t_bitrate(0,1);
  else if (!strcmp(t,"bitrate-ll-limits")) t_bitrate(1,1);
  else if (!strcmp(t,"irefresh-none")) t_irefresh(0,@{});
  else if (!strcmp(t,"irefresh-frames")) t_irefresh(0,@{@"IntraRefreshFrames":@(arg?arg:30)});
  else if (!strcmp(t,"irefresh-ll-none")) t_irefresh(1,@{});
  else if (!strcmp(t,"irefresh-ll-dur")) t_irefresh(1,@{@"MaxRefreshFrameIntervalDuration":@(arg?arg:1)});
  else if (!strcmp(t,"ltr")) t_ltr(1,arg?arg:3);
  else if (!strcmp(t,"ltr-norefresh")) t_ltr(0,arg?arg:3);
  getrusage(RUSAGE_SELF,&r1);
  printf("# cpu user=%.2fs sys=%.2fs\n",(r1.ru_utime.tv_sec-r0.ru_utime.tv_sec)+(r1.ru_utime.tv_usec-r0.ru_utime.tv_usec)/1e6,(r1.ru_stime.tv_sec-r0.ru_stime.tv_sec)+(r1.ru_stime.tv_usec-r0.ru_stime.tv_usec)/1e6);
}}
