#!/usr/bin/env bash
# Run identical SQLite, Redis and Nginx workloads on native, Wasmtime,
# WALI AOT and Wave AOT, then write Markdown tables to RESULTS.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
RUNTIME="$ROOT/runtime"
WASMTIME="$RUNTIME/wasmtime/wasmtime"
IWASM="$RUNTIME/wali/iwasm"
WALI_APPS="$RUNTIME/wali/apps"
WAVE_RUNNER="$RUNTIME/wave/wasm2c-runner"
WAVE_LIB="$RUNTIME/wave"
WAVE_APPS="$RUNTIME/wave/apps"
AB="$HERE/ab"
RESULTS="$HERE/RESULTS.md"
WORK="$(mktemp -d /tmp/wasip2-bench.XXXXXX)"
SERVER_PID=""

# These values are also compiled into the current Wave P2 adapters. Changing
# them requires regenerating the Wave application .so files (runtime/README.md).
SQLITE_SIZE=25
REDIS_REQUESTS=100000
REDIS_CLIENTS=50
NGINX_REQUESTS=50000
NGINX_CLIENTS=50
NGINX_KEEPALIVE_REQUESTS=20000
NGINX_KEEPALIVE_CLIENTS=128

clean_benchmark_state() {
    rm -f "$HERE/sqlite"/speedtest1.db* "$HERE/sqlite"/*.lock
    rm -rf "$HERE/redis/redis-data"
    rm -f "$HERE/nginx/native-conf/logs"/* "$HERE/nginx/wasm-conf/logs"/*
    rm -rf "$HERE/nginx/native-conf/client_body_temp" \
        "$HERE/nginx/native-conf/proxy_temp" \
        "$HERE/nginx/wasm-conf/client_body_temp" \
        "$HERE/nginx/wasm-conf/proxy_temp"
}

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    clean_benchmark_state
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

need_exec() { [ -x "$1" ] || { echo "错误: 缺少可执行文件 $1" >&2; exit 1; }; }
need_file() { [ -f "$1" ] || { echo "错误: 缺少文件 $1" >&2; exit 1; }; }
for f in "$WASMTIME" "$IWASM" "$WAVE_RUNNER" "$AB" \
         "$HERE/sqlite/speedtest1-native" "$HERE/redis/redis-server-native" \
         "$HERE/redis/redis-benchmark" "$HERE/nginx/nginx-native"; do
    need_exec "$f"
done
for f in "$HERE/sqlite/speedtest1.wasm" "$HERE/redis/redis-server.wasm" \
         "$HERE/nginx/nginx.wasm" "$WALI_APPS/sqlite.aot" \
         "$WALI_APPS/redis.aot" "$WALI_APPS/nginx.aot" \
         "$WAVE_APPS/sqlite.so" "$WAVE_APPS/redis.so" \
         "$WAVE_APPS/nginx.so" "$WAVE_LIB/libwave.so"; do
    need_file "$f"
done
(cd "$ROOT" && sha256sum -c runtime/APPS.sha256 >/dev/null) || {
    echo "错误: benchmark 的 P2 应用与 runtime/ 中的 WALI/Wave AOT 产物不匹配" >&2
    echo "请按 NOTICE.md 重新生成 runtime/wali/apps 和 runtime/wave/apps" >&2
    exit 1
}
clean_benchmark_state

start_server() {
    local log="$1"
    shift
    "$@" >"$log" 2>&1 &
    SERVER_PID=$!
}

start_server_in() {
    local dir="$1" log="$2"
    shift 2
    (cd "$dir" && exec "$@") >"$log" 2>&1 &
    SERVER_PID=$!
}

stop_server() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
}

check_port_free() {
    local port="$1"
    if python3 -c "import socket; socket.create_connection(('127.0.0.1',$port),timeout=.3).close()" 2>/dev/null; then
        echo "错误: 端口 $port 已被占用" >&2
        exit 1
    fi
}

wait_port() {
    local port="$1" name="$2" log="$3" i
    for i in $(seq 1 100); do
        if python3 -c "import socket; socket.create_connection(('127.0.0.1',$port),timeout=.3).close()" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "错误: $name 启动失败" >&2
            sed -n '1,120p' "$log" >&2
            exit 1
        fi
        sleep .1
    done
    echo "错误: $name 在端口 $port 上未就绪" >&2
    sed -n '1,120p' "$log" >&2
    exit 1
}

: >"$RESULTS"
printf '# WASI P2 benchmark 结果\n\n' >>"$RESULTS"
printf '同一份应用、同一组参数；服务端测试逐个运行，避免相互争抢 CPU。\n' >>"$RESULTS"

############################################
# SQLite
############################################
echo "=== SQLite: speedtest1 --size $SQLITE_SIZE（按测试集）==="
(
    cd "$HERE/sqlite"
    ./speedtest1-native --size "$SQLITE_SIZE" >"$WORK/sqlite-native.txt"
    "$WASMTIME" run -S cli --dir=. speedtest1.wasm --size "$SQLITE_SIZE" \
        >"$WORK/sqlite-wasmtime.txt"
    "$IWASM" -f 'wasi:cli/run@0.2.12#run' "$WALI_APPS/sqlite.aot" \
        --size "$SQLITE_SIZE" >"$WORK/sqlite-wali.txt"
    LD_LIBRARY_PATH="$WAVE_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$WAVE_RUNNER" "$WAVE_APPS/sqlite.so" --homedir=. \
        >"$WORK/sqlite-wave.txt"
)
python3 - "$WORK" "$RESULTS" "$SQLITE_SIZE" <<'PYEOF'
import re, sys
work, results, size = sys.argv[1:]
def parse(path):
    out = open(path, errors="replace").read()
    sets, cur = {}, None
    for line in out.splitlines():
        m = re.search(r'Begin testset "(\w+)"', line)
        if m:
            cur = m.group(1); sets.setdefault(cur, 0.0); continue
        if line.lstrip().startswith("TOTAL") or cur is None: continue
        m = re.search(r'([\d.]+)s\s*$', line)
        if m: sets[cur] += float(m.group(1))
    m = re.search(r'TOTAL.*?([\d.]+)s', out)
    if not m: raise SystemExit(f"无法解析 SQLite 输出: {path}")
    total = float(m.group(1))
    return {"main": total - sum(sets.values()), **sets}, total
files = ["native", "wasmtime", "wali", "wave"]
parsed = [parse(f"{work}/sqlite-{name}.txt") for name in files]
rows = ["| 测试集 | Native | Wasmtime | WALI AOT | Wave |",
        "|---|---:|---:|---:|---:|"]
for testset in parsed[0][0]:
    vals = [p[0][testset] for p in parsed]
    rows.append("| " + testset + " | " + " | ".join(f"{v:.3f}s" for v in vals) + " |")
rows.append("| **TOTAL** | " + " | ".join(f"**{p[1]:.3f}s**" for p in parsed) + " |")
print("\n".join(rows))
with open(results, "a") as f:
    f.write(f"\n## SQLite（speedtest1 --size {size}，按测试集）\n\n" + "\n".join(rows) + "\n")
PYEOF
rm -f "$HERE/sqlite"/speedtest1.db* "$HERE/sqlite"/*.lock

############################################
# Redis
############################################
echo "=== Redis: redis-benchmark -n $REDIS_REQUESTS -c $REDIS_CLIENTS ==="
REDIS_PORT=6390
check_port_free "$REDIS_PORT"
CMDS="set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,spop,mset"

run_redis_case() {
    local name="$1"
    shift
    local log="$WORK/redis-$name-server.log"
    echo "  -> $name"
    start_server "$log" "$@"
    wait_port "$REDIS_PORT" "$name Redis" "$log"
    "$HERE/redis/redis-benchmark" -h 127.0.0.1 -p "$REDIS_PORT" \
        -n "$REDIS_REQUESTS" -c "$REDIS_CLIENTS" -q -t "$CMDS" \
        >"$WORK/redis-$name.txt"
    stop_server
}

run_redis_case native "$HERE/redis/redis-server-native" \
    --port "$REDIS_PORT" --save '' --appendonly no
run_redis_case wasmtime "$WASMTIME" run -W max-wasm-stack=8388608 \
    -S cli -S inherit-network=y --dir="$HERE/redis" --env HOME="$HOME" \
    "$HERE/redis/redis-server.wasm" --port "$REDIS_PORT" --save '' --appendonly no
run_redis_case wali "$IWASM" -f 'wasi:cli/run@0.2.12#run' \
    "$WALI_APPS/redis.aot" --port "$REDIS_PORT" --save '' --appendonly no
echo "  -> wave"
start_server "$WORK/redis-wave-server.log" env WAVE_REDIS_PORT="$REDIS_PORT" \
    LD_LIBRARY_PATH="$WAVE_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$WAVE_RUNNER" "$WAVE_APPS/redis.so" --homedir="$HERE/redis"
wait_port "$REDIS_PORT" "Wave Redis" "$WORK/redis-wave-server.log"
"$HERE/redis/redis-benchmark" -h 127.0.0.1 -p "$REDIS_PORT" \
    -n "$REDIS_REQUESTS" -c "$REDIS_CLIENTS" -q -t "$CMDS" \
    >"$WORK/redis-wave.txt"
stop_server

python3 - "$WORK" "$RESULTS" "$REDIS_REQUESTS" "$REDIS_CLIENTS" <<'PYEOF'
import re, sys
work, results, requests, clients = sys.argv[1:]
def parse(name):
    out = {}
    for line in open(f"{work}/redis-{name}.txt", errors="replace"):
        m = re.match(r'(\w[\w ()]*?): ([\d.]+) requests per second', line.strip())
        if m and "needed to benchmark" not in m.group(1): out[m.group(1)] = float(m.group(2))
    return out
data = [parse(name) for name in ["native", "wasmtime", "wali", "wave"]]
if not all(data): raise SystemExit("Redis benchmark 输出不完整")
rows = ["| 命令 | Native rps | Wasmtime rps | WALI AOT rps | Wave rps |",
        "|---|---:|---:|---:|---:|"]
for cmd in data[0]:
    rows.append("| " + cmd + " | " + " | ".join(f"{d[cmd]:,.0f}" for d in data) + " |")
print("\n".join(rows))
with open(results, "a") as f:
    f.write(f"\n## Redis（redis-benchmark -n {requests} -c {clients}）\n\n" + "\n".join(rows) + "\n")
PYEOF

############################################
# Nginx
############################################
echo "=== Nginx: short -n $NGINX_REQUESTS -c $NGINX_CLIENTS; keepalive -n $NGINX_KEEPALIVE_REQUESTS -c $NGINX_KEEPALIVE_CLIENTS ==="
check_port_free 8083
check_port_free 8082

run_nginx_case() {
    local name="$1" port="$2" dir="$3" scenario attempt
    shift 3
    echo "  -> $name"
    for scenario in short keepalive; do
        for attempt in 1 2; do
            start_server_in "$dir" "$WORK/nginx-$name-$scenario-server.log" "$@"
            wait_port "$port" "$name Nginx ($scenario)" \
                "$WORK/nginx-$name-$scenario-server.log"
            if { [ "$scenario" = short ] \
                    && "$AB" -n "$NGINX_REQUESTS" -c "$NGINX_CLIENTS" \
                        "http://127.0.0.1:$port/" >"$WORK/nginx-$name-short.txt"; } \
               || { [ "$scenario" = keepalive ] \
                    && timeout 120 "$AB" -n "$NGINX_KEEPALIVE_REQUESTS" \
                        -c "$NGINX_KEEPALIVE_CLIENTS" -k \
                        "http://127.0.0.1:$port/" >"$WORK/nginx-$name-keepalive.txt"; }; then
                stop_server
                break
            fi
            stop_server
            if [ "$attempt" -eq 1 ]; then
                echo "     $name/$scenario 出现临时 socket timeout，重启后重试" >&2
                sleep .5
            else
                echo "错误: $name Nginx $scenario 连续两次失败" >&2
                return 1
            fi
        done
    done
}

run_nginx_case native 8083 "$HERE/nginx/native-conf" \
    "$HERE/nginx/nginx-native" -p . -c nginx.conf
run_nginx_case wasmtime 8082 "$HERE/nginx/wasm-conf" \
    "$WASMTIME" run -W max-wasm-stack=8388608 -S cli -S inherit-network=y \
    -S allow-ip-name-lookup=y --dir=. --env HOME="$HOME" \
    "$HERE/nginx/nginx.wasm" -p . -c nginx.conf
run_nginx_case wali 8082 "$HERE/nginx/wasm-conf" \
    "$IWASM" -f 'wasi:cli/run@0.2.12#run' "$WALI_APPS/nginx.aot" -p . -c nginx.conf
run_nginx_case wave 8082 "$HERE/nginx/wasm-conf" \
    env LD_LIBRARY_PATH="$WAVE_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$WAVE_RUNNER" "$WAVE_APPS/nginx.so" --homedir=.

python3 - "$WORK" "$RESULTS" "$NGINX_REQUESTS" "$NGINX_CLIENTS" \
    "$NGINX_KEEPALIVE_REQUESTS" "$NGINX_KEEPALIVE_CLIENTS" <<'PYEOF'
import re, sys
work, results, nr, nc, kr, kc = sys.argv[1:]
def rps(name, scenario):
    text = open(f"{work}/nginx-{name}-{scenario}.txt", errors="replace").read()
    m = re.search(r'Requests per second:\s*([\d.]+)', text)
    if not m: raise SystemExit(f"无法解析 Nginx 输出: {name}/{scenario}")
    return float(m.group(1))
names = ["native", "wasmtime", "wali", "wave"]
rows = ["| 场景 | Native rps | Wasmtime rps | WALI AOT rps | Wave rps |",
        "|---|---:|---:|---:|---:|",
        "| 短连接 | " + " | ".join(f"{rps(n, 'short'):,.0f}" for n in names) + " |",
        "| keepalive | " + " | ".join(f"{rps(n, 'keepalive'):,.0f}" for n in names) + " |"]
print("\n".join(rows))
with open(results, "a") as f:
    f.write(f"\n## Nginx（短连接 -n {nr} -c {nc}；keepalive -n {kr} -c {kc}）\n\n" + "\n".join(rows) + "\n")
PYEOF

echo
echo "完成。结果已写入 $RESULTS"
