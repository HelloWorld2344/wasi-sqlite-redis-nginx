# wasi-sqlite-redis-nginx/Makefile
#
# 三个经典应用的 WebAssembly/WASI 移植：SQLite(p2) / Redis(p2) / Nginx(p2)。
# 每个应用的编译细节在各自目录的 Makefile，这里负责编排。
#
# 用法:
#   make setup                 下载构建工具链到仓库外（仅 wasi-sdk 34）
#   make build                 编译全部三个应用
#   make build-wasip2-sqlite   只编 SQLite
#   make build-wasip2-redis    只编 Redis（wasm 服务端）
#   make build-wasip2-nginx    只编 Nginx
#   make cli-redis             只编宿主 redis-cli
#   make demo-prepare          编译全部并把成品拷贝到 demo/（demo/ 里的预编译产物即为该命令的产物）
#   make run-demo-sqlite       在 demo/sqlite 里跑交互式 sqlite3 CLI
#   make run-demo-redis        在 demo/redis 里起 redis-server（6379），另开终端用 demo/redis/redis-cli 连接
#   make run-demo-nginx        在 demo/nginx 里起 nginx（8080），浏览器/curl 访问
#   make clean                 清理三个应用的构建产物（保留 demo/ 里的预编译成品）
#
#   make bench-build           一键编译测试程序，并在 native + 三个运行时上运行全部测试
#   make bench-run             不重新编译，直接运行全部测试并刷新 benchmark/RESULTS.md
#
# wasi-sdk 默认在仓库外；Wasmtime 默认使用仓库 runtime/ 内的固定版本。
#
# 工具依赖说明：
#   编译 wasm 需要 wasi-sdk；运行 wasm 只需要 wasmtime；编译宿主 redis-cli 只需要宿主 cc。
#   唯一例外是 nginx：它的 configure 用 wasmtime 执行探测测试程序，编译时两者都要。

HERE      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TOOLS     := $(abspath $(HERE)/..)
WASI_SDK  ?= $(abspath $(TOOLS)/wasi-sdk-34.0-x86_64-linux)
WASMTIME  ?= $(HERE)/runtime/wasmtime/wasmtime

.PHONY: setup check-toolchain check-runtime check-bench-runtimes \
	build build-wasip2-sqlite build-wasip2-redis build-wasip2-nginx \
	cli-redis demo-prepare run-demo-sqlite run-demo-redis run-demo-nginx \
	bench-build bench-run bench-clean clean

# 编译检查（wasi-sdk）
check-toolchain:
	@test -x "$(WASI_SDK)/bin/clang" || { echo "错误: 未找到 wasi-sdk，请先运行 ./setup.sh 或设置 WASI_SDK"; exit 1; }

# 运行检查（wasmtime）
check-runtime:
	@test -x "$(WASMTIME)" || { echo "错误: 未找到 runtime/wasmtime/wasmtime"; exit 1; }

# benchmark 使用仓库 runtime/ 内固定版本，避免误用系统上不同版本的运行时。
check-bench-runtimes:
	@test -x "$(HERE)/runtime/wasmtime/wasmtime" || { echo "错误: runtime/ 中缺少 Wasmtime"; exit 1; }
	@test -x "$(HERE)/runtime/wali/iwasm" || { echo "错误: runtime/ 中缺少 WALI"; exit 1; }
	@test -x "$(HERE)/runtime/wave/wasm2c-runner" || { echo "错误: runtime/ 中缺少 Wave"; exit 1; }

setup:
	./setup.sh

# ---- 构建 ----
build-wasip2-sqlite: check-toolchain
	$(MAKE) -C wasip2-sqlite all WASI_SDK="$(WASI_SDK)" WASMTIME="$(WASMTIME)"

build-wasip2-redis: check-toolchain
	$(MAKE) -C wasip2-redis all WASI_SDK="$(WASI_SDK)" WASMTIME="$(WASMTIME)"

# 原生二进制：只需要宿主 cc，不需要任何 wasm 工具
cli-redis:
	$(MAKE) -C wasip2-redis cli

# nginx configure 的交叉探测用 wasmtime 执行测试程序 → 编译时两者都要
build-wasip2-nginx: check-toolchain check-runtime
	$(MAKE) -C wasip2-nginx build WASI_SDK="$(WASI_SDK)" WASMTIME="$(WASMTIME)"

build: build-wasip2-sqlite build-wasip2-redis build-wasip2-nginx

# ---- demo：编译并刷新 demo/ 里的成品 ----
demo-prepare: build cli-redis
	mkdir -p demo/sqlite demo/redis demo/nginx
	cp wasip2-sqlite/out/sqlite3.wasm demo/sqlite/
	cp wasip2-redis/out/redis-server.wasm wasip2-redis/out/redis-cli demo/redis/
	cp wasip2-nginx/out/nginx.wasm demo/nginx/

# ---- 运行 demo（全部前台运行，Ctrl-C 退出；redis 连接请另开终端）----
# 交互式 CLI：--interactive 强制逐行执行（wasmtime 下 isatty 检测不可靠）
run-demo-sqlite: check-runtime
	cd demo/sqlite && $(WASMTIME) run --env HOME=$(HOME) --dir=. sqlite3.wasm --interactive

run-demo-redis: check-runtime
	mkdir -p demo/redis/redis-data
	cd demo/redis && $(WASMTIME) run -W max-wasm-stack=8388608 -S cli \
		-S inherit-network=y -S allow-ip-name-lookup=y --dir=. --env HOME=$(HOME) \
		redis-server.wasm redis.conf

run-demo-nginx: check-runtime
	mkdir -p demo/nginx/logs
	cd demo/nginx && $(WASMTIME) run -W max-wasm-stack=8388608 -S cli \
		-S inherit-network=y -S allow-ip-name-lookup=y --dir=. --env HOME=$(HOME) \
		nginx.wasm -p . -c conf/nginx.conf

# ---- 基准测试（编译 + 运行；工具见 benchmark/build.sh 与 benchmark/run.sh）----
bench-build: check-toolchain check-bench-runtimes
	WASI_SDK="$(WASI_SDK)" WASMTIME="$(WASMTIME)" ./benchmark/build.sh
	./benchmark/run.sh

bench-run: check-bench-runtimes
	./benchmark/run.sh

bench-clean:
	rm -f benchmark/RESULTS.md

# ---- 清理构建产物（保留 demo/ 里的成品）----
clean:
	$(MAKE) -C wasip2-sqlite clean WASI_SDK="$(WASI_SDK)" WASMTIME="$(WASMTIME)" 2>/dev/null || true
	$(MAKE) -C wasip2-redis clean WASI_SDK="$(WASI_SDK)" WASMTIME="$(WASMTIME)" 2>/dev/null || true
	$(MAKE) -C wasip2-nginx clean WASI_SDK="$(WASI_SDK)" WASMTIME="$(WASMTIME)" 2>/dev/null || true
