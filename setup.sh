#!/usr/bin/env bash
# Download WASI SDK 34 to the directory next to this repository.
# Wasmtime is already distributed in runtime/ and is not downloaded here.
set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "用法: ./setup.sh" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$(dirname "$ROOT")"
cd "$TOOLS"

if [ -x wasi-sdk-34.0-x86_64-linux/bin/clang ]; then
    echo "==> wasi-sdk 已就绪"
else
    echo "==> 下载 wasi-sdk-34.0-x86_64-linux"
    curl -L --retry 3 -o wasi-sdk.tar.gz \
        https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/wasi-sdk-34.0-x86_64-linux.tar.gz
    tar xzf wasi-sdk.tar.gz
    rm -f wasi-sdk.tar.gz
fi

echo "==> 构建工具链就绪：$TOOLS/wasi-sdk-34.0-x86_64-linux"
