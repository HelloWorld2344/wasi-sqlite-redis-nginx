# wasip2-redis/Makefile（wasmtime 上运行 Redis 7.4.11，wasi 补丁见 redis.patch）
#
# Redis 7.4.11 编译到 wasm32-wasip2（WASI preview2）并在 wasmtime 里运行。
# 源码补丁见 redis-7.4.11/ 的 git log（基线 b3ba492，补丁在其上）。
#
# 用法:
#   make           只编译 redis-server.wasm → out/（wasm 产物跨平台，不需要频繁重编）
#   make cli       只编译宿主 redis-cli → out/（两条命令互不触发）
#   make run       在 wasmtime 里起服务（6379，AOF 持久化落盘 redis-data/）
#   make run-cli   直接启动宿主 redis-cli 连 6379
#   make clean     清理构建产物（wasm-obj/ host-obj/ out/ 与 deps 残留对象）
#
# 构建布局（宿主与 wasm 对象彻底隔离，任意顺序交替 make / make cli 互不污染）:
#   wasm-obj/   wasm 侧全部对象（redis 源码 + hiredis + fpconv + hdr_histogram）
#   host-obj/   宿主侧全部对象（redis-cli 源码 + hiredis + linenoise + hdr_histogram）
#   out/        redis-server.wasm + redis-cli
#   不再使用 deps/* 的构建产物（redis 官方会往 src/ 就地丢对象，那是它的原生行为）
#
# 关键点（详见 ../NOTES.md 的 Redis 章节）:
#   1) 必须用 wasm32-wasip2（p1 没有 socket 头文件；p2 有 wasi:sockets）
#   2) wasip2 目标不自动定义 __wasi__（实测），补丁守卫靠手动 -D__wasi__
#   3) 网络必须 -S inherit-network=y；持久化见 NOTES（AOF/SAVE 可用，BGSAVE 不可用）
#
# 已知限制（源码中已守护/打桩）:
#   无 BGSAVE/BGREWRITEAOF（fork）、无 bio/IO 线程（单线程内联）、无 unix socket、
#   无 daemonize/sentinel/模块加载、无 Lua（EVAL/SCRIPT/FUNCTION）、select 事件循环

HERE      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
# wasi-sdk 默认由 setup.sh 下载到仓库外；Wasmtime 默认使用仓库 runtime/ 版本。
WASI_SDK  ?= $(abspath $(HERE)/../../wasi-sdk-34.0-x86_64-linux)
WASMTIME  ?= $(abspath $(HERE)/../runtime/wasmtime/wasmtime)
REDIS     := $(HERE)/redis-7.4.11
SRC       := $(REDIS)/src

WCC       := $(WASI_SDK)/bin/clang
SYSROOT   := $(WASI_SDK)/share/wasi-sysroot
TARGET    := wasm32-wasip2

OUT_DIR   := $(HERE)/out
WASM_OUT  := $(OUT_DIR)/redis-server.wasm
CLI_OUT   := $(OUT_DIR)/redis-cli
WOBJ      := $(HERE)/wasm-obj
HOBJ      := $(HERE)/host-obj

# ---- wasm 编译参数 ----
CFLAGS    := --target=$(TARGET) --sysroot=$(SYSROOT) -O2 \
	-D__wasi__ -D_GNU_SOURCE \
	-D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID \
	-D_WASI_EMULATED_MMAN \
	-I$(SRC) -I$(REDIS)/deps/hiredis -I$(REDIS)/deps/hdr_histogram \
	-I$(REDIS)/deps/fpconv -I$(REDIS)/deps/lua/src \
	-I$(HERE)/wasi-include \
	-include $(HERE)/wasi-include/wasi_shims.h

EMU_LIBS  := -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid \
	-lwasi-emulated-mman $(SYSROOT)/lib/wasm32-wasip2/libsetjmp.a

# ---- 宿主编译参数（redis-cli）----
# 注意：deps 目录必须在 src 之前——cli_common.h 用尖括号包含 <hiredis.h>/<sdscompat.h>，
# 若 src 在前会把 hiredis 的 sds 兼容层和 redis 自身 sds.h 混在一起导致重定义
HCC       := cc
HCFLAGS   := -O2 -D_GNU_SOURCE -I$(REDIS)/deps/hiredis -I$(REDIS)/deps/linenoise \
	-I$(REDIS)/deps/hdr_histogram -I$(REDIS)/deps/lua/src -I$(SRC)

# ---- wasm 侧对象 ----
# 官方 REDIS_SERVER_OBJ 去掉 tls/syscheck/memtest，加上 stubs 与 hiredis/fpconv/hdr
SRV_SRCS  := threads_mngr adlist quicklist ae anet dict ebuckets mstr \
	kvstore server sds zmalloc lzf_c lzf_d pqsort zipmap sha1 \
	ziplist release networking util object db replication rdb \
	t_string t_list t_set t_zset t_hash config aof pubsub multi \
	debug sort intset syncio cluster cluster_legacy crc16 endianconv \
	slowlog bio rio rand crcspeed crc64 bitops \
	sentinel notify setproctitle blocked hyperloglog latency sparkline \
	redis-check-rdb redis-check-aof geo lazyfree module evict expire \
	geohash geohash_helper childinfo defrag siphash rax t_stream \
	listpack localtime lolwut lolwut5 lolwut6 acl tracking socket \
	sha256 timeout setcpuaffinity monotonic mt19937-64 resp_parser \
	call_reply commands strl \
	connection unix logreqres wasi_stubs scripting_stubs
# hiredis 官方对象列表不含 dict.c（async.c 内部 #include dict.c，单独编会重复符号）
HIREDIS_SRCS := alloc async hiredis net read sds sockcompat

WASM_OBJS := $(addprefix $(WOBJ)/,$(addsuffix .o,$(SRV_SRCS))) \
	$(addprefix $(WOBJ)/hiredis_,$(addsuffix .o,$(HIREDIS_SRCS))) \
	$(WOBJ)/fpconv_dtoa.o $(WOBJ)/hdr_histogram.o

# ---- 宿主侧对象（REDIS_CLI_OBJ 去掉依赖）+ hiredis/linenoise/hdr ----
CLI_SRCS  := anet adlist dict redis-cli zmalloc release ae redisassert crcspeed \
	crc64 siphash crc16 monotonic cli_common mt19937-64 strl cli_commands

HOST_OBJS := $(addprefix $(HOBJ)/,$(addsuffix .o,$(CLI_SRCS))) \
	$(addprefix $(HOBJ)/hiredis_,$(addsuffix .o,$(HIREDIS_SRCS))) \
	$(HOBJ)/linenoise.o $(HOBJ)/hdr_histogram.o

.PHONY: all run run-cli cli clean

all: $(WASM_OUT)

# ---- 编译规则 ----
$(WOBJ)/%.o: $(SRC)/%.c
	mkdir -p $(WOBJ)
	$(WCC) $(CFLAGS) -c $< -o $@

$(WOBJ)/hiredis_%.o: $(REDIS)/deps/hiredis/%.c
	mkdir -p $(WOBJ)
	$(WCC) $(CFLAGS) -c $< -o $@

$(WOBJ)/fpconv_dtoa.o: $(REDIS)/deps/fpconv/fpconv_dtoa.c
	mkdir -p $(WOBJ)
	$(WCC) $(CFLAGS) -c $< -o $@

$(WOBJ)/hdr_histogram.o: $(REDIS)/deps/hdr_histogram/hdr_histogram.c
	mkdir -p $(WOBJ)
	$(WCC) $(CFLAGS) -DHDR_MALLOC_INCLUDE=\"hdr_redis_malloc.h\" -c $< -o $@

$(HOBJ)/%.o: $(SRC)/%.c
	mkdir -p $(HOBJ)
	$(HCC) $(HCFLAGS) -c $< -o $@

$(HOBJ)/hiredis_%.o: $(REDIS)/deps/hiredis/%.c
	mkdir -p $(HOBJ)
	$(HCC) $(HCFLAGS) -c $< -o $@

$(HOBJ)/linenoise.o: $(REDIS)/deps/linenoise/linenoise.c
	mkdir -p $(HOBJ)
	$(HCC) $(HCFLAGS) -c $< -o $@

$(HOBJ)/hdr_histogram.o: $(REDIS)/deps/hdr_histogram/hdr_histogram.c
	mkdir -p $(HOBJ)
	$(HCC) $(HCFLAGS) -DHDR_MALLOC_INCLUDE=\"hdr_redis_malloc.h\" -c $< -o $@

# ---- 链接 ----
$(WASM_OUT): $(WASM_OBJS)
	mkdir -p $(OUT_DIR)
	$(WCC) $(CFLAGS) $(WASM_OBJS) $(EMU_LIBS) -lm \
		-Wl,-z,stack-size=8388608 -o $@

$(CLI_OUT): $(HOST_OBJS)
	mkdir -p $(OUT_DIR)
	$(HCC) -o $@ $(HOST_OBJS) -lm

cli: $(CLI_OUT)

# ---- 运行 ----
# -S cli: p2 文件系统 + wasi:sockets；--save '' 避免 serverCron 反复尝试 BGSAVE（会失败刷日志）
# 持久化：--appendonly yes 落盘到 redis-data/（实测重启可恢复，见 NOTES.md）；
# 注意 redis-data 目录必须事先存在（redis 启动时会 chdir 进去，不存在直接退出）
run: $(WASM_OUT)
	mkdir -p $(HERE)/redis-data
	cd $(HERE) && $(WASMTIME) run -W max-wasm-stack=8388608 -S cli \
		-S inherit-network=y -S allow-ip-name-lookup=y --dir=. --env HOME=$(HOME) \
		$(WASM_OUT) --port 6379 --save '' --appendonly yes --dir redis-data

run-cli: $(CLI_OUT)
	$(CLI_OUT) -p 6379

# ---- 清理 ----
clean:
	rm -rf $(WOBJ) $(HOBJ) $(OUT_DIR)
	# deps 里可能残留旧构建方式的产物（本 Makefile 已不再使用），一并清掉
	find $(REDIS)/deps -name '*.o' -delete 2>/dev/null || true
	find $(REDIS)/deps -name '*.a' -delete 2>/dev/null || true
	# src/ 里旧构建方式（redis 官方就地编译）留下的对象也清掉；
	# 注意：若你自己用 redis 官方 make 在 src/ 里编过，这些会被一并清理
	find $(SRC) -name '*.o' -delete 2>/dev/null || true
