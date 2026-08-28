#!/usr/bin/env bash
# 运行三项 benchmark（sqlite/redis/nginx，native vs wasm），输出结果并清理运行产物。
# 用法（由根 Makefile 的 bench-run 调用）:
#   WASMTIME=... ./benchmark/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WASMTIME="${WASMTIME:?需要 WASMTIME 环境变量}"
AB="$HERE/ab"
RESULTS="$HERE/RESULTS.md"

red() { printf '\033[31m%s\033[0m\n' "$1"; }
ok()  { printf '\033[32m%s\033[0m\n' "$1"; }

start_server() { # $1: 启动命令（前台阻塞），返回 PID
    "$@" > /tmp/bench-server.log 2>&1 &
    echo $!
}
stop_server() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
check_port_free() { # $1: port $2: 描述——被占用时直接报错退出（可能是残留进程）
    if python3 -c "import socket; socket.create_connection(('127.0.0.1',$1),timeout=1).close()" 2>/dev/null; then
        echo "错误: 端口 $1 已被占用（$2 无法启动）。请先清理占用该端口的进程。" >&2
        exit 1
    fi
}
wait_port() { # $1: port $2: 描述
    for i in $(seq 1 50); do
        if python3 -c "import socket; socket.create_connection(('127.0.0.1',$1),timeout=1).close()" 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    echo "错误: $2 (端口 $1) 未就绪" >&2; return 1
}

: > "$RESULTS"

############################################
# SQLite
############################################
echo "=== SQLite: speedtest1 --size 25（按测试集）==="
python3 - "$HERE" "$WASMTIME" "$RESULTS" << 'PYEOF'
import subprocess, re, sys
HERE, WASMTIME, RESULTS = sys.argv[1], sys.argv[2], sys.argv[3]

def parse(out):
    """按测试集汇总每行耗时；无头的首块（第一个测试集 main 不打 Begin 头）
    用 TOTAL - 其余测试集之和 计算"""
    sets, cur, order = {}, None, []
    for line in out.splitlines():
        m = re.search(r'Begin testset "(\w+)"', line)
        if m:
            cur = m.group(1); sets.setdefault(cur, 0.0); order.append(cur); continue
        if line.lstrip().startswith('TOTAL'): continue
        if cur is None: continue
        m = re.search(r'([\d.]+)s\s*$', line)
        if m: sets[cur] += float(m.group(1))
    tot = float(re.search(r'TOTAL.*?([\d.]+)s', out).group(1))
    return sets, tot

def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=300).stdout

SQLITE_DIR = f"{HERE}/sqlite"
n_sets, n_tot = parse(run([f"{SQLITE_DIR}/speedtest1-native", "--size", "25"], SQLITE_DIR))
w_sets, w_tot = parse(run([WASMTIME, "run", "--dir=.", "speedtest1.wasm", "--size", "25"], SQLITE_DIR))

n_main = n_tot - sum(n_sets.values())
w_main = w_tot - sum(w_sets.values())

rows = ["| 测试集 | 原生 | wasm | 比值 |", "|---|---|---|---|"]
for k in ["main"] + list(n_sets):
    n = n_main if k == "main" else n_sets[k]
    w = w_main if k == "main" else w_sets[k]
    rows.append(f"| {k} | {n:.3f}s | {w:.3f}s | {w/n:.2f}x |")
rows.append(f"| **TOTAL** | **{n_tot:.3f}s** | **{w_tot:.3f}s** | **{w_tot/n_tot:.2f}x** |")

print("=== sqlite 结果 ===")
print("\n".join(rows))
with open(RESULTS, 'a') as f:
    f.write("\n## SQLite（speedtest1 --size 25，按测试集）\n\n" + "\n".join(rows) + "\n")
PYEOF
rm -f "$HERE/sqlite"/speedtest1.db* "$HERE/sqlite"/*.lock

############################################
# Redis
############################################
echo "=== Redis: redis-benchmark -n 100000 -c 50 ==="
check_port_free 6390 "原生 redis"
check_port_free 6391 "wasm redis"
RN=$(start_server "$HERE/redis/redis-server-native" --port 6390 --save '' --appendonly no)
RW=$(start_server "$WASMTIME" run -W max-wasm-stack=8388608 -S cli -S inherit-network=y \
     --dir="$HERE/redis" --env HOME="$HOME" "$HERE/redis/redis-server.wasm" \
     --port 6391 --save '' --appendonly no)
wait_port 6390 "原生 redis" && wait_port 6391 "wasm redis"
CMDS="set,get,incr,lpush,rpush,lpop,rpop,sadd,hset,spop,mset"
"$HERE/redis/redis-benchmark" -h 127.0.0.1 -p 6390 -n 100000 -c 50 -q -t "$CMDS" > /tmp/redis-n.txt 2>/dev/null || true
"$HERE/redis/redis-benchmark" -h 127.0.0.1 -p 6391 -n 100000 -c 50 -q -t "$CMDS" > /tmp/redis-w.txt 2>/dev/null || true
stop_server $RN; stop_server $RW
rm -rf "$HERE/redis"/redis-data
python3 - "$RESULTS" << 'PYEOF'
import re, sys
def parse(path):
    res = {}
    for line in open(path, errors='replace'):
        m = re.match(r'(\w[\w ()]*?): ([\d.]+) requests per second', line.strip())
        if m and 'needed to benchmark' not in m.group(1):
            res[m.group(1)] = float(m.group(2))
    return res
n, w = parse('/tmp/redis-n.txt'), parse('/tmp/redis-w.txt')
rows = [f"| 命令 | 原生 rps | wasm rps | 比值 |", "|---|---|---|---|"]
for k in sorted(n, key=lambda k: -n[k]):
    if k in w:
        rows.append(f"| {k} | {n[k]:,.0f} | {w[k]:,.0f} | {n[k]/w[k]:.2f}x |")
print("=== redis 结果 ===")
print('\n'.join(rows))
with open(sys.argv[1], 'a') as f:
    f.write("\n## Redis（redis-benchmark -n 100000 -c 50）\n\n" + '\n'.join(rows) + "\n")
PYEOF

############################################
# Nginx
############################################
echo "=== Nginx: ab -n 50000 -c 50 ==="
check_port_free 8083 "原生 nginx"
check_port_free 8082 "wasm nginx"
NN=$(start_server "$HERE/nginx/nginx-native" -p "$HERE/nginx/native-conf" -c nginx.conf)
# 注意：必须 cd 进配置目录——wasmtime 的 cwd 是脚本所在目录，而 -p . 的 guest
# cwd 就是 wasmtime 进程 cwd，只有 cd 后 --dir=. 预打开的目录才对得上
NW=$(cd "$HERE/nginx/wasm-conf" && start_server "$WASMTIME" run -W max-wasm-stack=8388608 \
     -S cli -S inherit-network=y -S allow-ip-name-lookup=y --dir=. --env HOME="$HOME" \
     "$HERE/nginx/nginx.wasm" -p . -c nginx.conf)
wait_port 8083 "原生 nginx" && wait_port 8082 "wasm nginx"
"$AB" -n 50000 -c 50 http://127.0.0.1:8083/ > /tmp/ab-n.txt 2>/dev/null || true
"$AB" -n 50000 -c 50 http://127.0.0.1:8082/ > /tmp/ab-w.txt 2>/dev/null || true
"$AB" -n 20000 -c 128 -k http://127.0.0.1:8083/ > /tmp/ab-nk.txt 2>/dev/null || true
timeout 60 "$AB" -n 20000 -c 128 -k http://127.0.0.1:8082/ > /tmp/ab-wk.txt 2>/dev/null || true
stop_server $NN; stop_server $NW
rm -rf "$HERE/nginx"/{native-conf,wasm-conf}/logs/* "$HERE/nginx"/{native-conf,wasm-conf}/{client_body_temp,proxy_temp} 2>/dev/null
python3 - "$RESULTS" << 'PYEOF'
import re, sys
def rps(path):
    for line in open(path, errors='replace'):
        m = re.search(r'Requests per second:\s*([\d.]+)', line)
        if m: return float(m.group(1))
    return 0.0
def reason(path):
    for line in open(path, errors='replace'):
        m = re.search(r'(apr_socket_connect|apr_socket_recv|Failed requests:[^\n]*|Connection refused|timed out)', line)
        if m: return line.strip()[:60]
    return "N/A（超时未完成）"
sn, sw = rps('/tmp/ab-n.txt'), rps('/tmp/ab-w.txt')
kn, kw = rps('/tmp/ab-nk.txt'), rps('/tmp/ab-wk.txt')
def ratio(a, b):
    return f"{a/b:.2f}x" if b > 0 else "N/A"
def fmt(x):
    return f"{x:,.0f}" if x > 0 else "N/A"
rows = [
    "| 场景 | 原生 rps | wasm rps | 比值 |",
    "|---|---|---|---|",
    f"| 短连接 | {fmt(sn)} | {fmt(sw) if sw else reason('/tmp/ab-w.txt')} | {ratio(sn, sw)} |",
    f"| keepalive | {fmt(kn)} | {fmt(kw) if kw else reason('/tmp/ab-wk.txt')} | {ratio(kn, kw)} |",
]
print("=== nginx 结果 ===")
print('\n'.join(rows))
with open(sys.argv[1], 'a') as f:
    f.write("\n## Nginx（ab -n 50000 -c 50；keepalive -n 20000 -c 128）\n\n" + '\n'.join(rows) + "\n")
PYEOF

echo
ok "完成。结果已写入 $RESULTS"
