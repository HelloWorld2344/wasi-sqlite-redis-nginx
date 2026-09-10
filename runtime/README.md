# 预编译 benchmark 运行时

这里保存 `make bench-build` 使用的固定版本 Linux x86_64 运行时，不包含各运行
时的源代码：

- `wasmtime/wasmtime`：Wasmtime 48.0.1（commit `7bac2c277`），使用上游
  `fastest-runtime` profile 和精简功能集构建，可以直接运行或预编译 WASI P2
  component；包含 `NOTICE.md` 记录的本地 TCP read/write、单个及批量 pollable
  fast path 和 P2 accepted socket `TCP_NODELAY` workaround；
- `wali/iwasm`：WAMR/WALI 2.4.3；`apps/*.aot` 是三个 P2 component 内
  canonical-ABI core module 的 WALI AOT 产物；P2 TCP adapter 对 accepted
  socket 启用 `TCP_NODELAY`；
- `wave/wasm2c-runner` 与 `wave/libwave.so`：Wave runner/runtime；
  `wave/apps/*.so` 是三个 P2 core module 经 wasm2c AOT 后与 P2 host adapter
  链接得到的产物；Redis/Nginx adapter 对 accepted socket 启用
  `TCP_NODELAY`。

WALI 和 Wave 的源码改动及 AOT 生成方法记录在仓库根目录的 `NOTICE.md`。
`make bench-run` 不需要相邻的 WALI 或 Wave 源码树。`make bench-build` 则会
重建三个 P2 component、Native 对照和两套 AOT，全部成功后替换这里的
产物并刷新 `APPS.sha256`。

这些本机代码产物面向 Linux x86_64。更换应用 `.wasm`、目标架构或 SQLite
`--size` 等编译进 Wave adapter 的参数后，需要使用 `NOTICE.md` 所列源码构建
步骤重新生成对应的 `apps/` 产物，并更新 `APPS.sha256`。benchmark 启动前会
校验三个 P2 文件，防止拿新 `.wasm` 与旧 AOT 产物比较。

各项目许可证随二进制分别放在 `wasmtime/LICENSE`、`wali/LICENSE` 和
`wave/LICENSE`。


## 实验 LLVM benchmark 入口

当前复制到 `wasmtime/wasmtime` 的运行时包含 LLVM 后端。
`make bench-run` 默认启用 LLVM，在项目 `.cache/wasmtime-llvm/` 下编译/复用三个
benchmark 原始 P2 输入的 Wasmtime AOT，不使用实验区不同版本的 Redis/Nginx 输入。
首次或缓存失效时需要 `opt-19` / `llc-19`；有效缓存执行不需要这些编译工具。
`make bench-run WASMTIME_BACKEND=cranelift` 使用原 Cranelift 路径。
缓存有运行时、输入、参数和输出哈希校验，替换运行时后会自动失效。

当前安装的是 `wasmtime-llvm-experiment/runtime/llvm-keepalive/wasmtime` 候选，
包含 P2 TCP 空闲写缓冲直接发放有界许可的优化。最终交替对照 Nginx keepalive
提升约72.7%；原项目本轮为55197 rps。应用及 WALI/Wave 输入保持不变，
完整源码、补丁、验证和恢复方法见实验区 `NGINX_KEEPALIVE.md`。


### Nginx I/O 更新（2026-09-10）

Wasmtime包含显式CLI选项 `run --io-current-thread`，LLVM benchmark默认使用它。
未指定时CLI保持原有多线程Tokio驱动。Nginx的P2/WALI/Wave AOT均来自合并小响应的新P2输入，
已更新APPS.sha256；WALI/Wave运行时二进制未替换。
包及验证：[llvm-nginx-io](../../wasmtime-llvm-experiment/runtime/llvm-nginx-io/)。
