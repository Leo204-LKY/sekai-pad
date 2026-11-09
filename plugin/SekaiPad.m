// SekaiPad.m — PlayCover 自定义插件（dylib），由 PlayTools 加载进游戏进程。
// 监听 127.0.0.1:47800 的 UDP 包（来自 sekai-pad 助手程序），
// 用 PlayTools 自带的 PTFakeMetaTouch 合成真正的多点触控。
// 不经过 Apple 的「触控替代」，所以不需要按住 Option。

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <os/log.h>

// 用 public 格式输出，否则「控制台」里只显示 <private>
#define SPLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "%{public}@", [NSString stringWithFormat:fmt, ##__VA_ARGS__])
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>

#include "protocol.h"

#define DOT_SIZE 44.0         // 触摸点直径（点）
#define CROSS_RING 36.0       // 十字准星样式的圆环直径（点）
#define CROSS_LINE 1.5        // 十字准星贯穿线粗细（点）
#define CURSOR_TIMEOUT 0.5    // 这么久没收到「开启」包就恢复鼠标
#define MAX_E  SP_MAX_ENT
#define ACK_INTERVAL 0.5     // 回应助手程序的最短间隔
#define TIMEOUT_SEC 0.25     // 助手程序断开/卡住时自动松开所有手指

typedef SpEnt Ent;
typedef struct { BOOL used; int32_t fid; NSInteger pid; CGPoint p; } Slot;

static Slot gSlot[MAX_E];
static NSMutableDictionary<NSNumber *, UIView *> *gViews;
static CFAbsoluteTime gLastPacket;
static Class gPT;
static SEL gSel5, gSel3, gSelAvail;
static BOOL gResolved;
static dispatch_source_t gSrc, gTimer;
static BOOL gGotFirst;
static CFAbsoluteTime gLastOn;
static BOOL gCursorLocked;
static int (*pAssoc)(int);           // CGAssociateMouseAndMouseCursorPosition
static int (*pHide)(uint32_t);       // CGDisplayHideCursor
static int (*pShow)(uint32_t);       // CGDisplayShowCursor
static uint32_t (*pMainDisplay)(void);
static int gBeganLogs;
static id gClickMonitor;              // NSEvent 本地监视器，需持有
typedef enum { DotNormal = SP_STYLE_DOT, DotNone = SP_STYLE_NONE, DotCross = SP_STYLE_CROSS } DotStyle;
static DotStyle gDotStyle = DotNormal;   // 当前样式，来自助手程序
static DotStyle gBuiltStyle = DotNormal; // gDots 里现有视图的样式
static NSMutableDictionary<NSNumber *, UIView *> *gDots;   // 手指 id -> 屏幕上的触摸点

static void Resolve(void) {
    if (gResolved) return;
    gResolved = YES;
    gPT = NSClassFromString(@"PTFakeMetaTouch");
    if (!gPT) { SPLOG(@"[SekaiPad] 找不到 PTFakeMetaTouch（PlayTools 未加载？）"); return; }
    SEL s5 = NSSelectorFromString(@"fakeTouchId:AtPoint:withTouchPhase:inWindow:onView:");
    SEL s3 = NSSelectorFromString(@"fakeTouchId:AtPoint:withTouchPhase:");
    SEL sa = NSSelectorFromString(@"getAvailablePointId");
    if ([gPT respondsToSelector:s5]) gSel5 = s5;
    if ([gPT respondsToSelector:s3]) gSel3 = s3;
    if ([gPT respondsToSelector:sa]) gSelAvail = sa;
    SPLOG(@"[SekaiPad] PTFakeMetaTouch: 5参=%d 3参=%d avail=%d", gSel5 != NULL, gSel3 != NULL, gSelAvail != NULL);
}

static UIWindow *KeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    return fallback;
}

static NSInteger Fake(NSInteger pid, CGPoint p, UITouchPhase ph, UIWindow *w, UIView *v) {
    if (gSel5)
        return ((NSInteger (*)(id, SEL, NSInteger, CGPoint, UITouchPhase, UIWindow *, UIView *))objc_msgSend)
            (gPT, gSel5, pid, p, ph, w, v);
    return ((NSInteger (*)(id, SEL, NSInteger, CGPoint, UITouchPhase))objc_msgSend)(gPT, gSel3, pid, p, ph);
}

// 在注入位置画半透明圆点（类似「触控替代」的点）。
// userInteractionEnabled = NO，不会挡住 hitTest，也不会吃掉触摸。
static UIView *MakeNormalDot(void) {
    UIView *d = [[UIView alloc] initWithFrame:CGRectMake(0, 0, DOT_SIZE, DOT_SIZE)];
    d.userInteractionEnabled = NO;
    d.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    d.layer.cornerRadius = DOT_SIZE / 2;
    d.layer.borderWidth = 2;
    d.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:0.6].CGColor;
    d.layer.zPosition = 10000;
    return d;
}

static UIView *Bar(CGRect f, UIColor *c) {
    UIView *v = [[UIView alloc] initWithFrame:f];
    v.userInteractionEnabled = NO;
    v.backgroundColor = c;
    return v;
}

// 醒目样式（校准用）：贯穿整个窗口的横竖细线 + 品红圆环 + 中心实心点。
// 每条线都是「黑底 + 亮色」两层，在亮/暗背景上都看得清。
// 视图本身是 0x0，所有内容以 (0,0) 为中心向外画，center 就是精确的注入坐标。
static UIView *MakeCrossDot(void) {
    UIView *d = [[UIView alloc] initWithFrame:CGRectZero];
    d.userInteractionEnabled = NO;
    d.clipsToBounds = NO;
    d.layer.zPosition = 10000;

    UIColor *hi = [UIColor colorWithRed:1.0 green:0.15 blue:0.85 alpha:0.95];
    UIColor *hiLine = [UIColor colorWithRed:1.0 green:0.15 blue:0.85 alpha:0.7];
    UIColor *shadow = [UIColor colorWithWhite:0 alpha:0.55];
    const CGFloat L = 4096;            // 足够长，覆盖任何窗口
    const CGFloat t = CROSS_LINE, o = 1; // 亮线粗细，黑边宽度

    // 贯穿线（先画黑边，再画亮线）
    [d addSubview:Bar(CGRectMake(-L, -t / 2 - o, 2 * L, t + 2 * o), shadow)];
    [d addSubview:Bar(CGRectMake(-t / 2 - o, -L, t + 2 * o, 2 * L), shadow)];
    [d addSubview:Bar(CGRectMake(-L, -t / 2, 2 * L, t), hiLine)];
    [d addSubview:Bar(CGRectMake(-t / 2, -L, t, 2 * L), hiLine)];

    // 圆环：外黑边 + 品红
    CGFloat R = CROSS_RING;
    UIView *ringShadow = Bar(CGRectMake(-R / 2 - o, -R / 2 - o, R + 2 * o, R + 2 * o), UIColor.clearColor);
    ringShadow.layer.cornerRadius = R / 2 + o;
    ringShadow.layer.borderWidth = 5 + 2 * o;
    ringShadow.layer.borderColor = shadow.CGColor;
    [d addSubview:ringShadow];
    UIView *ring = Bar(CGRectMake(-R / 2, -R / 2, R, R), UIColor.clearColor);
    ring.layer.cornerRadius = R / 2;
    ring.layer.borderWidth = 4;
    ring.layer.borderColor = hi.CGColor;
    [d addSubview:ring];

    // 中心点：白芯黑边，标出精确位置
    CGFloat c = 6;
    UIView *center = Bar(CGRectMake(-c / 2, -c / 2, c, c), UIColor.whiteColor);
    center.layer.cornerRadius = c / 2;
    center.layer.borderWidth = 1.5;
    center.layer.borderColor = UIColor.blackColor.CGColor;
    [d addSubview:center];
    return d;
}

static UIView *MakeDot(void) {
    return gDotStyle == DotCross ? MakeCrossDot() : MakeNormalDot();
}

static void UpdateDots(UIWindow *w) {
    NSMutableSet<NSNumber *> *alive = [NSMutableSet set];
    if (gBuiltStyle != gDotStyle) {   // 样式变了：丢掉旧视图，下面按新样式重建
        for (UIView *d in gDots.allValues) [d removeFromSuperview];
        [gDots removeAllObjects];
        gBuiltStyle = gDotStyle;
    }
    if (w && gDotStyle != DotNone) {
        for (int k = 0; k < MAX_E; k++) {
            if (!gSlot[k].used) continue;
            NSNumber *key = @(gSlot[k].fid);
            [alive addObject:key];
            UIView *d = gDots[key];
            if (!d) { d = MakeDot(); gDots[key] = d; }
            if (d.superview != w) [w addSubview:d];
            else [w bringSubviewToFront:d];
            d.center = gSlot[k].p;
        }
    }
    for (NSNumber *key in gDots.allKeys) {
        if ([alive containsObject:key]) continue;
        [gDots[key] removeFromSuperview];
        [gDots removeObjectForKey:key];
    }
}

// 在主线程调用：把当前帧的手指集合与上一帧比较，生成 began / moved / ended
static void Apply(const Ent *e, int n) {
    Resolve();
    if (!gPT || (!gSel5 && !gSel3)) return;

    UIWindow *w = KeyWindow();
    static BOOL warned;
    if (!warned && n > 0 && (!w || UIApplication.sharedApplication.applicationState != UIApplicationStateActive)) {
        warned = YES;
        SPLOG(@"[SekaiPad] 忽略触摸：window=%@ state=%ld", w, (long)UIApplication.sharedApplication.applicationState);
    }
    if (!w || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) n = 0;
    CGSize sz = w ? w.bounds.size : CGSizeMake(0, 0);

    // 1. 本帧消失的手指 -> ended
    for (int k = 0; k < MAX_E; k++) {
        if (!gSlot[k].used) continue;
        BOOL found = NO;
        for (int i = 0; i < n; i++) if (e[i].id == gSlot[k].fid) { found = YES; break; }
        if (found) continue;
        if (w) Fake(gSlot[k].pid, gSlot[k].p, UITouchPhaseEnded, w, gViews[@(gSlot[k].fid)] ?: w);
        [gViews removeObjectForKey:@(gSlot[k].fid)];
        gSlot[k].used = NO;
    }

    // 2. 已有手指 -> moved；新手指 -> began
    for (int i = 0; i < n; i++) {
        CGPoint p = CGPointMake(e[i].x * sz.width, e[i].y * sz.height);
        int slot = -1, freeSlot = -1;
        for (int k = 0; k < MAX_E; k++) {
            if (gSlot[k].used && gSlot[k].fid == e[i].id) { slot = k; break; }
            if (!gSlot[k].used && freeSlot < 0) freeSlot = k;
        }
        if (slot >= 0) {
            if (!CGPointEqualToPoint(p, gSlot[slot].p)) {
                Fake(gSlot[slot].pid, p, UITouchPhaseMoved, w, gViews[@(e[i].id)] ?: w);
                gSlot[slot].p = p;
            }
        } else if (freeSlot >= 0) {
            // 新版 PlayTools：传 -1 由它分配编号（从 0 开始）；旧版需先 getAvailablePointId
            NSInteger pid = gSelAvail ? ((NSInteger (*)(id, SEL))objc_msgSend)(gPT, gSelAvail) : -1;
            if (gSelAvail && pid <= 0) continue;
            UIView *v = [w hitTest:p withEvent:nil] ?: w;
            NSInteger got = Fake(pid, p, UITouchPhaseBegan, w, v);
            if (gBeganLogs < 20) {
                gBeganLogs++;
                SPLOG(@"[SekaiPad] began 指#%d (%.0f,%.0f) 窗口%.0fx%.0f view=%@ pid=%ld->%ld",
                      e[i].id, p.x, p.y, sz.width, sz.height, NSStringFromClass(v.class), (long)pid, (long)got);
            }
            pid = got;
            if (pid < 0) continue;
            gSlot[freeSlot] = (Slot){ YES, e[i].id, pid, p };
            gViews[@(e[i].id)] = v;
        }
    }

    UpdateDots(w);
}

// 映射开启 + 游戏在前台时：隐藏鼠标并让它不跟随触控板移动；否则恢复。
// 这些是 macOS 的 CoreGraphics 函数，Catalyst 头文件里没有，用 dlsym 取。
static void SetCursorLocked(BOOL lock) {
    if (lock == gCursorLocked) return;
    static BOOL loaded;
    if (!loaded) {
        loaded = YES;
        pAssoc = dlsym(RTLD_DEFAULT, "CGAssociateMouseAndMouseCursorPosition");
        pHide = dlsym(RTLD_DEFAULT, "CGDisplayHideCursor");
        pShow = dlsym(RTLD_DEFAULT, "CGDisplayShowCursor");
        pMainDisplay = dlsym(RTLD_DEFAULT, "CGMainDisplayID");
        SPLOG(@"[SekaiPad] 鼠标控制函数: assoc=%d hide=%d show=%d", pAssoc != NULL, pHide != NULL, pShow != NULL);
    }
    if (!pAssoc || !pHide || !pShow || !pMainDisplay) return;
    gCursorLocked = lock;
    pAssoc(lock ? 0 : 1);
    if (lock) pHide(pMainDisplay()); else pShow(pMainDisplay());
}

static void UpdateCursor(void) {
    BOOL active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL on = gLastOn > 0 && CFAbsoluteTimeGetCurrent() - gLastOn < CURSOR_TIMEOUT;
    SetCursorLocked(on && active);
}

// 映射开启时，用力按下触控板会产生真实的鼠标点击，落在（已隐藏的）鼠标位置，
// 被游戏当成一次额外的触摸。这里给本进程加一个 NSEvent 本地监视器，
// 映射生效期间吞掉鼠标按键和压力事件。只作用于游戏进程本身，不需要额外权限；
// PTFakeMetaTouch 直接走 UIApplication，不经过 NSEvent，不受影响。
// 按下时被吞掉的点击，对应的松开/拖动也一起吞掉，避免游戏收到孤立的 up。
static void InstallClickBlocker(void) {
    Class ev = NSClassFromString(@"NSEvent");
    SEL sel = NSSelectorFromString(@"addLocalMonitorForEventsMatchingMask:handler:");
    if (!ev || ![ev respondsToSelector:sel]) { SPLOG(@"[SekaiPad] 无法拦截鼠标点击（找不到 NSEvent 本地监视器）"); return; }

    // NSEventType：1/2/6 左键按下/松开/拖动，3/4/7 右键，25/26/27 其他键，34 压力（Force Touch）
    static const int kDown[] = { 1, 3, 25 }, kUp[] = { 2, 4, 26 };
    uint64_t mask = 0;
    for (int i = 0; i < 3; i++) mask |= 1ull << kDown[i] | 1ull << kUp[i];
    mask |= 1ull << 6 | 1ull << 7 | 1ull << 27 | 1ull << 34;

    static int swallowed;   // 当前被吞掉、还没松开的按键数
    id (^handler)(id) = ^id(id e) {
        NSUInteger type = ((NSUInteger (*)(id, SEL))objc_msgSend)(e, NSSelectorFromString(@"type"));
        BOOL isDown = NO, isUp = NO;
        for (int i = 0; i < 3; i++) { if ((int)type == kDown[i]) isDown = YES; if ((int)type == kUp[i]) isUp = YES; }
        if (isDown) {
            if (!gCursorLocked) return e;
            swallowed++;
            return nil;
        }
        if (isUp) {
            if (swallowed > 0) { swallowed--; return nil; }
            return e;
        }
        return (gCursorLocked || swallowed > 0) ? nil : e;   // 拖动 / 压力
    };
    gClickMonitor = ((id (*)(id, SEL, uint64_t, id))objc_msgSend)(ev, sel, mask, handler);
    SPLOG(@"[SekaiPad] 鼠标点击拦截：%@", gClickMonitor ? @"已启用" : @"失败");
}

static BOOL AnyActive(void) {
    for (int k = 0; k < MAX_E; k++) if (gSlot[k].used) return YES;
    return NO;
}

static void StartListener(void) {
    int port = 47800;
    const char *env = getenv("SEKAIPAD_PORT");
    if (env && atoi(env) > 0) port = atoi(env);

    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { SPLOG(@"[SekaiPad] socket 失败"); return; }
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        SPLOG(@"[SekaiPad] 绑定 127.0.0.1:%d 失败（端口被占用或沙盒限制）", port);
        close(fd);
        return;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

    dispatch_queue_t q = dispatch_queue_create("sekaipad.udp", DISPATCH_QUEUE_SERIAL);
    gSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, q);
    dispatch_source_set_event_handler(gSrc, ^{
        uint8_t buf[sizeof(SpHeader) + MAX_E * sizeof(Ent)];
        static CFAbsoluteTime lastAck;
        static int warnedProto = -1;
        for (;;) {
            struct sockaddr_in from;
            socklen_t fromLen = sizeof from;
            ssize_t r = recvfrom(fd, buf, sizeof buf, 0, (struct sockaddr *)&from, &fromLen);
            if (r < 4) break;
            uint32_t magic;
            memcpy(&magic, buf, 4);
            if (magic == SP_MAGIC_V1_ON || magic == SP_MAGIC_V1_NODOT || magic == SP_MAGIC_V1_OFF) {
                if (warnedProto != 1) {
                    warnedProto = 1;
                    SPLOG(@"[SekaiPad] 助手程序版本过旧（v0.1.x 协议），插件 v%s 需要协议 %d，请重新编译并运行新的 sekai-pad",
                          SEKAIPAD_VERSION, SP_PROTO);
                }
                continue;
            }
            if (magic != SP_MAGIC || r < (ssize_t)sizeof(SpHeader)) continue;
            SpHeader h;
            memcpy(&h, buf, sizeof h);

            // 回应助手程序（带上插件的协议号和版本），让它能在终端提示版本不一致
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastAck >= ACK_INTERVAL) {
                lastAck = now;
                SpAck ack = { SP_MAGIC_ACK, SP_PROTO, 0, {0} };
                strlcpy(ack.version, SEKAIPAD_VERSION, sizeof ack.version);
                sendto(fd, &ack, sizeof ack, 0, (struct sockaddr *)&from, fromLen);
            }

            if (h.proto != SP_PROTO) {
                if (warnedProto != h.proto) {
                    warnedProto = h.proto;
                    SPLOG(@"[SekaiPad] 协议版本不一致：助手程序 %d，插件 v%s 为 %d，请用同一次编译的 sekai-pad 和 SekaiPad.dylib",
                          h.proto, SEKAIPAD_VERSION, SP_PROTO);
                }
                continue;
            }
            if (!h.on) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    gLastPacket = CFAbsoluteTimeGetCurrent();
                    gLastOn = 0;
                    Apply(NULL, 0);
                    UpdateCursor();
                });
                continue;
            }
            if (h.count > MAX_E || sizeof(SpHeader) + h.count * sizeof(Ent) > (size_t)r) continue;
            DotStyle style = h.style == SP_STYLE_NONE ? DotNone : h.style == SP_STYLE_CROSS ? DotCross : DotNormal;
            NSData *d = [NSData dataWithBytes:buf + sizeof(SpHeader) length:h.count * sizeof(Ent)];
            int cnt = (int)h.count;
            // 每个包按顺序在主线程处理（不合并，避免吞掉极短的点按）
            dispatch_async(dispatch_get_main_queue(), ^{
                gLastPacket = CFAbsoluteTimeGetCurrent();
                gLastOn = gLastPacket;
                gDotStyle = style;
                UpdateCursor();
                if (!gGotFirst) { gGotFirst = YES; SPLOG(@"[SekaiPad] 收到第一个数据包（%d 指）", cnt); }
                Apply((const Ent *)d.bytes, cnt);
            });
        }
    });
    dispatch_resume(gSrc);

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{
        if (AnyActive() && CFAbsoluteTimeGetCurrent() - gLastPacket > TIMEOUT_SEC) Apply(NULL, 0);
        UpdateCursor();   // 助手程序退出或切到其他 App 时恢复鼠标
    });
    dispatch_resume(gTimer);

    SPLOG(@"[SekaiPad] v%s（协议 %d）正在监听 127.0.0.1:%d", SEKAIPAD_VERSION, SP_PROTO, port);
}

__attribute__((constructor))
static void SekaiPadInit(void) {
    gViews = [NSMutableDictionary new];
    gDots = [NSMutableDictionary new];
    StartListener();
    // NSApplication 在 constructor 时可能还没准备好，放到主线程下一轮再装
    dispatch_async(dispatch_get_main_queue(), ^{ InstallClickBlocker(); });
}
