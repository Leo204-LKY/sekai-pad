// SekaiPad.m — PlayCover 自定义插件（dylib），由 PlayTools 加载进游戏进程。
// 监听 127.0.0.1:47800 的 UDP 包（来自 sekai-pad 助手程序），
// 用 PlayTools 自带的 PTFakeMetaTouch 合成真正的多点触控。
// 不经过 Apple 的「触控替代」，所以不需要按住 Option。

#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>

#define MAGIC  0x31504B53u   // "SKP1"
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

static void Resolve(void) {
    if (gResolved) return;
    gResolved = YES;
    gPT = NSClassFromString(@"PTFakeMetaTouch");
    if (!gPT) { NSLog(@"[SekaiPad] 找不到 PTFakeMetaTouch（PlayTools 未加载？）"); return; }
    SEL s5 = NSSelectorFromString(@"fakeTouchId:AtPoint:withTouchPhase:inWindow:onView:");
    SEL s3 = NSSelectorFromString(@"fakeTouchId:AtPoint:withTouchPhase:");
    SEL sa = NSSelectorFromString(@"getAvailablePointId");
    if ([gPT respondsToSelector:s5]) gSel5 = s5;
    if ([gPT respondsToSelector:s3]) gSel3 = s3;
    if ([gPT respondsToSelector:sa]) gSelAvail = sa;
    NSLog(@"[SekaiPad] PTFakeMetaTouch: 5参=%d 3参=%d avail=%d", gSel5 != NULL, gSel3 != NULL, gSelAvail != NULL);
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

// 在主线程调用：把当前帧的手指集合与上一帧比较，生成 began / moved / ended
static void Apply(const Ent *e, int n) {
    Resolve();
    if (!gPT || !gSelAvail || (!gSel5 && !gSel3)) return;

    UIWindow *w = KeyWindow();
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
            NSInteger pid = ((NSInteger (*)(id, SEL))objc_msgSend)(gPT, gSelAvail);
            if (pid <= 0) continue;
            UIView *v = [w hitTest:p withEvent:nil] ?: w;
            pid = Fake(pid, p, UITouchPhaseBegan, w, v);
            if (pid <= 0) continue;
            gSlot[freeSlot] = (Slot){ YES, e[i].id, pid, p };
            gViews[@(e[i].id)] = v;
        }
    }
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
    if (fd < 0) { NSLog(@"[SekaiPad] socket 失败"); return; }
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) {
        NSLog(@"[SekaiPad] 绑定 127.0.0.1:%d 失败（端口被占用或沙盒限制）", port);
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
            if (magic != MAGIC || count > MAX_E || 8 + count * sizeof(Ent) > (size_t)r) continue;
            NSData *d = [NSData dataWithBytes:buf + 8 length:count * sizeof(Ent)];
            int cnt = (int)count;
            // 每个包按顺序在主线程处理（不合并，避免吞掉极短的点按）
            dispatch_async(dispatch_get_main_queue(), ^{
                gLastPacket = CFAbsoluteTimeGetCurrent();
                Apply((const Ent *)d.bytes, cnt);
            });
        }
    });
    dispatch_resume(gSrc);

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gTimer, ^{
        if (AnyActive() && CFAbsoluteTimeGetCurrent() - gLastPacket > TIMEOUT_SEC) Apply(NULL, 0);
    });
    dispatch_resume(gTimer);

    NSLog(@"[SekaiPad] 正在监听 127.0.0.1:%d", port);
}

__attribute__((constructor))
static void SekaiPadInit(void) {
    gViews = [NSMutableDictionary new];
    StartListener();
}
