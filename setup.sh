#!/usr/bin/env bash
# 下载构建工具链到仓库同级目录（不进入仓库）：
#   ../wasi-sdk-34.0-x86_64-linux/      WASI SDK 34（编译 wasm 用）
#   ../wasmtime-v48.0.1-x86_64-linux/   wasmtime 48.0.1（运行 wasm 用）
# Makefile 会按此位置查找；也可用环境变量 WASI_SDK / WASMTIME 指向其他位置。
#
# 用法:
#   ./setup.sh                  # 全部下载（编译 + 运行）
#   ./setup.sh --runtime        # 只下载 wasmtime——wasm 产物是跨平台的，
#                               # 只想跑 demo/ 里的成品时无需编译工具链
#   ./setup.sh --toolchain      # 只下载 wasi-sdk（编译用）
set -euo pipefail

MODE="${1:-all}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$(dirname "$ROOT")"
cd "$TOOLS"

download_sdk() {
    if [ -x wasi-sdk-34.0-x86_64-linux/bin/clang ]; then
        echo "==> wasi-sdk 已就绪"
        return
    fi
    echo "==> 下载 wasi-sdk-34.0-x86_64-linux"
    curl -L --retry 3 -o wasi-sdk.tar.gz \
        https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/wasi-sdk-34.0-x86_64-linux.tar.gz
    tar xzf wasi-sdk.tar.gz
    rm wasi-sdk.tar.gz
}

download_wasmtime() {
    if [ -x wasmtime-v48.0.1-x86_64-linux/wasmtime ]; then
        echo "==> wasmtime 已就绪"
        return
    fi
    echo "==> 下载 wasmtime-v48.0.1-x86_64-linux"
    curl -L --retry 3 -o wasmtime.tar.xz \
        https://github.com/bytecodealliance/wasmtime/releases/download/v48.0.1/wasmtime-v48.0.1-x86_64-linux.tar.xz
    tar xJf wasmtime.tar.xz
    rm wasmtime.tar.xz
}

case "$MODE" in
    all)
        download_sdk
        download_wasmtime
        ;;
    --runtime)
        download_wasmtime
        ;;
    --toolchain)
        download_sdk
        ;;
    *)
        echo "用法: ./setup.sh [--runtime|--toolchain]" >&2
        exit 1
        ;;
esac

echo "==> 工具链就绪："
[ -d "$TOOLS/wasi-sdk-34.0-x86_64-linux" ] && ls -d "$TOOLS/wasi-sdk-34.0-x86_64-linux" || true
[ -d "$TOOLS/wasmtime-v48.0.1-x86_64-linux" ] && ls -d "$TOOLS/wasmtime-v48.0.1-x86_64-linux" || true
