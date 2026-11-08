// sekai_pad.c — 读取 Mac 触控板原始多点触控数据，把每根手指映射到判定线上，
// 通过 UDP (127.0.0.1) 发给注入游戏进程的 SekaiPad.dylib 插件。
//
// 映射规则：
//   x：触控板横向位置 -> 判定线上的横向位置（线性，按判定线处轨道宽度）
//   y：手指按下时一律落在判定线上；之后只保留"相对位移"（用于 Flick / 滑动），
//      不管从触控板哪个高度按下去，效果都一样。
//
// 编译：见 build.sh（只依赖系统框架，私有框架用 dlopen 加载）

#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDParameter.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/file.h>
#include <fcntl.h>

// ---- MultitouchSupport.framework 私有结构 ----
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;        // 4 = makeTouch, 5 = touching, 6 = breakTouch ...
    int32_t fingerId;
    int32_t handId;
    MTVector normalized;  // 0..1，左下角为 (0,0)，y 向上
    float total;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;    // 毫米
    int32_t field14;
    int32_t field15;
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTFrameCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFMutableArrayRef (*pMTDeviceCreateList)(void);
static void (*pMTRegisterContactFrameCallback)(MTDeviceRef, MTFrameCallback);
static void (*pMTDeviceStart)(MTDeviceRef, int);

// ---- 协议（与 SekaiPad.m 一致）----
#define MAX_DEV 4
#define MAX_F   16
#define MAGIC   0x31504B53u  // "SKP1"：映射开启时的帧
#define MAGIC_NODOT 0x4E504B53u // "SKPN"：映射开启，插件不显示触摸点
#define MAGIC_OFF 0x30504B53u // "SKP0"：映射关闭（插件据此恢复鼠标）

typedef struct { int32_t id; float x, y; } Ent;   // x,y 为窗口归一化坐标，y 向下
typedef struct { uint32_t magic, count; Ent e[MAX_DEV * MAX_F]; } Packet;

typedef struct { int32_t id; float x, y, y0; } Finger;
typedef struct { MTDeviceRef dev; int n; Finger f[MAX_F]; } DevState;

static DevState gDev[MAX_DEV];
static int gNDev;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static int gSock = -1;
static struct sockaddr_in gAddr;
static int gWasOn = -1;

static struct {
    float judgeY;   // 判定线高度（窗口高度比例，0=顶 1=底）
    float left;     // 判定线处轨道左端（窗口宽度比例）
    float right;    // 判定线处轨道右端
    float padL;     // 触控板有效区域左端（0..1）
    float padR;     // 触控板有效区域右端
    float gain;     // 竖向相对位移倍率（Flick 灵敏度）
    int toggle;     // 0 = 始终开启，1 = 跟随 Caps Lock
    int debug;
    int port;
    int hideTouches; // 1 = 不在屏幕上显示触摸点
} cfg = { 0.82f, 0.12f, 0.88f, 0.03f, 0.97f, 1.0f, 1, 0, 47800, 0 };

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static io_connect_t gHID;

// 读 Caps Lock 的真实锁定状态（和指示灯一致）。
// 「短按切换输入法」模式下，CG 的 AlphaShift 标志可能和指示灯不同步，只作后备。
static int MappingOn(void) {
    if (cfg.toggle == 0) return 1;
    int cg = (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskAlphaShift) != 0;
    bool lock = false;
    if (!gHID || IOHIDGetModifierLockState(gHID, kIOHIDCapsLockState, &lock) != KERN_SUCCESS) return cg;
    if (cfg.debug && cg != (int)lock) {
        static int lastWarn = -1;
        if (lastWarn != (int)lock) { printf("（提示：指示灯=%d，CG 标志=%d，以指示灯为准）\n", lock, cg); lastWarn = lock; }
    }
    return lock;
}

static void SendAll(int on, int quiet) {
    Packet p;
    p.magic = !on ? MAGIC_OFF : (cfg.hideTouches ? MAGIC_NODOT : MAGIC);
    p.count = 0;
    if (on) {
        for (int d = 0; d < gNDev; d++) {
            for (int i = 0; i < gDev[d].n; i++) {
                Finger *f = &gDev[d].f[i];
                Ent *e = &p.e[p.count++];
                e->id = d * 100000 + f->id;
                float u = clampf((f->x - cfg.padL) / (cfg.padR - cfg.padL), 0.f, 1.f);
                e->x = cfg.left + u * (cfg.right - cfg.left);
                // 触控板 y 向上，屏幕 y 向下：手指往上推 -> 屏幕上的点往上走
                e->y = clampf(cfg.judgeY - (f->y - f->y0) * cfg.gain, 0.f, 1.f);
            }
        }
    }
    size_t len = 8 + p.count * sizeof(Ent);
    sendto(gSock, &p, len, 0, (struct sockaddr *)&gAddr, sizeof gAddr);

    if (cfg.debug && !quiet) {
        printf("[%s] %u 指", on ? "ON " : "OFF", p.count);
        for (uint32_t i = 0; i < p.count; i++)
            printf("  #%d(%.3f, %.3f)", p.e[i].id, p.e[i].x, p.e[i].y);
        printf("\n");
    }
}

static int Callback(MTDeviceRef dev, MTTouch *t, int n, double ts, int frame) {
    (void)ts; (void)frame;
    pthread_mutex_lock(&gLock);

    int on = MappingOn();
    DevState *ds = NULL;
    for (int d = 0; d < gNDev; d++) if (gDev[d].dev == dev) { ds = &gDev[d]; break; }

    if (!on) {
        for (int d = 0; d < gNDev; d++) gDev[d].n = 0;   // 关闭时清空，重新开启后重新记录起点
    } else if (ds) {
        Finger nf[MAX_F];
        int nn = 0;
        for (int i = 0; i < n && nn < MAX_F; i++) {
            if (t[i].state != 4 && t[i].state != 5) continue;
            float x = t[i].normalized.pos.x, y = t[i].normalized.pos.y;
            float y0 = y;
            for (int k = 0; k < ds->n; k++)
                if (ds->f[k].id == t[i].identifier) { y0 = ds->f[k].y0; break; }
            nf[nn++] = (Finger){ t[i].identifier, x, y, y0 };
        }
        memcpy(ds->f, nf, sizeof(Finger) * nn);
        ds->n = nn;
    }

    if (on || gWasOn != 0) SendAll(on, 0);   // 关闭状态只补发一次空帧
    gWasOn = on;

    pthread_mutex_unlock(&gLock);
    return 0;
}

// 每 0.1 秒发一次当前状态：没摸触控板时也能让插件及时知道 Caps Lock 开关，
// 插件据此隐藏/恢复鼠标；助手程序退出后插件 0.5 秒内自动恢复。
static void Heartbeat(CFRunLoopTimerRef t, void *info) {
    (void)t; (void)info;
    pthread_mutex_lock(&gLock);
    int on = MappingOn();
    if (!on) for (int d = 0; d < gNDev; d++) gDev[d].n = 0;
    SendAll(on, on == gWasOn);
    gWasOn = on;
    pthread_mutex_unlock(&gLock);
}

// 同一端口只允许一个助手程序：两个实例同时发包，插件会在两种映射之间来回跳。
// 锁随进程退出自动释放（包括 Ctrl+C、关掉终端、崩溃）。
static int SingleInstance(int port) {
    char path[64];
    snprintf(path, sizeof path, "/tmp/sekai-pad-%d.lock", port);
    int fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0) return 1;   // 拿不到锁文件就不检查，不影响使用
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        char buf[16] = {0};
        pread(fd, buf, sizeof buf - 1, 0);
        fprintf(stderr, "已有一个 sekai-pad 在运行（端口 %d，PID %s），请先关掉它（Ctrl+C 或 kill %s）\n",
                port, buf[0] ? buf : "?", buf[0] ? buf : "<PID>");
        return 0;
    }
    char pid[16];
    int n = snprintf(pid, sizeof pid, "%d", (int)getpid());
    ftruncate(fd, 0);
    pwrite(fd, pid, n, 0);
    return 1;               // 故意不关闭 fd，进程存活期间一直持有锁
}

static void Usage(const char *argv0) {
    printf(
        "用法: %s [选项]\n"
        "  --judge-y F     判定线高度，窗口高度比例 (默认 %.2f)\n"
        "  --left F        判定线处轨道左端，窗口宽度比例 (默认 %.2f)\n"
        "  --right F       判定线处轨道右端 (默认 %.2f)\n"
        "  --pad-left F    触控板有效区左端 0..1 (默认 %.2f)\n"
        "  --pad-right F   触控板有效区右端 0..1 (默认 %.2f)\n"
        "  --flick-gain F  竖向位移倍率，越大 Flick 越容易 (默认 %.2f)\n"
        "  --toggle MODE   capslock = Caps Lock 亮灯时生效 / always = 一直生效 (默认 capslock)\n"
        "  --port N        UDP 端口 (默认 %d)\n"
        "  --hide-touches  不在游戏画面上显示触摸点（默认显示）\n"
        "  --debug         打印每帧映射后的坐标\n",
        argv0, cfg.judgeY, cfg.left, cfg.right, cfg.padL, cfg.padR, cfg.gain, cfg.port);
}

int main(int argc, char **argv) {
    static struct option opts[] = {
        { "judge-y",    required_argument, 0, 'y' },
        { "left",       required_argument, 0, 'l' },
        { "right",      required_argument, 0, 'r' },
        { "pad-left",   required_argument, 0, 'L' },
        { "pad-right",  required_argument, 0, 'R' },
        { "flick-gain", required_argument, 0, 'g' },
        { "toggle",     required_argument, 0, 't' },
        { "port",       required_argument, 0, 'p' },
        { "debug",      no_argument,       0, 'd' },
        { "hide-touches", no_argument,     0, 'H' },
        { "help",       no_argument,       0, 'h' },
        { 0, 0, 0, 0 }
    };
    int c;
    while ((c = getopt_long(argc, argv, "y:l:r:L:R:g:t:p:dHh", opts, NULL)) != -1) {
        switch (c) {
            case 'y': cfg.judgeY = strtof(optarg, NULL); break;
            case 'l': cfg.left   = strtof(optarg, NULL); break;
            case 'r': cfg.right  = strtof(optarg, NULL); break;
            case 'L': cfg.padL   = strtof(optarg, NULL); break;
            case 'R': cfg.padR   = strtof(optarg, NULL); break;
            case 'g': cfg.gain   = strtof(optarg, NULL); break;
            case 't': cfg.toggle = strcmp(optarg, "always") == 0 ? 0 : 1; break;
            case 'p': cfg.port   = atoi(optarg); break;
            case 'd': cfg.debug  = 1; break;
            case 'H': cfg.hideTouches = 1; break;
            default:  Usage(argv[0]); return c == 'h' ? 0 : 1;
        }
    }
    if (cfg.padR <= cfg.padL) { fprintf(stderr, "pad-right 必须大于 pad-left\n"); return 1; }
    if (!SingleInstance(cfg.port)) return 1;
    setvbuf(stdout, NULL, _IOLBF, 0);

    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!h) { fprintf(stderr, "无法加载 MultitouchSupport: %s\n", dlerror()); return 1; }
    pMTDeviceCreateList = dlsym(h, "MTDeviceCreateList");
    pMTRegisterContactFrameCallback = dlsym(h, "MTRegisterContactFrameCallback");
    pMTDeviceStart = dlsym(h, "MTDeviceStart");
    if (!pMTDeviceCreateList || !pMTRegisterContactFrameCallback || !pMTDeviceStart) {
        fprintf(stderr, "MultitouchSupport 符号缺失\n");
        return 1;
    }

    io_service_t hidSvc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass));
    if (!hidSvc || IOServiceOpen(hidSvc, mach_task_self(), kIOHIDParamConnectType, &gHID) != KERN_SUCCESS) {
        gHID = 0;
        fprintf(stderr, "提示：无法读取 Caps Lock 锁定状态，改用键盘标志\n");
    }
    if (hidSvc) IOObjectRelease(hidSvc);

    gSock = socket(AF_INET, SOCK_DGRAM, 0);
    memset(&gAddr, 0, sizeof gAddr);
    gAddr.sin_family = AF_INET;
    gAddr.sin_port = htons((uint16_t)cfg.port);
    gAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    CFMutableArrayRef list = pMTDeviceCreateList();
    CFIndex count = list ? CFArrayGetCount(list) : 0;
    if (count == 0) { fprintf(stderr, "没有找到触控板设备\n"); return 1; }
    for (CFIndex i = 0; i < count && gNDev < MAX_DEV; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        gDev[gNDev].dev = dev;
        gDev[gNDev].n = 0;
        gNDev++;
        pMTRegisterContactFrameCallback(dev, Callback);
        pMTDeviceStart(dev, 0);
    }

    printf("SekaiPad 已启动：%d 个触控板，UDP 127.0.0.1:%d\n", gNDev, cfg.port);
    printf("判定线 y=%.2f，轨道 x=%.2f~%.2f，Flick 倍率 %.2f，开关：%s\n",
           cfg.judgeY, cfg.left, cfg.right, cfg.gain,
           cfg.toggle ? "Caps Lock（亮灯=生效）" : "始终生效");
    printf("触摸点：%s\n", cfg.hideTouches ? "不显示" : "显示（--hide-touches 可关闭）");
    printf("Ctrl+C 退出。\n");
    CFRunLoopTimerRef hb = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 0.1, 0, 0, Heartbeat, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), hb, kCFRunLoopCommonModes);
    CFRunLoopRun();
    return 0;
}
