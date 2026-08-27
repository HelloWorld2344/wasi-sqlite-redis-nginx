# wasip2-nginx/Makefile（wasmtime 上运行 nginx 1.31.4，wasi 补丁见 nginx.patch）
#
# Nginx 1.31.4 编译到 wasm32-wasip2 并在 wasmtime 里运行（单进程、静态文件+反代）。
# 源码补丁见 nginx-1.31.4/ 的 git log（基线 6ed26f2，补丁在其上）。
#
# 用法:
#   make          configure（wasi cc + wasmtime 交叉运行探测）+ 编译 nginx.wasm
#   make run      wasmtime 里起服务（监听 8080，见 run/conf/nginx.conf）
#   make test     curl 验证静态文件
#   make clean    清掉 objs/（下次 make 会重新 configure）
#
# 关键点（详见 ../NOTES.md）:
#   1) 编译探测：auto/feature 打补丁支持 NGX_RUNNER（wasmtime run -S cli）执行测试二进制
#   2) 无 fork → 必须 master_process off + daemon off（单进程调试模式）
#   3) 事件循环自动落到 select 后端（wasi 无 epoll 头文件，configure 探测自动关闭）
#   4) shims 在 wasi-include/（wasi_shims.h 强制包含 + nginx_stubs.c 链接）
#
# 已知限制:
#   无 master/worker 多进程、无 gzip/ssl/rewrite(PCRE)、无 fastcgi/uwsgi/scgi/grpc、
#   无 unix socket 监听、无 epoll（select 后端）、无文件锁语义（flock 相关未用）

HERE      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
# 工具链：环境变量优先，否则找仓库外 setup.sh 下载的位置
WASI_SDK  ?= $(abspath $(HERE)/../../wasi-sdk-34.0-x86_64-linux)
WASMTIME  ?= $(abspath $(HERE)/../../wasmtime-v48.0.1-x86_64-linux/wasmtime)
NGINX     := $(HERE)/nginx-1.31.4
SYSROOT   := $(WASI_SDK)/share/wasi-sysroot
# 最终产物拷到 out/（objs/ 是 configure 生成的原生构建树，保持不动）
OUT       := $(HERE)/out/nginx.wasm

WCC       := $(WASI_SDK)/bin/clang
CC_OPT    := --target=wasm32-wasip2 --sysroot=$(SYSROOT) -O2 -D__wasi__ -D_GNU_SOURCE \
	-D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID \
	-D_WASI_EMULATED_MMAN -I$(HERE)/wasi-include -include $(HERE)/wasi-include/wasi_shims.h
LD_OPT    := --target=wasm32-wasip2 --sysroot=$(SYSROOT) -L$(SYSROOT)/lib/wasm32-wasip2 \
	-lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid \
	-lwasi-emulated-mman

.PHONY: all configure build run test clean

all: build

$(NGINX)/objs/Makefile:
	cd $(NGINX) && NGX_RUNNER="$(WASMTIME) run -S cli" ./auto/configure \
		--with-cc=$(WCC) --with-debug \
		--with-cc-opt="$(CC_OPT)" \
		--with-ld-opt="$(LD_OPT)" \
		--with-select_module \
		--without-http_gzip_module \
		--without-pcre --without-http_rewrite_module \
		--without-http_fastcgi_module --without-http_uwsgi_module --without-http_scgi_module \
		--without-http_grpc_module --without-http_memcached_module \
		--without-http_geo_module --without-http_split_clients_module \
		--without-http_ssi_module --without-http_userid_module --without-http_browser_module \
		--without-http_mirror_module --without-http_tunnel_module --without-http_referer_module \
		--without-http_map_module --without-http_empty_gif_module \
		--without-http_limit_conn_module --without-http_limit_req_module \
		--without-http_upstream_hash_module --without-http_upstream_ip_hash_module \
		--without-http_upstream_least_conn_module --without-http_upstream_least_time_module \
		--without-http_upstream_random_module --without-http_upstream_keepalive_module \
		--prefix=$(HERE)/run
	python3 $(HERE)/patch-objs.py

build: $(NGINX)/objs/Makefile
	$(MAKE) -C $(NGINX) -f objs/Makefile objs/nginx
	mkdir -p $(HERE)/out
	cp $(NGINX)/objs/nginx $(OUT)

# 单进程前台运行；-S cli 提供 p2 文件系统+sockets，inherit-network 允许监听
run:
	mkdir -p $(HERE)/run/logs
	cd $(HERE) && $(WASMTIME) run -W max-wasm-stack=8388608 -S cli \
		-S inherit-network=y -S allow-ip-name-lookup=y \
		--dir=. --env HOME=$(HOME) \
		$(OUT) -p run -c conf/nginx.conf

test:
	curl -s -o /dev/null -w 'HTTP %{http_code}\n' http://127.0.0.1:8080/ || true
	curl -s http://127.0.0.1:8080/ | head -5

clean:
	rm -rf $(NGINX)/objs
	rm -rf $(HERE)/out
