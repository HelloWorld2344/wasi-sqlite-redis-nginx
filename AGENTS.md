# AGENTS.md — 给 AI 代理的项目指引

## 项目是什么

把 SQLite、Redis、Nginx 三个应用编译为 WASI Preview 2，并在 Wasmtime、WALI
和 Wave 上与 native 做相同 workload 的对比。三个应用均已实测跑通。

## 结构约定（重要）

- 每个应用一个文件夹：`wasip2-sqlite/`、`wasip2-redis/`、`wasip2-nginx/`
- 各应用目录里：源码树 + 自己的 Makefile + 应用专属 shim（wasi-include/）
- 应用构建中间产物写入各应用目录的 `out/` 等 gitignore 目录；benchmark 所需
  的固定 P2 文件、native 对照程序和 `runtime/` 预编译运行时需要提交
- `demo/` 存放预编译成品（wasm/cli/配置），只用于演示运行，**不是构建输出目录**
- `./setup.sh` 只把 wasi-sdk 34 下载到仓库外；Wasmtime 48、WALI、Wave 的固定
  Linux x86_64 二进制在 `runtime/`，不要再从外部运行时源码树调用 benchmark
- 根 `Makefile` 负责编排构建与 demo；`make bench-build` 构建 native 对照并运行
  完整四路测试，`make bench-run` 直接复用现有测试程序

## 修改代码时的注意事项

1. **SQLite 源码零修改**（官方自带 WASI 支持），构建时从 sqlite.org 下载官方 autoconf 包
   （不能用 GitHub 镜像——它没有预生成的 sqlite3.c，而本环境没有 tclsh）
2. Redis/Nginx 的源码补丁以 `<app>.patch` 存档（相对各自上游基线的 `git diff`），
   源码树本身是补丁后状态；改动后记得重新导出 patch
3. WALI/Wave 的适配改动、限制与 benchmark 分析统一记录在 `NOTICE.md`：
   - p2 的 writev/readv 只处理第一个 iov（必须逐段 write/read）
   - p2 的 recv(MSG_PEEK) 返回 ENOTSUP(58)；ENOSYS=52（与 Linux 的 errno 编号完全不同）
   - wasm32-wasip2 不自动定义 `__wasi__`，补丁守卫靠 `-D__wasi__`
   - wasmtime 48 不支持旧版（legacy）异常处理 → Lua 类依赖 setjmp/longjmp 的组件无法移植
4. 各应用 Makefile 支持独立运行（`make -C wasipX-app`），工具链变量用 `?=` 参数化
5. `runtime/APPS.sha256` 绑定三个 P2 文件和 WALI/Wave AOT。改变 `.wasm` 后必须
   同时重建两套 AOT 并更新校验值，不能混用新应用和旧 AOT

## 验证方式

- 完整对比：`make bench-build`，结果同时打印并写入 `benchmark/RESULTS.md`
- SQLite: `make -C wasip2-sqlite run-cli`；性能测试使用 `benchmark/sqlite/speedtest1.wasm`
- Redis: 起服务后用 RESP 客户端（demo/redis/redis-cli 或 python）PING/SET/GET；大回复
  （>16KB）必须测——历史上 writev 截断 bug 就是这种场景暴露的
- Nginx: `make -C wasip2-nginx run` 后 curl 静态文件和反代
