/* WASI stubs for Redis.
 *
 * wasi-libc 声明了这些 POSIX API 但没有实现（或语义无法支持），这里给出
 * 单线程 guest 下语义正确的实现：
 *
 * - syslog:     WASI 无 syslog，转发到 stderr（Redis 默认也不用 syslog）
 * - dlfcn:      WASI 不能加载动态库 → MODULE 命令会优雅报错
 * - dladdr:     WASI 无动态符号表 → 返回 0（调用方自然跳过）
 * - mmap:       官方 -lwasi-emulated-mman 提供 mmap/munmap；这里补 madvise
 * - pthread 锁: 单线程 no-op 实现（guest 里没有线程，no-op 锁语义正确）
 * - 信号相关:   sigaction/sigemptyset 等 no-op（guest 收不到真实信号；
 *               signal/raise 由 -lwasi-emulated-signal 提供）
 */

#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>

/* ---- syslog ---- */
void openlog(const char *ident, int option, int facility) {
    (void)ident; (void)option; (void)facility;
}

void syslog(int priority, const char *format, ...) {
    va_list ap;
    fprintf(stderr, "[syslog:%d] ", priority);
    va_start(ap, format);
    vfprintf(stderr, format, ap);
    va_end(ap);
    fputc('\n', stderr);
}

void closelog(void) {
}

/* ---- dlfcn ---- */
static const char dl_error[] = "dynamic module loading is not supported under WASI";

void *dlopen(const char *file, int mode) {
    (void)file; (void)mode;
    errno = ENOSYS;
    return NULL;
}

void *dlsym(void *handle, const char *symbol) {
    (void)handle; (void)symbol;
    errno = ENOSYS;
    return NULL;
}

int dlclose(void *handle) {
    (void)handle;
    return 0;
}

char *dlerror(void) {
    return (char *)dl_error;
}

int dladdr(void *addr, Dl_info *info) {
    (void)addr; (void)info;
    return 0; /* WASI 无动态符号表 */
}

/* ---- mman 补缺（mmap/munmap 走官方 -lwasi-emulated-mman） ---- */
/* madvise 只被当作性能优化使用，单线程场景假装成功即可 */
int madvise(void *addr, size_t length, int advice) {
    (void)addr; (void)length; (void)advice;
    return 0;
}

/* ---- 信号：no-op 实现（信号永远不会投递，安装/清空都无害） ---- */
int sigemptyset(sigset_t *set) { if (set) *set = 0; return 0; }
int sigfillset(sigset_t *set) { if (set) *set = ~(sigset_t)0; return 0; }
int sigaddset(sigset_t *set, int signum) { (void)signum; if (set) *set |= 1; return 0; }
int sigdelset(sigset_t *set, int signum) { (void)signum; if (set) *set = 0; return 0; }
int sigismember(const sigset_t *set, int signum) { (void)set; (void)signum; return 0; }
int sigprocmask(int how, const sigset_t *set, sigset_t *oldset) {
    (void)how; (void)set; (void)oldset;
    return 0;
}
int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact) {
    (void)signum; (void)act; (void)oldact;
    return 0;
}
int pthread_sigmask(int how, const sigset_t *set, sigset_t *oldset) {
    (void)how; (void)set; (void)oldset;
    return 0;
}

/* ---- 杂项 ---- */
mode_t umask(mode_t mask) {
    (void)mask;
    return 0; /* WASI 无文件权限位语义，空实现 */
}

void tzset(void) {
    /* WASI 无环境时区概念，localtime.c 自行处理时区 */
}

int setitimer(int which, const struct itimerval *new_value, struct itimerval *old_value) {
    (void)which; (void)new_value; (void)old_value;
    return 0; /* watchdog 定时器在 WASI 下不起作用（无信号投递） */
}

/* mkstemp/mkostemp：wasi-libc 没有，用计数器 + O_EXCL 实现 */
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

static int mkstemp_common(char *t, int flags) {
    size_t len = strlen(t);
    if (len < 6) { errno = EINVAL; return -1; }
    char *xs = t + len - 6;
    static unsigned counter;
    static const char alnum[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    for (unsigned i = 0; i < 999999; i++) {
        unsigned n = ++counter;
        for (int j = 5; j >= 0; j--) { xs[j] = alnum[n % 36]; n /= 36; }
        int fd = open(t, flags | O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd != -1) return fd;
        if (errno != EEXIST) return -1;
    }
    errno = EEXIST;
    return -1;
}

int mkstemp(char *t) { return mkstemp_common(t, 0); }
int mkostemp(char *t, int flags) { return mkstemp_common(t, flags); }

/* tmpnam：Lua 的 os.tmpname 用（不创建文件，只生成名字） */
char *tmpnam(char *s) {
    static char buf[512];
    static unsigned counter;
    if (!s) s = buf;
    snprintf(s, 512, "wasi-tmp-%u", ++counter);
    return s;
}

/* flock：pidfile/集群配置文件的排他锁。单实例 guest 下恒成功。 */
#include <sys/file.h>
int flock(int fd, int operation) {
    (void)fd; (void)operation;
    return 0;
}

/* TLS 连接类型未编译（BUILD_TLS=no），注册函数空实现满足 connection.c 的调用 */
int RedisRegisterConnectionTypeTLS(void) {
    return 0;
}

/* ---- pthread: 单线程 no-op ---- */
int pthread_mutex_lock(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_unlock(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_trylock(pthread_mutex_t *m) { (void)m; return 0; }
int pthread_mutex_timedlock(pthread_mutex_t *m, const struct timespec *ts) {
    (void)m; (void)ts;
    return 0;
}

int pthread_once(pthread_once_t *once, void (*init)(void)) {
    (void)once;
    init();
    return 0;
}
