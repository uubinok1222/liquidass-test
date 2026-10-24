#import "XCStyle.h"
#import "XCLiveBackdropView.h"
#import <objc/runtime.h>
#import <notify.h>
#include <uuid/uuid.h>
#include <string.h>
#include <stdarg.h>

extern void XCInvalidateGlassPreferenceCache(void);
extern void XCRunReloadHandlersNow(void);

#define kSetName "com.clockglass.style.set"
#define kDefClarity 0.75
#define kDefDistortion 0.5

static NSMutableDictionary *sCfg;
static XCStyleValue sCurrent, sEdit, sEditInit;
static __weak UIViewController *sPosterVC;
static BOOL sEditing;
static uint32_t sEditHash;
static uint32_t sTintRGB = 0xFFFFFF;
static char kGlassSigKey;

BOOL XCIsSpringBoard(void) {
    static BOOL v;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        v = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
    });
    return v;
}

static XCStyleValue DefStyle(void) {
    XCStyleValue s = { NO, NO, -1, kDefClarity, kDefDistortion };
    return s;
}

void XCLogf(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *proc = NSProcessInfo.processInfo.processName;
    NSData *d = [[NSString stringWithFormat:@"[%@] %@\n", proc, s] dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *dir in @[@"/var/mobile/Library/Caches", NSTemporaryDirectory()]) {
        NSString *p = [dir stringByAppendingFormat:@"/clockglass_%@.log", proc];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!h) {
            [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            h = [NSFileHandle fileHandleForWritingAtPath:p];
        }
        if (!h) continue;
        if ([h seekToEndOfFile] < 200000) [h writeData:d];
        [h closeFile];
        return;
    }
}

static NSString *CfgPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.clockglass.styles.plist"];
}
static void CfgLoad(void) {
    sCfg = [NSMutableDictionary dictionaryWithContentsOfFile:CfgPath()] ?: [NSMutableDictionary new];
}
static void CfgSave(void) {
    [sCfg writeToFile:CfgPath() atomically:YES];
}
static NSString *Hex(uint32_t h) {
    return [NSString stringWithFormat:@"%08x", h];
}
static uint32_t HashUUID(NSUUID *u) {
    uuid_t b;
    [u getUUIDBytes:b];
    uint32_t w[4];
    memcpy(w, b, 16);
    return w[0] ^ w[1] ^ w[2] ^ w[3];
}

static XCStyleValue FromDict(NSDictionary *c) {
    XCStyleValue s = DefStyle();
    if (![c isKindOfClass:NSDictionary.class]) return s;
    s.valid = YES;
    s.glass = [c[@"g"] boolValue];
    double st = c[@"s"] ? [c[@"s"] doubleValue] : -1;
    s.stretch = st < 0 ? -1 : MIN(1.0, st);
    if (c[@"c"]) s.clarity = MIN(1.0, MAX(0.0, [c[@"c"] doubleValue]));
    if (c[@"d"]) s.distortion = MIN(1.0, MAX(0.0, [c[@"d"] doubleValue]));
    return s;
}

static NSUUID *UUIDFromCfgKey(UIViewController *vc, NSString *key) {
    @try {
        id cfg = [vc valueForKey:key];
        SEL s = NSSelectorFromString(@"pr_posterUUID");
        if (cfg && [cfg respondsToSelector:s]) {
            id u = [cfg performSelector:s];
            if ([u isKindOfClass:NSUUID.class]) return u;
        }
    } @catch (...) {}
    return nil;
}

static void Recompute(void) {
    if (sEditing) {
        sCurrent = sEdit;
        return;
    }
    UIViewController *vc = sPosterVC;
    NSUUID *u = vc ? UUIDFromCfgKey(vc, @"_configuration") : nil;
    sCurrent = u ? FromDict(sCfg[Hex(HashUUID(u))]) : DefStyle();
}

void XCStyleDidChange(void) {
    static BOOL pending;
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pending = NO;
        XCRunReloadHandlersNow();
    });
}

void XCSetActivePosterVC(UIViewController *vc) {
    sPosterVC = vc;
    Recompute();
    XCStyleDidChange();
    XCLogf(@"poster appeared valid=%d glass=%d stretch=%.2f", sCurrent.valid, sCurrent.glass, sCurrent.stretch);
}

XCStyleValue XCCurrentStyle(void) {
    return sCurrent;
}

BOOL XCClockStyleGlassOn(void) {
    return XCIsSpringBoard() && sCurrent.valid && sCurrent.glass;
}

double XCStyleSignature(void) {
    if (!sCurrent.valid) return 0;
    double st = sCurrent.stretch >= 0 ? (double)lround(sCurrent.stretch * 100) + 1.0 : 0.0;
    double v = st + 102.0 * (double)lround(sCurrent.clarity * 100)
             + 10302.0 * (double)lround(sCurrent.distortion * 100)
             + 1040502.0 * (sCurrent.glass ? 1.0 : 0.0);
    return v + 2200000.0 * (double)(sTintRGB & 0xFFFFFF);
}

CGAffineTransform XCStretchTransform(CGFloat anchorY) {
    return CGAffineTransformIdentity;
}

void XCSyncHostTransform(UIView *host) {
    (void)host;
}

void XCSetTint(UIColor *c) {
    if (![c isKindOfClass:UIColor.class]) return;
    CGFloat r = 1, g = 1, b = 1, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 1;
        if ([c getWhite:&w alpha:&a]) {
            r = w;
            g = w;
            b = w;
        } else {
            return;
        }
    }
    uint32_t ri = (uint32_t)lround(r * 255) & 0xFF;
    uint32_t gi = (uint32_t)lround(g * 255) & 0xFF;
    uint32_t bi = (uint32_t)lround(b * 255) & 0xFF;
    uint32_t rgb = (ri << 16) | (gi << 8) | bi;
    if (rgb == sTintRGB) return;
    sTintRGB = rgb;
    XCLogf(@"tint %06x", rgb);
    XCStyleDidChange();
}

UIColor *XCCurrentTintColor(void) {
    return [UIColor colorWithRed:((sTintRGB >> 16) & 0xFF) / 255.0
                           green:((sTintRGB >> 8) & 0xFF) / 255.0
                            blue:(sTintRGB & 0xFF) / 255.0
                           alpha:1.0];
}

void XCNoteClockHost(UIView *host) {
    for (UIResponder *r = host; r; r = r.nextResponder) {
        if ([NSStringFromClass(r.class) isEqualToString:@"CSProminentDisplayViewController"]) {
            @try {
                id v = [r valueForKey:@"_textColor"];
                if ([v isKindOfClass:UIColor.class]) XCSetTint((UIColor *)v);
            } @catch (...) {}
            break;
        }
    }
}

BOOL XCVarHeightRange(double *mn, double *mx) {
    Class c = NSClassFromString(@"XCClockFontStore");
    SEL sh = NSSelectorFromString(@"shared");
    if (!c || ![c respondsToSelector:sh]) return NO;
    id store = [c performSelector:sh];
    if (!store) return NO;
    NSDictionary *ranges = nil;
    @try {
        ranges = [store valueForKey:@"axisRanges"];
    } @catch (...) {
        return NO;
    }
    NSArray *r = [ranges isKindOfClass:NSDictionary.class] ? ranges[@"height"] : nil;
    if (![r isKindOfClass:NSArray.class] || r.count != 2) return NO;
    double a = [r[0] doubleValue];
    double b = [r[1] doubleValue];
    if (!(b > a)) return NO;
    if (mn) *mn = a;
    if (mx) *mx = b;
    return YES;
}

static void LogKeyOnce(NSString *key) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [NSMutableSet new];
    });
    @synchronized (seen) {
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    XCLogf(@"pref key %@", key);
}

id XCStylePreferenceOverride(NSString *key) {
    if (!key.length) return nil;
    if ([key isEqualToString:@"Global.Enabled"]) return @YES;
    if (![key hasPrefix:@"Clock."] && ![key hasPrefix:@"Lockscreen.Clock."]) return nil;
    LogKeyOnce(key);
    if ([key isEqualToString:@"Clock.VariableFont.Enabled"]) {
        return @(XCIsSpringBoard() && sCurrent.valid && sCurrent.glass && sCurrent.stretch >= 0);
    }
    if ([key isEqualToString:@"Lockscreen.Clock.DateFormat.Enabled"]) return @NO;
    if (!sCurrent.valid) return nil;
    double c = sCurrent.clarity;
    double d = sCurrent.distortion;
    if ([key isEqualToString:@"Clock.VariableFont.Height"]) {
        if (sCurrent.stretch < 0) return nil;
        double mn = 100;
        double mx = 600;
        XCVarHeightRange(&mn, &mx);
        return @(mn + (mx - mn) * sCurrent.stretch);
    }
    if ([key isEqualToString:@"Clock.Blur"]) return @(12.0 * (1.0 - c));
    if ([key isEqualToString:@"Clock.BezelWidth"]) return @(4.0 + 24.0 * d);
    if ([key isEqualToString:@"Clock.GlassThickness"]) return @(60.0 + 120.0 * d);
    if ([key isEqualToString:@"Clock.RefractionScale"]) return @(0.6 + 2.2 * d);
    if ([key isEqualToString:@"Clock.SpecularOpacity"]) return @(0.4 + 0.6 * c);
    if ([key isEqualToString:@"Clock.LightTintColor"] || [key isEqualToString:@"Clock.DarkTintColor"]) {
        int alpha = (int)lround((0.25 + 0.5 * (1.0 - c)) * 255);
        return [NSString stringWithFormat:@"#%06X%02X", sTintRGB & 0xFFFFFF, alpha];
    }
    return nil;
}

BOOL XCProcessHostsClock(void) {
    if (XCIsSpringBoard()) return YES;
    return NSClassFromString(@"PREditingFontAndColorPickerViewController") != nil
        && NSClassFromString(@"CSProminentTimeView") != nil;
}

BOOL XCHostShouldRender(UIView *host) {
    if (XCIsSpringBoard()) return YES;
    UIWindow *w = host.window;
    if (!w) return NO;
    if (!CGRectIntersectsRect([host convertRect:host.bounds toView:nil], w.bounds)) return NO;
    UIView *dv = host;
    while (dv && ![NSStringFromClass(dv.class) isEqualToString:@"CSProminentDisplayView"]) dv = dv.superview;
    if (!dv || !dv.superview) return YES;
    for (UIView *s in dv.superview.subviews.reverseObjectEnumerator) {
        if (![NSStringFromClass(s.class) isEqualToString:@"CSProminentDisplayView"]) continue;
        if (CGRectIntersectsRect([s convertRect:s.bounds toView:nil], w.bounds)) return s == dv;
    }
    return YES;
}

void XCSyncGlassParams(id glass) {
    if (!glass) return;
    NSString *sig = [NSString stringWithFormat:@"%.3f|%.3f|%06x|%.3f",
                     sCurrent.clarity, sCurrent.distortion, sTintRGB, sCurrent.stretch];
    if ([sig isEqualToString:objc_getAssociatedObject(glass, &kGlassSigKey)]) return;
    objc_setAssociatedObject(glass, &kGlassSigKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);
    XCInvalidateGlassPreferenceCache();
    if ([glass respondsToSelector:@selector(applyFilters)]) {
        [glass applyFilters];
    }
}

static void Send(uint32_t h, XCStyleValue v) {
    static int tok = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kSetName, &tok);
    });
    uint64_t sc = v.stretch < 0 ? 0 : (uint64_t)(MIN(100, lround(v.stretch * 100)) + 1);
    uint64_t cp = (uint64_t)MIN(100, MAX(0, lround(v.clarity * 100)));
    uint64_t dp = (uint64_t)MIN(100, MAX(0, lround(v.distortion * 100)));
    uint64_t st = ((uint64_t)h << 32) | ((uint64_t)(v.glass ? 1 : 0) << 31) | (sc << 24)
                | (0xA5ULL << 16) | (cp << 8) | dp;
    uint32_t r1 = notify_set_state(tok, st);
    uint32_t r2 = notify_post(kSetName);
    XCLogf(@"send hash=%08x glass=%d s=%.2f c=%.2f d=%.2f r=%u/%u", h, v.glass, v.stretch, v.clarity, v.distortion, r1, r2);
}

void XCEditBegin(NSUUID *uuid) {
    sEditing = YES;
    sEditHash = uuid ? HashUUID(uuid) : 0;
    XCStyleValue base = uuid ? FromDict(sCfg[Hex(sEditHash)]) : DefStyle();
    sEditInit = base;
    sEdit = base;
    Recompute();
    XCStyleDidChange();
    XCLogf(@"edit begin uuid=%@ valid=%d", uuid.UUIDString, base.valid);
}

void XCEditEnd(void) {
    sEditing = NO;
    Recompute();
    XCStyleDidChange();
}

BOOL XCEditActive(void) {
    return sEditing;
}

XCStyleValue XCEditGet(void) {
    return sEdit;
}

void XCEditSet(XCStyleValue v) {
    v.valid = YES;
    sEdit = v;
    Recompute();
    XCStyleDidChange();
}

void XCEditCommit(void) {
    if (!sEditing || !sEdit.valid || sEditHash == 0) return;
    if (sEditInit.valid && sEdit.glass == sEditInit.glass
        && fabs(sEdit.stretch - sEditInit.stretch) < 0.005
        && fabs(sEdit.clarity - sEditInit.clarity) < 0.005
        && fabs(sEdit.distortion - sEditInit.distortion) < 0.005) return;
    sCfg[Hex(sEditHash)] = @{ @"g": @(sEdit.glass), @"s": @(sEdit.stretch), @"c": @(sEdit.clarity), @"d": @(sEdit.distortion) };
    CfgSave();
    Send(sEditHash, sEdit);
    sEditInit = sEdit;
}

static void StartReceiver(void) {
    static int tok = 0;
    uint32_t r = notify_register_dispatch(kSetName, &tok, dispatch_get_main_queue(), ^(int t) {
        uint64_t st = 0;
        notify_get_state(t, &st);
        if (((st >> 16) & 0xFF) != 0xA5) return;
        uint32_t h = (uint32_t)(st >> 32);
        BOOL g = (st >> 31) & 1;
        int code = (int)((st >> 24) & 0x7F);
        double s = code > 0 ? (code - 1) / 100.0 : -1.0;
        double c = ((st >> 8) & 0x7F) / 100.0;
        double d = (st & 0x7F) / 100.0;
        sCfg[Hex(h)] = @{ @"g": @(g), @"s": @(s), @"c": @(c), @"d": @(d) };
        CfgSave();
        Recompute();
        XCRunReloadHandlersNow();
        XCLogf(@"recv hash=%08x glass=%d s=%.2f c=%.2f d=%.2f", h, g, s, c, d);
    });
    XCLogf(@"receiver r=%u", r);
}

__attribute__((constructor)) static void XCStyleInit(void) {
    @autoreleasepool {
        CfgLoad();
        if (!XCIsSpringBoard()) return;
        CFStringRef dom = CFSTR("xc.clockglass.prefs");
        CFPropertyListRef cur = CFPreferencesCopyAppValue(CFSTR("Global.Enabled"), dom);
        if (!cur) {
            CFPreferencesSetAppValue(CFSTR("Global.Enabled"), kCFBooleanTrue, dom);
            CFPreferencesAppSynchronize(dom);
        } else {
            CFRelease(cur);
        }
        StartReceiver();
    }
}
