# wasi-sqlite-redis-nginx

三个经典应用的 WebAssembly/WASI 移植，全部在 [wasmtime](https://wasmtime.dev/) 上实测跑通：

| 应用 | 目录 | WASI 版本 | 源码修改 | 说明 |
|---|---|---|---|---|
| SQLite 3.53.4 | `wasip1-sqlite/` | preview1 | **零修改**（官方自带 WASI 支持） | 含交互式 CLI |
| Redis 7.4.11 | `wasip2-redis/` | preview2 | 有（`redis.patch`） | 完整 KV/数据结构命令 + AOF 持久化 |
| Nginx 1.31.4 | `wasip2-nginx/` | preview2 | 有（`nginx.patch`） | 单进程模式，静态文件 + 反向代理 |

- Redis/Nginx 需要 socket，而 `wasi:sockets` 只存在于 preview2，因此用 wasm32-wasip2；
  SQLite 不需要网络，用官方支持的 preview1。

## 目录结构

```
├── Makefile               # 根编排：构建 / demo 准备 / 运行
├── setup.sh               # 下载工具链到仓库外（wasi-sdk 34 + wasmtime 48）
├── wasip1-sqlite/         # 源码（官方 tarball 构建时下载）+ Makefile
├── wasip2-redis/          # redis-7.4.11 源码（修改）+ Makefile + redis.patch
├── wasip2-nginx/          # nginx-1.31.4 源码（修改）+ Makefile + nginx.patch
├── benchmark/             # 三个应用的基准测试文件
└── demo/                  # 预编译成品与测试配置（供演示）
```

## 编译

```bash
$ ./setup.sh          # 1) 下载 wasi-sdk 34 + wasmtime 48 到仓库外（../）
$ make build          # 2) 编译三个应用
$ make demo-prepare   # 3) 把成品拷进 demo/
```

## 演示

wasm 本身是跨平台的，无需再次编译（redis-cli原生可能需要重新编译）：

```bash
$ ./setup.sh --runtime   # 只下载 wasmtime
$ make cli-redis         # 重新编译 cli-redis
```

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
$ make bench-run          # 运行已经编译好的基准测试
$ make bench-build        # 重新编译基准测试 
```

### SQLite

使用 [SQLite 官方 benchmark speedtest1](https://sqlite.org/speed.html)（全量默认测试集，最全面的混合负载：
插入/索引/查询/ORM/JSON/CTE/浮点/解析/RTree/星型查询/应用场景）。

`--size 25`（25MB 库）按测试集：

| 测试集 | 原生 | wasm | 比值 |
|---|---|---|---|
| main | 0.356s | 0.607s | 1.71x |
| json | 0.079s | 0.116s | 1.47x |
| cte | 0.028s | 0.053s | 1.89x |
| rtree | 0.017s | 0.030s | 1.76x |
| orm | 0.015s | 0.024s | 1.60x |
| app | 0.015s | 0.025s | 1.67x |
| fp | 0.011s | 0.020s | 1.82x |
| star | 0.006s | 0.012s | 2.00x |
| parsenumber | 0.004s | 0.006s | 1.50x |
| **TOTAL** | **0.531s** | **0.893s** | **1.68x** |

更大负载：

| 负载 | 原生 | wasm | 比值 |
|---|---|---|---|
| `--size 100`（100MB 库） | 2.61s | 4.37s | 1.67x |

结论：开销在所有测试集均匀分布（1.5~2.0x），不随负载规模变化；

### Redis

使用官方 [redis-benchmark](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/benchmarks/)：
`-n 100000 -c 50`，两边都是单线程事件循环（原生 io-threads 默认关闭）。

| 命令 | 原生 rps | wasm rps | 比值 |
|---|---|---|---|
| SET | 106,724 | 78,401 | 1.36x |
| GET | 106,157 | 77,851 | 1.36x |
| INCR | 106,101 | 72,648 | 1.46x |
| LPUSH / RPUSH | 106,838 / 106,895 | 76,017 / 74,991 | 1.41x / 1.43x |
| LPOP / RPOP | 106,781 / 106,667 | 76,658 / 76,220 | 1.39x / 1.40x |
| SADD / SPOP | 105,597 / 105,932 | 77,369 / 79,713 | 1.36x / 1.33x |
| HSET | 105,988 | 75,614 | 1.40x |
| MSET（10 keys） | 106,838 | 63,452 | 1.68x |
| LRANGE 100（一百元素） | 72,543 | 53,850 | 1.35x |
| LRANGE 500（五百元素） | 23,708 | 22,965 | **1.03x** |

结论：简单命令 wasm 约为原生 **1.3~1.5x**；回复负载越大比值越低（LRANGE 500 已接近 1.0x，
传输字节数均摊了每请求的固定开销）。

### Nginx

使用 [ApacheBench](https://httpd.apache.org/docs/2.4/programs/ab.html)：`ab -n 50000 -c 50`
keepalive `ab -n 20000 -c 128 -k`；原生用 epoll，
wasm 只能用 select（平台限制）。

| 场景 | 原生 rps | wasm rps | 比值 |
|---|---|---|---|
| 短连接 | 20,627 | 9,583 | 2.15x |
| keepalive `-k` | 64,559 | **2,845** | **22.69x** ⚠️ |

结论：短连接场景 2.15x，**keepalive 场景存在平台级限制**：

- **p2 的 select() 单次调用 ~1.4ms**（原生 ~2μs，约 700 倍）——wasi-libc 的 select
   走 poll_oneoff 组件边界，带超时订阅时尤其昂贵

## 要求

- Linux x86_64；`curl`、`tar`、`cc`（编译宿主 redis-cli 用）、`python3`
- 工具链通过 `./setup.sh` 获取，或设置环境变量 `WASI_SDK` / `WASMTIME` 指向已有安装

## 已知限制

- **SQLite**：无 WAL、无扩展加载、单连接（多连接需自行处理 dotfile 锁）
- **Redis**：无 BGSAVE/BGREWRITEAOF（WASI 无 fork）、无 Lua（EVAL/SCRIPT/FUNCTION，
  wasmtime 48 不支持旧版异常处理）、无 unix socket/io-threads/sentinel/模块
- **Nginx**：仅单进程（`master_process off`）、select 事件后端、无 gzip/ssl/rewrite/fastcgi 等模块

详见各应用目录的 Makefile 注释。
