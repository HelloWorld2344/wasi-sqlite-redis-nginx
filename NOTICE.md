# WALI / Wave 本地改动说明

本文记录为了让 WALI 和 Wave 运行本仓库 SQLite、Redis、Nginx 基准而在相邻
WALI 与 Wave 源码树中所做的本地改动，以及统一 benchmark 的结果与分析。

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

## 统一 benchmark 结果与分析

四个实现使用相同应用和 workload，服务端逐个运行；Nginx 的短连接与
keepalive 分别启动新进程，避免前一场景遗留的连接状态影响后一场景。以下是
同机单次完整运行结果，实际数据以每次 `make bench-build` 生成的
`benchmark/RESULTS.md` 为准。

### SQLite

`speedtest1 --size 25` 运行完整默认测试集：

| 实现 | TOTAL | 相对 native |
|---|---:|---:|
| Native | 0.534s | 1.00x |
| Wasmtime | 0.889s | 1.66x |
| WALI AOT | 0.785s | 1.47x |
| Wave AOT | 0.698s | 1.31x |

SQLite 主要是 Wasm 内部计算、内存访问和大量短函数调用，因此执行引擎本身的
开销比网络 benchmark 更明显。WALI fast interpreter 的早期结果约为
`16.3s`，慢的主要原因是每条 Wasm 指令都要经过解释分派，并非 SQLite size 25
触发了异常 I/O；改成 AOT 后约为 `0.8s`，快约 20 倍。Wave 将 core Wasm
静态翻译为宿主 C，WALI AOT 生成本机代码，二者都消除了主要解释器分派成本。

### Redis

官方 `redis-benchmark -n 100000 -c 50`：

| 命令 | Native rps | Wasmtime rps | WALI AOT rps | Wave rps |
|---|---:|---:|---:|---:|
| SET | 106,496 | 79,302 | 111,483 | 110,988 |
| GET | 106,383 | 78,678 | 110,865 | 110,375 |
| INCR | 106,496 | 78,125 | 110,865 | 110,619 |
| LPUSH | 106,496 | 77,399 | 111,111 | 111,111 |
| RPUSH | 105,820 | 73,260 | 111,359 | 111,111 |
| LPOP | 106,045 | 75,415 | 110,619 | 110,619 |
| RPOP | 105,485 | 77,459 | 110,011 | 110,865 |
| SADD | 105,820 | 78,555 | 109,890 | 110,497 |
| HSET | 105,820 | 76,570 | 110,011 | 110,375 |
| SPOP | 105,932 | 80,580 | 110,375 | 110,742 |
| MSET (10 keys) | 108,578 | 66,094 | 109,649 | 110,375 |

WALI AOT 和 Wave 在简单命令中比 native 高约 3%～5%，这个差距接近单次测量的
系统调度、频率和 TCP 抖动范围，不能据此认为 Wasm 普遍快于 native。两条路径
都把 socket 操作直接落到宿主 shim，SET/GET 的服务端计算量很小，结果主要受
宿主网络栈与 benchmark 客户端限制。Wasmtime 的 canonical ABI/资源管理路径
成本更明显，简单命令约为 native 的 70%～76%，MSET 的多参数和多段数据处理使
差距进一步扩大。早期 WALI fast interpreter 的 SET/GET/MSET 分别约为
28k/32k/11k rps；AOT 消除了 Redis 命令执行部分的解释开销。

### Nginx

| 场景 | Native rps | Wasmtime rps | WALI AOT rps | Wave rps |
|---|---:|---:|---:|---:|
| 短连接，`-n 50000 -c 50` | 20,202 | 9,961 | 20,123 | 20,409 |
| keepalive，`-n 20000 -c 128 -k` | 64,656 | 2,873 | 2,906 | 2,905 |

短连接下 WALI/Wave 与 native 基本相同；Wave 偶尔略高于 native 的约 1% 同样
属于测量噪声和宿主 shim 路径差异，不应解释为 Wasm 的固有优势。Wasmtime 在
该场景约为 native 的一半。keepalive 下三个 Wasm 路径却都只有约 2.9k rps，
约慢 22 倍，说明瓶颈不在代码生成质量，而在 P2 stream/poll 与 wasi-libc
`select()` 桥接：一次事件等待需要更多组件边界、resource 和订阅处理。早期
WALI fast interpreter 的短连接约 7.8k rps，而 keepalive 仍约 2.9k rps，也
印证短连接更受执行引擎影响、keepalive 更受 poll 桥影响。

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
  bind/listen/accept/shutdown 和 socket options。
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
Wasm 使用同一选项，避免比较条件不一致。三个提交到 `benchmark/` 的 P2 文件
是两套 AOT 的固定输入，`benchmark/build.sh` 不会用带不同构建标识的新文件
覆盖它们。

最新一次完整运行结果由脚本写入 `benchmark/RESULTS.md`。

## 仓库内预编译运行时

为了让 benchmark 不依赖两个运行时的本地源码工作树，最终使用的 Linux x86_64
二进制放入 `runtime/`：Wasmtime 48.0.1、带 P2 adapter 与 raw-import AOT 修复的
WALI/iwasm 2.4.3，以及 Wave 的 `wasm2c-runner`/`libwave.so`。WALI 的三个
canonical-ABI core module 已离线编译为 `runtime/wali/apps/*.aot`；Wave 的对应
wasm2c AOT 共享库放在 `runtime/wave/apps/*.so`。因此 `make bench-build` 和
`make bench-run` 都不读取相邻的 WALI 或 Wave 源码树。
三个已提交的 `benchmark/**/*.wasm` 是这些 AOT 的固定输入；`bench-build` 只
重建 native 对照程序，并通过 `runtime/APPS.sha256` 校验 P2/AOT 对应关系。

二进制布局、平台约束和许可证位置见 `runtime/README.md`。

## 已知限制

- Redis 在 WALI/Wave 下打印的 wall-clock 日志时间戳不正确；monotonic clock、
  超时处理和 benchmark 请求均正常。
- WALI 加载时会对尚未注册且本测试未使用的 UDP、DNS、目录枚举 imports 打印
  warning。
- Wave 对未实现且真正被调用的 imports 会中止，并报告 symbol 名。
- Nginx keepalive 在两套 P2 stream/poll bridge 上约为 2.9k rps，仍有明显的
  适配层优化空间。
- 上述运行时目录中的改动是本地工作树改动，未自动合并到对应上游项目。
