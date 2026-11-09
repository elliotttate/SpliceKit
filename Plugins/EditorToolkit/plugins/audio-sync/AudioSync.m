// Batch Sync Audio for Final Cut Pro (SpliceKit plugin)
//
// Select video clips in the timeline plus the external recordings (in the browser, and/or audio-only
// clips in the timeline), run "Batch Sync Audio" (Clip menu / Command Editor). Every video's camera
// audio is compared with every recording, the right recording and the exact offset are found, and each
// timeline clip is swapped for a native Synchronized Clip (video + that recording, camera audio off as
// a sync source) in the same place with the same in/out. One review panel, one undo step.
//
// Engine (no third-party code, all Apple Accelerate/AVFoundation):
//   1. decode to mono, 8 kHz; onset envelope (multi-band spectral flux, 5 ms hops)
//   2. coarse: FFT cross-correlation of envelopes video x recording -> best recording + offset (+-5 ms),
//      confidence = peak height in standard deviations (same idea as BBC audio-offset-finder)
//   3. fine: GCC-PHAT on 16 kHz audio around the coarse offset, parabolic peak -> sub-sample offset
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - small helpers
static void ALog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt); NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/audiosync.log"];
    FILE *f = fopen(p.fileSystemRepresentation, "a");
    if (f) { fprintf(f, "%s %s\n", [NSDate date].description.UTF8String, s.UTF8String); fclose(f); }
}
static id O(id o, NSString *s) {
    SEL x = NSSelectorFromString(s);
    if (!o || ![o respondsToSelector:x]) return nil;
    NSMethodSignature *g = [o methodSignatureForSelector:x];
    if (g.numberOfArguments != 2 || strcmp(g.methodReturnType, "@")) return nil;
    return ((id(*)(id, SEL))objc_msgSend)(o, x);
}
static BOOL OB(id o, NSString *s) { SEL x = NSSelectorFromString(s); return (o && [o respondsToSelector:x]) ? ((BOOL(*)(id, SEL))objc_msgSend)(o, x) : NO; }
static CMTimeRange OR(id o, NSString *s) {
    SEL x = NSSelectorFromString(s);
    if (!o || ![o respondsToSelector:x]) return kCMTimeRangeInvalid;
    return ((CMTimeRange(*)(id, SEL))objc_msgSend)(o, x);
}
static CMTime OT(id o, NSString *s) {
    SEL x = NSSelectorFromString(s);
    if (!o || ![o respondsToSelector:x]) return kCMTimeInvalid;
    return ((CMTime(*)(id, SEL))objc_msgSend)(o, x);
}
static CMTimeRange RangeIn(id o, id c) {
    SEL s = NSSelectorFromString(@"timeRangeInContainerSpace:");
    return [o respondsToSelector:s] ? ((CMTimeRange(*)(id, SEL, id))objc_msgSend)(o, s, c) : kCMTimeRangeInvalid;
}
static long Lane(id o) { SEL s = NSSelectorFromString(@"anchoredLane"); return [o respondsToSelector:s] ? ((long(*)(id, SEL))objc_msgSend)(o, s) : 0; }
static double Sec(CMTime t) { return CMTIME_IS_VALID(t) ? CMTimeGetSeconds(t) : 0; }
static id ActiveTM(void) {
    id (*fn)(void) = (id(*)(void))dlsym(RTLD_DEFAULT, "SpliceKit_getActiveTimelineModule");
    if (fn) { id tm = fn(); if (tm) return tm; }
    return O(O([NSApp delegate], @"activeEditorContainer"), @"timelineModule");
}
static NSURL *ItemURL(id item) {
    SEL s = NSSelectorFromString(@"assetsIncludingAnchored:");
    if ([item respondsToSelector:s]) {
        id assets = ((id(*)(id, SEL, BOOL))objc_msgSend)(item, s, NO);
        for (id a in assets) { NSURL *u = O(a, @"originalMediaURL"); if (u) return u; }
    }
    // a browser clip is a little sequence: look at the media inside it
    id prim = O(item, @"primaryObject");
    if (prim && prim != item) for (id it in (NSArray *)O(prim, @"containedItems")) { NSURL *u = ItemURL(it); if (u) return u; }
    return nil;
}
static NSArray *gTestSources;   // test hook: recordings by browser-clip name instead of the browser selection

#pragma mark - audio engine
static const double kEnvRate = 200.0;     // envelope frames per second (5 ms)
static const double kDecRate = 8000.0;    // analysis sample rate for the envelope
static const double kFineRate = 16000.0;  // sample rate for the fine (GCC-PHAT) stage

// decode [start, start+dur) of the file (dur <= 0: to the end) as mono float at `rate`
static NSData *Decode(NSURL *url, double rate, double start, double dur, NSString **err) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop
    if (!tracks.count) { if (err) *err = @"no audio track Final Cut's media framework can read"; return nil; }
    NSError *e = nil;
    AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&e];
    if (!r) { if (err) *err = e.localizedDescription ?: @"cannot read file"; return nil; }
    NSDictionary *set = @{ AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @1,
                           AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsNonInterleaved: @NO, AVLinearPCMIsBigEndianKey: @NO };
    AVAssetReaderAudioMixOutput *o = [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:@[tracks.firstObject] audioSettings:set];
    if (start > 0 || dur > 0) {
        CMTime st = CMTimeMakeWithSeconds(MAX(0, start), 48000);
        CMTime du = dur > 0 ? CMTimeMakeWithSeconds(dur, 48000) : kCMTimePositiveInfinity;
        r.timeRange = CMTimeRangeMake(st, du);
    }
    if (![r canAddOutput:o]) { if (err) *err = @"cannot decode audio"; return nil; }
    [r addOutput:o];
    if (![r startReading]) { if (err) *err = r.error.localizedDescription ?: @"cannot start reading"; return nil; }
    NSMutableData *d = [NSMutableData data];
    BOOL first = YES;
    CMSampleBufferRef sb;
    while ((sb = [o copyNextSampleBuffer])) {
        if (first) {   // keep timing honest if the audio starts later than asked for
            double lead = Sec(CMSampleBufferGetPresentationTimeStamp(sb)) - MAX(0, start);
            if (lead > 0.0005 && lead < 30) [d increaseLengthBy:(NSUInteger)llround(lead * rate) * sizeof(float)];
            first = NO;
        }
        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
        size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
        if (len) { NSUInteger at = d.length; [d increaseLengthBy:len]; CMBlockBufferCopyDataBytes(bb, 0, len, (char *)d.mutableBytes + at); }
        CFRelease(sb);
    }
    if (r.status == AVAssetReaderStatusFailed) { if (err) *err = r.error.localizedDescription ?: @"decode failed"; return nil; }
    // AVFoundation's sample-rate conversion over long files drifts slightly (measured ~25 ppm: 46 ms over
    // 30 min on a DJI recording). Final Cut plays media by its own clock (the asset duration), so stretch the
    // decoded samples to exactly the length that time range should have - then sample index == media time.
    double assetDur = CMTimeGetSeconds(asset.duration);
    double want = (dur > 0 ? MIN(dur, assetDur - MAX(0, start)) : assetDur - MAX(0, start)) * rate;
    size_t have = d.length / sizeof(float);
    if (want > 100 && have > 100 && fabs(have - want) > 0.5 && fabs(have - want) / want < 0.002) {
        size_t n = (size_t)llround(want);
        NSMutableData *o = [NSMutableData dataWithLength:n * sizeof(float)];
        const float *x = d.bytes; float *y = o.mutableBytes; double k = (double)(have - 1) / (double)(n - 1);
        for (size_t i = 0; i < n; i++) { double p = i * k; size_t j = (size_t)p; double f = p - j; y[i] = j + 1 < have ? (float)(x[j] * (1 - f) + x[j + 1] * f) : x[have - 1]; }
        return o;
    }
    return d;
}

static void ZNorm(float *x, vDSP_Length n) {
    if (!n) return;
    float mean = 0, sd = 0;
    vDSP_normalize(x, 1, x, 1, &mean, &sd, n);   // x = (x - mean) / sd
    if (!(sd > 0)) memset(x, 0, n * sizeof(float));
}

// multi-band spectral-flux onset envelope at 200 Hz from 8 kHz mono
static NSData *Envelope(NSData *pcm) {
    const float *x = pcm.bytes; size_t n = pcm.length / sizeof(float);
    const int N = 256, hop = (int)(kDecRate / kEnvRate), nb = 6;
    if (n < (size_t)N) return [NSData data];
    size_t frames = (n - N) / hop + 1;
    NSMutableData *out = [NSMutableData dataWithLength:frames * sizeof(float)];
    float *env = out.mutableBytes;
    FFTSetup fs = vDSP_create_fftsetup(8, kFFTRadix2);
    float win[256], buf[256], re[128], im[128], mag[128], prev[6] = {0};
    vDSP_hann_window(win, N, vDSP_HANN_NORM);
    DSPSplitComplex sc = { re, im };
    const int edges[7] = { 2, 4, 8, 16, 32, 64, 128 };   // 62 Hz .. 4 kHz in octaves
    for (size_t f = 0; f < frames; f++) {
        vDSP_vmul(x + f * hop, 1, win, 1, buf, 1, N);
        vDSP_ctoz((const DSPComplex *)buf, 2, &sc, 1, N / 2);
        vDSP_fft_zrip(fs, &sc, 1, 8, kFFTDirection_Forward);
        im[0] = 0;
        vDSP_zvmags(&sc, 1, mag, 1, N / 2);
        float flux = 0;
        for (int b = 0; b < nb; b++) {
            float e = 0; vDSP_sve(mag + edges[b], 1, &e, edges[b + 1] - edges[b]);
            float l = logf(e + 1e-6f);
            if (f > 0 && l > prev[b]) flux += l - prev[b];
            prev[b] = l;
        }
        env[f] = flux;
    }
    vDSP_destroy_fftsetup(fs);
    ZNorm(env, frames);
    return out;
}

// cross-correlation c[L] = sum_n a[n] * b[n+L] for L in [-(na-1), nb-1]; returned array index k = L + (na-1).
// phat: GCC-PHAT weighting (unit magnitude cross-spectrum).
// phat: generalised cross-correlation with PHAT-beta weighting, only bins within [loFrac, hiFrac] of Nyquist count
static NSData *XCorrBand(const float *a, size_t na, const float *b, size_t nb, BOOL phat, double loFrac, double hiFrac) {
    size_t need = na + nb; int lg = 1; while (((size_t)1 << lg) < need) lg++;
    size_t N = (size_t)1 << lg, H = N / 2;
    FFTSetup fs = vDSP_create_fftsetup(lg, kFFTRadix2);
    float *A = calloc(N, sizeof(float)), *B = calloc(N, sizeof(float));
    memcpy(A, a, na * sizeof(float)); memcpy(B, b, nb * sizeof(float));
    float *ar = malloc(H * 4), *ai = malloc(H * 4), *br = malloc(H * 4), *bi = malloc(H * 4);
    DSPSplitComplex sa = { ar, ai }, sbx = { br, bi };
    vDSP_ctoz((const DSPComplex *)A, 2, &sa, 1, H); vDSP_ctoz((const DSPComplex *)B, 2, &sbx, 1, H);
    vDSP_fft_zrip(fs, &sa, 1, lg, kFFTDirection_Forward); vDSP_fft_zrip(fs, &sbx, 1, lg, kFFTDirection_Forward);
    // DC and Nyquist are packed in [0]
    float dc = ar[0] * br[0], ny = ai[0] * bi[0];
    size_t klo = (size_t)(loFrac * H), khi = (size_t)(hiFrac * H);
    for (size_t k = 1; k < H; k++) {
        float r = ar[k] * br[k] + ai[k] * bi[k], i = ar[k] * bi[k] - ai[k] * br[k];
        if (phat) {
            if (k < klo || k > khi) { r = 0; i = 0; }
            else { float m = powf(r * r + i * i, 0.5f * 0.85f) + 1e-12f; r /= m; i /= m; }   // PHAT-beta, beta 0.85
        }
        ar[k] = r; ai[k] = i;
    }
    if (phat) { dc = 0; ny = 0; }
    ar[0] = dc; ai[0] = ny;
    vDSP_fft_zrip(fs, &sa, 1, lg, kFFTDirection_Inverse);
    vDSP_ztoc(&sa, 1, (DSPComplex *)A, 2, H);
    size_t outN = na + nb - 1;
    NSMutableData *out = [NSMutableData dataWithLength:outN * sizeof(float)];
    float *c = out.mutableBytes;
    for (size_t k = 0; k < outN; k++) { long L = (long)k - (long)(na - 1); c[k] = A[L >= 0 ? L : (long)N + L]; }
    free(A); free(B); free(ar); free(ai); free(br); free(bi);
    vDSP_destroy_fftsetup(fs);
    return out;
}

static NSData *XCorr(const float *a, size_t na, const float *b, size_t nb, BOOL phat) { return XCorrBand(a, na, b, nb, phat, 0, 1); }
// best lag within [lo, hi] (lags), z-score of the peak over that window, z-score of the best other peak
// (more than `excl` lags away), sub-sample (parabolic) position
static double PeakLag2(NSData *cd, size_t na, long lo, long hi, long excl, double *zscore, double *zsecond) {
    const float *c = cd.bytes; long n = (long)(cd.length / sizeof(float));
    long k0 = MAX(0, lo + (long)na - 1), k1 = MIN(n - 1, hi + (long)na - 1);
    if (k1 <= k0) { if (zscore) *zscore = 0; return 0; }
    float mx = 0; vDSP_Length at = 0; vDSP_maxvi(c + k0, 1, &mx, &at, (vDSP_Length)(k1 - k0 + 1));
    float mean = 0, sd = 0; vDSP_normalize(c + k0, 1, NULL, 1, &mean, &sd, (vDSP_Length)(k1 - k0 + 1));
    if (zscore) *zscore = sd > 0 ? (mx - mean) / sd : 0;
    long k = k0 + (long)at;
    if (zsecond) {
        float m2 = -INFINITY;
        for (long j = k0; j <= k1; j++) if (labs(j - k) > excl && c[j] > m2) m2 = c[j];
        *zsecond = (sd > 0 && m2 > -INFINITY) ? (m2 - mean) / sd : 0;
    }
    double frac = 0;
    if (k > 0 && k < n - 1) { double y0 = c[k - 1], y1 = c[k], y2 = c[k + 1], den = y0 - 2 * y1 + y2; if (fabs(den) > 1e-12) frac = 0.5 * (y0 - y2) / den; if (fabs(frac) > 1) frac = 0; }
    return (double)(k - ((long)na - 1)) + frac;
}
static double PeakLag(NSData *cd, size_t na, long lo, long hi, double *zscore) { return PeakLag2(cd, na, lo, hi, 0, zscore, NULL); }
// Pearson correlation of a[n] and b[n+lag] over their overlap
static double Pearson(const float *a, size_t na, const float *b, size_t nb, long lag) {
    long s0 = MAX(0, -lag), s1 = MIN((long)na, (long)nb - lag);
    if (s1 - s0 < 50) return 0;
    double sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0; long n = s1 - s0;
    for (long i = s0; i < s1; i++) { double x = a[i], y = b[i + lag]; sa += x; sb += y; saa += x * x; sbb += y * y; sab += x * y; }
    double cov = sab - sa * sb / n, va = saa - sa * sa / n, vb = sbb - sb * sb / n;
    return (va > 0 && vb > 0) ? cov / sqrt(va * vb) : 0;
}

#pragma mark - model objects
@interface ASVideo : NSObject
@property (strong) id item; @property (copy) NSString *name; @property (strong) NSURL *url;
@property double inFile, dur; @property CMTime tlStart; @property long lane;
@property (strong) NSData *env; @property (copy) NSString *problem;
@end
@implementation ASVideo @end
@interface ASAudio : NSObject
@property (strong) id clip; @property (copy) NSString *name; @property (strong) NSURL *url;
@property CMTimeRange media; @property (strong) NSData *env; @property (copy) NSString *problem; @property BOOL fromTimeline; @property (strong) NSMutableArray *timelineItems;
@end
@implementation ASAudio @end
@interface ASMatch : NSObject
@property (strong) ASVideo *video; @property (strong) ASAudio *audio;
@property double offset, score, fineScore, nudge, ratio, otherRec, corr; @property BOOL include; @property (copy) NSString *note;
@end
@implementation ASMatch @end

#pragma mark - analysis
static void AnalyseAll(NSArray<ASVideo *> *videos, NSArray<ASAudio *> *audios, NSMutableArray<ASMatch *> *out, void (^progress)(NSString *)) {
    for (ASAudio *a in audios) {
        if (progress) progress([NSString stringWithFormat:@"Reading recording %@…", a.name]);
        NSString *err = nil;
        NSData *pcm = Decode(a.url, kDecRate, 0, 3 * 3600, &err);
        if (!pcm) { a.problem = err; ALog(@"audio %@: %@", a.name, err); continue; }
        a.env = Envelope(pcm);
        { float *e = (float *)a.env.bytes; size_t n = a.env.length / 4, edge = (size_t)(kEnvRate * 0.5); if (n > 4 * edge) { memset(e, 0, edge * 4); memset(e + n - edge, 0, edge * 4); } }
        ALog(@"audio %@: %.1f s analysed", a.name, pcm.length / 4.0 / kDecRate);
    }
    for (ASVideo *v in videos) {
        ASMatch *m = [ASMatch new]; m.video = v; [out addObject:m];
        if (progress) progress([NSString stringWithFormat:@"Analysing %@…", v.name]);
        NSString *err = nil;
        double len = MIN(v.dur, 600);
        NSData *pcm = v.url ? Decode(v.url, kDecRate, v.inFile, len, &err) : nil;
        if (!pcm || pcm.length / 4 < kDecRate * 1.0) { m.note = [NSString stringWithFormat:@"Camera audio can't be read (%@)", err ?: @"too short"]; continue; }
        v.env = Envelope(pcm);
        size_t nv = v.env.length / 4;
        {   // the clip's own start/end (sound cut on/off) is not part of the scene: don't let it drive the match
            float *e = (float *)v.env.bytes; size_t edge = (size_t)(kEnvRate * 0.5);
            if (nv > 4 * edge) { memset(e, 0, edge * 4); memset(e + nv - edge, 0, edge * 4); }
        }
        double best = 0, second = 0, bestLag = 0, bestSide = 0; ASAudio *bestA = nil;
        for (ASAudio *a in audios) {
            if (!a.env.length) continue;
            size_t na = a.env.length / 4;
            NSData *c = XCorr(v.env.bytes, nv, a.env.bytes, na, NO);
            long minOverlap = (long)MIN(nv, (size_t)(kEnvRate * 3)) ;   // at least 3 s (or the whole clip) must overlap
            long lo = -(long)nv + minOverlap, hi = (long)na - minOverlap;
            double z = 0, side = 0, lag = PeakLag2(c, nv, lo, hi, (long)(kEnvRate * 1.0), &z, &side);
            ALog(@"  %@ vs %@: z=%.1f side=%.1f lag=%.3f s", v.name, a.name, z, side, lag / kEnvRate);
            if (z > best) { second = best; best = z; bestLag = lag; bestA = a; bestSide = side; } else if (z > second) second = z;
        }
        if (!bestA) { m.note = @"No readable recordings"; continue; }
        m.audio = bestA; m.score = best;
        m.corr = Pearson(v.env.bytes, nv, bestA.env.bytes, bestA.env.length / 4, lround(bestLag));
        double d0 = bestLag / kEnvRate - v.inFile;            // audio_file_time = video_file_time + d0
        // fine: GCC-PHAT on 16 kHz around the coarse offset
        double flen = MIN(45.0, v.dur), fst = v.inFile + MAX(0, (v.dur - flen) / 2), pad = 0.15;
        NSData *fv = Decode(v.url, kFineRate, fst, flen, NULL);
        double ast = fst + d0 - pad;
        NSData *fa = Decode(bestA.url, kFineRate, MAX(0, ast), flen + 2 * pad, NULL);
        double off = d0;
        if (fv.length > 4000 && fa.length > 4000) {
            double lead = ast < 0 ? -ast : 0;                 // decode was clamped at 0
            size_t a1 = fv.length / 4, b1 = fa.length / 4;
            float *va = malloc(a1 * 4), *aa = malloc(b1 * 4);
            memcpy(va, fv.bytes, a1 * 4); memcpy(aa, fa.bytes, b1 * 4);
            NSData *c = XCorrBand(va, a1, aa, b1, YES, 150.0 / (kFineRate / 2), 4000.0 / (kFineRate / 2));
            long expect = (long)llround((pad - lead) * kFineRate), w = (long)(0.1 * kFineRate);
            double fz = 0, lag = PeakLag(c, a1, expect - w, expect + w, &fz);
            free(va); free(aa);
            m.fineScore = fz;
            double fineOff = (MAX(0, ast) - fst) + lag / kFineRate;
            // coarse is good to a few ms; the fine stage refines it when it clearly agrees
            if (fz >= 4.5 && fabs(fineOff - d0) < 0.02) off = fineOff;
            ALog(@"  fine %@: coarse %.4f -> %.5f s (phat z=%.1f)", v.name, d0, off, fz);
        }
        m.offset = off;
        // a real match is a single sharp peak: clearly above the rest of this correlation (repetitive music
        // gives many similar peaks) and clearly better than any other recording; the fine stage must agree
        m.ratio = bestSide > 0 ? best / bestSide : 99; m.otherRec = second;
        BOOL unique = m.ratio >= 1.35 && (second < 6 || best >= 1.3 * second);
        BOOL clear = best >= 8 && unique && m.corr >= 0.25 && (m.fineScore >= 5 || (best >= 15 && m.corr >= 0.7));
        m.include = clear;
        if (clear) m.note = @"Matched";
        else if (best >= 8 && unique && m.corr >= 0.3) m.note = @"Probably matched - please check";
        else if (best >= 7 && m.ratio >= 1.2 && m.corr >= 0.2) m.note = @"Low confidence - please check";
        else { m.note = @"No match found"; m.audio = nil; }
        ALog(@"%@ -> %@ offset %.5f s score %.1f side-ratio %.2f other-rec %.1f fine %.1f r %.2f: %@", v.name, bestA.name, off, best, m.ratio, second, m.fineScore, m.corr, m.note);
    }
}

#pragma mark - Final Cut side
static NSArray *AllBrowserClips(void) {
    NSMutableArray *all = [NSMutableArray array];
    id libs = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
    for (id lib in libs) for (id ev in (NSArray *)O(lib, @"events")) {
        id clips = O(ev, @"ownedClips") ?: O(O(ev, @"project"), @"ownedClips") ?: O(ev, @"displayOwnedClips");
        for (id c in clips) [all addObject:c];
    }
    return all;
}
static BOOL IsAudioOnly(id x);
static id BrowserClipForURL(NSURL *u) {
    for (id c in AllBrowserClips()) if ([ItemURL(c).path isEqualToString:u.path] && IsAudioOnly(c)) return c;
    for (id c in AllBrowserClips()) if ([ItemURL(c).path isEqualToString:u.path]) return c;
    return nil;
}
static NSArray *BrowserSelection(void) {
    id app = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("PEAppController"), NSSelectorFromString(@"appController"));
    id org = O(O(app, @"mediaEventOrganizerContainer"), @"activeOrganizerModule");
    id fs = O(org, @"filmstripModule");
    NSMutableArray *out = [NSMutableArray array];
    for (id x in (NSArray *)(O(fs, @"selectedItems") ?: @[])) {
        id obj = [x respondsToSelector:NSSelectorFromString(@"object")] ? O(x, @"object") : x;
        if (obj && ![out containsObject:obj]) [out addObject:obj];
    }
    return out;
}
static BOOL IsAudioOnly(id x) {
    if (OB(x, @"isAudioOnly")) return YES;
    id prim = O(x, @"primaryObject");          // browser clip
    if (prim && prim != x) { BOOL v = NO, a = NO; for (id it in (NSArray *)O(prim, @"containedItems")) { v |= OB(it, @"hasVideo"); a |= OB(it, @"hasAudio") || OB(it, @"isAudioOnly"); } return a && !v; }
    return !OB(x, @"hasVideo") && OB(x, @"hasAudio");
}

static BOOL Gather(NSMutableArray<ASVideo *> *videos, NSMutableArray<ASAudio *> *audios, NSString **why) {
    id tm = ActiveTM(); id seq = O(tm, @"sequence"); id prim = O(seq, @"primaryObject");
    if (!prim) { *why = @"Open a project first."; return NO; }
    NSArray *sel = ((id(*)(id, SEL, BOOL, BOOL))objc_msgSend)(tm, NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:"), NO, NO);
    NSMutableSet *seenAudio = [NSMutableSet set];
    NSString *(^akey)(id, NSURL *) = ^NSString *(id clip, NSURL *u) { return [NSString stringWithFormat:@"%@|%.2f", u.lastPathComponent.lowercaseString, Sec(OR(clip, @"mediaRange").duration)]; };
    for (id it in sel) {
        NSURL *u = ItemURL(it);
        if (!u) continue;
        if (IsAudioOnly(it)) {   // an external recording already in the timeline
            id clip = BrowserClipForURL(u);
            if (!clip) { ALog(@"no browser clip for %@", u.path); continue; }
            if ([seenAudio containsObject:u.path] || [seenAudio containsObject:akey(clip, u)]) {
                for (ASAudio *x in audios) if ([x.url.path isEqualToString:u.path] && x.fromTimeline) [x.timelineItems addObject:it];
                continue;
            }
            ASAudio *a = [ASAudio new]; a.clip = clip; a.url = u; a.name = O(clip, @"displayName") ?: u.lastPathComponent;
            a.media = OR(clip, @"mediaRange"); a.fromTimeline = YES; a.timelineItems = [NSMutableArray arrayWithObject:it]; [audios addObject:a]; [seenAudio addObject:u.path]; [seenAudio addObject:akey(clip, u)];
            continue;
        }
        if (!OB(it, @"hasVideo")) continue;
        ASVideo *v = [ASVideo new]; v.item = it; v.url = u; v.name = O(it, @"displayName") ?: u.lastPathComponent;
        CMTimeRange cr = OR(it, @"clippedRange"), mr = OR(it, @"mediaRange");
        v.inFile = Sec(cr.start) - Sec(mr.start); v.dur = Sec(cr.duration);
        {   // a clip whose frame rate Final Cut conforms keeps its times in project-rate units: bring them back to file time
            double fileLen = 0;
            for (id c in AllBrowserClips()) if (!IsAudioOnly(c) && [ItemURL(c).path isEqualToString:u.path]) { fileLen = Sec(OR(c, @"mediaRange").duration); break; }
            double sc = (fileLen > 0 && Sec(mr.duration) > 0) ? fileLen / Sec(mr.duration) : 1;
            if (fabs(sc - 1) >= 0.0005) { v.inFile *= sc; v.dur *= sc; }
        }
        CMTimeRange tr = RangeIn(it, prim); v.tlStart = tr.start; v.lane = Lane(it);
        [videos addObject:v];
    }
    NSArray *browserSources = BrowserSelection();
    if (gTestSources.count) { NSMutableArray *t = [NSMutableArray array]; for (id c in AllBrowserClips()) if ([gTestSources containsObject:O(c, @"displayName") ?: @""]) [t addObject:c]; browserSources = t; }
    for (id c in browserSources) {
        NSURL *u = ItemURL(c);
        if (!u || [seenAudio containsObject:u.path] || [seenAudio containsObject:akey(c, u)] || !IsAudioOnly(c)) continue;
        ASAudio *a = [ASAudio new]; a.clip = c; a.url = u; a.name = O(c, @"displayName") ?: u.lastPathComponent;
        a.media = OR(c, @"mediaRange"); [audios addObject:a]; [seenAudio addObject:u.path]; [seenAudio addObject:akey(c, u)];
    }
    if (!videos.count) { *why = @"Nothing to sync: select the video clips and their audio recordings in the timeline first (drag a box around them, or ⌘-click each one), then choose Batch Sync Audio again."; return NO; }
    if (!audios.count) { *why = @"Only video clips are selected. Also select the external audio clips (⌘-click them in the timeline, or select the recordings in the browser), then choose Batch Sync Audio again."; return NO; }
    return YES;
}

@interface NSObject (ASFF)
- (id)initWithName:(id)n; - (BOOL)writeRangesOfMedia:(id)r options:(id)o; + (id)rangeAndObjectWithRange:(CMTimeRange)r andObject:(id)o;
- (void)setPlayheadTime:(CMTime)t; - (void)pasteAnchored:(id)s; - (void)setSelectedItems:(id)i;
@end

static NSArray *SavePasteboard(void) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSPasteboardItem *it in [NSPasteboard generalPasteboard].pasteboardItems) {
        NSPasteboardItem *c = [NSPasteboardItem new];
        for (NSString *t in it.types) { NSData *d = [it dataForType:t]; if (d) [c setData:d forType:t]; }
        [items addObject:c];
    }
    return items;
}
static void RestorePasteboard(NSArray *items) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard]; [pb clearContents];
    if (items.count) [pb writeObjects:items];
}
static NSSet *AnchoredSet(id prim) {
    NSMutableSet *s = [NSMutableSet set];
    for (id item in (NSArray *)O(prim, @"containedItems")) for (id x in (NSSet *)O(item, @"anchoredItems")) [s addObject:[NSValue valueWithNonretainedObject:x]];
    return s;
}

// connect the matching part of each recording under its video clip; returns a report line
__attribute__((unused)) static NSString *ApplyMatches(NSArray<ASMatch *> *matches, BOOL removeOriginals) {
    id tm = ActiveTM(); id seq = O(tm, @"sequence"); id prim = O(seq, @"primaryObject");
    CMTime fd = OT(seq, @"frameDuration"); if (!CMTIME_IS_VALID(fd) || fd.value <= 0) fd = CMTimeMake(1, 25);
    double fds = Sec(fd);
    CMTime playhead = OT(tm, @"playheadTime");
    NSArray *savedPB = SavePasteboard();
    NSUndoManager *um = O(tm, @"undoManager");
    [um beginUndoGrouping];
    int ok = 0, failed = 0, removed = 0; double worst = 0;
    NSMutableSet *used = [NSMutableSet set];
    @try {
        [tm setSelectedItems:@[]];
        for (ASMatch *m in matches) {
            if (!m.include || !m.audio) continue;
            ASVideo *v = m.video; ASAudio *a = m.audio;
            double d = m.offset + m.nudge;
            double aStart = v.inFile + d, dur = v.dur, shift = 0, aLen = Sec(a.media.duration);
            if (aStart < 0) { shift = ceil(-aStart / fds - 1e-9) * fds; aStart += shift; dur -= shift; }
            if (aStart + dur > aLen) dur = aLen - aStart;
            if (dur < 0.2) { m.note = @"Recording doesn't cover this clip"; failed++; continue; }
            CMTime st = CMTimeAdd(a.media.start, CMTimeMakeWithSeconds(aStart, 192000));
            CMTimeRange r = CMTimeRangeMake(st, CMTimeMakeWithSeconds(dur, 192000));
            CMTime at = CMTimeAdd(v.tlStart, CMTimeMultiply(fd, (int32_t)llround(shift / fds)));
            NSSet *before = AnchoredSet(prim);
            [[NSPasteboard generalPasteboard] clearContents];
            id pb = [[objc_getClass("FFPasteboard") alloc] initWithName:NSPasteboardNameGeneral];
            id mr = [objc_getClass("FigTimeRangeAndObject") rangeAndObjectWithRange:r andObject:a.clip];
            if (!pb || !mr || ![pb writeRangesOfMedia:@[mr] options:nil]) { m.note = @"Couldn't place the recording"; failed++; continue; }
            [tm setPlayheadTime:at];
            [tm pasteAnchored:nil];
            id added = nil;
            for (id item in (NSArray *)O(prim, @"containedItems")) for (id x in (NSSet *)O(item, @"anchoredItems"))
                if (![before containsObject:[NSValue valueWithNonretainedObject:x]] && IsAudioOnly(x)) added = x;
            if (!added) { m.note = @"Paste didn't happen"; failed++; continue; }
            // verify: where does the placed audio really sit against the video?
            CMTimeRange cr = OR(added, @"clippedRange"), amr = OR(added, @"mediaRange");
            double placedIn = Sec(cr.start) - Sec(amr.start), placedAt = Sec(RangeIn(added, prim).start);
            double videoAtThatPoint = v.inFile + (placedAt - Sec(v.tlStart));
            double err = (placedIn - videoAtThatPoint) - d;
            worst = MAX(worst, fabs(err));
            m.note = fabs(err) < 0.0005 ? @"Synced" : [NSString stringWithFormat:@"Synced (%.1f ms off)", err * 1000];
            [used addObject:a];
            ALog(@"placed %@ under %@: audio in %.5f at %.5f, error %.3f ms", a.name, v.name, placedIn, placedAt, err * 1000);
            ok++;
        }
        // the loose recordings that were selected in the timeline have now been placed under each clip:
        // take the originals out (connected clips only - removing a clip from the main storyline would ripple)
        if (removeOriginals && ok) {
            NSMutableArray *gone = [NSMutableArray array];
            for (ASAudio *a in used) for (id it in a.timelineItems) if (Lane(it) != 0) [gone addObject:it];
            if (gone.count) {
                [tm setSelectedItems:gone];
                ((void(*)(id, SEL, id))objc_msgSend)(tm, @selector(delete:), nil);
                [tm setSelectedItems:@[]];
                removed = (int)gone.count;
                ALog(@"removed %d original recording clip(s) from the timeline", removed);
            }
        }
    } @finally {
        @try { [um setActionName:@"Batch Sync Audio"]; } @catch (id e) {}
        [um endUndoGrouping];
        [tm setPlayheadTime:playhead];
        RestorePasteboard(savedPB);
    }
    ALog(@"apply: %d synced, %d failed, worst placement error %.3f ms", ok, failed, worst * 1000);
    return [NSString stringWithFormat:@"%d clip%@ synced%@%@. Undo with ⌘Z.", ok, ok == 1 ? @"" : @"s",
            removed ? [NSString stringWithFormat:@", %d original audio clip%@ removed", removed, removed == 1 ? @"" : @"s"] : @"",
            failed ? [NSString stringWithFormat:@", %d couldn't be placed", failed] : @""];
}

#pragma mark - native Synchronized Clips (FCPXML)
// Final Cut's own container for "this video + that external audio" is the Synchronized Clip (FCPXML
// <sync-clip>). We describe one per video clip - the camera clip on the storyline, the recording connected
// to it at the measured offset (sample accurate), and the camera audio switched off as a sync source
// (exactly what Synchronize Clips does with "Disable audio components on AV clips") - and let Final Cut's
// own FCPXML importer build them.
static NSString *T(CMTime t) {   // FCPXML rational time
    if (!CMTIME_IS_VALID(t) || t.value == 0) return @"0s";
    return [NSString stringWithFormat:@"%lld/%ds", t.value, t.timescale];
}
static NSString *TS(double s) { return T(CMTimeMake(llround(s * 48000.0), 48000)); }
static NSString *X(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    s = [s stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return [s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
}
static id BrowserAVClipForURL(NSURL *u) {
    for (id c in AllBrowserClips()) if ([ItemURL(c).path isEqualToString:u.path] && !IsAudioOnly(c)) return c;
    return nil;
}
static CGSize VideoSize(NSURL *u) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack *t = [[AVURLAsset URLAssetWithURL:u options:nil] tracksWithMediaType:AVMediaTypeVideo].firstObject;
#pragma clang diagnostic pop
    CGSize s = t ? CGSizeApplyAffineTransform(t.naturalSize, t.preferredTransform) : CGSizeMake(1920, 1080);
    return CGSizeMake(fabs(s.width), fabs(s.height));
}
// one <audio-channel-source> per audio track of the camera file (Final Cut's default layout), switched off:
// the camera audio stays inside the synchronized clip (tick it back on in Audio Configuration) but doesn't play
static int gXMode;
static NSString *CameraAudioOff(NSURL *u, NSString *ind) {
    if (gXMode == 1) return @"";
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray *tracks = [[AVURLAsset URLAssetWithURL:u options:nil] tracksWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop
    NSMutableString *out = [NSMutableString string]; int ch = 1;
    for (AVAssetTrack *t in tracks) {
        int n = 1;
        for (id fd in t.formatDescriptions) { const AudioStreamBasicDescription *d = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)fd); if (d && d->mChannelsPerFrame > 0) n = (int)d->mChannelsPerFrame; }
        NSMutableArray *list = [NSMutableArray array]; for (int i = 0; i < n; i++) [list addObject:@(ch + i)];
        [out appendFormat:@"%@<audio-channel-source srcCh=\"%@\" role=\"dialogue\" %@/>\n", ind, [list componentsJoinedByString:@", "], gXMode == 2 ? @"enabled=\"0\"" : gXMode == 3 ? @"enabled=\"0\" active=\"0\"" : @"active=\"0\""];
        ch += n;
    }
    return out;
}
// one entry: @{ @"name", @"video" (browser clip), @"audio" (browser clip), @"offset" (NSNumber: audio file time = video file time + offset) }
static NSString *SyncClipsXML(NSArray<NSDictionary *> *entries, NSString *eventName, double *fdOut) {
    NSMutableString *res = [NSMutableString string], *clips = [NSMutableString string];
    NSMutableDictionary *assetIDs = [NSMutableDictionary dictionary], *formatIDs = [NSMutableDictionary dictionary];
    __block int nextID = 1;
    NSString *(^formatFor)(id, NSURL *) = ^NSString *(id clip, NSURL *u) {
        CMTime fd = OT(clip, @"frameDuration"); CGSize sz = VideoSize(u);
        NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f", T(fd), sz.width, sz.height];
        if (formatIDs[key]) return formatIDs[key];
        NSString *fid = [NSString stringWithFormat:@"r%d", nextID++]; formatIDs[key] = fid;
        [res appendFormat:@"    <format id=\"%@\" frameDuration=\"%@\" width=\"%.0f\" height=\"%.0f\"/>\n", fid, T(fd), sz.width, sz.height];
        return fid;
    };
    NSString *(^assetFor)(id, BOOL) = ^NSString *(id clip, BOOL video) {
        NSURL *u = ItemURL(clip);
        if (assetIDs[u.path]) return assetIDs[u.path];
        NSString *fmt = video ? formatFor(clip, u) : nil;
        NSString *aid = [NSString stringWithFormat:@"r%d", nextID++]; assetIDs[u.path] = aid;
        CMTimeRange mr = OR(clip, @"mediaRange");
        [res appendFormat:@"    <asset id=\"%@\" name=\"%@\" start=\"%@\" duration=\"%@\" hasVideo=\"%d\" hasAudio=\"1\"%@ audioSources=\"1\">\n      <media-rep kind=\"original-media\" src=\"%@\"/>\n    </asset>\n",
            aid, X(O(clip, @"displayName") ?: u.lastPathComponent), T(mr.start), T(mr.duration), video ? 1 : 0, fmt ? [NSString stringWithFormat:@" format=\"%@\"", fmt] : @"", X(u.absoluteString)];
        return aid;
    };
    for (NSDictionary *e in entries) {
        id v = e[@"video"], a = e[@"audio"]; double d = [e[@"offset"] doubleValue];
        NSString *vid = assetFor(v, YES), *aid = assetFor(a, NO);
        NSString *fmt = formatFor(v, ItemURL(v));
        CMTimeRange vr = OR(v, @"mediaRange"), ar = OR(a, @"mediaRange");
        CMTime fd = OT(v, @"frameDuration"); double fds = Sec(fd) > 0 ? Sec(fd) : 0.04; if (fdOut) *fdOut = fds;
        double vlen = Sec(vr.duration), alen = Sec(ar.duration);
        double v0 = d < 0 ? ceil(-d / fds - 1e-9) * fds : 0;               // video time where the recording starts
        double aIn = v0 + d, len = MIN(vlen - v0, alen - aIn);
        if (len < 0.2) continue;
        CMTime connectAt = CMTimeAdd(vr.start, CMTimeMultiply(fd, (int32_t)llround(v0 / fds)));
        [clips appendFormat:@"      <sync-clip name=\"%@\" start=\"%@\" duration=\"%@\" format=\"%@\" tcFormat=\"NDF\">\n"
            "        <asset-clip ref=\"%@\" name=\"%@\" offset=\"%@\" start=\"%@\" duration=\"%@\" format=\"%@\" tcFormat=\"NDF\">\n"
            "          <asset-clip ref=\"%@\" name=\"%@\" lane=\"-1\" offset=\"%@\" start=\"%@\" duration=\"%@\"/>\n"
            "%@"
            "        </asset-clip>\n"
            "%@"
            "      </sync-clip>\n",
            X(e[@"name"]), T(vr.start), T(vr.duration), fmt,
            vid, X(O(v, @"displayName") ?: @"video"), T(vr.start), T(vr.start), T(vr.duration), fmt,
            aid, X(O(a, @"displayName") ?: @"audio"), T(connectAt), [TS(Sec(ar.start) + aIn) copy], TS(len), CameraAudioOff(ItemURL(v), @"          "), gXMode == 1 ? @"        <sync-source sourceID=\"storyline\">\n          <audio-role-source role=\"dialogue.dialogue-1\" active=\"0\"/>\n        </sync-source>\n" : @""];
    }
    return [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n<fcpxml version=\"1.14\">\n  <resources>\n%@  </resources>\n  <event name=\"%@\">\n%@  </event>\n</fcpxml>\n", res, X(eventName), clips];
}
@interface NSObject (ASXML)
- (id)initForPasteboard:(id)pb; - (id)importWithOptions:(id)o; - (BOOL)importClipsWithOptions:(id)o; - (void)setIncrementalImport:(BOOL)b;
- (void)setConflictResolutionType:(long long)t; - (void)setLibrary:(id)l; - (void)setLibraryURL:(id)u; - (id)error;
@end
// import through Final Cut's own FCPXML translator (the paste path - no dialogs), into the given library
static BOOL ImportXML(NSString *xml, id library, NSString **err) {
    NSArray *saved = SavePasteboard();
    BOOL ok = NO;
    @try {
        NSPasteboard *pb = [NSPasteboard generalPasteboard]; [pb clearContents];
        Class ix = objc_getClass("IXXMLPasteboardType"); NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
        NSString *g = ((id(*)(id, SEL))objc_msgSend)(ix, NSSelectorFromString(@"generic")), *cur = ((id(*)(id, SEL))objc_msgSend)(ix, NSSelectorFromString(@"current"));
        if (g) [pb setData:data forType:g];
        if (cur) [pb setData:data forType:cur];
        id task = [[objc_getClass("FFXMLTranslationTask") alloc] initForPasteboard:pb];
        if (!task) { if (err) *err = @"Final Cut's XML importer is not available"; return NO; }
        id perr = [task error];
        if (perr) { if (err) *err = [NSString stringWithFormat:@"XML error: %@", [perr localizedDescription]]; return NO; }
        id opt = [objc_getClass("FFXMLImportOptions") new];
        [opt setIncrementalImport:YES]; [opt setConflictResolutionType:3];
        if (library) { [opt setLibrary:library]; id u = O(library, @"url"); if (u) [opt setLibraryURL:u]; }
        if ([task respondsToSelector:@selector(importWithOptions:)]) ok = [task importWithOptions:opt] != nil;
        if (!ok && [task respondsToSelector:@selector(importClipsWithOptions:)]) ok = [task importClipsWithOptions:opt];
        if (!ok && err) *err = @"Final Cut refused the import";
    } @catch (id e) { if (err) *err = [NSString stringWithFormat:@"%@", e]; ok = NO; }
    @finally { RestorePasteboard(saved); }
    return ok;
}

#pragma mark - replace the timeline clips with synchronized clips
static NSArray *AllTimelineItems(id prim) {
    NSMutableArray *all = [NSMutableArray array];
    for (id it in (NSArray *)O(prim, @"containedItems")) {
        [all addObject:it];
        for (id x in (NSSet *)O(it, @"anchoredItems")) {
            [all addObject:x];
            for (id y in (NSArray *)O(x, @"containedItems")) [all addObject:y];   // clips inside connected storylines
        }
    }
    return all;
}
static id BrowserAVClipInLibrary(NSURL *u, id lib) {
    id any = nil;
    for (id c in AllBrowserClips()) {
        if (IsAudioOnly(c) || ![ItemURL(c).path isEqualToString:u.path]) continue;
        if ([O(c, @"displayName") hasSuffix:@")"] && [O(c, @"displayName") rangeOfString:@"(synced"].location != NSNotFound) continue;
        if (O(c, @"library") == lib) return c;
        if (!any) any = c;
    }
    return any;
}
static NSString *ApplySyncClips(NSArray<ASMatch *> *matches, BOOL removeOriginals) {
    id tm = ActiveTM(); id seq = O(tm, @"sequence"); id prim = O(seq, @"primaryObject"); id lib = O(seq, @"library");
    CMTime fd = OT(seq, @"frameDuration"); if (!CMTIME_IS_VALID(fd) || fd.value <= 0) fd = CMTimeMake(1, 25);
    // 1. one synchronized clip per camera file + recording + offset
    NSMutableSet *names = [NSMutableSet set], *before = [NSMutableSet set];
    for (id c in AllBrowserClips()) if (O(c, @"library") == lib) { [names addObject:O(c, @"displayName") ?: @""]; [before addObject:[NSValue valueWithNonretainedObject:c]]; }
    NSMutableDictionary *byKey = [NSMutableDictionary dictionary]; NSMutableArray *entries = [NSMutableArray array];
    NSMutableArray *todo = [NSMutableArray array]; NSMutableArray *todoName = [NSMutableArray array], *todoBV = [NSMutableArray array];
    int failed = 0, skipped = 0;
    for (ASMatch *m in matches) {
        if (!m.include || !m.audio) continue;
        ASVideo *v = m.video;
        if (OB(v.item, @"hasArtisticRetime")) { m.note = @"Has a speed change - left as it was"; skipped++; continue; }
        id bv = BrowserAVClipInLibrary(v.url, lib);
        if (!bv) { m.note = @"Camera clip not found in the browser"; failed++; continue; }
        double d = m.offset + m.nudge;
        // pieces of the same camera file that line up within 2 ms share one synchronized clip
        NSString *key = nil, *name = nil;
        for (NSString *k in byKey) { NSArray *kp = [k componentsSeparatedByString:@"\t"]; if ([kp[0] isEqual:v.url.path] && [kp[1] isEqual:m.audio.url.path] && fabs([kp[2] doubleValue] - d) < 0.002) { key = k; name = byKey[k]; } }
        if (!name) {
            key = [NSString stringWithFormat:@"%@\t%@\t%.6f", v.url.path, m.audio.url.path, d];
            NSString *base = [NSString stringWithFormat:@"%@ (synced)", O(bv, @"displayName") ?: v.url.URLByDeletingPathExtension.lastPathComponent];
            name = base; for (int i = 2; [names containsObject:name]; i++) name = [NSString stringWithFormat:@"%@ (synced %d)", O(bv, @"displayName"), i];
            [names addObject:name]; byKey[key] = name;
            [entries addObject:@{ @"name": name, @"video": bv, @"audio": m.audio.clip, @"offset": @(d) }];
        }
        [todo addObject:m]; [todoName addObject:name]; [todoBV addObject:bv];
    }
    if (!todo.count) return [NSString stringWithFormat:@"Nothing synced%@.", failed + skipped ? @" (see Status)" : @""];
    // 2. let Final Cut build them (FCPXML import into the project's library, event "Batch Synced Clips")
    NSString *xml = SyncClipsXML(entries, @"Batch Synced Clips", NULL);
    [xml writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/last_sync.fcpxml"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *err = nil;
    NSUndoManager *um = O(tm, @"undoManager");
    [um beginUndoGrouping];   // the import and every replace undo together with one ⌘Z
    BOOL imported = NO;
    @try { imported = ImportXML(xml, lib, &err); } @catch (id e) { err = [e description]; }
    if (!imported) { @try { [um setActionName:@"Batch Sync Audio"]; } @catch (id e) {} [um endUndoGrouping]; }
    if (!imported) { ALog(@"sync clip import failed: %@", err); for (ASMatch *m in todo) m.note = @"Couldn't create the synchronized clip"; return [NSString stringWithFormat:@"Nothing changed - Final Cut couldn't create the synchronized clips (%@).", err]; }
    NSMutableDictionary *made = [NSMutableDictionary dictionary];
    for (id c in AllBrowserClips())
        if (O(c, @"library") == lib && ![before containsObject:[NSValue valueWithNonretainedObject:c]] && O(c, @"displayName")) made[O(c, @"displayName")] = c;
    ALog(@"imported %lu synchronized clip(s): %@", (unsigned long)made.count, [made.allKeys componentsJoinedByString:@", "]);
    // 3. swap each timeline clip for its synchronized clip - same place, same in/out, attributes pasted back - one undo
    CMTime playhead = OT(tm, @"playheadTime");
    NSArray *savedPB = SavePasteboard();
    int ok = 0, removed = 0; NSMutableSet *used = [NSMutableSet set];
    @try {
        for (NSUInteger i = 0; i < todo.count; i++) {
            ASMatch *m = todo[i]; id item = m.video.item, sc = made[todoName[i]], bv = todoBV[i];
            if (!sc) { m.note = @"Synchronized clip wasn't created"; failed++; continue; }
            if (![AllTimelineItems(prim) containsObject:item]) { m.note = @"Clip is no longer in the timeline"; failed++; continue; }
            CMTimeRange cr = OR(item, @"clippedRange"), mr = OR(item, @"mediaRange"), sr = OR(sc, @"mediaRange"), br = OR(bv, @"mediaRange");
            CMTimeRange tl = RangeIn(item, prim); long lane = Lane(item);
            // the clip's own time runs at the project rate when Final Cut conforms the frame rate - map it to file time
            double scale = Sec(mr.duration) > 0 ? Sec(br.duration) / Sec(mr.duration) : 1;
            CMTimeRange r;
            if (fabs(scale - 1) < 0.0005) r = CMTimeRangeMake(CMTimeAdd(sr.start, CMTimeSubtract(cr.start, mr.start)), cr.duration);
            else r = CMTimeRangeMake(CMTimeAdd(sr.start, CMTimeMakeWithSeconds(Sec(CMTimeSubtract(cr.start, mr.start)) * scale, 240000)), CMTimeMakeWithSeconds(Sec(cr.duration) * scale, 240000));
            if (CMTimeCompare(CMTimeRangeGetEnd(r), CMTimeRangeGetEnd(sr)) > 0) r.duration = CMTimeSubtract(CMTimeRangeGetEnd(sr), r.start);
            // keep the clip's attributes (effects, colour, transform, volume…)
            [tm setSelectedItems:@[item]];
            ((void(*)(id, SEL, id))objc_msgSend)(tm, NSSelectorFromString(@"copyAttributes:"), nil);
            NSArray *attrs = SavePasteboard();
            [[NSPasteboard generalPasteboard] clearContents];
            id pb = [[objc_getClass("FFPasteboard") alloc] initWithName:NSPasteboardNameGeneral];
            id mro = [objc_getClass("FigTimeRangeAndObject") rangeAndObjectWithRange:r andObject:sc];
            if (!pb || !mro || ![pb writeRangesOfMedia:@[mro] options:nil]) { m.note = @"Couldn't prepare the replace"; failed++; continue; }
            ((void(*)(id, SEL, id, int))objc_msgSend)(tm, NSSelectorFromString(@"replaceWithPasteboard:replaceActionType:"), NSPasteboardNameGeneral, 0);
            id added = nil;
            for (id x in AllTimelineItems(prim))
                if (x != item && Lane(x) == lane && [O(x, @"displayName") isEqualToString:todoName[i]] && fabs(Sec(RangeIn(x, prim).start) - Sec(tl.start)) < 0.001) added = x;
            if (!added) { m.note = @"Replace didn't happen"; failed++; ALog(@"replace of %@ didn't happen", m.video.name); continue; }
            RestorePasteboard(attrs);
            [tm setSelectedItems:@[added]];
            ((void(*)(id, SEL, id))objc_msgSend)(tm, NSSelectorFromString(@"pasteAllAttributes:"), nil);
            for (id x in AllTimelineItems(prim)) if (Lane(x) == lane && [O(x, @"displayName") isEqualToString:todoName[i]] && fabs(Sec(RangeIn(x, prim).start) - Sec(tl.start)) < 0.001) added = x;
            CMTimeRange nt = RangeIn(added, prim);
            double dErr = Sec(nt.duration) - Sec(tl.duration);
            m.note = fabs(dErr) < Sec(fd) / 2 ? @"Synced" : [NSString stringWithFormat:@"Synced, length changed by %.2f s", dErr];
            [used addObject:m.audio];
            ALog(@"replaced %@ with %@ at %.4f lane %ld: range %.5f+%.5f, length %.5f -> %.5f", m.video.name, todoName[i], Sec(tl.start), lane, Sec(r.start), Sec(r.duration), Sec(tl.duration), Sec(nt.duration));
            ok++;
        }
        if (removeOriginals && ok) {
            NSMutableArray *gone = [NSMutableArray array];
            for (ASAudio *a in used) for (id it in a.timelineItems) if (Lane(it) != 0 && [AllTimelineItems(prim) containsObject:it]) [gone addObject:it];
            if (gone.count) {
                [tm setSelectedItems:gone];
                ((void(*)(id, SEL, id))objc_msgSend)(tm, @selector(delete:), nil);
                removed = (int)gone.count;
                ALog(@"removed %d loose recording clip(s) from the timeline", removed);
            }
        }
    } @finally {
        [tm setSelectedItems:@[]];
        @try { [um setActionName:@"Batch Sync Audio"]; } @catch (id e) {}
        [um endUndoGrouping];
        [tm setPlayheadTime:playhead];
        RestorePasteboard(savedPB);
    }
    ALog(@"sync clips: %d replaced, %d failed, %d skipped", ok, failed, skipped);
    return [NSString stringWithFormat:@"%d clip%@ now play the synced audio%@%@%@. Undo with ⌘Z.", ok, ok == 1 ? @"" : @"s",
            removed ? [NSString stringWithFormat:@", %d loose recording%@ removed", removed, removed == 1 ? @"" : @"s"] : @"",
            failed ? [NSString stringWithFormat:@", %d failed", failed] : @"", skipped ? [NSString stringWithFormat:@", %d skipped", skipped] : @""];
}

#pragma mark - review panel
@interface ASPanel : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (strong) NSPanel *panel; @property (strong) NSTableView *table; @property (strong) NSTextField *status;
@property (strong) NSButton *syncButton; @property (strong) NSButton *removeBox; @property (strong) NSMutableArray<ASMatch *> *matches; @property double frame;
@end
static ASPanel *gPanel;
@implementation ASPanel
- (NSTableColumn *)col:(NSString *)ident title:(NSString *)t width:(CGFloat)w {
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:ident]; c.title = t; c.width = w; [self.table addTableColumn:c]; return c;
}
- (void)build {
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 760, 410) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskUtilityWindow backing:NSBackingStoreBuffered defer:NO];
    p.title = @"Batch Sync Audio"; p.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; p.delegate = self; p.releasedWhenClosed = NO;
    p.floatingPanel = YES; p.hidesOnDeactivate = YES;
    NSView *cv = p.contentView;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 84, 736, 290)];
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; sv.hasVerticalScroller = YES; sv.borderType = NSBezelBorder;
    self.table = [[NSTableView alloc] initWithFrame:sv.bounds];
    self.table.usesAlternatingRowBackgroundColors = YES; self.table.allowsMultipleSelection = YES;
    NSTableColumn *c0 = [self col:@"use" title:@"" width:24]; NSButtonCell *bc = [NSButtonCell new]; bc.buttonType = NSButtonTypeSwitch; bc.title = @""; c0.dataCell = bc;
    [self col:@"video" title:@"Video clip" width:160]; [self col:@"audio" title:@"Recording" width:160];
    [self col:@"offset" title:@"Offset" width:90]; [self col:@"conf" title:@"Confidence" width:80]; [self col:@"note" title:@"Status" width:200];
    self.table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    self.table.dataSource = self; self.table.delegate = self; sv.documentView = self.table; [cv addSubview:sv];
    self.status = [NSTextField labelWithString:@""]; self.status.frame = NSMakeRect(12, 382, 736, 18); self.status.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin; [cv addSubview:self.status];
    NSArray *nudges = @[@[@"−1 fr", @(-1.0)], @[@"−¼ fr", @(-0.25)], @[@"+¼ fr", @(0.25)], @[@"+1 fr", @(1.0)]];
    CGFloat x = 12;
    for (NSArray *n in nudges) {
        NSButton *b = [NSButton buttonWithTitle:n[0] target:self action:@selector(nudge:)]; b.tag = (NSInteger)([n[1] doubleValue] * 4); b.frame = NSMakeRect(x, 14, 64, 28); x += 68; [cv addSubview:b];
    }
    self.removeBox = [NSButton checkboxWithTitle:@"Remove the loose recording clips from the timeline after syncing (the synced clips carry that audio now)" target:nil action:nil];
    self.removeBox.frame = NSMakeRect(12, 50, 736, 24); self.removeBox.state = NSControlStateValueOn; self.removeBox.hidden = YES; [cv addSubview:self.removeBox];
    NSButton *reset = [NSButton buttonWithTitle:@"Reset" target:self action:@selector(resetNudge:)]; reset.frame = NSMakeRect(x, 14, 64, 28); [cv addSubview:reset];
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)]; cancel.frame = NSMakeRect(560, 14, 90, 28); cancel.autoresizingMask = NSViewMinXMargin; cancel.keyEquivalent = @"\e"; [cv addSubview:cancel];
    self.syncButton = [NSButton buttonWithTitle:@"Sync" target:self action:@selector(sync:)]; self.syncButton.frame = NSMakeRect(656, 14, 92, 28); self.syncButton.autoresizingMask = NSViewMinXMargin; self.syncButton.keyEquivalent = @"\r"; self.syncButton.enabled = NO; [cv addSubview:self.syncButton];
    self.panel = p;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)self.matches.count; }
- (id)tableView:(NSTableView *)t objectValueForTableColumn:(NSTableColumn *)c row:(NSInteger)r {
    ASMatch *m = self.matches[(NSUInteger)r]; NSString *i = c.identifier;
    if ([i isEqual:@"use"]) return @(m.include);
    if ([i isEqual:@"video"]) return m.video.name;
    if ([i isEqual:@"audio"]) return m.audio.name ?: @"—";
    if ([i isEqual:@"offset"]) { if (!m.audio) return @""; double d = m.offset + m.nudge; return [NSString stringWithFormat:@"%+.3f s%@", d, m.nudge != 0 ? @" *" : @""]; }
    if ([i isEqual:@"conf"]) return m.audio ? (m.score >= 12 ? @"High" : m.score >= 8 ? @"Good" : @"Low") : @"";
    return m.note ?: @"";
}
- (void)tableView:(NSTableView *)t setObjectValue:(id)v forTableColumn:(NSTableColumn *)c row:(NSInteger)r {
    if ([c.identifier isEqual:@"use"]) { ASMatch *m = self.matches[(NSUInteger)r]; m.include = [v boolValue] && m.audio != nil; [self refresh]; }
}
- (void)refresh {
    [self.table reloadData];
    NSUInteger n = 0; for (ASMatch *m in self.matches) if (m.include && m.audio) n++;
    self.syncButton.title = n ? [NSString stringWithFormat:@"Sync %lu", (unsigned long)n] : @"Sync"; self.syncButton.enabled = n > 0;
}
- (void)nudge:(NSButton *)b {
    NSIndexSet *rows = self.table.selectedRowIndexes; if (!rows.count) { NSBeep(); return; }
    [rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { self.matches[i].nudge += self.frame * (b.tag / 4.0); }];
    [self refresh];
}
- (void)resetNudge:(id)s { [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) { self.matches[i].nudge = 0; }]; [self refresh]; }
- (void)cancel:(id)s { [self.panel orderOut:nil]; gPanel = nil; }
- (void)sync:(id)s {
    self.syncButton.enabled = NO;
    NSString *r = nil;
    @try { r = ApplySyncClips(self.matches, !self.removeBox.hidden && self.removeBox.state == NSControlStateValueOn); } @catch (id e) { r = [NSString stringWithFormat:@"Error: %@", e]; ALog(@"apply threw %@", e); }
    self.status.stringValue = r;
    for (ASMatch *m in self.matches) m.include = NO;
    [self.table reloadData];
}
- (void)windowWillClose:(NSNotification *)n { gPanel = nil; }
@end

static void RunBatchSync(BOOL autoApply) {
    NSMutableArray *videos = [NSMutableArray array], *audios = [NSMutableArray array]; NSString *why = nil;
    BOOL okToGo = Gather(videos, audios, &why);
    if (gPanel) [gPanel.panel orderOut:nil];
    CMTime fd = OT(O(ActiveTM(), @"sequence"), @"frameDuration");
    ASPanel *p = [ASPanel new]; [p build];
    if (!okToGo) {
        ALog(@"not started: %@", why);
        p.matches = [NSMutableArray array]; gPanel = p;
        p.status.stringValue = why; p.status.textColor = [NSColor systemOrangeColor];
        [p.panel center]; [p.panel makeKeyAndOrderFront:nil]; [p refresh];
        return;
    }
    for (ASAudio *a in audios) if (a.fromTimeline) p.removeBox.hidden = NO; p.frame = (CMTIME_IS_VALID(fd) && fd.value > 0) ? Sec(fd) : 0.04; p.matches = [NSMutableArray array];
    gPanel = p;
    p.status.stringValue = [NSString stringWithFormat:@"Analysing %lu video clip%@ against %lu recording%@…", (unsigned long)videos.count, videos.count == 1 ? @"" : @"s", (unsigned long)audios.count, audios.count == 1 ? @"" : @"s"];
    [p.panel center]; [p.panel makeKeyAndOrderFront:nil];
    ALog(@"=== batch sync: %lu videos, %lu recordings", (unsigned long)videos.count, (unsigned long)audios.count);
    NSDate *t0 = [NSDate date];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *res = [NSMutableArray array];
        @try {
            AnalyseAll(videos, audios, res, ^(NSString *s) { dispatch_async(dispatch_get_main_queue(), ^{ p.status.stringValue = s; }); });
        } @catch (id e) { ALog(@"analysis threw %@", e); }
        dispatch_async(dispatch_get_main_queue(), ^{
            p.matches = res;
            NSUInteger ok = 0; for (ASMatch *m in res) if (m.include) ok++;
            p.status.stringValue = [NSString stringWithFormat:@"%lu of %lu clips matched in %.1f s. Untick anything wrong, nudge if needed, then Sync.", (unsigned long)ok, (unsigned long)res.count, -[t0 timeIntervalSinceNow]];
            ALog(@"analysis done in %.2f s", -[t0 timeIntervalSinceNow]);
            [p refresh];
            if (autoApply) [p sync:nil];
        });
    });
}

#pragma mark - command, menu, test hooks
#ifndef ASNOTE
#define ASNOTE @"SKAS"
#endif
@interface NSObject (ASLK)
- (id)initWithCommandIdentifier:(id)i dictionary:(id)d; - (void)_setName:(id)n; - (void)_setDetailedDescription:(id)d;
- (void)registerCommand:(id)c; - (void)addCommandWithIdentifier:(id)i toGroupWithIdentifier:(id)g; - (id)commandWithIdentifier:(id)i;
@end
static void InstallMenu(void) {
    NSMenu *main = NSApp.mainMenu; NSMenuItem *clipItem = nil;
    for (NSMenuItem *it in main.itemArray) if ([it.title isEqualToString:@"Clip"]) clipItem = it;
    NSMenu *m = clipItem.submenu; if (!m || [m itemWithTitle:@"Batch Sync Audio…"]) return;
    NSInteger idx = m.numberOfItems;
    for (NSInteger i = 0; i < m.numberOfItems; i++) if ([[m itemAtIndex:i].title hasPrefix:@"Synchronize Clips"]) idx = i + 1;
    NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:@"Batch Sync Audio…" action:NSSelectorFromString(@"spliceKitBatchSyncAudio:") keyEquivalent:@""];
    [m insertItem:it atIndex:idx];
}
__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) { (void)api; }
static void Install(void) {
    static BOOL done; if (done) return; done = YES;
    SEL s = NSSelectorFromString(@"spliceKitBatchSyncAudio:");
    IMP imp = imp_implementationWithBlock(^(id self, id sender) { @try { RunBatchSync(NO); } @catch (id e) { ALog(@"run threw %@", e); } });
    if (!class_addMethod([NSApplication class], s, imp, "v@:@")) class_replaceMethod([NSApplication class], s, imp, "v@:@");
    id cc = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("LKCommandsController"), NSSelectorFromString(@"sharedController"));
    if (cc && ![cc commandWithIdentifier:@"SpliceKitBatchSyncAudio"]) {
        id cmd = [[objc_getClass("LKCommand") alloc] initWithCommandIdentifier:@"SpliceKitBatchSyncAudio" dictionary:@{ @"downSelector": @"spliceKitBatchSyncAudio:", @"downRepeats": @0 }];
        [cmd _setName:@"Batch Sync Audio"];
        [cmd _setDetailedDescription:@"Sync the selected video clips with the selected external audio recordings by waveform, without compound clips"];
        [cc registerCommand:cmd]; [cc addCommandWithIdentifier:@"SpliceKitBatchSyncAudio" toGroupWithIdentifier:@"Editing"];
    }
    InstallMenu();
    // test hooks (notification "SKAS"): "run", "auto", "probe", "append:<clip name>"
    [[NSNotificationCenter defaultCenter] addObserverForName:ASNOTE object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        NSString *c = n.object;
        @try {
            if ([c isEqual:@"run"]) RunBatchSync(NO);
            else if ([c isEqual:@"auto"]) RunBatchSync(YES);
            else if ([c hasPrefix:@"decode:"]) {   // test helper: can the camera audio of this browser clip be read?
                NSString *name = [c substringFromIndex:7]; id clip = nil;
                for (id x in AllBrowserClips()) if ([O(x, @"displayName") isEqualToString:name]) clip = x;
                NSString *err = nil; NSURL *u = ItemURL(clip); NSData *d = u ? Decode(u, kDecRate, 0, 5, &err) : nil;
                ALog(@"decode %@ (%@): %lu samples %@", name, u.lastPathComponent, (unsigned long)(d.length / 4), err ?: @"");
            }
            else if ([c isEqual:@"close"] && gPanel) [gPanel cancel:nil];
            else if ([c isEqual:@"snap"] && gPanel) {   // test helper: picture of the review panel
                NSView *v = gPanel.panel.contentView; NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
                [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/panel.png"] atomically:YES];
            }
            else if ([c hasPrefix:@"dlen:"]) {   // diagnostic: decoded length vs file duration, and seek-vs-sequential agreement
                NSString *name = [c substringFromIndex:5]; id clip = nil;
                for (id x in AllBrowserClips()) if ([O(x, @"displayName") isEqualToString:name]) clip = x;
                NSURL *u = ItemURL(clip);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    AVURLAsset *as = [AVURLAsset URLAssetWithURL:u options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
                    NSData *full = Decode(u, kDecRate, 0, 3 * 3600, NULL);
                    double fileDur = CMTimeGetSeconds(as.duration), got = full.length / 4.0 / kDecRate;
                    ALog(@"dlen %@: asset %.4f s, decoded %.4f s (diff %.1f ms), media %.4f s", name, fileDur, got, (got - fileDur) * 1000, Sec(OR(clip, @"mediaRange").duration));
                    for (double t = 60; t < got - 20; t += 300) {
                        NSData *seg = Decode(u, kDecRate, t, 10, NULL);
                        const float *F = full.bytes; size_t base = (size_t)(t * kDecRate);
                        NSData *c = XCorr(seg.bytes, seg.length / 4, F + base - 800, 10 * (size_t)kDecRate + 1600, NO);
                        double z = 0, lag = PeakLag(c, seg.length / 4, -800, 2400, &z);
                        ALog(@"   at %.0f s: seeked audio sits %.2f ms later in the sequential decode (z %.1f)", t, (lag - 800) / kDecRate * 1000, z);
                    }
                });
            }
            else if ([c hasPrefix:@"info:"]) {   // diagnostic: what we know about a browser clip
                NSString *name = [c substringFromIndex:5]; id clip = nil;
                for (id x in AllBrowserClips()) if ([O(x, @"displayName") isEqualToString:name]) clip = x;
                id prim = O(clip, @"primaryObject"); id inner = [(NSArray *)O(prim, @"containedItems") firstObject];
                ALog(@"info %@: %@ media=%.4f+%.4f fd=%.5f vprops=%@ inner=%@ innerMedia=%.4f url=%@ event=%@ lib=%@", name, [clip class], Sec(OR(clip, @"mediaRange").start), Sec(OR(clip, @"mediaRange").duration),
                     Sec(OT(clip, @"frameDuration")), O(clip, @"videoProps"), [inner class], Sec(OR(inner, @"mediaRange").start), ItemURL(clip), O(O(clip, @"event"), @"displayName") ?: O(clip, @"containerEvent"), O(O(clip, @"library"), @"displayName"));
                for (id x in (NSArray *)O(inner, @"containedItems")) ALog(@"   comp %@ %@ v=%d a=%d", [x class], O(x, @"displayName"), OB(x, @"hasVideo"), OB(x, @"hasAudio"));
                id tm = ActiveTM(); id seq = O(tm, @"sequence");
                ALog(@"   project %@ event %@ lib %@ vprops %@", O(seq, @"displayName"), O(O(seq, @"event"), @"displayName"), O(O(seq, @"library"), @"displayName"), O(seq, @"videoProps"));
            }
            else if ([c hasPrefix:@"mksync:"]) {   // test: mksync:<video clip name>|<recording name>|<offset s>
                NSArray *p = [[c substringFromIndex:7] componentsSeparatedByString:@"|"]; id v = nil, au = nil;
                id lib = O(O(ActiveTM(), @"sequence"), @"library");
                for (id x in AllBrowserClips()) { if (O(x, @"library") != lib) continue; if ([O(x, @"displayName") isEqualToString:p[0]] && !IsAudioOnly(x)) v = x; if ([O(x, @"displayName") isEqualToString:p[1]] && IsAudioOnly(x)) au = x; }
                NSString *xml = SyncClipsXML(@[@{ @"name": p.count > 3 ? p[3] : [p[0] stringByAppendingString:@" (synced)"], @"video": v, @"audio": au, @"offset": @([p[2] doubleValue]) }], @"Batch Synced Clips", NULL);
                [xml writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SpliceKit/last_sync.fcpxml"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                NSString *err = nil; BOOL ok = ImportXML(xml, lib, &err);
                ALog(@"mksync %@ + %@ -> %@ %@ (lib %@)", O(v, @"displayName"), O(au, @"displayName"), ok ? @"imported" : @"FAILED", err ?: @"", O(lib, @"displayName"));
            }
            else if ([c hasPrefix:@"sinfo:"]) {   // diagnostic: structure of a (synchronized) clip, browser or timeline
                NSString *name = [c substringFromIndex:6]; id clip = nil;
                for (id x in AllBrowserClips()) if ([O(x, @"displayName") isEqualToString:name]) clip = x;
                if (!clip) { id prim = O(O(ActiveTM(), @"sequence"), @"primaryObject"); for (id it in (NSArray *)O(prim, @"containedItems")) if ([O(it, @"displayName") isEqualToString:name]) clip = it; }
                __block void (^dump)(id, int);
                void (^dumpB)(id, int) = ^(id o, int depth) {
                    NSString *ind = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
                    CMTimeRange cr = OR(o, @"clippedRange"), mr = OR(o, @"mediaRange");
                    ALog(@"%@%@ '%@' lane %ld clipped %.5f+%.5f media %.5f+%.5f sync=%d v=%d a=%d", ind, [o class], O(o, @"displayName"), Lane(o), Sec(cr.start), Sec(cr.duration), Sec(mr.start), Sec(mr.duration), OB(o, @"isSyncronized"), OB(o, @"hasVideo"), OB(o, @"hasAudio"));
                    id map = O(o, @"audioComponentsLayoutMap"); if (map) ALog(@"%@  audio layout: %@", ind, [[map description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
                    if (depth > 6) return;
                    for (id x in (NSArray *)O(o, @"containedItems")) dump(x, depth + 1);
                    for (id x in (NSSet *)O(o, @"anchoredItems")) dump(x, depth + 1);
                    id po = O(o, @"primaryObject"); if (po && po != o) dump(po, depth + 1);
                };
                dump = dumpB;
                ALog(@"=== sinfo %@ (%@)", name, clip ? @"found" : @"NOT FOUND");
                if (clip) dump(clip, 0);
            }
            else if ([c hasPrefix:@"rpl:"]) {   // test: rpl:<timeline item name>|<browser clip name>|<replace type>
                NSArray *p = [[c substringFromIndex:4] componentsSeparatedByString:@"|"];
                id tm = ActiveTM(); id prim = O(O(tm, @"sequence"), @"primaryObject"); id item = nil, src = nil;
                for (id it in (NSArray *)O(prim, @"containedItems")) { if ([O(it, @"displayName") isEqualToString:p[0]]) item = it; for (id x in (NSSet *)O(it, @"anchoredItems")) if ([O(x, @"displayName") isEqualToString:p[0]]) item = x; }
                id lib = O(O(tm, @"sequence"), @"library");
                for (id x in AllBrowserClips()) if (O(x, @"library") == lib && [O(x, @"displayName") isEqualToString:p[1]]) src = x;
                CMTimeRange cr = OR(item, @"clippedRange"), mr = OR(item, @"mediaRange"), sr = OR(src, @"mediaRange");
                CMTimeRange r = CMTimeRangeMake(CMTimeAdd(sr.start, CMTimeSubtract(cr.start, mr.start)), cr.duration);
                ALog(@"rpl item %@ (%@) src %@ range %.5f+%.5f type %@ at %.5f lane %ld retimed %d/%d media %.5f+%.5f", O(item, @"displayName"), [item class], O(src, @"displayName"), Sec(r.start), Sec(r.duration), p[2], Sec(RangeIn(item, prim).start), Lane(item), OB(item, @"isRetimed"), OB(item, @"hasArtisticRetime"), Sec(mr.start), Sec(mr.duration));
                if (!item || !src) return;
                [tm setSelectedItems:@[item]];
                [[NSPasteboard generalPasteboard] clearContents];
                id pb = [[objc_getClass("FFPasteboard") alloc] initWithName:NSPasteboardNameGeneral];
                [pb writeRangesOfMedia:@[[objc_getClass("FigTimeRangeAndObject") rangeAndObjectWithRange:r andObject:src]] options:nil];
                ((void(*)(id, SEL, id, int))objc_msgSend)(tm, NSSelectorFromString(@"replaceWithPasteboard:replaceActionType:"), NSPasteboardNameGeneral, [p[2] intValue]);
                ALog(@"rpl done");
            }
            else if ([c hasPrefix:@"xmode:"]) { gXMode = [[c substringFromIndex:6] intValue]; ALog(@"xml mode %d", gXMode); }
            else if ([c hasPrefix:@"sources:"]) { gTestSources = [[c substringFromIndex:8] componentsSeparatedByString:@","]; if ([c isEqual:@"sources:"]) gTestSources = nil; ALog(@"test sources %@", gTestSources); }
            else if ([c hasPrefix:@"clips:"]) {
                NSString *q = [c substringFromIndex:6]; int n = 0;
                id libs = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
                for (id lib in libs) { id evs = O(lib, @"events"); ALog(@"lib %@ events %@ %lu", O(lib, @"displayName"), [evs class], (unsigned long)[evs count]);
                    for (id ev in evs) { id cl = O(ev, @"ownedClips") ?: O(O(ev, @"project"), @"ownedClips") ?: O(ev, @"displayOwnedClips"); for (id x in cl) { n++; if ([O(x, @"displayName") rangeOfString:q].location != NSNotFound) ALog(@"  clip %@ in %@ (%@)", O(x, @"displayName"), O(ev, @"displayName"), [x class]); } } }
                ALog(@"clips total %d", n);
            }
            else if ([c isEqual:@"probe"]) {
                for (id x in BrowserSelection()) ALog(@"browser sel %@ %@ url=%@ media=%.3f+%.3f audioOnly=%d", [x class], O(x, @"displayName"), ItemURL(x).lastPathComponent, Sec(OR(x, @"mediaRange").start), Sec(OR(x, @"mediaRange").duration), IsAudioOnly(x));
                id tm = ActiveTM(); id prim = O(O(tm, @"sequence"), @"primaryObject");
                NSArray *sel = ((id(*)(id, SEL, BOOL, BOOL))objc_msgSend)(tm, NSSelectorFromString(@"selectedItems:includeItemBeforePlayheadIfLast:"), NO, NO);
                for (id x in sel) ALog(@"timeline sel %@ %@ url=%@ clipped=%.4f+%.4f media=%.4f+%.4f tl=%.4f lane=%ld audioOnly=%d", [x class], O(x, @"displayName"), ItemURL(x).lastPathComponent, Sec(OR(x, @"clippedRange").start), Sec(OR(x, @"clippedRange").duration), Sec(OR(x, @"mediaRange").start), Sec(OR(x, @"mediaRange").duration), Sec(RangeIn(x, prim).start), Lane(x), IsAudioOnly(x));
            } else if ([c hasPrefix:@"append:"]) {   // test helper: put a browser clip at the end of the primary storyline
                NSString *name = [c substringFromIndex:7]; id clip = nil;
                for (id x in AllBrowserClips()) if ([O(x, @"displayName") isEqualToString:name]) clip = x;
                id tm = ActiveTM(); id seq = O(tm, @"sequence");
                CMTimeRange mr = OR(clip, @"mediaRange");
                id pb = [[objc_getClass("FFPasteboard") alloc] initWithName:NSPasteboardNameGeneral];
                [[NSPasteboard generalPasteboard] clearContents];
                [pb writeRangesOfMedia:@[[objc_getClass("FigTimeRangeAndObject") rangeAndObjectWithRange:mr andObject:clip]] options:nil];
                CMTime end = CMTimeAdd(OR(seq, @"timeRange").start, OT(seq, @"duration"));
                [tm setPlayheadTime:end];
                ((void(*)(id, SEL, id))objc_msgSend)(tm, @selector(paste:), nil);
                ALog(@"appended %@ (%@) at %.3f", name, clip ? @"found" : @"NOT FOUND", Sec(end));
            } else if ([c hasPrefix:@"select:"]) {   // test helper: select timeline items whose name contains any of the comma list
                NSArray *names = [[c substringFromIndex:7] componentsSeparatedByString:@","];
                id tm = ActiveTM(); id prim = O(O(tm, @"sequence"), @"primaryObject"); NSMutableArray *pick = [NSMutableArray array];
                NSMutableArray *all = [NSMutableArray array];
                for (id it in (NSArray *)O(prim, @"containedItems")) { [all addObject:it]; for (id x in (NSSet *)O(it, @"anchoredItems")) [all addObject:x]; }
                for (id x in all) for (NSString *nm in names) if (nm.length && [O(x, @"displayName") rangeOfString:nm].location != NSNotFound) { [pick addObject:x]; break; }
                [tm setSelectedItems:pick]; ALog(@"selected %lu timeline items", (unsigned long)pick.count);
            } else if ([c hasPrefix:@"bselect:"]) {  // test helper: select browser clips by exact names
                NSArray *names = [[c substringFromIndex:8] componentsSeparatedByString:@","]; NSMutableArray *ranges = [NSMutableArray array];
                for (id x in AllBrowserClips()) if ([names containsObject:O(x, @"displayName") ?: @""]) [ranges addObject:[objc_getClass("FigTimeRangeAndObject") rangeAndObjectWithRange:OR(x, @"mediaRange") andObject:x]];
                id app = ((id(*)(id, SEL))objc_msgSend)(objc_getClass("PEAppController"), NSSelectorFromString(@"appController"));
                id fs = O(O(O(app, @"mediaEventOrganizerContainer"), @"activeOrganizerModule"), @"filmstripModule");
                ((void(*)(id, SEL, id))objc_msgSend)(fs, NSSelectorFromString(@"_selectMediaRanges:"), ranges);
                ALog(@"browser selected %lu", (unsigned long)ranges.count);
            }
        } @catch (id e) { ALog(@"%@ threw %@", c, e); }
    }];
    ALog(@"batch sync audio ready");
}
__attribute__((constructor)) static void as_init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ Install(); });
}
