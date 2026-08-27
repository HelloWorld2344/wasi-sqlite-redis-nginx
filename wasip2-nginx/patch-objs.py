#!/usr/bin/env python3
"""把 nginx_stubs.o 注入 configure 生成的 objs/Makefile。
configure 每次运行都会重新生成 objs/Makefile，所以这里单独维护。"""
import re
import sys

import os
HERE = os.path.dirname(os.path.abspath(__file__))
NGINX = os.path.join(HERE, 'nginx-1.31.4')
STUBS = os.path.join(HERE, 'wasi-include', 'nginx_stubs.c')
p = f'{NGINX}/objs/Makefile'
s = open(p).read()

# 1) 编译规则
anchor = 'LINK =\t$(CC)\n'
assert anchor in s
if 'objs/nginx_stubs.o:' not in s:
    s = s.replace(anchor, anchor + f'\nobjs/nginx_stubs.o:\t{STUBS}\n\t$(CC) -c $(CFLAGS) -o $@ $<\n', 1)

# 2) 依赖列表
dep = 'objs/nginx:\tobjs/src/core/nginx.o \\\n'
assert dep in s
if '\tobjs/nginx_stubs.o \\\n' not in s:
    s = s.replace(dep, dep + '\tobjs/nginx_stubs.o \\\n', 1)

# 3) 链接命令（紧跟 -o objs/nginx 后插入对象）
cmd = '\t$(LINK) -o objs/nginx \\\n'
assert cmd in s
if ' objs/nginx_stubs.o' not in s.split('\n')[s.split('\n').index(cmd.strip('\n')) + 1]:
    s = s.replace(cmd, cmd + '\tobjs/nginx_stubs.o \\\n', 1)

open(p, 'w').write(s)
print('objs/Makefile patched with nginx_stubs.o')
