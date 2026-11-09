// protocol.h — 助手程序与插件之间的 UDP 协议，两边共用。
//
// 助手程序 -> 插件（127.0.0.1:47800）：Header + count 个 Ent，约 100Hz 加 0.1 秒心跳。
// 插件 -> 助手程序（回到发送方地址）：Ack，最多每 0.5 秒一次。
//
// 改动包格式或语义时把 SP_PROTO 加一。两边版本不一致时：
//   - 新插件收到旧格式/旧版本的包：在「控制台」日志里提示，并忽略
//   - 新助手程序收到不一致的 Ack，或一直收不到 Ack：在终端提示
#pragma once
#include <stdint.h>

#ifndef SEKAIPAD_VERSION
#define SEKAIPAD_VERSION "dev"   // 由 build.sh 从 VERSION 文件传入
#endif

#define SP_PROTO 2

#define SP_MAGIC     0x32504B53u   // "SKP2"：助手程序发出的帧
#define SP_MAGIC_ACK 0x41504B53u   // "SKPA"：插件的回应
// v0.1.x 用的旧魔数，只用来识别旧版助手程序
#define SP_MAGIC_V1_ON    0x31504B53u  // "SKP1"
#define SP_MAGIC_V1_NODOT 0x4E504B53u  // "SKPN"
#define SP_MAGIC_V1_OFF   0x30504B53u  // "SKP0"

enum { SP_STYLE_DOT = 0, SP_STYLE_NONE = 1, SP_STYLE_CROSS = 2 };

#define SP_MAX_ENT 64

typedef struct {
    uint32_t magic;   // SP_MAGIC
    uint16_t proto;   // SP_PROTO
    uint8_t  on;      // 1 = 映射开启，0 = 关闭（插件据此恢复鼠标，count 为 0）
    uint8_t  style;   // SP_STYLE_*
    uint32_t count;   // 后面跟着的 SpEnt 个数
} SpHeader;

typedef struct { int32_t id; float x, y; } SpEnt;   // x,y 为窗口归一化坐标，y 向下

typedef struct {
    uint32_t magic;       // SP_MAGIC_ACK
    uint16_t proto;       // 插件的 SP_PROTO
    uint16_t reserved;
    char     version[16]; // 插件的 SEKAIPAD_VERSION，以 \0 结尾
} SpAck;
