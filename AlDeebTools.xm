// أدوات سوفيت (AlDeeb) — ميزات أُعيدت كتابتها داخل Aflatoon Suite
// ملف مستقل: لا يعتمد على Tweak.xm إلا بنافذة DSMiniWindow (تمرّر اللمس + تستثنيها حساسية الكيبورد).
//
// الميزات:
//   1) تزييف الموقع (CLLocation) + مفضلة
//   2) نمط الشبكة: سرعة / متوازن / ثبات (على جلسات NSURLSession الجديدة) + فحص الشبكة
//   3) توفير البطارية (حد 30 إطار/ث + تخفيف السطوع)
//   4) حارس الجهاز (إيقاف تلقائي بعد 30ث + توقف عند ارتفاع الحرارة)
//   5) النقر التلقائي: نص عنصر أو نقطة، خطوتان A ثم B (150ms)، حد أقصى 30 نقرة/ث
//   6) تسجيل اللمسات وتشغيلها + تصدير سكربت .lua
//   7) إزالة شاشة التحديث (YallaUpdateView)
//
// ملاحظة: النقر يعمل على عناصر UIKit (أزرار + إيماءات tap) ولا يحاكي لمساً حقيقياً داخل محرك الرسم.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/runtime.h>
#include <objc/message.h>

#pragma mark - الحالة والحفظ

static volatile BOOL gADLocOn = NO;
static volatile double gADLat = 33.3152, gADLon = 44.3661;
static volatile NSInteger gADNet = 0;          // 0 إيقاف، 1 سرعة، 2 متوازن، 3 ثبات
static volatile BOOL gADBattery = NO;
static volatile BOOL gADRemoveUpdate = NO;
static volatile BOOL gADGuard = YES;
static BOOL gADRecording = NO;
static NSMutableDictionary *gADCfg;
static NSString *const kADCfgKey = @"AflatoonAlDeebCfg";
static NSString *const ADStatusNote = @"ADStatusNote";
static NSString *gADStatus = @"";
static __weak UIWindow *gADPanelWin;
static __weak UIWindow *gADPickWin;

// النقر التلقائي
static NSString *gADTextA = @"", *gADTextB = @"";
static CGPoint gADPtA, gADPtB;
static BOOL gADHasA = NO, gADHasB = NO;
static NSInteger gADCPS = 5;                    // نقرة/ثانية (الحد الأقصى 30)
static BOOL gADEngineOn = NO;
static NSInteger gADTaps = 0;
static double gADEngineT0 = 0, gADPausedUntil = 0;
static __weak UIView *gADCacheA;
static __weak UIView *gADCacheB;

// التسجيل
static NSMutableArray<NSDictionary *> *gADRec;
static double gADRecT0 = 0;
static NSArray<NSDictionary *> *gADLastRec;
static NSInteger gADPlayGen = 0;

static void ADSaveCfg(void) {
    if (gADCfg) [[NSUserDefaults standardUserDefaults] setObject:gADCfg forKey:kADCfgKey];
}

static void ADStatus(NSString *s) {
    gADStatus = s ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ADStatusNote object:nil];
    });
}

static NSArray *ADSeedFavs(void) {
    return @[ @{@"n": @"بغداد", @"lat": @33.3152, @"lon": @44.3661},
              @{@"n": @"الرياض", @"lat": @24.7136, @"lon": @46.6753},
              @{@"n": @"دبي", @"lat": @25.2048, @"lon": @55.2708},
              @{@"n": @"القاهرة", @"lat": @30.0444, @"lon": @31.2357},
              @{@"n": @"إسطنبول", @"lat": @41.0082, @"lon": @28.9784},
              @{@"n": @"لندن", @"lat": @51.5072, @"lon": @-0.1276} ];
}

static NSString *ADDir(void) {
    NSString *base = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *d = [base stringByAppendingPathComponent:@"AlDeeb"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void ADLoadLastRec(void) {
    NSString *name = gADCfg[@"lastRec"];
    if (![name isKindOfClass:NSString.class] || !name.length) return;
    NSData *d = [NSData dataWithContentsOfFile:[ADDir() stringByAppendingPathComponent:[name stringByAppendingString:@".json"]]];
    if (!d) return;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if ([j isKindOfClass:NSArray.class]) gADLastRec = j;
}

static void ADLoadCfg(void) {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kADCfgKey];
    gADCfg = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
    gADLocOn = [gADCfg[@"locOn"] boolValue];
    if (gADCfg[@"lat"]) gADLat = [gADCfg[@"lat"] doubleValue];
    if (gADCfg[@"lon"]) gADLon = [gADCfg[@"lon"] doubleValue];
    gADNet = [gADCfg[@"net"] integerValue];
    gADBattery = [gADCfg[@"battery"] boolValue];
    gADRemoveUpdate = [gADCfg[@"removeUpdate"] boolValue];
    gADGuard = gADCfg[@"guard"] ? [gADCfg[@"guard"] boolValue] : YES;
    if (![gADCfg[@"fav"] isKindOfClass:NSArray.class]) gADCfg[@"fav"] = ADSeedFavs();
    gADTextA = [gADCfg[@"textA"] isKindOfClass:NSString.class] ? gADCfg[@"textA"] : @"";
    gADTextB = [gADCfg[@"textB"] isKindOfClass:NSString.class] ? gADCfg[@"textB"] : @"";
    NSArray *pa = gADCfg[@"ptA"], *pb = gADCfg[@"ptB"];
    if ([pa isKindOfClass:NSArray.class] && pa.count == 2) { gADHasA = YES; gADPtA = CGPointMake([pa[0] doubleValue], [pa[1] doubleValue]); }
    if ([pb isKindOfClass:NSArray.class] && pb.count == 2) { gADHasB = YES; gADPtB = CGPointMake([pb[0] doubleValue], [pb[1] doubleValue]); }
    if (gADCfg[@"cps"]) gADCPS = MAX(1, MIN(30, [gADCfg[@"cps"] integerValue]));
    ADLoadLastRec();
}

#pragma mark - نمط الشبكة (يُطبّق على إعدادات NSURLSession الجديدة)

static void ADApplyNet(NSURLSessionConfiguration *c) {
    if (!c || gADNet <= 0) return;
    if (gADNet == 1) {            // سرعة
        c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 60;
        c.networkServiceType = NSURLNetworkServiceTypeResponsiveData;
        c.HTTPShouldUsePipelining = YES;
    } else if (gADNet == 2) {     // متوازن
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 120;
    } else {                      // ثبات
        c.timeoutIntervalForRequest = 60; c.timeoutIntervalForResource = 300;
        c.waitsForConnectivity = YES;
    }
}

static void ADNetDiagnose(void (^done)(NSString *)) {
    NSArray *names = @[@"Google", @"Cloudflare"];
    NSArray *urls = @[@"https://www.gstatic.com/generate_204", @"https://1.1.1.1/cdn-cgi/trace"];
    NSMutableArray *res = [NSMutableArray arrayWithObjects:@(-1), @(-1), nil];
    dispatch_group_t g = dispatch_group_create();
    for (NSUInteger i = 0; i < urls.count; i++) {
        dispatch_group_enter(g);
        NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urls[i]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
        double t0 = CACurrentMediaTime();
        [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            @synchronized (res) { res[i] = e ? @(-1) : @((CACurrentMediaTime() - t0) * 1000.0); }
            dispatch_group_leave(g);
        }] resume];
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        NSMutableString *s = [NSMutableString string];
        double sum = 0; int ok = 0;
        for (NSUInteger i = 0; i < names.count; i++) {
            double v = [res[i] doubleValue];
            if (v < 0) [s appendFormat:@"%@: فشل  ", names[i]];
            else { [s appendFormat:@"%@: %.0fms  ", names[i], v]; sum += v; ok++; }
        }
        if (!ok) [s appendString:@"— لا اتصال"];
        else {
            double avg = sum / ok;
            [s appendString:avg < 90 ? @"→ الشبكة ممتازة (جرّب سرعة)" : (avg < 220 ? @"→ متوسطة (متوازن)" : @"→ بطيئة (اختر ثبات)")];
        }
        if (done) done(s);
    });
}

#pragma mark - توفير البطارية

static void ADApplyBrightness(BOOL on) {
    UIScreen *s = UIScreen.mainScreen;
    if (on) {
        if (!gADCfg[@"savedBr"]) gADCfg[@"savedBr"] = @(s.brightness);
        if (s.brightness > 0.4) s.brightness = 0.4;
    } else if (gADCfg[@"savedBr"]) {
        s.brightness = [gADCfg[@"savedBr"] doubleValue];
        [gADCfg removeObjectForKey:@"savedBr"];
    }
    ADSaveCfg();
}

static void ADSetBattery(BOOL on) {
    gADBattery = on; gADCfg[@"battery"] = @(on); ADSaveCfg();
    dispatch_async(dispatch_get_main_queue(), ^{ ADApplyBrightness(on); });
}

#pragma mark - النوافذ والعثور على العناصر

static UIWindowScene *ADActiveScene(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:UIWindowScene.class] && sc.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)sc;
    }
    return nil;
}

static NSArray<UIWindow *> *ADWindowsTopDown(void) {
    NSMutableArray<UIWindow *> *a = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w.hidden || w.alpha < 0.01 || w == gADPanelWin || w == gADPickWin) continue;
            [a addObject:w];
        }
    }
    [a sortUsingComparator:^NSComparisonResult(UIWindow *x, UIWindow *y) {
        if (x.windowLevel > y.windowLevel) return NSOrderedAscending;
        if (x.windowLevel < y.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return a;
}

static UIView *ADSearchText(UIView *v, NSString *needle, int depth) {
    if (!v || v.hidden || v.alpha < 0.05 || depth > 40) return nil;
    NSString *s = nil;
    if ([v isKindOfClass:UILabel.class]) s = ((UILabel *)v).text;
    else if ([v isKindOfClass:UIButton.class]) s = [(UIButton *)v titleForState:UIControlStateNormal];
    if (!s.length) s = v.accessibilityLabel;
    if (s.length && [s rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return v;
    for (UIView *sv in [v.subviews reverseObjectEnumerator]) {
        UIView *r = ADSearchText(sv, needle, depth + 1);
        if (r) return r;
    }
    return nil;
}

static UIView *ADFindViewWithText(NSString *text) {
    for (UIWindow *w in ADWindowsTopDown()) {
        UIView *r = ADSearchText(w, text, 0);
        if (r) return r;
    }
    return nil;
}

// يشغّل إيماءة tap بإرسال الرسالة إلى أهدافها (best-effort)
static BOOL ADFireTapGesture(UIGestureRecognizer *g) {
    @try {
        NSArray *targets = [g valueForKey:@"_targets"];
        if (![targets isKindOfClass:NSArray.class] || !targets.count) return NO;
        @try { [g setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"]; } @catch (NSException *e) {}
        BOOL fired = NO;
        for (id tg in targets) {
            Ivar ivT = class_getInstanceVariable([tg class], "_target");
            Ivar ivA = class_getInstanceVariable([tg class], "_action");
            if (!ivT || !ivA) continue;
            uint8_t *base = (uint8_t *)(__bridge void *)tg;
            void *rawT = *(void **)(base + ivar_getOffset(ivT));
            SEL act = *(SEL *)(base + ivar_getOffset(ivA));
            id target = (__bridge id)rawT;
            if (target && act && [target respondsToSelector:act]) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, act, g);
                fired = YES;
            }
        }
        return fired;
    } @catch (NSException *e) {
        return NO;
    }
}

static BOOL ADActivate(UIView *v) {
    for (UIView *x = v; x; x = x.superview) {
        if ([x isKindOfClass:UIControl.class] && ((UIControl *)x).enabled) {
            [(UIControl *)x sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        for (UIGestureRecognizer *g in x.gestureRecognizers) {
            if ([g isKindOfClass:UITapGestureRecognizer.class] && g.enabled && ADFireTapGesture(g)) return YES;
        }
    }
    return NO;
}

static BOOL ADTapPoint(CGPoint sp) {
    for (UIWindow *w in ADWindowsTopDown()) {
        CGPoint p = [w convertPoint:sp fromCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
        UIView *v = [w hitTest:p withEvent:nil];
        if (v && ADActivate(v)) return YES;
    }
    return NO;
}

static BOOL ADTapSlot(int slot) {
    NSString *text = slot == 0 ? gADTextA : gADTextB;
    BOOL hasPt = slot == 0 ? gADHasA : gADHasB;
    CGPoint pt = slot == 0 ? gADPtA : gADPtB;
    if (text.length) {
        UIView *v = slot == 0 ? gADCacheA : gADCacheB;
        if (!v || !v.window) {
            v = ADFindViewWithText(text);
            if (slot == 0) gADCacheA = v; else gADCacheB = v;
        }
        if (v && ADActivate(v)) return YES;
        if (slot == 0) gADCacheA = nil; else gADCacheB = nil;
    }
    return hasPt ? ADTapPoint(pt) : NO;
}

#pragma mark - محرك النقر التلقائي + حارس الجهاز

static dispatch_source_t gADTimer;

static void ADEngineStop(NSString *why) {
    if (gADTimer) { dispatch_source_cancel(gADTimer); gADTimer = nil; }
    BOOL was = gADEngineOn;
    gADEngineOn = NO;
    if (was) ADStatus([NSString stringWithFormat:@"%@ — النقرات: %ld", why ?: @"توقّف", (long)gADTaps]);
}

static void ADEngineTick(void) {
    double now = CACurrentMediaTime();
    if (gADGuard && now - gADEngineT0 >= 30.0) { ADEngineStop(@"حارس الجهاز: إيقاف تلقائي بعد 30 ثانية"); return; }
    if (gADGuard && [NSProcessInfo processInfo].thermalState >= NSProcessInfoThermalStateSerious) {
        gADPausedUntil = now + 2.0;   // حرارة عالية: توقف مؤقت
    }
    if (now < gADPausedUntil) return;
    BOOL hasB = gADTextB.length > 0 || gADHasB;
    ADTapSlot(0);
    if (hasB) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gADEngineOn) ADTapSlot(1);
        });
    }
    gADTaps++;
    if (gADTaps % 5 == 1) ADStatus([NSString stringWithFormat:@"يعمل — النقرات: %ld", (long)gADTaps]);
}

static void ADEngineStart(void) {
    if (gADEngineOn) return;
    if (!gADTextA.length && !gADHasA) { ADStatus(@"حدد نص عنصر أو نقطة A أولاً"); return; }
    gADEngineOn = YES; gADTaps = 0; gADEngineT0 = CACurrentMediaTime(); gADPausedUntil = 0;
    gADCacheA = nil; gADCacheB = nil;
    double iv = 1.0 / (double)MAX(1, MIN(30, gADCPS));
    gADTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gADTimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(iv * NSEC_PER_SEC), (uint64_t)(0.002 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gADTimer, ^{ ADEngineTick(); });
    dispatch_resume(gADTimer);
    ADStatus(@"يعمل…");
}

#pragma mark - تسجيل اللمسات وتشغيلها

static void ADRecordEvent(UIEvent *e) {
    if (!gADRecording || e.type != UIEventTypeTouches) return;
    for (UITouch *t in e.allTouches) {
        if (t.phase != UITouchPhaseBegan || !t.window) continue;
        if (t.window == gADPanelWin || t.window == gADPickWin) continue;
        CGPoint p = [t locationInView:t.window];
        CGPoint sp = [t.window convertPoint:p toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
        [gADRec addObject:@{@"t": @(CACurrentMediaTime() - gADRecT0), @"x": @(sp.x), @"y": @(sp.y)}];
    }
}

static NSString *ADSaveRecording(NSArray<NSDictionary *> *rec) {
    if (!rec.count) return nil;
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *name = [@"rec_" stringByAppendingString:[f stringFromDate:[NSDate date]]];
    NSData *json = [NSJSONSerialization dataWithJSONObject:rec options:0 error:nil];
    [json writeToFile:[ADDir() stringByAppendingPathComponent:[name stringByAppendingString:@".json"]] atomically:YES];
    NSMutableString *lua = [NSMutableString stringWithString:@"-- AutoTouch Script Generated by Aflatoon Suite\n"];
    double prev = 0;
    for (NSDictionary *e in rec) {
        double t = [e[@"t"] doubleValue];
        long gap = (long)((t - prev) * 1000000.0);
        if (gap > 0) [lua appendFormat:@"usleep(%ld)\n", gap];
        [lua appendFormat:@"tap(%.1f, %.1f)\n", [e[@"x"] doubleValue], [e[@"y"] doubleValue]];
        prev = t;
    }
    [lua writeToFile:[ADDir() stringByAppendingPathComponent:[name stringByAppendingString:@".lua"]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    gADCfg[@"lastRec"] = name; ADSaveCfg();
    gADLastRec = [rec copy];
    return name;
}

static void ADStopPlay(void) { gADPlayGen++; }

static void ADPlay(NSArray<NSDictionary *> *rec, void (^done)(void)) {
    NSInteger gen = ++gADPlayGen;
    double last = 0;
    for (NSDictionary *e in rec) {
        double t = [e[@"t"] doubleValue]; if (t > last) last = t;
        CGPoint p = CGPointMake([e[@"x"] doubleValue], [e[@"y"] doubleValue]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen == gADPlayGen) ADTapPoint(p);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((last + 0.3) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == gADPlayGen && done) done();
    });
}

#pragma mark - Hooks

%group ADHooks

%hook CLLocation
- (CLLocationCoordinate2D)coordinate {
    if (gADLocOn) return CLLocationCoordinate2DMake(gADLat, gADLon);
    return %orig;
}
%end

%hook CLLocationManager
- (CLLocation *)location {
    CLLocation *l = %orig;
    if (!gADLocOn) return l;
    CLLocationCoordinate2D c = CLLocationCoordinate2DMake(gADLat, gADLon);
    return [[CLLocation alloc] initWithCoordinate:c altitude:(l ? l.altitude : 0)
                               horizontalAccuracy:(l ? l.horizontalAccuracy : 5)
                                 verticalAccuracy:(l ? l.verticalAccuracy : 5)
                                        timestamp:[NSDate date]];
}
%end

%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    ADApplyNet(c);
    return c;
}
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    ADApplyNet(c);
    return c;
}
%end

%hook CADisplayLink
- (void)setPreferredFramesPerSecond:(NSInteger)fps {
    if (gADBattery && (fps == 0 || fps > 30)) fps = 30;
    %orig(fps);
}
- (void)addToRunLoop:(NSRunLoop *)rl forMode:(NSRunLoopMode)mode {
    if (gADBattery) {
        NSInteger f = self.preferredFramesPerSecond;
        if (f == 0 || f > 30) self.preferredFramesPerSecond = 30;
    }
    %orig;
}
%end

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    ADRecordEvent(event);
}
%end

%end

// إزالة شاشة التحديث: hook يدوي (الكلاس قد لا يوجد في كل نسخة من اللعبة)
static void (*orig_YUV_didMoveToWindow)(id, SEL);
static void new_YUV_didMoveToWindow(id self_, SEL _cmd) {
    if (orig_YUV_didMoveToWindow) orig_YUV_didMoveToWindow(self_, _cmd);
    if (gADRemoveUpdate && [self_ isKindOfClass:UIView.class]) {
        UIView *v = (UIView *)self_;
        if (v.window) { v.hidden = YES; [v removeFromSuperview]; }
    }
}

static void ADInstallUpdateHook(void) {
    Class c = objc_getClass("YallaUpdateView");
    if (!c) return;
    SEL s = @selector(didMoveToWindow);
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    orig_YUV_didMoveToWindow = (void (*)(id, SEL))method_getImplementation(m);
    class_replaceMethod(c, s, (IMP)new_YUV_didMoveToWindow, method_getTypeEncoding(m));
}

#pragma mark - عناصر واجهة صغيرة

@interface ADBtn : UIButton
@property (nonatomic, copy) void (^act)(ADBtn *b);
@property (nonatomic, copy) void (^longAct)(ADBtn *b);
@end
@implementation ADBtn
- (void)fire { if (self.act) self.act(self); }
- (void)lp:(UILongPressGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateBegan && self.longAct) self.longAct(self); }
@end

@interface ADSw : UISwitch
@property (nonatomic, copy) void (^chg)(BOOL on);
@end
@implementation ADSw
- (void)changed { if (self.chg) self.chg(self.isOn); }
@end

static UIColor *ADGreen(void) { return [UIColor colorWithRed:0.0 green:0.96 blue:0.63 alpha:1]; }
static UIColor *ADCyan(void)  { return [UIColor colorWithRed:0.0 green:0.83 blue:1.0 alpha:1]; }
static UIColor *ADRed(void)   { return [UIColor colorWithRed:1.0 green:0.32 blue:0.38 alpha:1]; }
static UIColor *ADAmber(void) { return [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:1]; }

static void ADStyleBtn(ADBtn *b, NSString *title, UIColor *c) {
    [b setTitle:title forState:UIControlStateNormal];
    b.tintColor = c; [b setTitleColor:c forState:UIControlStateNormal];
    b.backgroundColor = [c colorWithAlphaComponent:0.14];
    b.layer.borderColor = [c colorWithAlphaComponent:0.5].CGColor;
}

static ADBtn *ADMakeBtn(NSString *title, UIColor *c, void (^act)(ADBtn *)) {
    ADBtn *b = [ADBtn buttonWithType:UIButtonTypeSystem];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES; b.titleLabel.minimumScaleFactor = 0.7;
    b.layer.cornerRadius = 8; b.layer.borderWidth = 0.8;
    ADStyleBtn(b, title, c);
    [b.heightAnchor constraintEqualToConstant:32].active = YES;
    b.act = act;
    [b addTarget:b action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UILabel *ADLabel(NSString *t, CGFloat size, UIColor *c, BOOL bold) {
    UILabel *l = [UILabel new];
    l.text = t; l.textColor = c; l.numberOfLines = 0; l.textAlignment = NSTextAlignmentRight;
    l.font = [UIFont systemFontOfSize:size weight:(bold ? UIFontWeightBold : UIFontWeightRegular)];
    return l;
}

static UITextField *ADField(NSString *ph, NSString *text, UIKeyboardType kt) {
    UITextField *f = [UITextField new];
    f.attributedPlaceholder = [[NSAttributedString alloc] initWithString:(ph ?: @"")
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.4]}];
    f.text = text; f.textColor = UIColor.whiteColor; f.font = [UIFont systemFontOfSize:13];
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1]; f.layer.cornerRadius = 7;
    f.keyboardType = kt; f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.returnKeyType = UIReturnKeyDone;
    f.textAlignment = NSTextAlignmentCenter; f.clearButtonMode = UITextFieldViewModeWhileEditing;
    [f.heightAnchor constraintEqualToConstant:32].active = YES;
    return f;
}

static UIStackView *ADRow(NSArray<UIView *> *views, BOOL equal) {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisHorizontal; s.spacing = 6;
    s.distribution = equal ? UIStackViewDistributionFillEqually : UIStackViewDistributionFill;
    s.alignment = UIStackViewAlignmentCenter;
    return s;
}

static UIView *ADSwitchRow(NSString *title, BOOL on, void (^chg)(BOOL)) {
    UILabel *l = ADLabel(title, 12, UIColor.whiteColor, NO);
    ADSw *sw = [ADSw new]; sw.on = on; sw.chg = chg; sw.onTintColor = ADGreen();
    [sw addTarget:sw action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [sw setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [sw setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return ADRow(@[sw, l], NO);
}

static UIView *ADCard(NSString *title, UIColor *c, NSArray<UIView *> *rows) {
    UIStackView *inner = [[UIStackView alloc] initWithArrangedSubviews:rows];
    inner.axis = UILayoutConstraintAxisVertical; inner.spacing = 6;
    UILabel *t = ADLabel(title, 12, c, YES);
    UIStackView *wrap = [[UIStackView alloc] initWithArrangedSubviews:@[t, inner]];
    wrap.axis = UILayoutConstraintAxisVertical; wrap.spacing = 6;
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *box = [UIView new];
    box.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    box.layer.cornerRadius = 10; box.layer.borderWidth = 0.6;
    box.layer.borderColor = [c colorWithAlphaComponent:0.45].CGColor;
    [box addSubview:wrap];
    [NSLayoutConstraint activateConstraints:@[
        [wrap.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],
        [wrap.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
        [wrap.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8],
        [wrap.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8]]];
    return box;
}

static NSString *ADThermalText(void) {
    switch ([NSProcessInfo processInfo].thermalState) {
        case NSProcessInfoThermalStateNominal: return @"طبيعية";
        case NSProcessInfoThermalStateFair: return @"دافئة";
        case NSProcessInfoThermalStateSerious: return @"مرتفعة (توقف مؤقت)";
        case NSProcessInfoThermalStateCritical: return @"حرجة";
    }
    return @"—";
}

static void ADToolsSetOnInternal(BOOL on);

#pragma mark - تحديد نقطة بالمس

@interface ADPickVC : UIViewController
@property (nonatomic, copy) void (^done)(CGPoint sp);
@end
@implementation ADPickVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    UILabel *l = ADLabel(@"المس الشاشة في المكان المطلوب", 16, UIColor.whiteColor, YES);
    l.textAlignment = NSTextAlignmentCenter; l.frame = CGRectMake(0, 80, 10, 30);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    CGRect f = l.frame; f.size.width = self.view.bounds.size.width; l.frame = f;
    [self.view addSubview:l];
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap:)]];
}
- (void)tap:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.view];
    CGPoint sp = [self.view.window convertPoint:p toCoordinateSpace:UIScreen.mainScreen.coordinateSpace];
    UIWindow *w = self.view.window;
    void (^cb)(CGPoint) = self.done;
    w.hidden = YES;
    objc_setAssociatedObject(self, "ADPickKeep", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // يفكّ الإمساك بالنافذة
    if (cb) cb(sp);
}
@end

static void ADPickPoint(void (^done)(CGPoint)) {
    UIWindowScene *scene = ADActiveScene();
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    ADPickVC *vc = [ADPickVC new]; vc.done = done;
    w.windowLevel = UIWindowLevelAlert + 400;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = vc; w.hidden = NO;
    gADPickWin = w;
    objc_setAssociatedObject(vc, "ADPickKeep", w, OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // يبقيها حيّة حتى تُلمس
}

#pragma mark - لوحة الأدوات

@interface ADPanelVC : UIViewController <UITextFieldDelegate>
@end

@implementation ADPanelVC {
    UIView *_panel, *_header;
    UIScrollView *_scroll;
    UIStackView *_stack, *_favStack;
    BOOL _collapsed, _placed;
    UITextField *_latF, *_lonF, *_textAF, *_textBF;
    UILabel *_netLbl, *_thermLbl, *_engLbl, *_recLbl, *_ptLbl;
    ADBtn *_engBtn, *_recBtn, *_playBtn;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    _panel = [[UIView alloc] initWithFrame:CGRectMake(10, 60, 310, 440)];
    _panel.backgroundColor = [UIColor colorWithRed:0.07 green:0.06 blue:0.12 alpha:0.97];
    _panel.layer.cornerRadius = 14; _panel.layer.borderWidth = 1.2; _panel.clipsToBounds = YES;
    _panel.layer.borderColor = [ADGreen() colorWithAlphaComponent:0.7].CGColor;
    [self.view addSubview:_panel];

    _header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 310, 34)];
    _header.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1];
    [_panel addSubview:_header];
    UILabel *title = ADLabel(@"أدوات سوفيت", 13, UIColor.whiteColor, YES);
    title.frame = CGRectMake(76, 0, 224, 34);
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
    [_header addSubview:title];
    __weak typeof(self) ws = self;
    ADBtn *close = ADMakeBtn(@"✕", ADRed(), ^(ADBtn *b) { ADToolsSetOnInternal(NO); });
    close.frame = CGRectMake(6, 3, 30, 28); close.translatesAutoresizingMaskIntoConstraints = YES;
    for (NSLayoutConstraint *c in close.constraints) c.active = NO;
    [_header addSubview:close];
    ADBtn *fold = ADMakeBtn(@"–", ADAmber(), ^(ADBtn *b) { [ws toggleCollapse]; });
    fold.frame = CGRectMake(40, 3, 30, 28); fold.translatesAutoresizingMaskIntoConstraints = YES;
    for (NSLayoutConstraint *c in fold.constraints) c.active = NO;
    [_header addSubview:fold];
    [_header addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 34, 310, 406)];
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [_panel addSubview:_scroll];
    _stack = [UIStackView new];
    _stack.axis = UILayoutConstraintAxisVertical; _stack.spacing = 8;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:8],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-10],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:8],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-8],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-16]]];

    [self buildSections];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshStatus) name:ADStatusNote object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshStatus) name:NSProcessInfoThermalStateDidChangeNotification object:nil];
    [self refreshStatus];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_placed || self.view.bounds.size.width < 10) return;
    _placed = YES;
    CGFloat w = MIN(310, self.view.bounds.size.width - 16);
    CGFloat h = MIN(460, self.view.bounds.size.height - 120);
    CGFloat top = MAX(self.view.safeAreaInsets.top, 20) + 50;
    _panel.frame = CGRectMake(8, top, w, h);
    _header.frame = CGRectMake(0, 0, w, 34);
    _scroll.frame = CGRectMake(0, 34, w, h - 34);
}

- (void)toggleCollapse {
    _collapsed = !_collapsed;
    CGRect f = _panel.frame;
    CGFloat full = MIN(460, self.view.bounds.size.height - 120);
    f.size.height = _collapsed ? 34 : full;
    _scroll.hidden = _collapsed;
    _panel.frame = f;
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    CGRect f = _panel.frame, b = self.view.bounds;
    f.origin.x = MAX(2, MIN(b.size.width - f.size.width - 2, f.origin.x + t.x));
    f.origin.y = MAX(20, MIN(b.size.height - 44, f.origin.y + t.y));
    _panel.frame = f; [g setTranslation:CGPointZero inView:self.view];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

- (void)refreshStatus {
    _thermLbl.text = [NSString stringWithFormat:@"حرارة الجهاز: %@", ADThermalText()];
    _engLbl.text = gADStatus.length ? gADStatus : @"جاهز";
    ADStyleBtn(_engBtn, gADEngineOn ? @"إيقاف ■" : @"ابدأ النقر ▶", gADEngineOn ? ADRed() : ADGreen());
}

- (void)updatePtLabel {
    NSString *a = gADHasA ? [NSString stringWithFormat:@"(%.0f,%.0f)", gADPtA.x, gADPtA.y] : @"—";
    NSString *b = gADHasB ? [NSString stringWithFormat:@"(%.0f,%.0f)", gADPtB.x, gADPtB.y] : @"—";
    _ptLbl.text = [NSString stringWithFormat:@"A: %@    B: %@", a, b];
}

- (void)savePointCfg {
    if (gADHasA) gADCfg[@"ptA"] = @[@(gADPtA.x), @(gADPtA.y)]; else [gADCfg removeObjectForKey:@"ptA"];
    if (gADHasB) gADCfg[@"ptB"] = @[@(gADPtB.x), @(gADPtB.y)]; else [gADCfg removeObjectForKey:@"ptB"];
    gADCfg[@"textA"] = gADTextA ?: @""; gADCfg[@"textB"] = gADTextB ?: @"";
    gADCfg[@"cps"] = @(gADCPS);
    ADSaveCfg();
}

- (void)applyCoords {
    double la = [[_latF.text stringByReplacingOccurrencesOfString:@"," withString:@"."] doubleValue];
    double lo = [[_lonF.text stringByReplacingOccurrencesOfString:@"," withString:@"."] doubleValue];
    if (la < -90 || la > 90 || lo < -180 || lo > 180) { ADStatus(@"إحداثيات غير صحيحة"); [self refreshStatus]; return; }
    gADLat = la; gADLon = lo;
    gADCfg[@"lat"] = @(la); gADCfg[@"lon"] = @(lo); ADSaveCfg();
    ADStatus([NSString stringWithFormat:@"الموقع: %.4f, %.4f", la, lo]);
}

- (void)rebuildFavs {
    for (UIView *v in [_favStack.arrangedSubviews copy]) { [_favStack removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSArray *favs = gADCfg[@"fav"];
    __weak typeof(self) ws = self;
    for (NSUInteger i = 0; i < favs.count; i += 2) {
        NSMutableArray *row = [NSMutableArray array];
        for (NSUInteger j = i; j < MIN(i + 2, favs.count); j++) {
            NSDictionary *f = favs[j];
            ADBtn *b = ADMakeBtn(f[@"n"] ?: @"موقع", ADCyan(), ^(ADBtn *bb) {
                __strong typeof(ws) me = ws; if (!me) return;
                me->_latF.text = [NSString stringWithFormat:@"%.5f", [f[@"lat"] doubleValue]];
                me->_lonF.text = [NSString stringWithFormat:@"%.5f", [f[@"lon"] doubleValue]];
                [me applyCoords];
            });
            b.longAct = ^(ADBtn *bb) {   // ضغطة مطوّلة = حذف
                NSMutableArray *m = [gADCfg[@"fav"] mutableCopy]; [m removeObjectAtIndex:j];
                gADCfg[@"fav"] = m; ADSaveCfg(); [ws rebuildFavs];
            };
            [b addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:b action:@selector(lp:)]];
            [row addObject:b];
        }
        if (row.count == 1) [row addObject:[UIView new]];
        [_favStack addArrangedSubview:ADRow(row, YES)];
    }
}

- (void)saveFav {
    __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"اسم الموقع المفضل" message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"مثال: بيتي"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"حفظ" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        __strong typeof(ws) me = ws; if (!me) return;
        NSString *n = a.textFields.firstObject.text;
        if (!n.length) n = [NSString stringWithFormat:@"موقع %lu", (unsigned long)([gADCfg[@"fav"] count] + 1)];
        double la = [[me->_latF.text stringByReplacingOccurrencesOfString:@"," withString:@"."] doubleValue];
        double lo = [[me->_lonF.text stringByReplacingOccurrencesOfString:@"," withString:@"."] doubleValue];
        NSMutableArray *m = [gADCfg[@"fav"] mutableCopy] ?: [NSMutableArray array];
        [m addObject:@{@"n": n, @"lat": @(la), @"lon": @(lo)}];
        gADCfg[@"fav"] = m; ADSaveCfg(); [me rebuildFavs];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)netChanged:(UISegmentedControl *)s {
    gADNet = s.selectedSegmentIndex; gADCfg[@"net"] = @(gADNet); ADSaveCfg();
    NSArray *t = @[@"الشبكة: الوضع الافتراضي", @"الشبكة: سرعة (مهلة 12ث)", @"الشبكة: متوازن (مهلة 30ث)", @"الشبكة: ثبات (مهلة 60ث + انتظار اتصال)"];
    _netLbl.text = [t[gADNet] stringByAppendingString:@"\nيسري على الجلسات الجديدة بعد التغيير"];
}

- (void)cpsChanged:(UISegmentedControl *)s {
    NSArray *v = @[@1, @5, @10, @20, @30];
    gADCPS = [v[s.selectedSegmentIndex] integerValue];
    [self savePointCfg];
}

- (void)buildSections {
    __weak typeof(self) ws = self;

    // 1) الموقع
    UIView *swLoc = ADSwitchRow(@"تزييف الموقع (GPS)", gADLocOn, ^(BOOL on) {
        gADLocOn = on; gADCfg[@"locOn"] = @(on); ADSaveCfg();
        ADStatus(on ? @"تزييف الموقع مفعّل" : @"رجع الموقع الحقيقي");
    });
    _latF = ADField(@"خط العرض", [NSString stringWithFormat:@"%.5f", gADLat], UIKeyboardTypeNumbersAndPunctuation);
    _lonF = ADField(@"خط الطول", [NSString stringWithFormat:@"%.5f", gADLon], UIKeyboardTypeNumbersAndPunctuation);
    _latF.delegate = self; _lonF.delegate = self;
    ADBtn *apply = ADMakeBtn(@"تطبيق", ADGreen(), ^(ADBtn *b) { [ws.view endEditing:YES]; [ws applyCoords]; });
    ADBtn *favB = ADMakeBtn(@"حفظ كمفضلة", ADCyan(), ^(ADBtn *b) { [ws saveFav]; });
    _favStack = [UIStackView new]; _favStack.axis = UILayoutConstraintAxisVertical; _favStack.spacing = 6;
    UILabel *favHint = ADLabel(@"المفضلة: اضغط للتطبيق، ضغطة مطوّلة للحذف", 10, [UIColor colorWithWhite:1 alpha:0.55], NO);
    [_stack addArrangedSubview:ADCard(@"الموقع", ADCyan(), @[swLoc, ADRow(@[_lonF, _latF], YES), ADRow(@[favB, apply], YES), favHint, _favStack])];
    [self rebuildFavs];

    // 2) الشبكة
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"افتراضي", @"سرعة", @"متوازن", @"ثبات"]];
    seg.selectedSegmentIndex = gADNet; [seg addTarget:self action:@selector(netChanged:) forControlEvents:UIControlEventValueChanged];
    _netLbl = ADLabel(@"", 10, [UIColor colorWithWhite:1 alpha:0.7], NO);
    [self netChanged:seg];
    ADBtn *diag = ADMakeBtn(@"فحص الشبكة", ADAmber(), nil);
    __weak ADBtn *wd = diag;
    diag.act = ^(ADBtn *b) {
        ADStyleBtn(wd, @"يفحص…", ADAmber());
        ADNetDiagnose(^(NSString *r) {
            __strong typeof(ws) me = ws; if (!me) return;
            me->_netLbl.text = r;
            if (wd) ADStyleBtn(wd, @"فحص الشبكة", ADAmber());
        });
    };
    [_stack addArrangedSubview:ADCard(@"نمط الشبكة", ADAmber(), @[seg, diag, _netLbl])];

    // 3) البطارية + الحارس
    UIView *swBat = ADSwitchRow(@"توفير البطارية (30 إطار/ث + سطوع أقل)", gADBattery, ^(BOOL on) { ADSetBattery(on); });
    UIView *swGuard = ADSwitchRow(@"حارس الجهاز (إيقاف بعد 30ث + توقف عند الحرارة)", gADGuard, ^(BOOL on) {
        gADGuard = on; gADCfg[@"guard"] = @(on); ADSaveCfg();
    });
    _thermLbl = ADLabel(@"", 10, [UIColor colorWithWhite:1 alpha:0.7], NO);
    [_stack addArrangedSubview:ADCard(@"البطارية والحماية", ADGreen(), @[swBat, swGuard, _thermLbl])];

    // 4) النقر التلقائي
    _textAF = ADField(@"نص العنصر A (اختياري)", gADTextA, UIKeyboardTypeDefault);
    _textBF = ADField(@"نص العنصر B (اختياري، بعد 150ms)", gADTextB, UIKeyboardTypeDefault);
    _textAF.delegate = self; _textBF.delegate = self;
    [_textAF addTarget:self action:@selector(textsChanged) forControlEvents:UIControlEventEditingChanged];
    [_textBF addTarget:self action:@selector(textsChanged) forControlEvents:UIControlEventEditingChanged];
    ADBtn *pa = ADMakeBtn(@"نقطة A", ADCyan(), ^(ADBtn *b) {
        [ws.view endEditing:YES];
        ADPickPoint(^(CGPoint p) { gADPtA = p; gADHasA = YES; [ws savePointCfg]; [ws updatePtLabel]; });
    });
    ADBtn *pb = ADMakeBtn(@"نقطة B", ADCyan(), ^(ADBtn *b) {
        [ws.view endEditing:YES];
        ADPickPoint(^(CGPoint p) { gADPtB = p; gADHasB = YES; [ws savePointCfg]; [ws updatePtLabel]; });
    });
    ADBtn *clr = ADMakeBtn(@"مسح", ADRed(), ^(ADBtn *b) { gADHasA = gADHasB = NO; [ws savePointCfg]; [ws updatePtLabel]; });
    _ptLbl = ADLabel(@"", 11, UIColor.whiteColor, NO); _ptLbl.textAlignment = NSTextAlignmentCenter;
    [self updatePtLabel];
    UISegmentedControl *cps = [[UISegmentedControl alloc] initWithItems:@[@"1/ث", @"5/ث", @"10/ث", @"20/ث", @"30/ث"]];
    NSArray *vals = @[@1, @5, @10, @20, @30];
    NSInteger idx = 1; for (NSUInteger i = 0; i < vals.count; i++) if ([vals[i] integerValue] == gADCPS) idx = (NSInteger)i;
    cps.selectedSegmentIndex = idx;
    [cps addTarget:self action:@selector(cpsChanged:) forControlEvents:UIControlEventValueChanged];
    _engBtn = ADMakeBtn(@"ابدأ النقر ▶", ADGreen(), ^(ADBtn *b) {
        [ws.view endEditing:YES]; [ws textsChanged];
        if (gADEngineOn) ADEngineStop(@"أوقفته يدوياً"); else ADEngineStart();
        [ws refreshStatus];
    });
    _engLbl = ADLabel(@"", 11, ADGreen(), NO); _engLbl.textAlignment = NSTextAlignmentCenter;
    [_stack addArrangedSubview:ADCard(@"النقر التلقائي (حد أقصى 30/ث)", ADRed(),
        @[_textAF, _textBF, ADRow(@[clr, pb, pa], YES), _ptLbl, cps, _engBtn, _engLbl])];

    // 5) التسجيل
    _recBtn = ADMakeBtn(@"تسجيل ●", ADRed(), ^(ADBtn *b) { [ws toggleRec]; });
    _playBtn = ADMakeBtn(@"تشغيل آخر تسجيل ▶", ADGreen(), ^(ADBtn *b) { [ws togglePlay]; });
    _recLbl = ADLabel(@"يسجّل لمساتك خارج هذه اللوحة، ويحفظها json + lua في Documents/AlDeeb", 10, [UIColor colorWithWhite:1 alpha:0.6], NO);
    [_stack addArrangedSubview:ADCard(@"تسجيل اللمسات", ADCyan(), @[ADRow(@[_playBtn, _recBtn], YES), _recLbl])];

    // 6) متفرقات
    UIView *swUpd = ADSwitchRow(@"إزالة شاشة التحديث", gADRemoveUpdate, ^(BOOL on) {
        gADRemoveUpdate = on; gADCfg[@"removeUpdate"] = @(on); ADSaveCfg();
    });
    [_stack addArrangedSubview:ADCard(@"متفرقات", ADAmber(), @[swUpd])];
}

- (void)textsChanged {
    gADTextA = _textAF.text ?: @""; gADTextB = _textBF.text ?: @"";
    gADCacheA = nil; gADCacheB = nil;
    [self savePointCfg];
}

- (void)toggleRec {
    if (!gADRecording) {
        gADRec = [NSMutableArray array]; gADRecT0 = CACurrentMediaTime(); gADRecording = YES;
        ADStyleBtn(_recBtn, @"إيقاف ■", ADRed());
        _recLbl.text = @"يسجّل… المس الشاشة خارج هذه اللوحة";
    } else {
        gADRecording = NO;
        NSString *name = ADSaveRecording(gADRec);
        ADStyleBtn(_recBtn, @"تسجيل ●", ADRed());
        _recLbl.text = name ? [NSString stringWithFormat:@"حُفظ %@ (%lu لمسة)", name, (unsigned long)gADRec.count] : @"لم تُسجَّل لمسات";
    }
}

- (void)togglePlay {
    if (!gADLastRec.count) { _recLbl.text = @"لا يوجد تسجيل محفوظ"; return; }
    __weak typeof(self) ws = self;
    static BOOL playing = NO;
    if (playing) { ADStopPlay(); playing = NO; ADStyleBtn(_playBtn, @"تشغيل آخر تسجيل ▶", ADGreen()); return; }
    playing = YES; ADStyleBtn(_playBtn, @"إيقاف التشغيل ■", ADRed());
    ADPlay(gADLastRec, ^{
        playing = NO;
        __strong typeof(ws) me = ws;
        if (me) ADStyleBtn(me->_playBtn, @"تشغيل آخر تسجيل ▶", ADGreen());
    });
}
@end

#pragma mark - الواجهة العامة (تستدعيها Tweak.xm)

extern "C" BOOL ADToolsIsOn(void) { return [gADCfg[@"panelOn"] boolValue]; }

extern "C" void ADToolsShow(void) {
    if (gADPanelWin) { gADPanelWin.hidden = NO; return; }
    UIWindowScene *scene = ADActiveScene();
    Class cls = NSClassFromString(@"DSMiniWindow") ?: UIWindow.class;   // تمرّر اللمس + تستثنيها حساسية الكيبورد
    UIWindow *w = scene ? [[cls alloc] initWithWindowScene:scene] : [[cls alloc] initWithFrame:UIScreen.mainScreen.bounds];
    w.windowLevel = UIWindowLevelAlert + 170;
    w.backgroundColor = UIColor.clearColor;
    w.rootViewController = [ADPanelVC new];
    w.hidden = NO;
    gADPanelWin = w;
    objc_setAssociatedObject(UIApplication.sharedApplication, "ADPanelKeep", w, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

extern "C" void ADToolsHide(void) {
    UIWindow *w = gADPanelWin;
    if (w) { w.hidden = YES; objc_setAssociatedObject(UIApplication.sharedApplication, "ADPanelKeep", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    gADPanelWin = nil;
}

extern "C" void ADToolsSetOn(BOOL on) {
    gADCfg[@"panelOn"] = @(on); ADSaveCfg();
    if (on) ADToolsShow(); else ADToolsHide();
}

static void ADToolsSetOnInternal(BOOL on) { ADToolsSetOn(on); }

extern "C" void ADToolsInit(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    ADLoadCfg();
    %init(ADHooks);
    ADInstallUpdateHook();
    if (gADBattery) dispatch_async(dispatch_get_main_queue(), ^{ ADApplyBrightness(YES); });
}
