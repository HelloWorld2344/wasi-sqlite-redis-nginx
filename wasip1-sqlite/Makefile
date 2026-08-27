# wasip1-sqlite/Makefile
#
# SQLite 3.53.4 → wasm32-wasip1（SQLite 官方自带的 WASI 支持，源码零修改）。
# 源码不随仓库分发：构建时从 sqlite.org 下载官方 autoconf 包（含预生成的
# sqlite3.c，不需要 tclsh；GitHub 镜像树没有这个文件，不能替代）。
#
# 用法（在本目录或仓库根目录 make build-wasip1-sqlite）:
#   make all         下载源码 + 编译 libsqlite3.a + demo + bench + 交互式 CLI
#   make run-demo    在 wasmtime 里跑建库/插入/查询 demo（数据写 demo.db）
#   make run-bench   10 万行性能基准
#   make run-cli     交互式 sqlite3 CLI（打开 demo.db）
#   make clean       清理 out/ 与运行时数据
#   make clean-all   额外删掉 libsqlite3.a 与源码树
#
# 工具链：环境变量 WASI_SDK / WASMTIME 优先，否则找仓库外 setup.sh 的位置
#（../../wasi-sdk-34.0-x86_64-linux 等）。SQLite 不需要网络，p1 足够。

HERE      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
WASI_SDK  ?= $(abspath $(HERE)/../../wasi-sdk-34.0-x86_64-linux)
WASMTIME  ?= $(abspath $(HERE)/../../wasmtime-v48.0.1-x86_64-linux/wasmtime)
SQLITE    := $(HERE)/sqlite-autoconf-3530400
SQLITE_TAR:= $(HERE)/sqlite-autoconf-3530400.tar.gz
SQLITE_URL:= https://sqlite.org/2026/sqlite-autoconf-3530400.tar.gz

WCC       := $(WASI_SDK)/bin/clang
SYSROOT   := $(WASI_SDK)/share/wasi-sysroot
TARGET    := wasm32-wasip1

CFLAGS    := --target=$(TARGET) --sysroot=$(SYSROOT) -O2 -I$(SQLITE)
LIBS      := $(SQLITE)/libsqlite3.a -lm

# shell.c 需要的特性宏（与 configure --enable-all 生成的 libsqlite3.a 保持一致）
SHELL_DEFS := -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 \
	-DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MATH_FUNCTIONS \
	-DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_FTS4 \
	-DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_CARRAY \
	-DSQLITE_ENABLE_DBPAGE_VTAB -DSQLITE_ENABLE_PERCENTILE
EMU_LIBS  := -lwasi-emulated-signal -lwasi-emulated-process-clocks
EMU_DEFS  := -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS

LIB       := $(SQLITE)/libsqlite3.a
OUT_DIR   := $(HERE)/out
DEMO      := $(OUT_DIR)/demo.wasm
BENCH     := $(OUT_DIR)/bench.wasm
CLI       := $(OUT_DIR)/sqlite3.wasm
SHIMS     := $(HERE)/shell-shims.c

.PHONY: all sqlite demo bench cli run-demo run-bench run-cli clean clean-all

all: sqlite demo bench cli

# ---- 0) 源码：官方 autoconf 包（sqlite.org 慢，断点续传；SQLite 源码零修改）----
$(SQLITE)/sqlite3.c:
	curl -sC - --retry 5 -o $(SQLITE_TAR) $(SQLITE_URL)
	cd $(HERE) && tar xzf $(SQLITE_TAR)

# ---- 1) 官方 --with-wasi-sdk 配置项编译 WASI 静态库 ----
sqlite: $(LIB)

$(LIB): $(SQLITE)/sqlite3.c
	cd $(SQLITE) && ./configure --with-wasi-sdk=$(WASI_SDK) --enable-all
	$(MAKE) -C $(SQLITE) -j$(shell nproc)

# ---- 2) 编译 demo 与 bench 到 wasm32-wasip1 ----
demo: $(DEMO)

bench: $(BENCH)

$(DEMO): $(HERE)/demo.c $(LIB)
	mkdir -p $(OUT_DIR)
	$(WCC) $(CFLAGS) $(HERE)/demo.c $(LIBS) -o $@

$(BENCH): $(HERE)/bench.c $(LIB)
	mkdir -p $(OUT_DIR)
	$(WCC) $(CFLAGS) -D_WASI_EMULATED_PROCESS_CLOCKS \
		$(HERE)/bench.c $(LIBS) -lwasi-emulated-process-clocks -o $@

# ---- 2b) 交互式 CLI（官方 wasi 构建不产 shell，用官方 shell.c 原样编译 + 桩链接）----
cli: $(CLI)

$(CLI): $(SQLITE)/shell.c $(SHIMS) $(LIB)
	mkdir -p $(OUT_DIR)
	$(WCC) $(CFLAGS) $(EMU_DEFS) $(SHELL_DEFS) \
		$(SQLITE)/shell.c $(SHIMS) $(LIBS) $(EMU_LIBS) -o $@

# ---- 3) 运行（demo.db 是运行时数据，写在本目录）----
run-demo: $(DEMO)
	cd $(HERE) && $(WASMTIME) run --dir=. out/demo.wasm

run-bench: $(BENCH)
	rm -rf $(HERE)/bench.db $(HERE)/bench.db.lock
	cd $(HERE) && $(WASMTIME) run --dir=. out/bench.wasm
	rm -rf $(HERE)/bench.db $(HERE)/bench.db.lock

run-cli: $(CLI)
	cd $(HERE) && $(WASMTIME) run --env HOME=$(HOME) --dir=. \
		out/sqlite3.wasm --interactive demo.db

# ---- 清理 ----
clean:
	rm -rf $(OUT_DIR)
	rm -rf $(HERE)/demo.db $(HERE)/bench.db $(HERE)/bench.db.lock

clean-all: clean
	rm -rf $(SQLITE) $(SQLITE_TAR)
