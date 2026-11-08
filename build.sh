#!/bin/bash
# 需要 Xcode（或 Command Line Tools），在 Apple Silicon Mac 上运行
set -e
cd "$(dirname "$0")"
mkdir -p build

echo "==> 编译助手程序 sekai-pad"
xcrun clang -O2 -Wall -o build/sekai-pad helper/sekai_pad.c \
    -framework CoreFoundation -framework ApplicationServices
codesign -fs - build/sekai-pad

echo "==> 编译插件 SekaiPad.dylib（Mac Catalyst 平台，与 PlayCover 转换后的游戏一致）"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -O2 -Wall -fobjc-arc -dynamiclib \
    -target arm64-apple-ios14.0-macabi -isysroot "$SDK" \
    -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -F "$SDK/System/iOSSupport/System/Library/Frameworks" \
    -framework UIKit -framework Foundation -framework CoreGraphics \
    -o build/SekaiPad.dylib plugin/SekaiPad.m
codesign -fs - build/SekaiPad.dylib

echo "==> 完成：build/sekai-pad 和 build/SekaiPad.dylib"
