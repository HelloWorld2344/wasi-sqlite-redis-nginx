# Wasmtime / WALI / Wave 本地改动说明

本文记录三个运行时用于本仓库 SQLite、Redis、Nginx 基准的构建和本地改动，
以及统一 benchmark 的结果与分析。

三个应用输入始终是 WASI Preview 2 component，文件头为
`00 61 73 6d 0d 00 01 00`。适配工作全部位于运行时、AOT 工具链和宿主 shim；
没有把应用重新编译或转换成 WASI Preview 1。

## 总体方案

WALI 和 Wave 都不能直接加载 Component Model 二进制，因此两条路径首先用
`wasm-tools component unbundle` 取出 component 内的主 core module。这个 core
module 的 imports 仍然是 canonical ABI 形式的 WASI 0.2 接口，不是 P1 接口：

- WALI 将这些 imports 注册为 WAMR native functions，并直接调用导出的
  `wasi:cli/run@0.2.12#run`；
- Wave 用扩展后的 wasm2c 将 core module AOT 转成宿主 C，再链接实现相同
  canonical ABI 的宿主 shim 和 `libwave.so`。

当前适配范围以这三个 benchmark 实际使用的接口为准，并不是完整的 WASI 0.2
实现。

### WALI/Wave adapter 的安全边界

两条 AOT 路径仍保留 core Wasm 的线性内存隔离：64 位 Linux 上使用大块保留
虚拟地址和 guard pages，让越界访问触发硬件 trap；间接调用也检查 table 范围和
函数类型。但是本仓库的 P2 adapter 是 benchmark 专用实现，不具备 Wasmtime
完整的 capability 与 resource 安全语义，不能用于运行任意不可信 component：

- 预打开目录直接映射为 `AT_FDCWD`，`openat` 没有完整拒绝绝对路径和 `..` 逃逸，
  guest 可访问运行进程权限范围内的其他路径；
- TCP 直接使用宿主 socket，没有独立的网络 capability 策略；
- resource 是简单的进程全局整数槽位，没有 Wasmtime ResourceTable 的父子所有
  权和 generation 检查，旧 handle 复用、drop 顺序等语义较弱；
- 部分 drop 是简化或空操作，未覆盖 import 只会 warning 或中止，errno 与异步
  stream 状态也只实现 benchmark 用到的子集；
- shim 是原生 C/native function，任何长度、生命周期或 ABI 实现错误都处在宿主
  信任边界内，可能从 guest trap 升级为宿主崩溃甚至内存安全问题。

因此提交的固定 P2/AOT 文件应视为可信输入；WALI/Wave 的当前性能数字不能等同
为“具有 Wasmtime 同等级通用安全语义时”的性能。

## Wasmtime 构建优化

仓库内的 Wasmtime 来自 v48.0.1（commit `7bac2c277`）。应用保持不变；运行时
使用上游已有的 `fastest-runtime` profile 重新构建，并只启用这三
个 P2 应用所需的 CLI、Cranelift 和 Component Model 功能：

```bash
cd ../wasmtime
CARGO_TARGET_DIR=target-bench-generic \
  cargo build --profile fastest-runtime --no-default-features \
  --features run,compile,cranelift,component-model,disable-logging
```

该 profile 使用单个 codegen unit 和全程序 LTO。构建没有使用
`-C target-cpu=native`，所以产物仍是通用 Linux x86_64 二进制。与官方同版本
发布包交错测量的中位数如下（这些数字用于判断运行时构建方案，不替代下方完整
四路 benchmark）：

| 工作负载 | 官方发布包 | 优化构建 | 变化 |
|---|---:|---:|---:|
| SQLite `--size 100` TOTAL | 4.297s | 4.322s | 无稳定提升 |
| Redis SET | 78,625 rps | 92,160 rps | +17% |
| Redis GET | 79,530 rps | 96,806 rps | +22% |
| Redis MSET | 64,978 rps | 77,400 rps | +19% |
| Nginx 短连接 | 9,865 rps | 11,648 rps | +18% |
| Nginx keepalive | 2,859 rps | 2,870 rps | 基本不变 |

另用相同裁剪功能的普通 `release` profile 验证，Redis SET/GET/MSET 约为
84.7k/84.9k/69.7k rps，Nginx 短连接约为 10.1k rps，说明主要收益来自 LTO，
功能裁剪只贡献较小部分。SQLite 的采样热点集中在 `sqlite3VdbeExec`、B-tree、
比较和 JSON 等 guest 代码，宿主调用不是主要瓶颈，因此宿主侧 LTO 没有帮助。
Nginx keepalive 对构建优化同样不敏感。后续并发曲线和 wasi-libc 源码检查确认，
当时的主要瓶颈并不是 `select()` 本身，而是 P2 缺少 `TCP_NODELAY`（见下文）。

该构建保留 `compile` 子命令，可以把整个 P2 component 预编译为 Wasmtime AOT
产物：

```bash
runtime/wasmtime/wasmtime compile -o speedtest1.cwasm \
  benchmark/sqlite/speedtest1.wasm
runtime/wasmtime/wasmtime run --allow-precompiled -S cli --dir=. \
  speedtest1.cwasm --size 25
```

一次冷启动测量中，直接运行 component 的进程墙钟时间约为 2.45s，预编译后约
为 0.90s；但 speedtest 自身报告的 TOTAL 分别为 0.909s 和 0.893s，差异属于
波动。这说明 AOT 能消除约 1.5s 的启动编译成本，不能改善本 benchmark 表格所
统计的 SQLite 稳态执行时间。`.cwasm` 只应加载可信产物，并且与 Wasmtime 版本
和构建配置绑定。

### Wasmtime Cranelift 的 SQLite byte-load combine

本地 Cranelift 在 x86-64 后 egraph 阶段识别 SQLite/WASI 编译结果中的两类
big-endian 反序列化模式：一类把 load 后的 32-bit rotate/xor 恒等式改成原位
`bswap`；另一类把同 base、同 flags、同基本块且精确覆盖 `0..7` 的八次
`uload8.i64 + shift/or` 改成一次 `load.i64 + bswap`。前者不移动 load；后者只对
Wasmtime 显式登记的非共享 Wasm 线性内存 alias region 启用。共享内存、VMContext、
GC 和 host memory 都不会拓宽，原有越界 trap 与副作用检查保持不变。

8-byte pass 原先在函数超过 1,024 条 DFG 指令时直接返回，未覆盖 CTE 中占约 9.6%
cycles 的 `sqlite3VdbeRecordCompareWithSkip`。最终只把该 pass 的有界上限提高到
4,096；32-bit peephole 仍维持 1,024。目标函数从 5,144 B 缩至 4,920 B。相对提高
上限前的 Wasmtime AOT，八轮正反交错 `cte --size 250` 中位数从 7.195s 降到
7.105s（-1.26%），instructions 从约 98.675B 降到 97.300B（-1.39%）。新增单元
测试覆盖大于 1,024 条指令的函数。

2/3/5-byte 特判、共享部分表达式 extraction 和 SQLite 源码
`memcpy + __builtin_bswap64` 均未得到稳定额外墙钟收益，已经回退；应用源码、P2
接口和 benchmark 内容没有改变。

### SQLite 跨目标 PGO

统一构建现在默认先用 host Clang 编译带 instrumentation 的同一份
`speedtest1.c + sqlite3.c`，运行完整 `--size 100` workload，再把
`llvm-profdata` 合并后的 source profile 用于 wasm32-wasip2 的 `-O3 -flto`
编译。source profile 不绑定目标 ISA；本机验证中 3,901 个函数只有 9 个因
native/WASI 条件编译导致 CFG hash 不同而被 Clang 忽略，其余 SQLite 热函数均能
使用计数。SQLite 源码、测试参数和运行时安全语义没有改变。

四轮交错测试中，未做 PGO 的 Wasmtime CTE 中位数约为 `7.116s`，PGO 版约为
`6.180s`（-8.3%；另一组同机测试为约 -12%，受当天频率影响）。标准完整
`--size 25` 四轮从约 `0.879s` 降到 `0.837s`（-4.8%）。最终完整四路回归为
Native/Wasmtime/WALI/Wave `0.536/0.840/0.739/0.659s`；上一份非 PGO component
结果为 `0.526/0.893/0.782/0.690s`。判断绝对 native 差距仍应使用同轮结果。

`make bench-build` 默认启用该流程，需要 host `clang` 和 `llvm-profdata`；可用
`HOST_CLANG`、`LLVM_PROFDATA` 指定工具，或以 `SQLITE_PGO=0` 复现非 PGO 构建。

### SQLite VDBE 的 Wasm-only 源码补丁

标准 `--size 25` 的 perf/DWARF 映射确认 `sqlite3VdbeExec` 仍有明显寄存器压力：
Wasmtime 栈帧约 848 B，native 约 392 B，且热机器码中存在密集 spill/reload。
PGO+LTO 将 `sqlite3VdbeHalt` 的 cursor/pager 退出链内联进主 opcode switch。
`wasip2-sqlite/sqlite-wasm-vdbe-noinline.patch` 仅在 `__wasm__` 下保留 Halt 调用边界，
并抽出 `OP_OpenDup`，使 VDBE 机器码约 240→212 KB、栈帧 848→640 B。相对最初
版本 cycles 约 -1.20%、instructions 约 -0.61%；热 B-tree、全局 cursor helper
和 `OP_VColumn` 拆分无收益；`OP_OpenRead/OpenWrite/ReopenIdx` 拆分也慢约 1%，
均未保留。最新完整回归为 Native/Wasmtime/WALI/Wave
`0.585/0.913/0.824/0.707s`；四者都受本轮较低整机频率影响，Wasmtime/native
比值为 1.56，局部改动使用交错硬件计数判断。

### Wasmtime P2 网络 fast path

Wasmtime 源码树中另外保留了四项不改变 P2 语义的本地优化：

- `crates/wasi/src/p2/tcp.rs`：小 socket write 先直接轮询一次；全部写完时避免
  装箱 future 和进入异步写状态机，短写、WouldBlock 与错误仍走原路径，写许可
  在完成后归零；
- `crates/wasi/src/p2/tcp.rs`、`crates/wasi/src/sockets/tcp.rs`：TCP read 使用
  `BytesMut` spare capacity 和 Tokio `try_read_buf`，不再先清零 guest 请求的整块
  最大容量；只有内核实际写入的字节会被标为已初始化并返回；
- `crates/wasi-io/src/impls.rs`：单个 pollable 直接等待并返回索引 0，避免构造
  BTreeMap、future 列表和 PollList；批量列表全部由支持直接 readiness 的 TCP
  stream、监听 socket 和 deadline 组成时，直接在 ResourceTable 上逐项 poll，
  避免每个描述符一个 boxed future 以及 BTreeMap/分组 Vec。混合其他类型时仍走
  原来的通用 future 路径；
- `crates/wasi-io/src/poll.rs`、`crates/wasi-io/src/streams.rs` 和
  `crates/wasi/src/p2/host/{tcp,clocks}.rs`：为上述类型提供可选的直接
  `poll_ready`；deadline 在订阅时创建并复用 Tokio `Sleep`，零超时仍先 yield
  一次，保留原先避免忙轮询饿死 reactor 的行为。

相对上文仅做 LTO/功能裁剪的 Wasmtime，三轮交错测试的中位数为：

| 工作负载 | 修改前 | fast path | 变化 |
|---|---:|---:|---:|
| Redis SET | 93,197 rps | 101,420 rps | +8.8% |
| Redis GET | 95,329 rps | 100,908 rps | +5.9% |
| Redis MSET | 76,511 rps | 81,301 rps | +6.3% |
| Nginx 短连接 | 12,083 rps | 12,012 rps | 无稳定变化 |
| Nginx keepalive | 2,864 rps | 2,863 rps | 无稳定变化 |

`wasmtime-wasi-io` crate 编译和测试通过（该 crate 当前没有单元测试），随后
`make bench-run` 四路完整回归通过。完整 `wasmtime-wasi` 测试需要本机额外安装
`wasm32-unknown-unknown` Rust target，当前环境未安装，构建 test-programs 时因而
停止。这些 Nginx 结果说明 buffer 清零、小写入 future 和单 pollable 路径不是
当时 keepalive 慢的主因。

### Nginx keepalive：TCP_NODELAY workaround

P2 Nginx 实际启动日志为 `using the "select" event method`；WASI 没有 Linux
`epoll` 接口。把 guest 改为 Nginx `poll` event module 后，Wasmtime keepalive
第一轮约为 `2,847 rps`，与 `select` 的约 `2,880 rps` 相同，且连续压力测试更
容易出现 socket timeout。反汇编和 wasi-libc 34 源码都表明 `select()` 与
`poll()` 最终进入同一个 P2 `ppoll()` 实现，因此换事件模块绕不过 P2 pollables。
测试后恢复了原来的 `select` 构建。

真正的特征来自并发曲线：修复前 Wasmtime keepalive 在 `c=8/32/128` 时分别约
为 `182/729/2,779 rps`，即每条连接始终只有约 23 req/s、每请求停顿约 44ms；
native epoll 对照在 `c=1/8/32/128` 时约为
`37,145/64,017/64,075/60,713 rps`。固定约 40ms 的连接内延迟是 Nagle 与 TCP
delayed ACK 的典型交互，不是 O(n) event scan。

wasi-libc 34 的 P2 `setsockopt(TCP_NODELAY)` 明确是兼容性占位：只保存
`fake_nodelay` 并返回成功，不会修改宿主 socket，因为 WASI Sockets 0.2 没有
暴露该选项。Nginx 因而认为 `TCP_NODELAY` 已生效，实际仍开启 Nagle。当前三条
benchmark 运行路径在 accept 后对宿主连接设置 `TCP_NODELAY`：

- Wasmtime：`crates/wasi/src/sockets/tcp.rs` 的 P2 accept 路径；
- WALI：`core/iwasm/libraries/libc-wali/wasip2.c` 的 P2 TCP accept adapter；
- Wave：Redis/Nginx 共用的 `examples/redis-p2/wasip2_shim.c`。

这是运行时/adapter 的低延迟策略 workaround，不会增加 guest 的文件或网络
权限，但并不等价于完整实现 POSIX socket option：它会对所有接受的 P2 TCP
连接启用该选项，可能增加小包数量。长期方案应由标准 WASI socket 接口显式携带
`TCP_NODELAY`，届时应删除该策略。

早期无分配 TCP readiness 原型在修复 `TCP_NODELAY` 前测试，五轮旧/新中位数都
约为 `2.85k rps`，当时固定约 40ms 的网络停顿掩盖了 CPU 收益，因此原型被回退。
修复网络停顿后重新实现了上面的通用批量 fast path。`-n 15000 -c 120 -k` 五轮
旧/新交错测试的中位数从 `14,997` 提升到 `16,072 rps`（`+7.2%`）；短连接没有
稳定变化。正式完整 benchmark 中 keepalive 从上一版 `16,013` 提升到
`17,100 rps`（`+6.8%`）。`c=128` 仍在约一千多个请求后超时，说明这个边界不是
boxed future/BTreeMap 引起的。

### Wasmtime accept/drop 与安全 metadata 缓存

继续保留了三项语义范围较窄的改动：

- P2 socket 普通 close 或可立即完成的显式 `shutdown(both)` 时，如果读侧仍打开
  且写侧已没有在途写入，用一次
  `shutdown(SHUT_RDWR)` 代替两个 stream 析构分别调用 `SHUT_RD`、`SHUT_WR`；
  单边关闭和在途写入仍走原有路径，不提前丢弃已接受的写入；
- `ResourceTable` 的小型 parent/child 索引集合由 `BTreeSet` 改为紧凑 `Vec`，减少
  socket→两个 stream、stream→pollable 在 accept/drop 路径中的树节点分配和
  遍历，父子所有权及删除约束不变；
- `open_at` 本来就要读取 metadata 区分文件和目录，现在把已打开对象不可变的
  descriptor type 留在 `File` 中，后续 `get-type` 不再重复查询 metadata。

Tokio 对每条 accepted `TcpStream` 只注册一次 reactor，input/output stream 共享
同一个 `Arc<TcpStream>`，所以不存在可删除的重复 reactor 注册。P2 API 要返回
socket、input、output 和按需 pollable，相关 ResourceTable 项也不能在不改变资源
所有权语义的情况下合并。

上述三项在相同精简 feature、相同 LTO profile 下做三轮旧/新交错测试：短连接
中位数 `11,814 → 11,855 rps`（`+0.35%`），keepalive
`16,107 → 16,022 rps`（`-0.53%`），均在轮间噪声内。因此它们减少了确定的工作，
但本 benchmark 没有测得稳定吞吐收益，不把它们计作性能提升。

没有加入路径或完整 metadata 的运行时全局缓存。文件大小、时间戳、链接数、权限
检查和符号链接解析结果仍按 hostcall 读取宿主文件系统。benchmark 现在由 Native
和 P2 Nginx 配置对称、显式启用 `open_file_cache`；这是 guest 管理员选择的缓存
语义，不是通用运行时暗中模拟。

`c=128` 的进一步探针显示，停住时 host poll 列表稳定为 130 项；Wasmtime 主线程
持续占用一个 CPU，Tokio worker 在等待。采样位置在 wasi-libc guest
`select/pselect`、canonical resource list lift/borrow 和 output `check-write` 之间，
不是 reactor 死锁。wasi-libc 34 的 P2 `fd_set` 是线性 fd 数组，`pselect` 合并集合
使用嵌套线性搜索，并在每轮构造 borrowed pollable 列表。`-n 5000 -c 127 -k`
仍能完成但出现约 1 秒尾延迟；`c=128/129` 都在完成 1344 个请求后稳定 timeout。
去掉端口就绪探测连接、提高 `worker_connections`、提高 backlog、启用
`open_file_cache` 均不能消除边界。只修改 Wasmtime 尚未找到不伪造 readiness、
不放松 canonical borrow 校验的安全修复，因此统一 benchmark 继续使用稳定的
`c=120`。

诊断用 native Nginx 分别采用 epoll 与 select：短连接均约 `20.2k rps`，
keepalive 分别约 `66k` 与 `60k`～`64k`，因此 Wasmtime 剩余差距不是 Nginx
选择 select 的算法差距。系统调用计数显示，每个 Wasmtime 静态文件请求约有
3 次 `openat2`、5 次 `statx` 和 2 次 `sendto`，native 则约为 1 次 `openat`、
2 次 metadata 查询和 1 次 `writev`。三轮交错验证后，benchmark 已对 Native 和
P2 配置同时启用 Nginx `open_file_cache`。Wasmtime 短连接从
`12.40k`～`12.45k` 升到 `17.95k`～`18.05k`，keepalive 从
`16.65k`～`16.87k` 升到 `26.71k`～`27.31k`。这说明 capability 路径解析和
重复 metadata 查询是明显成本；批量 poll 的收益仍主要出现在大并发列表。

启用 workaround 后，Wasmtime 在 `c=1/8/32` 达到约
`18,116/23,924/28,381 rps`；WALI 在 `c=32/120` 达到约
`35,763/34,269 rps`；Wave 达到约 `41,248/39,591 rps`。Wasmtime 在恰好
`c=128` 时可重复出现 ApacheBench timeout，而 `c=127` 及以下完成；提高
`worker_connections` 和 listen backlog 都不能消除该边界。为使四路测试稳定且
保持相同请求内容，正式 keepalive 规模从 `-c 128` 调为 `-c 120`。

## WALI 改动

WALI 顶层仓库新增：

- `Makefile`：增加 `wamrc-system`，从 PATH 或 `/usr/lib/llvm-*` 查找宿主
  `llvm-config`，用系统 LLVM 构建 `wamrc`，并为 GCC 14 添加旧版 WAMR 所需的
  `-Wno-error=incompatible-pointer-types`。
- `run-wasip2.sh`：创建临时目录、拆分 P2 component，然后用 `iwasm -f` 调用
  P2 CLI 的 `run` 导出；命令行参数原样传给 guest。增加 `--aot` 模式，可先用
  `wamrc` 将拆出的 canonical-ABI core module 编译成 AOT 再运行。
- `benchmark-shims.c`：早期探索 WALI/musl 构建时使用的 shim；最终 P2 运行
  路径不依赖此文件。

嵌套的 `WALI/wasm-micro-runtime` 仓库改动：

- `core/iwasm/libraries/libc-wali/wasip2.c`：新增 P2 canonical ABI 宿主适配。
  已覆盖 CLI 参数与环境变量、stdin/stdout/stderr、terminal 判定、monotonic 与
  wall clock、preopen、descriptor open/stat/stat-at/read/write、input/output
  stream、poll 与 timer，以及 Redis/Nginx 使用的 TCP socket resource、
  bind/listen/accept/shutdown 和 socket options。wasi-sdk 34 的 LTO 产物还会导入
  `wasi:random/random.get-random-bytes`；适配使用 Linux `getrandom(2)` 填充
  canonical-ABI `list<u8>`，完整处理短读和 `EINTR`。
- `core/iwasm/libraries/libc-wali/inc/wasip2.h`：声明 P2 native 注册入口。
- `core/iwasm/libraries/libc-wali/libc_wali.cmake`：把 `wasip2.c` 加入 WAMR
  libc-wali 构建。
- `core/iwasm/common/wasm_native.c`：在原 WALI native symbols 之后初始化并注册
  P2 native imports。
- `core/iwasm/compilation/aot_emit_function.c`：raw native import 即使带有用于类型
  校验的 signature，也必须经 `aot_invoke_native()` 调用。原实现会错误生成普通
  C ABI 的直接调用，导致 P2 raw adapter 把 guest 的第一个整数参数当成 argv
  指针并崩溃。
- `product-mini/platforms/posix/main.c`：识别
  `wasi:cli/run@0.2.12#run`；将宿主 argc/argv 暴露给 P2 adapter，并以零个
  core-Wasm 参数调用 canonical ABI 导出。
- `core/iwasm/libraries/libc-wali/wali.c`：只包含文件末尾换行整理，不改变逻辑。

WALI 的本地构建命令是：

```bash
ninja -C ../WALI/build/wamr/iwasm
```

运行 P2 component 的通用形式是：

```bash
../WALI/run-wasip2.sh COMPONENT.wasm [guest arguments...]
```

AOT 模式为：

```bash
../WALI/run-wasip2.sh --aot COMPONENT.wasm [guest arguments...]
```

本地 `wamrc` 使用 WAMR 2.4.3 和系统 LLVM 19 构建在
`WALI/build/wamr/wamrc-system/`。GCC 14 构建旧 WAMR 源码时需要
`-Wno-error=incompatible-pointer-types`。SQLite `speedtest1 --size 25` 的一次
验证结果为：fast interpreter `16.398s`，WALI AOT `0.803s`，native
`0.537s`；AOT 相比当前解释路径约快 20 倍。

可重复构建本地 `wamrc`：

```bash
make -C ../WALI wamrc-system
```

该目标优先查找 PATH 中的 `llvm-config`，否则选择 `/usr/lib/llvm-*` 下版本最高
的实例；也可通过 `LLVM_CONFIG=/path/to/llvm-config` 显式指定。

## Wave 改动

Wave 顶层仓库的 Rust 构建兼容性改动：

- `Cargo.toml`、`Cargo.lock`：固定 `libc`、`paste`、`log`、`env_logger`、
  `quickcheck`、`quickcheck_macros` 和 `regex` 到当前 Rust 1.61 可编译的版本。
- `waverunner/Cargo.toml`、`waverunner/Cargo.lock`：固定 `libc`、`clap`、
  `anyhow` 的兼容版本。
- `src/tcb/sbox_mem.rs`：公开 `wave_alloc_linmem`，供 runner 分配线性内存。
- `waverunner/src/waverunner.rs`：改用公开后的分配入口。
- `bindings/wave.h`：随当前 cbindgen 重新生成的 C 绑定；包含路径长度常量、
  subscription 常量和 descriptor 枚举布局的同步。

嵌套的 `wave/tools/wasm2c_sandbox_compiler` 仓库改动：

- `src/tools/wasm2c.cc`：允许 bulk-memory feature。
- `src/c-writer.cc`：增加 `memory.copy`、`memory.fill`、饱和浮点转整数和
  sign-extension 指令的 C 代码生成。
- `src/wasm2c.c.tmpl`、`src/prebuilt/wasm2c.include.c`：增加 trunc-sat
  runtime helpers，并同步预生成 include。

Wave 新增三个 P2 构建目录：

- `examples/speedtest1-p2/`
- `examples/redis-p2/`
- `examples/nginx-p2/`

每个目录的 Makefile 都执行如下流程：拆分 component；用
`wasm-tools print`/`parse` 将 padded encoding 规范化，兼容旧版 WABT；使用修改后
的 wasm2c 生成 C；再将生成代码、wasm2c runtime、P2 宿主 shim 和
`libwave.so` 链接成共享库。SQLite 有独立 shim；Redis 与 Nginx 共用包含
filesystem、stream、poll、clock 和 TCP 的实现，Nginx 通过编译宏启用其差异。
其中 SQLite shim 同样用 Linux `getrandom(2)` 实现
`wasi:random/random.get-random-bytes`，以支持 wasi-sdk 34 在 `-O3 -flto` 下
保留的随机数 import。
生成的弱 import 若实际被调用，会打印缺失 symbol 并确定性中止，避免静默地产生
错误结果。

`examples/speedtest1/` 是早期探索目录，不属于最终 P2 benchmark 路径。最终
运行使用 wasm2c 项目的 `wasm2c-runner`；对 Rust `waverunner` 的调整是构建兼容
和内存接口准备工作。

三个 P2 目标可分别构建为：

```bash
make -C ../wave/examples/speedtest1-p2 all
make -C ../wave/examples/redis-p2 all
make -C ../wave/examples/nginx-p2 all
```

## 与应用构建有关的配套调整

三个应用始终使用 `wasm32-wasip2`。移植和调试中确认的共性约束包括：

- wasi-libc 的 P2 `writev`/`readv` 路径曾只处理首个 iovec，应用 shim 必须逐段
  处理，否则 Redis 大回复等场景会截断；
- P2 下 `recv(MSG_PEEK)` 返回 `ENOTSUP`，且 WASI errno 数值不能按 Linux errno
  硬编码；
- `wasm32-wasip2` 当前不会自动定义 `__wasi__`，构建参数显式使用
  `-D__wasi__` 保护 WASI 专用代码；
- Wasmtime 48 不支持应用所用的 legacy exception handling，因而 Redis 的 Lua
  及其 setjmp/longjmp 依赖保持禁用；
- Redis/Nginx 均保持单线程或单进程事件循环，避免把运行时不支持的 fork、后台
  I/O 线程等路径混入 benchmark。

SQLite native 和 P2 benchmark 均使用 `SQLITE_TEMP_STORE=3`，让临时表驻留内存。
原因是当前两套适配尚未完整覆盖 wasi-libc 对绝对临时目录的所有访问；native 与
Wasm 使用同一选项，避免比较条件不一致。`make bench-build` 对 P2 和
Native 统一使用 `-O3 -flto`；新 component、WALI AOT 和 Wave AOT 先生成在
临时目录，只有整套成功后才一起替换仓库产物并刷新
`runtime/APPS.sha256`，避免混用新应用和旧 AOT。

SQLite benchmark 还默认执行上文的跨目标 PGO。训练程序和 `.profraw/.profdata`
只存在于临时构建目录，最终提交的是使用 profile 优化后的 P2 component 及与之
匹配的 WALI/Wave AOT；`SQLITE_PGO=0 make bench-build` 可关闭此步骤。

最新一次完整运行结果由脚本写入 `benchmark/RESULTS.md`。

## 仓库内预编译运行时

为了让 benchmark 不依赖外部运行时的本地源码工作树，最终使用的 Linux x86_64
二进制放入 `runtime/`：使用上文 `fastest-runtime` profile 构建的 Wasmtime
48.0.1、带 P2 adapter、raw-import AOT 修复与 TCP_NODELAY workaround 的
WALI/iwasm 2.4.3，以及 Wave 的 `wasm2c-runner`/`libwave.so`。WALI 的三个
canonical-ABI core module 已离线编译为 `runtime/wali/apps/*.aot`；Wave 的对应
wasm2c AOT 共享库放在 `runtime/wave/apps/*.so`。`make bench-run` 只使用这些
已提交成品，不读取相邻源码树。`make bench-build` 会从相邻 WALI/Wave
源码树重建两套 AOT，替换三个 `benchmark/**/*.wasm`，并通过
`runtime/APPS.sha256` 绑定新的 P2/AOT 组合。默认源码路径是仓库相邻的
`WALI` 和 `wave`，可分别用 `WALI_ROOT` 和 `WAVE_ROOT` 覆盖。

二进制布局、平台约束和许可证位置见 `runtime/README.md`。

## 已知限制

- Redis 在 WALI/Wave 下打印的 wall-clock 日志时间戳不正确；monotonic clock、
  超时处理和 benchmark 请求均正常。
- WALI 加载时会对尚未注册且本测试未使用的 UDP、DNS、目录枚举 imports 打印
  warning。
- Wave 对未实现且真正被调用的 imports 会中止，并报告 symbol 名。
- `TCP_NODELAY` workaround 是 accepted socket 的运行时策略，不是标准 P2
  socket option；将来标准接口支持该选项后应改为遵循 guest 的显式设置。
- Wasmtime 在 Nginx keepalive `-c 128` 的高吞吐状态会稳定 timeout，因此统一
  benchmark 使用 `-c 120`；该边界不影响 `TCP_NODELAY` 根因判断。
- 上述运行时目录中的改动是本地工作树改动，未自动合并到对应上游项目。

## 2026-09-10 SQLite 独立后续实验

使用本仓库固定 Wasmtime 和完全相同的标准 workload，当前 P2 与 Native 的
六轮中位数为 `0.8355/0.5300s`，耗时比 1.576。新构建的基线 P2 与本仓库产物
SHA-256 一致。OP_Column header outline 与 VDBE minsize 两项实验虽通过四组
查询 hash 比对，却令标准耗时分别增加 1.74% 和 1.86%，因此不部署。
详见 [实验源码、脚本与原始结果](../sqlite-next-experiments/README.md)。

另外将应用端 LLVM 的热点内联阈值设为 525 的独立六轮实验中，标准耗时
`0.8285→0.8355s`，CTE `6.3305→6.3900s`，未测得收益，亦不部署。

## 2026-09-10 新保留：Cranelift 栈重载清理与 SQLite 整字比较

继续针对 main 实测后，新增 x86-64 跨单前驱块的整数 spill reload 清理，以及
SQLite Wasm 的精确范围整字 memcmp（常量长度仍交给 builtin）。六轮标准
`--size 25` 由 `0.827→0.796s`，耗时 -3.75%、user cycles -4.08%、
user instructions -6.74%；同轮 Native 为 0.531s，Wasmtime/native 从 1.557
降到 1.499。CTE 六轮 `6.2645→6.2250s`，时间变化接近噪声，cycles/instructions
各约降低 1.6%。这是相对本轮修改前的增量结果，不与历史百分比直接相加。

新 pass 保持 guest 访存与 ABI 不变，对调用、safepoint、clobber、合流、回边、
寄存器和栈槽覆盖均保守失效；198 项单元测试、184 个 x64 filetest 文件及
487 个执行/优化/wasm 文件检查通过（8 个不支持的旧 i686 文件跳过），完整
SQLite component 也通过寄存器分配校验器及四组结果 hash 对照。

实现、原始数据和部署状态见 [本轮优化报告](../SQLITE_CRANELIFT_OPTIMIZATION_2026-09-10.md)。

最终部署复核：直接加载 Wasm（含运行时编译）的六轮交错测试，SQLite TOTAL
中位数 `0.8270→0.7905s`（-4.41%），完整进程 `2.3576→2.3264s`（-1.32%）。
正式 runtime 与 SQLite P2/native/WALI/Wave 已更新，9 项产物 SHA 校验通过；
部署后完整 `make bench-run`、SQLite CLI integrity_check 与 Redis 大响应往返通过。
这与上面的预编译 AOT 对照是两组独立测量，不混合计算收益。

## 2026-09-10 第二轮增量：合流 reload 与 LIKE/GLOB 扫描

进一步保留 Cranelift 已访问前驱的 spill 相等事实交集，以及 SQLite Wasm 的
两字符 LIKE/GLOB 专用扫描。相对上一轮已部署版，六轮交错 AOT 标准
TOTAL `0.7965→0.7775s`（-2.39%），user cycles -2.51%、instructions -3.11%；
同轮 native 0.5270s，耗时仍约 native 的 1.475 倍。放大 CTE
`6.1565→6.0415s`（-1.87%）。memcmp 短尾部候选没有时间收益，排除。

正式源码补丁、runtime、SQLite P2/native/WALI/Wave 已更新；旧文件另存于
`sqlite-followup-experiments/before-deploy/`（相对 /home/fxs/Wasm）。
199 项 Cranelift 单元测试、671 个 filetest 文件检查（含 8 个旧 i686 跳过）、
完整 SQLite component 的寄存器分配校验、四组查询 hash、扫描边界检查、
CLI integrity_check 和 Redis 大响应往返均通过。

最终直接加载与完整回归结果、PGO 测量修正和后续方向见[第二轮报告](../SQLITE_CRANELIFT_FOLLOWUP_2026-09-10.md)。

最终直接加载 Wasm 的六轮：SQLite TOTAL `0.7945→0.7785s`（-2.01%），
完整进程 `2.3419→2.3257s`（-0.69%）。部署后四路三应用 `make bench-run`
全部完成，SQLite 单轮 native/Wasmtime/WALI/Wave 为
`0.531/0.781/0.730/0.624s`；9 项产物 SHA 校验通过。

## 2026-09-10 第三轮增量：比较目标直接调用与冗余 spill 删除

保留 SQLite Wasm 的 B-tree 已知整数/字符串比较目标直接调用（其他目标
仍间接调用），以及 Cranelift 已知同值写回 spill slot 的删除。
最终 LTO 六轮标准 AOT 对照：`0.7755→0.7575s`（-2.32%），
user cycles -2.26%、instructions -2.91%；Native 0.5270s，耗时仍约
native 的 1.437 倍。四轮 CTE 时间变化很小，指令数基本不变，不宣称可靠加速。

整数整字解码与通用路径外提虽通过正确性验证，组合测量未胜出，没有保留。
201 项 Cranelift 单元测试、671 个 filetest 文件检查（8 个旧 i686 跳过）、
SQLite component checker、四组查询 hash、混合类型索引/NOCASE 冒烟和
Redis 大响应往返均通过。正式源码、runtime 与 SQLite 四路产物已更新。
最终直接加载与完整回归结果见[第三轮报告](../SQLITE_CRANELIFT_THIRD_2026-09-10.md)。

最终直接加载 Wasm 的六轮：SQLite TOTAL `0.7760→0.7645s`（-1.48%），
完整进程 `2.3273→2.3080s`（-0.83%）。部署后三应用四路完整 benchmark
通过，SQLite 单轮 native/Wasmtime/WALI/Wave 为
`0.529/0.762/0.705/0.612s`；9 项 SHA 校验全部通过。

## 2026-09-10 第四轮：用已有寄存器副本替代 spill reload

Cranelift 保留无效写回删除后的副本事实，并把可证明等值的栈 reload 改成
GPR 复制。同一 SQLite P2 六轮：最终标准 AOT `0.763→0.761s`（-0.26%，
接近波动范围），L1 data loads -3.32%；CTE `6.051→5.8615s`（-3.13%），
L1 data loads -2.53%，指令数基本不变。标准耗时仍约 native 的 1.44 倍。

直接加载 Wasm 的 SQLite TOTAL `0.7625→0.7510s`（-1.51%），含编译/启动
的完整进程 `2.3057→2.3031s`（-0.12%），几乎不变。不同测量方式的标准
收益幅度不一致，不宣称固定的整体加速。

新 runtime 已部署；206 项单元测试、671 个文件检查（8 个旧 i686 跳过）、
完整 SQLite checker/查询 hash/类型索引冒烟及三应用四路回归通过。
patchable-call 汇编快照按预期复制指令更新，并新增 regalloc_checker 检查。
应用 P2/产物清单与基线相同，9 项 SHA 校验通过。详见[第四轮报告](../SQLITE_CRANELIFT_FOURTH_2026-09-10.md)。

## 2026-09-10 热点基本块对照：B-tree 两字节读取

按 native / Cranelift 的 VDBE、B-tree 热地址对照后，保留 SQLite Wasm
get2byteAligned 的精确两字节 memcpy + bswap16；普通 get2byte 扩大改写与
BtreeNext noinline 两个候选更慢，未保留。Wasmtime runtime 源码和二进制不变。

原 benchmark 六轮筛选 `0.7540→0.7430s`（-1.46%），独立六轮
`0.7525→0.7390s`（-1.79%）；后一组 instructions -1.09%、L1 loads -2.96%，
native 为 0.5270s，耗时比约1.40。指令采样表明净收益还涉及 VDBE 的内联/
寄存器分配变化，不能全归因于 B-tree 局部减少一次读取。

放大 CTE 首轮 `5.8725→5.9250s`（+0.89%），虽然指令减少，但并非所有
场景都加速。最终复测、直接加载及回归状态见[热点对照报告](../SQLITE_HOT_BLOCKS_2026-09-10.md)。

最终补充：第二组六轮放大 CTE `5.8415→5.8505s`（+0.15%，未测得加速）；
直接加载 P2 的 SQLite TOTAL `0.7530→0.7355s`（-2.32%），完整进程
`2.3028→2.2833s`（-0.85%）。正式 SQLite P2/native/WALI/Wave 已成套更新，
完整三应用四路 benchmark、CLI 类型/索引检查、9项 SHA 和补丁重放通过。

## 2026-09-10 Cranelift 16 位字节交换实验（未部署）

已实现并验证移位/合并到单条 rolw $8 的识别。广泛egraph和x64 lowering
版本均令标准耗时增加约2.5%；限制DFG规模后避免VDBE膨胀，但两组六轮标准
`0.7420→0.7425s`、`0.7405→0.7410s`，未测得收益；放大CTE慢约1.14%。
局部指令变短没有带来整体加速，因此正式Cranelift源码已恢复，runtime与
SQLite/P2/AOT产物未更换，保留上一轮版本。完整补丁、正确性验证和原始数据
见[16位字节交换实验](../SQLITE_BSWAP16_2026-09-10.md)。


## 2026-09-10：bench-run 接入 Wasmtime LLVM

用户复制的 Wasmtime 二进制包含实验 LLVM 后端，但原 `benchmark/run.sh` 没有
传入 LLVM 开关，因此此前 0.754s 的 Wasmtime 列实际仍使用 Cranelift。
现在 `make bench-run` 默认使用 LLVM AOT；通过
`make bench-run WASMTIME_BACKEND=cranelift` 切回原后端，表头明确区分二者。

`benchmark/wasmtime-llvm-aot.py` 编译当前 benchmark 的同一份 P2，按运行时 SHA-256、
输入 SHA-256、编译参数建立缓存，并验证输出 AOT 哈希。缓存位于 `.cache/wasmtime-llvm/`，
有锁及临时构建文件保护。首次/失效时需要 opt-19、llc-19，有效缓存执行不需要 LLVM 工具。
所有编译在计时和服务启动前完成；编译失败直接报错。未替换三个 P2 或 WALI/Wave AOT，
原 `runtime/APPS.sha256` 校验继续执行。这里只接入编译后端和缓存，没有合入实验区
Redis/Nginx 的额外应用兼容性补丁。

本轮完整 `make bench-run` 四路执行成功，SQLite 单轮 TOTAL 为 native 0.544s、
Wasmtime LLVM AOT 0.709s、WALI 0.719s、Wave 0.629s；Redis/Nginx 负载完成。
小组件验证了缓存命中、输入变更失效和损坏重编；三个实际应用缓存均验证在
PATH 不含 LLVM 工具时命中。实际结果见 `benchmark/RESULTS.md`。


## 2026-09-10：Wasmtime P2 输出流容量与 Nginx keepalive

独立 Wasmtime LLVM 源码把 `WriteState::Ready` 的判断改为内部有界缓冲容量，
不再为每次 check-write 查询 socket writable / 消耗 Tokio cooperative budget。
真实背压仍进入原 Writing 异步状态，保留64 KiB上限、许可消费、关闭和错误处理。
低层测试复现旧实现空闲时返回0许可，新实现通过；16 MiB慢客户端/中途断连、
原 Redis/Nginx 功能检查和 SQLite 五组哈希校验通过。
同输入、20000请求/120并发、交替顺序四轮中位数：旧26309、新47347 rps，约+80%。
新运行时来自 `wasmtime-llvm-experiment/runtime/llvm-keepalive/`，已安装至项目
`runtime/wasmtime/wasmtime`；旧版保留在实验区 `runtime/llvm-p2/`。
本轮未改应用P2或WALI/Wave；完整记录见实验区 `NGINX_KEEPALIVE.md`。

最终打包运行时交替四轮复验中位数为旧27098、新46803 rps（+72.7%）；
原项目完整 `make bench-run` 的 keepalive 为 native105510、LLVM55197、
WALI55163、Wave63982 rps，SQLite LLVM 0.707s。初期候选+80%是前一组独立记录，
最终同轮收益以+72.7%为准。三个应用的新旧AOT哈希全部相同，收益来自宿主修改。


## Nginx 合并写入与 Wasmtime I/O（2026-09-10）

WASI ngx_writev 对不超过4KiB的多段数据合并写入，保留短写和错误处理。
已同步早先验证的FIONREAD/pread/pwritev兼容修复，并重建匹配的WALI/Wave Nginx AOT。
LLVM benchmark默认启用 Wasmtime `--io-current-thread`；
`WASMTIME_IO_CURRENT_THREAD=0 make bench-run` 可关闭该调度选项。
原输入/产物备份及详细验证见 [报告](../wasmtime-llvm-experiment/NGINX_IO_OPTIMIZATIONS.md)。
