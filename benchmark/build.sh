#!/usr/bin/env bash
# 一键编译三个应用的测试程序（native + wasm）到本目录，并清理中间产物。
# 用法（由根 Makefile 的 bench-build 调用）:
#   WASI_SDK=... WASMTIME=... ./benchmark/build.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
WASI_SDK="${WASI_SDK:?需要 WASI_SDK 环境变量}"
WASMTIME="${WASMTIME:?需要 WASMTIME 环境变量}"
WCC="$WASI_SDK/bin/clang"
SYSROOT="$WASI_SDK/share/wasi-sysroot"
NPROC="$(nproc)"

SQLITE_TREE="$ROOT/wasip1-sqlite/sqlite-autoconf-3530400"
REDIS_TREE="$ROOT/wasip2-redis/redis-7.4.11"
NGINX_TREE="$ROOT/wasip2-nginx/nginx-1.31.4"

FEATURES='-DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MATH_FUNCTIONS -DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_CARRAY -DSQLITE_ENABLE_DBPAGE_VTAB -DSQLITE_ENABLE_PERCENTILE'

echo "==> [1/4] SQLite speedtest1（native + wasm）"
# 确保 wasm 侧依赖就绪（官方源码 + libsqlite3.a）
[ -f "$SQLITE_TREE/sqlite3.c" ] || make -C "$ROOT/wasip1-sqlite" sqlite WASI_SDK="$WASI_SDK" WASMTIME="$WASMTIME" >/dev/null
[ -f "$SQLITE_TREE/libsqlite3.a" ] || make -C "$ROOT/wasip1-sqlite" sqlite WASI_SDK="$WASI_SDK" WASMTIME="$WASMTIME" >/dev/null
gcc -O2 $FEATURES -I"$SQLITE_TREE" "$HERE/sqlite/speedtest1.c" "$SQLITE_TREE/sqlite3.c" -lm \
    -o "$HERE/sqlite/speedtest1-native"
"$WCC" --target=wasm32-wasip1 --sysroot="$SYSROOT" -O2 $FEATURES -I"$SQLITE_TREE" \
    "$HERE/sqlite/speedtest1.c" "$SQLITE_TREE/libsqlite3.a" -lm -o "$HERE/sqlite/speedtest1.wasm"

echo "==> [2/4] Redis（原生 redis-server + redis-benchmark；wasm 从应用 out/ 拷贝）"
( cd "$REDIS_TREE" \
  && make -C deps hiredis linenoise lua hdr_histogram fpconv CC=cc CFLAGS="-O2" >/dev/null 2>&1 \
  && make -C src redis-server redis-benchmark -j"$NPROC" MALLOC=libc CC=cc CFLAGS="-O2" >/dev/null 2>&1 )
cp "$REDIS_TREE/src/redis-server" "$HERE/redis/redis-server-native"
cp "$REDIS_TREE/src/redis-benchmark" "$HERE/redis/redis-benchmark"
# wasm 产物缺失时先构建（wasm 侧对象在 wasm-obj/，不影响上面的原生构建）
[ -f "$ROOT/wasip2-redis/out/redis-server.wasm" ] ||     make -C "$ROOT/wasip2-redis" all WASI_SDK="$WASI_SDK" WASMTIME="$WASMTIME" >/dev/null
cp "$ROOT/wasip2-redis/out/redis-server.wasm" "$HERE/redis/redis-server.wasm"
# 清理原生构建残留（wasm 构建用独立的 wasm-obj/host-obj，不依赖 src/deps 里的对象）
( cd "$REDIS_TREE" && make -C src clean >/dev/null 2>&1 || true
  # deps/Makefile 没有 clean 目标，显式删掉原生构建产物
  rm -f deps/hiredis/*.o deps/hiredis/*.a \
        deps/linenoise/*.o deps/hdr_histogram/*.o deps/hdr_histogram/*.a \
        deps/fpconv/*.o deps/fpconv/*.a \
        deps/lua/src/*.o deps/lua/src/liblua.a deps/lua/src/lua deps/lua/src/luac )

echo "==> [3/4] Nginx（原生从源码副本构建，不碰 wasm 的 objs/ 构建树）"
TMPN="$(mktemp -d)"
trap 'rm -rf "$TMPN"' EXIT
cp -r "$NGINX_TREE" "$TMPN/src"
( cd "$TMPN/src" && rm -rf objs && ./auto/configure --with-cc=cc --with-cc-opt="-O2" \
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
cp "$TMPN/src/objs/nginx" "$HERE/nginx/nginx-native"
[ -f "$ROOT/wasip2-nginx/out/nginx.wasm" ] ||     make -C "$ROOT/wasip2-nginx" build WASI_SDK="$WASI_SDK" WASMTIME="$WASMTIME" >/dev/null
cp "$ROOT/wasip2-nginx/out/nginx.wasm" "$HERE/nginx/nginx.wasm"

echo "==> [4/4] ApacheBench（缺失时从 apache2-utils 提取）"
if [ ! -x "$HERE/ab" ]; then
    TMPA="$(mktemp -d)"
    ( cd "$TMPA" && apt-get download apache2-utils >/dev/null 2>&1 \
      && mkdir x && dpkg -x apache2-utils*.deb x )
    cp "$TMPA/x/usr/bin/ab" "$HERE/ab"
    rm -rf "$TMPA"
fi

echo "==> 完成。benchmark/ 下产物："
ls -la "$HERE/sqlite" "$HERE/redis" "$HERE/nginx" | grep -E '^-|:$'
