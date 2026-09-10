#!/usr/bin/env bash
# Build one matched benchmark set: P2 components, WALI/Wave AOT, and native.
# New files are staged first, so a failed AOT build cannot leave new components
# paired with stale AOT artifacts in runtime/.
# 用法（由根 Makefile 的 bench-build 调用）:
#   WASI_SDK=... WASMTIME=... ./benchmark/build.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
WASI_SDK="${WASI_SDK:?需要 WASI_SDK 环境变量}"
WASMTIME="${WASMTIME:?需要 WASMTIME 环境变量}"
WALI_ROOT="${WALI_ROOT:?需要 WALI_ROOT 环境变量}"
WAVE_ROOT="${WAVE_ROOT:?需要 WAVE_ROOT 环境变量}"
WASM_TOOLS="${WASM_TOOLS:?需要 WASM_TOOLS 环境变量}"
WAMRC="${WAMRC:?需要 WAMRC 环境变量}"
WASM_OPT_FLAGS="${WASM_OPT_FLAGS:--O3 -flto}"
NATIVE_OPT_FLAGS="${NATIVE_OPT_FLAGS:--O3 -flto}"
SQLITE_PGO="${SQLITE_PGO:-1}"
SQLITE_PGO_SIZE="${SQLITE_PGO_SIZE:-100}"
SQLITE_PGO_TRAIN_FLAGS="${SQLITE_PGO_TRAIN_FLAGS:--O3 -flto}"
HOST_CLANG="${HOST_CLANG:-clang}"
NPROC="$(nproc)"

SQLITE_TREE="$ROOT/wasip2-sqlite/sqlite-autoconf-3530400"
REDIS_TREE="$ROOT/wasip2-redis/redis-7.4.11"
NGINX_TREE="$ROOT/wasip2-nginx/nginx-1.31.4"
TMPBUILD="$(mktemp -d /tmp/wasip2-bench-build.XXXXXX)"
trap 'rm -rf "$TMPBUILD"' EXIT INT TERM
STAGE="$TMPBUILD/stage"
mkdir -p "$STAGE/wasm" "$STAGE/wali" "$STAGE/wave"

FEATURES='-DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_CARRAY -DSQLITE_ENABLE_DBPAGE_VTAB -DSQLITE_ENABLE_PERCENTILE -DSQLITE_TEMP_STORE=3'

# Ensure that the official amalgamation exists and has the reproducible,
# Wasm-only VDBE/memcmp optimizations applied before PGO training/building.
make -C "$ROOT/wasip2-sqlite" "$SQLITE_TREE/sqlite3.c" >/dev/null
grep -q 'SQLITE_WASM_VDBE_NOINLINE sqlite3VdbeHalt' "$SQLITE_TREE/sqlite3.c" || {
    echo "错误: SQLite Wasm VDBE 性能补丁没有应用" >&2
    exit 1
}

SQLITE_WASM_PROFILE_FLAGS=()
if [ "$SQLITE_PGO" = 1 ]; then
    command -v "$HOST_CLANG" >/dev/null || {
        echo "错误: SQLite PGO 需要 host clang（可设置 HOST_CLANG 或 SQLITE_PGO=0）" >&2
        exit 1
    }
    if [ -z "${LLVM_PROFDATA:-}" ]; then
        LLVM_PROFDATA="$(command -v llvm-profdata 2>/dev/null || command -v llvm-profdata-19 2>/dev/null || true)"
    fi
    [ -n "$LLVM_PROFDATA" ] && [ -x "$LLVM_PROFDATA" ] || {
        echo "错误: SQLite PGO 需要 llvm-profdata（可设置 LLVM_PROFDATA 或 SQLITE_PGO=0）" >&2
        exit 1
    }

    echo "==> [1/8] 训练 SQLite PGO（native speedtest1 --size $SQLITE_PGO_SIZE）"
    PGO_DIR="$TMPBUILD/sqlite-pgo"
    mkdir -p "$PGO_DIR/run"
    PGO_RAW="$PGO_DIR/sqlite.profraw"
    PGO_DATA="$PGO_DIR/sqlite.profdata"
    "$HOST_CLANG" $SQLITE_PGO_TRAIN_FLAGS -fprofile-instr-generate="$PGO_RAW" \
        $FEATURES -I"$SQLITE_TREE" "$HERE/sqlite/speedtest1.c" "$SQLITE_TREE/sqlite3.c" -lm \
        -o "$PGO_DIR/speedtest1-train"
    ( cd "$PGO_DIR/run" && LLVM_PROFILE_FILE="$PGO_RAW" \
        "$PGO_DIR/speedtest1-train" --size "$SQLITE_PGO_SIZE" >/dev/null )
    "$LLVM_PROFDATA" merge -output="$PGO_DATA" "$PGO_RAW"
    # Source profiles are target-independent. A handful of OS-specific
    # functions have different CFG hashes between native and WASI and are
    # deliberately ignored; the matching SQLite hot functions retain counts.
    SQLITE_WASM_PROFILE_FLAGS=(
        -fprofile-instr-use="$PGO_DATA"
        -Wno-profile-instr-unprofiled
        -Wno-profile-instr-out-of-date
    )
else
    echo "==> [1/8] 跳过 SQLite PGO（SQLITE_PGO=$SQLITE_PGO）"
fi

echo "==> [2/8] 构建三个 P2 benchmark component（$WASM_OPT_FLAGS）"
"$WASI_SDK/bin/clang" --target=wasm32-wasip2 --sysroot="$WASI_SDK/share/wasi-sysroot" \
    $WASM_OPT_FLAGS "${SQLITE_WASM_PROFILE_FLAGS[@]}" -D__wasi__ -D_GNU_SOURCE \
    -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
    -D_WASI_EMULATED_GETPID -D_WASI_EMULATED_MMAN \
    $FEATURES -I"$SQLITE_TREE" "$HERE/sqlite/speedtest1.c" "$SQLITE_TREE/sqlite3.c" \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks \
    -lwasi-emulated-getpid -lwasi-emulated-mman -lm -o "$STAGE/wasm/sqlite.wasm"
cp "$ROOT/wasip2-redis/out/redis-server.wasm" "$STAGE/wasm/redis.wasm"
cp "$ROOT/wasip2-nginx/out/nginx.wasm" "$STAGE/wasm/nginx.wasm"

echo "==> [3/8] 重建 WALI AOT"
for app in sqlite redis nginx; do
    module_dir="$TMPBUILD/wali-$app/modules"
    mkdir -p "$module_dir"
    "$WASM_TOOLS" component unbundle "$STAGE/wasm/$app.wasm" \
        --module-dir "$module_dir" -o "$TMPBUILD/wali-$app/component.wasm"
    "$WAMRC" --opt-level=3 --size-level=0 \
        -o "$STAGE/wali/$app.aot" "$module_dir/unbundled-module0.wasm"
done

echo "==> [4/8] 重建 Wave AOT"
build_wave_app() {
    local example="$1" input="$2" output="$3"
    make -C "$WAVE_ROOT/examples/$example" clean >/dev/null
    make -C "$WAVE_ROOT/examples/$example" -j"$NPROC" all \
        INPUT="$input" WASM_TOOLS="$WASM_TOOLS"
    cp "$WAVE_ROOT/examples/$example/$output" "$STAGE/wave/"
}
build_wave_app speedtest1-p2 "$STAGE/wasm/sqlite.wasm" speedtest1-p2.so
build_wave_app redis-p2 "$STAGE/wasm/redis.wasm" redis-p2.so
build_wave_app nginx-p2 "$STAGE/wasm/nginx.wasm" nginx-p2.so

echo "==> [5/8] SQLite native（$NATIVE_OPT_FLAGS）"
gcc $NATIVE_OPT_FLAGS $FEATURES -I"$SQLITE_TREE" "$HERE/sqlite/speedtest1.c" "$SQLITE_TREE/sqlite3.c" -lm \
    -o "$STAGE/speedtest1-native"

echo "==> [6/8] Redis native（$NATIVE_OPT_FLAGS）"
REDIS_NATIVE_TREE="$TMPBUILD/redis"
cp -r "$REDIS_TREE" "$REDIS_NATIVE_TREE"
( cd "$REDIS_NATIVE_TREE" \
  && make -C deps hiredis linenoise lua hdr_histogram fpconv CC=cc CFLAGS="$NATIVE_OPT_FLAGS" >/dev/null 2>&1 \
  && make -C src redis-server redis-benchmark -j"$NPROC" MALLOC=libc CC=cc CFLAGS="$NATIVE_OPT_FLAGS" >/dev/null 2>&1 )
cp "$REDIS_NATIVE_TREE/src/redis-server" "$STAGE/redis-server-native"
cp "$REDIS_NATIVE_TREE/src/redis-benchmark" "$STAGE/redis-benchmark"

echo "==> [7/8] Nginx native（$NATIVE_OPT_FLAGS）"
TMPN="$TMPBUILD/nginx"
mkdir -p "$TMPN"
cp -r "$NGINX_TREE" "$TMPN/src"
( cd "$TMPN/src" && rm -rf objs && ./auto/configure --with-cc=cc \
    --with-cc-opt="$NATIVE_OPT_FLAGS" --with-ld-opt="$NATIVE_OPT_FLAGS" \
    --without-http_gzip_module --without-pcre --without-http_rewrite_module \
    --without-http_fastcgi_module --without-http_uwsgi_module --without-http_scgi_module \
    --without-http_grpc_module --without-http_memcached_module \
    --without-http_geo_module --without-http_split_clients_module \
    --without-http_ssi_module --without-http_userid_module --without-http_browser_module \
    --without-http_mirror_module --without-http_tunnel_module --without-http_referer_module \
    --without-http_map_module --without-http_empty_gif_module \
    --without-http_limit_conn_module --without-http_limit_req_module \
    --without-http_upstream_hash_module --without-http_upstream_ip_hash_module \
    --without-http_upstream_least_conn_module --without-http_upstream_least_time_module \
    --without-http_upstream_random_module --without-http_upstream_keepalive_module \
    --prefix="$HERE/nginx/native-conf" >/dev/null \
  && make -f objs/Makefile objs/nginx -j"$NPROC" >/dev/null )
cp "$TMPN/src/objs/nginx" "$STAGE/nginx-native"

echo "==> [8/8] 提交整套匹配产物"
install -m 0644 "$STAGE/wasm/sqlite.wasm" "$HERE/sqlite/speedtest1.wasm"
install -m 0644 "$STAGE/wasm/redis.wasm" "$HERE/redis/redis-server.wasm"
install -m 0644 "$STAGE/wasm/nginx.wasm" "$HERE/nginx/nginx.wasm"
install -m 0644 "$STAGE/wali/sqlite.aot" "$ROOT/runtime/wali/apps/sqlite.aot"
install -m 0644 "$STAGE/wali/redis.aot" "$ROOT/runtime/wali/apps/redis.aot"
install -m 0644 "$STAGE/wali/nginx.aot" "$ROOT/runtime/wali/apps/nginx.aot"
install -m 0755 "$STAGE/wave/speedtest1-p2.so" "$ROOT/runtime/wave/apps/sqlite.so"
install -m 0755 "$STAGE/wave/redis-p2.so" "$ROOT/runtime/wave/apps/redis.so"
install -m 0755 "$STAGE/wave/nginx-p2.so" "$ROOT/runtime/wave/apps/nginx.so"
install -m 0755 "$WAVE_ROOT/tools/wasm2c_sandbox_compiler/bin/wasm2c-runner" "$ROOT/runtime/wave/wasm2c-runner"
install -m 0755 "$WAVE_ROOT/target/release/libwave.so" "$ROOT/runtime/wave/libwave.so"
install -m 0755 "$STAGE/speedtest1-native" "$HERE/sqlite/speedtest1-native"
install -m 0755 "$STAGE/redis-server-native" "$HERE/redis/redis-server-native"
install -m 0755 "$STAGE/redis-benchmark" "$HERE/redis/redis-benchmark"
install -m 0755 "$STAGE/nginx-native" "$HERE/nginx/nginx-native"
( cd "$ROOT" && sha256sum \
    benchmark/sqlite/speedtest1.wasm \
    benchmark/redis/redis-server.wasm \
    benchmark/nginx/nginx.wasm \
    runtime/wali/apps/sqlite.aot \
    runtime/wali/apps/redis.aot \
    runtime/wali/apps/nginx.aot \
    runtime/wave/apps/sqlite.so \
    runtime/wave/apps/redis.so \
    runtime/wave/apps/nginx.so > runtime/APPS.sha256.new )
mv "$ROOT/runtime/APPS.sha256.new" "$ROOT/runtime/APPS.sha256"

# ApacheBench（缺失时从 apache2-utils 提取）
if [ ! -x "$HERE/ab" ]; then
    TMPA="$TMPBUILD/apache"
    mkdir -p "$TMPA"
    ( cd "$TMPA" && apt-get download apache2-utils >/dev/null 2>&1 \
      && mkdir x && dpkg -x apache2-utils*.deb x )
    cp "$TMPA/x/usr/bin/ab" "$HERE/ab"
fi

echo "==> 完成：P2/WALI/Wave/native 已使用同一轮源码和优化配置刷新。"
ls -la "$HERE/sqlite" "$HERE/redis" "$HERE/nginx" | grep -E '^-|:$'
