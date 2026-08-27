# AGENTS.md — 给 AI 代理的项目指引

## 项目是什么

把 SQLite(p1)、Redis(p2)、Nginx(p2) 三个应用编译到 WebAssembly/WASI 并在 wasmtime 上运行。
三个应用**全部实测跑通**；本仓库是可复现发布的产物。

## 结构约定（重要）

- 每个应用一个文件夹：`wasip1-sqlite/`、`wasip2-redis/`、`wasip2-nginx/`
- 各应用目录里：源码树 + 自己的 Makefile + 应用专属 shim（wasi-include/）
- **构建产物与中间对象一律 gitignore**，最终产物输出到各应用目录的 `out/`
- `demo/` 存放预编译成品（wasm/cli/配置），只用于演示运行，**不是构建输出目录**
- 工具链（wasi-sdk 34、wasmtime 48）不在仓库内：`./setup.sh` 下载到仓库外，
  Makefile 按 环境变量 > 仓库外默认位置 的顺序查找
- 根 `Makefile` 负责编排：`make build[-<app>]` / `make demo-prepare` / `make run-demo-*`

## 修改代码时的注意事项

1. **SQLite 源码零修改**（官方自带 WASI 支持），构建时从 sqlite.org 下载官方 autoconf 包
   （不能用 GitHub 镜像——它没有预生成的 sqlite3.c，而本环境没有 tclsh）
2. Redis/Nginx 的源码补丁以 `<app>.patch` 存档（相对各自上游基线的 `git diff`），
   源码树本身是补丁后状态；改动后记得重新导出 patch
3. wasi 特有的坑都记录在 NOTES.md，改代码前先读：
   - p2 的 writev/readv 只处理第一个 iov（必须逐段 write/read）
   - p2 的 recv(MSG_PEEK) 返回 ENOTSUP(58)；ENOSYS=52（与 Linux 的 errno 编号完全不同）
   - wasm32-wasip2 不自动定义 `__wasi__`，补丁守卫靠 `-D__wasi__`
   - wasmtime 48 不支持旧版（legacy）异常处理 → Lua 类依赖 setjmp/longjmp 的组件无法移植
4. 各应用 Makefile 支持独立运行（`make -C wasipX-app`），工具链变量用 `?=` 参数化

## 验证方式

- SQLite: `make -C wasip1-sqlite run-demo` / `run-bench` / `run-cli`
- Redis: 起服务后用 RESP 客户端（demo/redis/redis-cli 或 python）PING/SET/GET；大回复
  （>16KB）必须测——历史上 writev 截断 bug 就是这种场景暴露的
- Nginx: `make -C wasip2-nginx run` 后 curl 静态文件和反代
