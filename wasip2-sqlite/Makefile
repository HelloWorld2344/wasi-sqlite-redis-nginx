# wasip2-sqlite/Makefile
#
# SQLite 3.53.4 → wasm32-wasip2（WASI preview2；SQLite 源码零修改）。
# 源码不随仓库分发：构建时从 sqlite.org 下载官方 autoconf 包（含预生成的
# sqlite3.c，不需要 tclsh；GitHub 镜像树没有这个文件，不能替代）。
#
# 用法（在本目录或仓库根目录 make build-wasip2-sqlite）:
#   make all         下载源码 + 编译 libsqlite3.a + 交互式 CLI
#   make run-cli     运行交互式 sqlite3 CLI
#   make clean       清理 out/
#   make clean-all   额外删掉 libsqlite3.a 与源码树
#
# wasi-sdk 默认由 setup.sh 下载到仓库外；Wasmtime 默认使用仓库 runtime/ 版本。
#
# 关键点：
#   1) wasip2 目标不自动定义 __wasi__（实测），编译/补丁守卫靠手动 -D__wasi__
#   2) wasip2 需要一组官方模拟库（信号/进程时钟/getpid/mman）
#   3) 运行必须 -S cli（p2 模块的 WASI 接口）
#   4) sqlite 官方 configure 的 wasi-sdk 模式目标三元组是 p1，这里用
#      CFLAGS 覆盖 + SHELL_DEFS 直接编译 sqlite3.c（同样的零修改源码）

HERE      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
WASI_SDK  ?= $(abspath $(HERE)/../../wasi-sdk-34.0-x86_64-linux)
WASMTIME  ?= $(abspath $(HERE)/../runtime/wasmtime/wasmtime)
SQLITE    := $(HERE)/sqlite-autoconf-3530400
SQLITE_TAR:= $(HERE)/sqlite-autoconf-3530400.tar.gz
SQLITE_URL:= https://sqlite.org/2026/sqlite-autoconf-3530400.tar.gz

WCC       := $(WASI_SDK)/bin/clang
WAR       := $(WASI_SDK)/bin/ar
SYSROOT   := $(WASI_SDK)/share/wasi-sysroot
TARGET    := wasm32-wasip2

CFLAGS    := --target=$(TARGET) --sysroot=$(SYSROOT) -O2 -D__wasi__ -D_GNU_SOURCE \
	-I$(SQLITE)
LIBS      := $(SQLITE)/libsqlite3.a -lm

# 特性宏（原 configure --enable-all 的集合；直接编译 sqlite3.c 时显式给出）
SHELL_DEFS := -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 \
	-DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MATH_FUNCTIONS \
	-DSQLITE_ENABLE_GEOPOLY -DSQLITE_ENABLE_DBSTAT_VTAB -DSQLITE_ENABLE_FTS4 \
	-DSQLITE_ENABLE_SESSION -DSQLITE_ENABLE_PREUPDATE_HOOK -DSQLITE_ENABLE_CARRAY \
	-DSQLITE_ENABLE_DBPAGE_VTAB -DSQLITE_ENABLE_PERCENTILE \
	-DSQLITE_TEMP_STORE=3
# WASI 缺的 POSIX API 的官方模拟库（信号 / 进程时钟 / getpid / mman）
EMU_LIBS  := -lwasi-emulated-signal -lwasi-emulated-process-clocks \
	-lwasi-emulated-getpid -lwasi-emulated-mman
EMU_DEFS  := -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
	-D_WASI_EMULATED_GETPID -D_WASI_EMULATED_MMAN

LIB       := $(SQLITE)/libsqlite3.a
OUT_DIR   := $(HERE)/out
CLI       := $(OUT_DIR)/sqlite3.wasm
SHIMS     := $(HERE)/shell-shims.c

.PHONY: all sqlite cli run-cli clean clean-all

all: sqlite cli

# ---- 0) 源码：官方 autoconf 包（sqlite.org 慢，断点续传；SQLite 源码零修改）----
$(SQLITE)/sqlite3.c:
	curl -sC - --retry 5 -o $(SQLITE_TAR) $(SQLITE_URL)
	cd $(HERE) && tar xzf $(SQLITE_TAR)

# ---- 1) 编译 WASI 静态库（sqlite3.c 直接用 wasip2 参数编译）----
sqlite: $(LIB)

# 依赖 Makefile 本身：编译标志变化时强制重建（防止旧的 p1 产物被时间戳跳过）
$(LIB): $(SQLITE)/sqlite3.c $(lastword $(MAKEFILE_LIST))
	$(WCC) $(CFLAGS) $(EMU_DEFS) $(SHELL_DEFS) -c $(SQLITE)/sqlite3.c -o $(SQLITE)/sqlite3.o
	$(WAR) rcs $(LIB) $(SQLITE)/sqlite3.o

# ---- 2) 交互式 CLI（官方 wasi 构建不产 shell，用官方 shell.c 原样编译 + 桩链接）----
cli: $(CLI)

$(CLI): $(SQLITE)/shell.c $(SHIMS) $(LIB)
	mkdir -p $(OUT_DIR)
	$(WCC) $(CFLAGS) $(EMU_DEFS) $(SHELL_DEFS) \
		$(SQLITE)/shell.c $(SHIMS) $(LIBS) $(EMU_LIBS) -o $@

# ---- 3) 运行（p2 模块需要 -S cli）----
run-cli: $(CLI)
	cd $(HERE) && $(WASMTIME) run -S cli --env HOME=$(HOME) --dir=. \
		out/sqlite3.wasm --interactive

# ---- 清理 ----
clean:
	rm -rf $(OUT_DIR)

clean-all: clean
	rm -rf $(SQLITE) $(SQLITE_TAR)
