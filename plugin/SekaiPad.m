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

#define MAGIC  0x31504B53u   // "SKP1"：映射开启
#define MAGIC_NODOT 0x4E504B53u // "SKPN"：映射开启，但不显示触摸点（助手程序 --hide-touches）
#define MAGIC_OFF 0x30504B53u // "SKP0"：映射关闭
#define DOT_SIZE 44.0         // 触摸点直径（点）
#define CURSOR_TIMEOUT 0.5    // 这么久没收到「开启」包就恢复鼠标
#define MAX_E  64
#define TIMEOUT_SEC 0.25     // 助手程序断开/卡住时自动松开所有手指

typedef struct { int32_t id; float x, y; } Ent;
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
static BOOL gShowDots = YES;
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
static UIView *MakeDot(void) {
    UIView *d = [[UIView alloc] initWithFrame:CGRectMake(0, 0, DOT_SIZE, DOT_SIZE)];
    d.userInteractionEnabled = NO;
    d.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    d.layer.cornerRadius = DOT_SIZE / 2;
    d.layer.borderWidth = 2;
    d.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:0.6].CGColor;
    d.layer.zPosition = 10000;
    return d;
}

static void UpdateDots(UIWindow *w) {
    NSMutableSet<NSNumber *> *alive = [NSMutableSet set];
    if (w && gShowDots) {
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
        uint8_t buf[8 + MAX_E * sizeof(Ent)];
        for (;;) {
            ssize_t r = recv(fd, buf, sizeof buf, 0);
            if (r < 8) break;
            uint32_t magic, count;
            memcpy(&magic, buf, 4);
            memcpy(&count, buf + 4, 4);
            if (magic == MAGIC_OFF) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    gLastPacket = CFAbsoluteTimeGetCurrent();
                    gLastOn = 0;
                    Apply(NULL, 0);
                    UpdateCursor();
                });
                continue;
            }
            BOOL dots = magic == MAGIC;
            if (magic == MAGIC_NODOT) magic = MAGIC;
            if (magic != MAGIC || count > MAX_E || 8 + count * sizeof(Ent) > (size_t)r) continue;
            NSData *d = [NSData dataWithBytes:buf + 8 length:count * sizeof(Ent)];
            int cnt = (int)count;
            // 每个包按顺序在主线程处理（不合并，避免吞掉极短的点按）
            dispatch_async(dispatch_get_main_queue(), ^{
                gLastPacket = CFAbsoluteTimeGetCurrent();
                gLastOn = gLastPacket;
                gShowDots = dots;
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

    SPLOG(@"[SekaiPad] 正在监听 127.0.0.1:%d", port);
}

__attribute__((constructor))
static void SekaiPadInit(void) {
    gViews = [NSMutableDictionary new];
    gDots = [NSMutableDictionary new];
    StartListener();
}
