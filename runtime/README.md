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
