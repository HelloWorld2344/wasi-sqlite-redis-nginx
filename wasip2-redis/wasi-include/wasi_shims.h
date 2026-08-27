/* wasi_shims.h — 被 Makefile 用 -include 强制包含的补丁声明/宏。
 *
 * 解决 wasi-libc 缺失的零散符号：
 * - ESOCKTNOSUPPORT/EPFNOSUPPORT：Linux 特有 errno，Redis 在 accept 错误
 *   分类里用到，取 Linux 同名值即可（比较永远不会命中，仅用于编译）
 * - Dl_info/dladdr：wasi 无动态符号表，实现见 wasi_stubs.c（返回 0）
 * - umask/tzset：wasi-libc 未声明，实现见 wasi_stubs.c（no-op）
 */
#ifndef _WASI_SHIMS_H
#define _WASI_SHIMS_H

#include <errno.h>
#include <sys/types.h>

#ifndef ESOCKTNOSUPPORT
#define ESOCKTNOSUPPORT 94
#endif
#ifndef EPFNOSUPPORT
#define EPFNOSUPPORT 96
#endif

typedef struct {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;
int dladdr(void *addr, Dl_info *info);

mode_t umask(mode_t mask);
void tzset(void);

/* setitimer（watchdog 用，实现为 no-op，见 wasi_stubs.c） */
#include <sys/time.h>
struct itimerval {
    struct timeval it_interval;
    struct timeval it_value;
};
#define ITIMER_REAL    0
#define ITIMER_VIRTUAL 1
#define ITIMER_PROF    2
int setitimer(int which, const struct itimerval *new_value, struct itimerval *old_value);

/* mkstemp/mkostemp（config 重写用，实现见 wasi_stubs.c） */
int mkstemp(char *template);
int mkostemp(char *template, int flags);

/* flock（pidfile 等，实现见 wasi_stubs.c） */
#define LOCK_SH 1
#define LOCK_EX 2
#define LOCK_NB 4
#define LOCK_UN 8
int flock(int fd, int operation);

/* TLS 注册桩（tls.o 未编译） */
int RedisRegisterConnectionTypeTLS(void);

#endif /* _WASI_SHIMS_H */
