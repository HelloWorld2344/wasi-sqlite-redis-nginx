# 预编译 benchmark 运行时

这里保存 `make bench-build` 使用的固定版本 Linux x86_64 运行时，不包含 WALI
或 Wave 的源代码：

- `wasmtime/wasmtime`：Wasmtime 48.0.1，直接运行 WASI P2 component；
- `wali/iwasm`：WAMR/WALI 2.4.3；`apps/*.aot` 是三个 P2 component 内
  canonical-ABI core module 的 WALI AOT 产物；
- `wave/wasm2c-runner` 与 `wave/libwave.so`：Wave runner/runtime；
  `wave/apps/*.so` 是三个 P2 core module 经 wasm2c AOT 后与 P2 host adapter
  链接得到的产物。

WALI 和 Wave 的源码改动及 AOT 生成方法记录在仓库根目录的 `NOTICE.md`。运行
benchmark 不需要相邻的 WALI 或 Wave 源码树。
`benchmark/` 中提交的三个 P2 文件也是这组 AOT 的固定输入；`bench-build` 构建
native 对照程序，但不会用可能带不同构建标识的新文件覆盖它们。

这些本机代码产物面向 Linux x86_64。更换应用 `.wasm`、目标架构或 SQLite
`--size` 等编译进 Wave adapter 的参数后，需要使用 `NOTICE.md` 所列源码构建
步骤重新生成对应的 `apps/` 产物，并更新 `APPS.sha256`。benchmark 启动前会
校验三个 P2 文件，防止拿新 `.wasm` 与旧 AOT 产物比较。

各项目许可证随二进制分别放在 `wasmtime/LICENSE`、`wali/LICENSE` 和
`wave/LICENSE`。
