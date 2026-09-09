# wasi-sqlite-redis-nginx

三个经典应用的 WebAssembly/WASI 移植，全部在 [wasmtime](https://wasmtime.dev/)-v48.0.1、[WALI](https://github.com/Wasm-Thin-Kernel-Interfaces/WALI)、[wave](https://github.com/PLSysSec/wave) 上实测跑通：

| 应用 | 目录 | WASI 版本 | 源码修改 | 说明 |
|---|---|---|---|---|
| SQLite 3.53.4 | `wasip2-sqlite/` | preview2 | **零修改**（官方自带 WASI 支持） | 含交互式 CLI |
| Redis 7.4.11 | `wasip2-redis/` | preview2 | 有（`redis.patch`） | 完整 KV/数据结构命令 + AOF 持久化 |
| Nginx 1.31.4 | `wasip2-nginx/` | preview2 | 有（`nginx.patch`） | 单进程模式，静态文件 + 反向代理 |

- 三个应用统一用 wasm32-wasip2（wasi:sockets 在 preview2；SQLite 不需要网络但也与其余两者统一），使用 wasi-sdk-34.0 编译。

## 目录结构

```
wasi-sqlite-redis-nginx
├── Makefile               # 构建 / demo 准备 / 运行
├── setup.sh               # 只下载 wasi-sdk 34 到仓库外
├── wasip2-sqlite/         # 源码（官方 tarball 构建时下载）+ Makefile
├── wasip2-redis/          # redis-7.4.11 源码（修改）+ Makefile + redis.patch
├── wasip2-nginx/          # nginx-1.31.4 源码（修改）+ Makefile + nginx.patch
├── benchmark/             # 三个应用的基准测试、驱动脚本与结果
├── runtime/               # Wasmtime、WALI、Wave 的预编译 Linux x86_64 运行时
└── demo/                  # 预编译成品与测试配置（供演示）
```

## 编译

```bash
$ ./setup.sh          # 1) 下载 wasi-sdk 34 到仓库外（../）
$ make build          # 2) 编译三个应用
$ make demo-prepare   # 3) 把成品拷进 demo/
```

## 演示

Wasmtime 已放在仓库的 `runtime/` 中；运行预编译 demo 不需要执行 `setup.sh`。
Redis CLI 如需重新构建，可运行 `make cli-redis`。

直接运行 demo（demo/ 已自带编译好的成品）：

### SQLite

```bash
$ make run-demo-sqlite       # SQLite 交互式程序

SQLite version 3.53.4 2026-07-24 19:02:57
Enter ".help" for usage hints.
sqlite> .open test.db
sqlite> CREATE TABLE test (
    id INTEGER PRIMARY KEY,
    name TEXT,
    value REAL
);(x1...> (x1...> (x1...> (x1...> 
sqlite> INSERT INTO test VALUES (1, 'hello', 3.14);
sqlite> INSERT INTO test VALUES (2, 'wasm', 6.28);
sqlite> INSERT INTO test VALUES (3, 'sqlite', 9.42);
sqlite> SELECT * FROM test;
╭────┬────────┬───────╮
│ id │  name  │ value │
╞════╪════════╪═══════╡
│  1 │ hello  │  3.14 │
│  2 │ wasm   │  6.28 │
│  3 │ sqlite │  9.42 │
╰────┴────────┴───────╯
```

### Redis

```bash
$ make run-demo-redis        # 起 redis-server（6379）

42:C 06 Oct 2063 11:29:55.576 # Can't create the pipe for module threads: Not supported
42:C 06 Oct 2063 11:29:55.576 * oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo
42:C 06 Oct 2063 11:29:55.576 * Redis version=7.4.11, bits=32, commit=fa6e018c, modified=1, pid=42, just started
42:C 06 Oct 2063 11:29:55.576 * Configuration loaded
42:M 06 Oct 2063 11:29:55.576 * monotonic clock: POSIX clock_gettime
42:M 06 Oct 2063 11:29:55.577 # Warning: 32 bit instance detected but no memory limit set. Setting 3 GB maxmemory limit with 'noeviction' policy now.
                _._                                                  
           _.-``__ ''-._                                             
      _.-``    `.  `_.  ''-._           Redis Community Edition      
  .-`` .-```.  ```\/    _.,_ ''-._     7.4.11 (fa6e018c/1) 32 bit
 (    '      ,       .-`  | `,    )     Running in standalone mode
 |`-._`-...-` __...-.``-._|'` _.-'|     Port: 6379
 |    `-._   `._    /     _.-'    |     PID: 42
  `-._    `-._  `-./  _.-'    _.-'                                   
 |`-._`-._    `-.__.-'    _.-'_.-'|                                  
 |    `-._`-._        _.-'_.-'    |           https://redis.io       
  `-._    `-._`-.__.-'_.-'    _.-'                                   
 |`-._`-._    `-.__.-'    _.-'_.-'|                                  
 |    `-._`-._        _.-'_.-'    |                                  
  `-._    `-._`-.__.-'_.-'    _.-'                                   
      `-._    `-.__.-'    _.-'                                       
          `-._        _.-'                                           
              `-.__.-'                                               

42:M 06 Oct 2063 11:29:55.577 # WARNING: The TCP backlog setting of 511 cannot be enforced because SOMAXCONN is set to the lower value of 128.
42:M 06 Oct 2063 11:29:55.577 * WASI build: background jobs run inline (no worker threads).
42:M 06 Oct 2063 11:29:55.577 * Server initialized
42:M 06 Oct 2063 11:29:55.587 * Creating AOF base file appendonly.aof.1.base.rdb on server start
42:M 06 Oct 2063 11:29:55.594 * Creating AOF incr file appendonly.aof.1.incr.aof on server start
42:M 06 Oct 2063 11:29:55.594 * Ready to accept connections tcp

# 另开终端
$ demo/redis/redis-cli -p 6379

127.0.0.1:6379> SET name redis-wasm
OK
127.0.0.1:6379> GET name
"redis-wasm"
127.0.0.1:6379> SET counter 100
OK
127.0.0.1:6379> INCR counter
(integer) 101
127.0.0.1:6379> KEYS *
1) "counter"
2) "name"
127.0.0.1:6379> SET persistent hello
OK
127.0.0.1:6379> SAVE
OK       # 会在 redis-data/ 内保存 dump.rdb
```

### Nginx

```bash
$ make run-demo-nginx        # 起 nginx（8080）

2026/08/27 10:55:55 [notice] 42#0: using the "select" event method
2026/08/27 10:55:55 [notice] 42#0: nginx/1.31.4
2026/08/27 10:55:55 [notice] 42#0: built by clang 23.1.0-wasi-sdk (https://github.com/llvm/llvm-project 895aa2c896ada719451be2e3673c83da8ddf1141)
2026/08/27 10:55:55 [notice] 42#0: OS: wasi 0.0.0
2026/08/27 10:55:55 [notice] 42#0: getrlimit(RLIMIT_NOFILE): 1048576:0

# 另开终端
$ curl http://localhost:8080
<!DOCTYPE html>
<html>
<head><title>nginx on wasmtime</title></head>
<body>
<h1>nginx running inside wasmtime (WASI p2)</h1>
<p>Hello from nginx/run/html/index.html</p>
</body>
</html>

$ curl http://localhost:8080/not-exist.txt
<html>
<head><title>404 Not Found</title></head>
<body>
<center><h1>404 Not Found</h1></center>
<hr><center>nginx/1.31.4</center>
</body>
</html>

# 起一个后端服务验证反向代理
$ mkdir -p /tmp/backend && echo '<h1>backend says hello</h1>' > /tmp/backend/index.html
$ python3 -m http.server 8081 --bind 127.0.0.1 --directory /tmp/backend &

$ curl -I http://127.0.0.1:8080/proxy/
HTTP/1.1 200 OK
Server: nginx/1.31.4
Date: Thu, 27 Aug 2026 11:03:06 GMT
Content-Type: text/html
Content-Length: 28
Connection: keep-alive
Last-Modified: Thu, 27 Aug 2026 11:01:14 GMT
```

## 基准测试

```bash
$ make bench-build        # 重建 P2/native/两套 AOT，运行四路测试，输出 RESULTS.md
$ make bench-run          # 不重新编译，直接运行全部测试并刷新 RESULTS.md
```

测试矩阵固定为 Native、Wasmtime、WALI AOT、Wave AOT（wasmtime JIT 和 AOT 时间并未太大差别），四者使用相同的应用和
workload：SQLite 官方 `speedtest1 --size 25` 全量测试集；Redis 官方
`redis-benchmark -n 100000 -c 50` 的 11 类命令；Nginx 的短连接与 keepalive
ApacheBench 测试。服务端逐个运行，避免并行争抢 CPU。Markdown 表格同时打印到
终端并写入 `benchmark/RESULTS.md`。

仓库内 `runtime/` 已带固定版本的预编译运行时，因此 `make bench-run`
不需要 WALI/Wave 源码。`make bench-build` 则会用 `-O3 -flto` 重建三个
P2 component 和 Native 对照，并从相邻的 `WALI`/`wave` 源码树重建匹配的
AOT 产物；路径可用 `WALI_ROOT`/`WAVE_ROOT` 覆盖。详细适配与生成方式见
`NOTICE.md`。

## SQLite（speedtest1 --size 25，按测试集）

| 测试集 | Native | Wasmtime | WALI AOT | Wave |
|---|---:|---:|---:|---:|
| main | 0.354s | 0.607s | 0.541s | 0.479s |
| orm | 0.014s | 0.024s | 0.021s | 0.019s |
| cte | 0.031s | 0.052s | 0.044s | 0.037s |
| json | 0.081s | 0.116s | 0.101s | 0.090s |
| fp | 0.011s | 0.020s | 0.017s | 0.015s |
| parsenumber | 0.004s | 0.006s | 0.006s | 0.005s |
| rtree | 0.016s | 0.029s | 0.025s | 0.023s |
| star | 0.007s | 0.012s | 0.010s | 0.008s |
| app | 0.015s | 0.024s | 0.024s | 0.020s |
| **TOTAL** | **0.533s** | **0.890s** | **0.789s** | **0.696s** |

## Redis（redis-benchmark -n 100000 -c 50）

| 命令 | Native rps | Wasmtime rps | WALI AOT rps | Wave rps |
|---|---:|---:|---:|---:|
| SET | 106,838 | 102,041 | 109,890 | 110,742 |
| GET | 104,712 | 100,301 | 110,497 | 110,254 |
| INCR | 105,932 | 100,503 | 109,170 | 110,011 |
| LPUSH | 106,383 | 102,354 | 110,011 | 109,769 |
| RPUSH | 106,496 | 102,041 | 109,290 | 109,769 |
| LPOP | 106,496 | 101,729 | 110,619 | 109,649 |
| RPOP | 106,610 | 101,937 | 110,742 | 110,132 |
| SADD | 105,485 | 101,626 | 108,814 | 109,769 |
| HSET | 105,820 | 101,112 | 109,649 | 109,890 |
| SPOP | 106,045 | 101,626 | 110,742 | 109,769 |
| MSET (10 keys) | 116,009 | 86,133 | 107,527 | 110,011 |

## Nginx（短连接 -n 50000 -c 50；keepalive -n 20000 -c 120）

| 场景 | Native rps | Wasmtime rps | WALI AOT rps | Wave rps |
|---|---:|---:|---:|---:|
| 短连接 | 20,060 | 17,692 | 20,111 | 19,987 |
| keepalive | 107,217 | 27,595 | 56,847 | 64,313 |

## 要求

- Linux x86_64；`curl`、`tar`、`cc`（编译宿主 redis-cli 用）、`python3`
- wasi-sdk 通过 `./setup.sh` 获取，也可设置 `WASI_SDK`；Wasmtime 默认使用
  `runtime/wasmtime/wasmtime`，仍可用 `WASMTIME` 覆盖

## 已知限制

- **SQLite**：无 WAL、无扩展加载、单连接（多连接需自行处理 dotfile 锁）
- **Redis**：无 BGSAVE/BGREWRITEAOF（WASI 无 fork）、无 Lua（EVAL/SCRIPT/FUNCTION，
  wasmtime 48 不支持旧版异常处理）、无 unix socket/io-threads/sentinel/模块
- **Nginx**：仅单进程（`master_process off`）、select 事件后端、无 gzip/ssl/rewrite/fastcgi 等模块

详见各应用目录的 Makefile 注释。
