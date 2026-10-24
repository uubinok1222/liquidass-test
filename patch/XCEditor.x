#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "../Shared/XCStyle.h"
#import "../Shared/XCGlassKit.h"

@interface XCUI : NSObject
@property (nonatomic, weak) UIViewController *rootVC;
@property (nonatomic, weak) UIView *root;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, weak) UISwitch *sw;
@property (nonatomic, weak) UISlider *clarity;
@property (nonatomic, weak) UISlider *distortion;
@property (nonatomic) double panStart;
@property (nonatomic) CGFloat hostH;
@property (nonatomic) BOOL hasButtons;
@property (nonatomic) BOOL settled;
@end

static XCUI *gUI;
static const void *kRootKey = &kRootKey;
static const void *kPanelKey = &kPanelKey;
static void Reposition(void);

@implementation XCUI

- (void)tail {
    if (self.settled && !self.hasButtons) {
        XCEditCommit();
    }
}

- (void)switched {
    XCStyleValue v = XCEditGet();
    v.glass = self.sw.isOn;
    XCEditSet(v);
    [self tail];
}

- (void)slid {
    XCStyleValue v = XCEditGet();
    v.clarity = self.clarity.value;
    v.distortion = self.distortion.value;
    XCEditSet(v);
}

- (void)done {
    XCEditCommit();
}

- (void)cancel {
    XCEditEnd();
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *root = self.root;
    if (!root) return;
    XCStyleValue v = XCEditGet();
    if (g.state == UIGestureRecognizerStateBegan) {
        self.panStart = v.stretch >= 0 ? v.stretch : 0;
    }
    CGFloat h = self.hostH > 1 ? self.hostH : 119;
    double s = self.panStart + [g translationInView:root].y / (XC_STRETCH_MAX * h);
    v.stretch = MAX(0.0, MIN(1.0, s));
    XCEditSet(v);
    Reposition();
    if (g.state == UIGestureRecognizerStateEnded) {
        [self tail];
    }
}

@end

static BOOL IsClass(UIView *v, NSString *n) {
    return [NSStringFromClass(v.class) isEqualToString:n];
}

static UIView *FindView(UIView *root, BOOL (^pred)(UIView *)) {
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
    NSUInteger i = 0;
    while (i < q.count && i < 4000) {
        UIView *v = q[i++];
        if (pred(v)) return v;
        [q addObjectsFromArray:v.subviews];
    }
    return nil;
}

static id Call(id o, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    return [o respondsToSelector:s] ? [o performSelector:s] : nil;
}

static NSUUID *UUIDFrom(id o) {
    if (!o || [o isKindOfClass:NSUUID.class]) return nil;
    for (NSString *s in @[@"pr_posterUUID", @"posterUUID"]) {
        id u = Call(o, s);
        if ([u isKindOfClass:NSUUID.class]) return u;
    }
    id ident = Call(o, @"identity");
    if (ident) {
        id u = Call(ident, @"posterUUID");
        if ([u isKindOfClass:NSUUID.class]) return u;
    }
    return nil;
}

static BOOL Interesting(id o) {
    if ([o isKindOfClass:UIView.class] || [o isKindOfClass:CALayer.class]) return NO;
    if ([o isKindOfClass:UIViewController.class] || [o isKindOfClass:NSArray.class]) return YES;
    NSString *n = NSStringFromClass([o class]);
    return [n hasPrefix:@"PR"] || [n hasPrefix:@"PBF"] || [n hasPrefix:@"PF"] || [n hasPrefix:@"PU"] ||
           [n hasPrefix:@"Poster"] || [n hasPrefix:@"_TtC"] || [n containsString:@"Wallpaper"];
}

static void Neighbors(id o, NSMutableArray *out) {
    if ([o isKindOfClass:NSArray.class]) {
        NSUInteger i = 0;
        for (id x in (NSArray *)o) {
            if (i++ > 40) break;
            [out addObject:x];
        }
        return;
    }
    if ([o isKindOfClass:UIViewController.class]) {
        UIViewController *vc = o;
        if (vc.parentViewController) [out addObject:vc.parentViewController];
        if (vc.presentingViewController) [out addObject:vc.presentingViewController];
        if (vc.presentedViewController) [out addObject:vc.presentedViewController];
        [out addObjectsFromArray:vc.childViewControllers];
    }
    for (Class k = [o class]; k && k != NSObject.class && k != UIResponder.class && k != UIViewController.class; k = class_getSuperclass(k)) {
        unsigned n = 0;
        Ivar *iv = class_copyIvarList(k, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *te = ivar_getTypeEncoding(iv[i]);
            if (!te || te[0] != '@') continue;
            id v = nil;
            @try { v = object_getIvar(o, iv[i]); } @catch (...) {}
            if (v) [out addObject:v];
        }
        free(iv);
    }
}

static NSUUID *FindPosterUUID(id root) {
    if (!root) return nil;
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger idx = 0;
    while (idx < queue.count && idx < 400) {
        id o = queue[idx];
        int d = [depths[idx] intValue];
        idx++;
        NSValue *key = [NSValue valueWithNonretainedObject:o];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        NSUUID *u = UUIDFrom(o);
        if (u) return u;
        if (d >= 5 || !Interesting(o)) continue;
        NSMutableArray *nb = [NSMutableArray array];
        Neighbors(o, nb);
        for (id x in nb) {
            [queue addObject:x];
            [depths addObject:@(d + 1)];
        }
    }
    return nil;
}

static UIView *FindHost(UIView *root) {
    UIWindow *w = root.window;
    if (!w) return nil;
    UIView *best = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
    NSUInteger i = 0;
    while (i < q.count && i < 4000) {
        UIView *v = q[i++];
        if (IsClass(v, @"CSProminentTimeView")) {
            if (XCHostShouldRender(v)) return v;
            CGRect r = CGRectIntersection([v convertRect:v.bounds toView:nil], w.bounds);
            CGFloat a = CGRectIsNull(r) ? 0 : r.size.width * r.size.height;
            if (a > bestArea) {
                bestArea = a;
                best = v;
            }
        }
        [q addObjectsFromArray:v.subviews];
    }
    return best;
}

static void Reposition(void) {
    XCUI *ui = gUI;
    UIView *root = ui.root;
    if (!ui || !ui.handle || !root.window) return;
    CGFloat W = root.bounds.size.width;
    CGFloat H = root.bounds.size.height;
    CGPoint c = CGPointMake(W - 34, 230);
    UIView *host = FindHost(root);
    if (host) {
        XCStyleValue v = XCEditGet();
        CGFloat sc = (v.valid && v.stretch >= 0) ? 1.0 + XC_STRETCH_MAX * v.stretch : 1.0;
        CGFloat h = host.bounds.size.height;
        ui.hostH = h;
        CGPoint tl = [host convertPoint:CGPointZero toView:root];
        CGPoint tr = [host convertPoint:CGPointMake(host.bounds.size.width, 0) toView:root];
        c = CGPointMake(tr.x - 14, tl.y + h * sc + 4);
    }
    c.x = MAX(30, MIN(W - 30, c.x));
    c.y = MAX(100, MIN(H - 150, c.y));
    ui.handle.center = c;
    ui.handle.hidden = NO;
    [root bringSubviewToFront:ui.handle];
}

static void SyncAll(void) {
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:w];
        NSUInteger i = 0;
        while (i < q.count && i < 4000) {
            UIView *v = q[i++];
            if (IsClass(v, @"CSProminentTimeView")) {
                XCSyncHostTransform(v);
            }
            [q addObjectsFromArray:v.subviews];
        }
    }
    Reposition();
}

static void InstallHandle(XCUI *ui, UIView *root) {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];
    UIView *c = [[UIView alloc] initWithFrame:CGRectMake(9, 9, 34, 34)];
    c.backgroundColor = UIColor.whiteColor;
    c.layer.cornerRadius = 17;
    c.userInteractionEnabled = NO;
    c.layer.shadowColor = UIColor.blackColor.CGColor;
    c.layer.shadowOpacity = 0.4;
    c.layer.shadowRadius = 5;
    c.layer.shadowOffset = CGSizeMake(0, 2);
    UIImage *img = [UIImage systemImageNamed:@"arrow.up.and.down"];
    if (img) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.tintColor = UIColor.blackColor;
        iv.frame = CGRectInset(c.bounds, 8, 8);
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [c addSubview:iv];
    } else {
        UILabel *l = [[UILabel alloc] initWithFrame:c.bounds];
        l.text = @"⇅";
        l.textAlignment = NSTextAlignmentCenter;
        l.textColor = UIColor.blackColor;
        [c addSubview:l];
    }
    [h addSubview:c];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:ui action:@selector(pan:)];
    [h addGestureRecognizer:pan];
    h.center = CGPointMake(root.bounds.size.width - 34, 230);
    [root addSubview:h];
    ui.handle = h;
}

static void HookButtons(XCUI *ui, int attempt) {
    UIWindow *w = ui.root.window;
    UIView *done = nil;
    UIView *cancel = nil;
    if (w) {
        done = FindView(w, ^BOOL(UIView *v) {
            return IsClass(v, @"PREditingDoneButton") && v.window && !v.isHidden;
        });
        cancel = FindView(w, ^BOOL(UIView *v) {
            return IsClass(v, @"PREditingCancelButton") && v.window && !v.isHidden;
        });
    }
    if (done && cancel) {
        [(UIControl *)done addTarget:ui action:@selector(done) forControlEvents:UIControlEventTouchUpInside];
        [(UIControl *)cancel addTarget:ui action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
        ui.hasButtons = YES;
        ui.settled = YES;
        XCLogf(@"buttons hooked");
        return;
    }
    if (attempt < 4) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (gUI == ui) HookButtons(ui, attempt + 1);
        });
        return;
    }
    ui.settled = YES;
    XCLogf(@"buttons NOT found -> commit on change");
}

static UIViewController *FindRootVC(UIViewController *vc) {
    Class rc = NSClassFromString(@"PREditorRootViewController");
    UIViewController *c = vc;
    for (int i = 0; c && i < 12; i++) {
        if (rc && [c isKindOfClass:rc]) return c;
        c = c.parentViewController ?: c.presentingViewController;
    }
    return nil;
}

static XCUI *EnsureEditor(UIViewController *anyVC) {
    UIViewController *rootVC = FindRootVC(anyVC);
    if (!rootVC) {
        XCLogf(@"no root vc for %@", NSStringFromClass(anyVC.class));
        return gUI;
    }
    XCUI *ui = objc_getAssociatedObject(rootVC, kRootKey);
    if (ui) {
        gUI = ui;
        return ui;
    }
    NSUUID *uuid = FindPosterUUID(rootVC);
    XCEditBegin(uuid);
    ui = [XCUI new];
    ui.rootVC = rootVC;
    ui.root = rootVC.view;
    gUI = ui;
    objc_setAssociatedObject(rootVC, kRootKey, ui, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    InstallHandle(ui, rootVC.view);
    HookButtons(ui, 0);
    for (int k = 1; k <= 3; k++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(k * 400) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            Reposition();
        });
    }
    if (!uuid) {
        __weak XCUI *wui = ui;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            XCUI *u = wui;
            if (!u || gUI != u) return;
            NSUUID *u2 = FindPosterUUID(u.rootVC);
            if (u2) {
                XCEditBegin(u2);
                XCLogf(@"uuid retry ok");
            }
        });
    }
    XCLogf(@"editor ready uuid=%@ root=%@", uuid.UUIDString ?: @"(none)", NSStringFromClass(rootVC.class));
    return ui;
}

static void RootGone(UIViewController *vc) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (vc.viewIfLoaded.window) return;
        XCUI *ui = objc_getAssociatedObject(vc, kRootKey);
        if (!ui) return;
        [ui.handle removeFromSuperview];
        objc_setAssociatedObject(vc, kRootKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (gUI == ui) gUI = nil;
        XCEditEnd();
        XCLogf(@"editor gone");
    });
}

static UILabel *Lbl(NSString *t) {
    UILabel *l = [UILabel new];
    l.text = t;
    l.textColor = UIColor.labelColor;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [l setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return l;
}

static UISlider *Sld(double val) {
    UISlider *s = [UISlider new];
    s.minimumValue = 0;
    s.maximumValue = 1;
    s.value = (float)val;
    return s;
}

static void InstallPanel(UIViewController *vc) {
    @try {
        if (objc_getAssociatedObject(vc, kPanelKey)) return;
        XCUI *ui = gUI;
        if (!ui) {
            ui = [XCUI new];
            ui.settled = YES;
            gUI = ui;
            XCEditBegin(FindPosterUUID(vc));
            XCLogf(@"panel: standalone ui (no root found)");
        }
        UIStackView *rs = nil;
        @try { rs = [vc valueForKey:@"rootStackView"]; } @catch (...) {}
        if (![rs isKindOfClass:UIStackView.class]) {
            XCLogf(@"panel: no rootStackView");
            return;
        }
        XCStyleValue v = XCEditGet();
        UISwitch *sw = [UISwitch new];
        sw.on = v.valid && v.glass;
        UISlider *cl = Sld(v.clarity);
        UISlider *ds = Sld(v.distortion);
        ui.sw = sw;
        ui.clarity = cl;
        ui.distortion = ds;
        [sw addTarget:ui action:@selector(switched) forControlEvents:UIControlEventValueChanged];
        [cl addTarget:ui action:@selector(slid) forControlEvents:UIControlEventValueChanged];
        [ds addTarget:ui action:@selector(slid) forControlEvents:UIControlEventValueChanged];
        UIControlEvents up = UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel;
        [cl addTarget:ui action:@selector(tail) forControlEvents:up];
        [ds addTarget:ui action:@selector(tail) forControlEvents:up];
        UIStackView *hs = [[UIStackView alloc] initWithArrangedSubviews:@[Lbl(@"Glass"), sw, Lbl(@"Trong"), cl, Lbl(@"Biến dạng"), ds]];
        hs.axis = UILayoutConstraintAxisHorizontal;
        hs.alignment = UIStackViewAlignmentCenter;
        hs.spacing = 8;
        hs.translatesAutoresizingMaskIntoConstraints = NO;
        UIView *row = [UIView new];
        [row addSubview:hs];
        NSLayoutConstraint *ht = [row.heightAnchor constraintEqualToConstant:44];
        ht.priority = 999;
        [NSLayoutConstraint activateConstraints:@[ht,
            [hs.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:23],
            [hs.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-23],
            [hs.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]]];
        [cl.widthAnchor constraintEqualToAnchor:ds.widthAnchor].active = YES;
        [rs addArrangedSubview:row];
        rs.spacing = MIN(rs.spacing, 6.0);
        objc_setAssociatedObject(vc, kPanelKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [rs setNeedsLayout];
        [vc.view setNeedsLayout];
        XCLogf(@"panel installed");
    } @catch (NSException *e) {
        XCLogf(@"panel exception %@", e);
    }
}

static void HandleAppear(UIViewController *vc) {
    Class rc = NSClassFromString(@"PREditorRootViewController");
    Class pc = NSClassFromString(@"PREditingFontAndColorPickerViewController");
    if (rc && [vc isKindOfClass:rc]) {
        EnsureEditor(vc);
        return;
    }
    if (pc && [vc isKindOfClass:pc]) {
        EnsureEditor(vc);
        InstallPanel(vc);
    }
}

static void HandleDisappear(UIViewController *vc) {
    Class rc = NSClassFromString(@"PREditorRootViewController");
    if (rc && [vc isKindOfClass:rc]) {
        RootGone(vc);
    }
}

%group SBGroup
%hook PBUIPosterViewController
- (void)viewDidAppear:(BOOL)a {
    %orig;
    XCSetActivePosterVC((UIViewController *)self);
}
%end
%end

%group EditorGroup
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    HandleAppear((UIViewController *)self);
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    HandleDisappear((UIViewController *)self);
}
%end
%end

static BOOL gInitSB, gInitEd;

static void TryInit(BOOL sb, int n) {
    if (sb) {
        if (!gInitSB && objc_getClass("PBUIPosterViewController")) {
            gInitSB = YES;
            %init(SBGroup);
            XCLogf(@"init SBGroup");
        }
    } else {
        if (!gInitEd && objc_getClass("PREditingFontAndColorPickerViewController")) {
            gInitEd = YES;
            %init(EditorGroup);
            XCLogf(@"init EditorGroup");
        }
    }
    BOOL done = sb ? gInitSB : gInitEd;
    if (!done && n < 15) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            TryInit(sb, n + 1);
        });
    }
}

%ctor {
    @autoreleasepool {
        BOOL sb = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
        xcObservePreferenceReload(^{
            SyncAll();
        });
        TryInit(sb, 0);
    }
}
