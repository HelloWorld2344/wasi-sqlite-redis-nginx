/* nginx_stubs.c — WASI 缺失的 POSIX API（语义正确的 no-op / 失败实现）。
 * 单进程单线程 guest：无 fork/信号/权限概念，失败即优雅降级。 */
#include <errno.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/time.h>
#include <sys/vfs.h>
#include <pwd.h>
#include <grp.h>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>

/* ---- syslog（nginx error_log syslog 特性，转发 stderr）---- */
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
void closelog(void) { }

/* ---- dlfcn ---- */
static const char dl_error[] = "dynamic loading is not supported under WASI";
void *dlopen(const char *file, int mode) { (void)file; (void)mode; errno = ENOSYS; return NULL; }
void *dlsym(void *handle, const char *symbol) { (void)handle; (void)symbol; errno = ENOSYS; return NULL; }
int dlclose(void *handle) { (void)handle; return 0; }
char *dlerror(void) { return (char *)dl_error; }

/* ---- mman 补缺（mmap/munmap 走官方 -lwasi-emulated-mman）---- */
int madvise(void *addr, size_t length, int advice) {
    (void)addr; (void)length; (void)advice;
    return 0;
}

/* ---- 信号：no-op（guest 收不到信号）---- */
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
int sigsuspend(const sigset_t *mask) { (void)mask; errno = EINTR; return -1; }

/* ---- 进程：WASI 无 fork，优雅失败 ---- */
pid_t fork(void) { errno = ENOSYS; return -1; }
pid_t waitpid(pid_t pid, int *status, int options) {
    (void)pid; (void)status; (void)options;
    errno = ECHILD;
    return -1;
}
int kill(pid_t pid, int sig) { (void)pid; (void)sig; errno = ESRCH; return -1; }
int execve(const char *path, char *const argv[], char *const envp[]) {
    (void)path; (void)argv; (void)envp;
    errno = ENOSYS;
    return -1;
}
int setsid(void) { errno = ENOSYS; return -1; }

/* ---- 权限/资源（无语义，恒成功）---- */
int setuid(uid_t uid) { (void)uid; return 0; }
int setgid(gid_t gid) { (void)gid; return 0; }
int setgroups(size_t size, const gid_t *list) { (void)size; (void)list; return 0; }
int initgroups(const char *user, gid_t group) { (void)user; (void)group; return 0; }
uid_t getuid(void) { return 0; }
gid_t getgid(void) { return 0; }
uid_t geteuid(void) { return 0; }
struct group;
int setrlimit(int resource, const struct rlimit *rlim) { (void)resource; (void)rlim; return 0; }
int getrlimit(int resource, struct rlimit *rlim) {
    (void)resource;
    if (rlim) { rlim->rlim_cur = 1 << 20; rlim->rlim_max = 1 << 20; }
    return 0;
}

/* ---- 杂项 ---- */
mode_t umask(mode_t mask) { (void)mask; return 0; }
void tzset(void) { }
int setitimer(int which, const struct itimerval *new_value, struct itimerval *old_value) {
    (void)which; (void)new_value; (void)old_value;
    return 0;
}
int sched_yield(void) { return 0; }

/* ---- pthread 锁：单线程 no-op ---- */
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

/* ---- 文件 ---- */
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

/* ---- 进程身份（WASI 无）---- */
pid_t getppid(void) { return 1; }
gid_t getegid(void) { return 0; }
int chown(const char *path, uid_t owner, gid_t group) { (void)path; (void)owner; (void)group; return 0; }
int fchown(int fd, uid_t owner, gid_t group) { (void)fd; (void)owner; (void)group; return 0; }
int lchown(const char *path, uid_t owner, gid_t group) { (void)path; (void)owner; (void)group; return 0; }

/* ---- recvmsg/sendmsg：基于 recvfrom/sendto 的近似（不支持控制消息）---- */
ssize_t recvmsg(int fd, struct msghdr *msg, int flags) {
    void *buf = (msg && msg->msg_iov && msg->msg_iovlen > 0) ? msg->msg_iov[0].iov_base : NULL;
    size_t len = (msg && msg->msg_iov && msg->msg_iovlen > 0) ? msg->msg_iov[0].iov_len : 0;
    socklen_t namelen = msg ? msg->msg_namelen : 0;
    ssize_t n = recvfrom(fd, buf, len, flags, msg ? msg->msg_name : NULL,
                         msg ? &namelen : NULL);
    if (n >= 0 && msg) {
        msg->msg_namelen = namelen;
        msg->msg_controllen = 0; /* 无控制消息 */
        msg->msg_flags = 0;
    }
    return n;
}

ssize_t sendmsg(int fd, const struct msghdr *msg, int flags) {
    const void *buf = (msg && msg->msg_iov && msg->msg_iovlen > 0) ? msg->msg_iov[0].iov_base : NULL;
    size_t len = (msg && msg->msg_iov && msg->msg_iovlen > 0) ? msg->msg_iov[0].iov_len : 0;
    return sendto(fd, buf, len, flags, msg ? msg->msg_name : NULL,
                  msg ? msg->msg_namelen : 0);
}
/* statvfs/fstatvfs：libc 有实现，无需桩 */
int socketpair(int domain, int type, int protocol, int sv[2]) {
    (void)domain; (void)type; (void)protocol; (void)sv;
    errno = ENOSYS;
    return -1;
}


/* ---- 用户/组数据库（WASI 无）：任意名字都解析为 uid=0/gid=0 ---- */
static struct passwd fake_pw = {
    "root", "x", 0, 0, "root", "/", "/bin/sh"
};
static struct group fake_gr = {
    "root", "x", 0, NULL
};
struct passwd *getpwnam(const char *name) { (void)name; return &fake_pw; }
struct passwd *getpwuid(uid_t uid) { (void)uid; return &fake_pw; }
struct passwd *getpwent(void) { return NULL; }
void setpwent(void) { }
void endpwent(void) { }
struct group *getgrnam(const char *name) { (void)name; return &fake_gr; }
struct group *getgrgid(gid_t gid) { (void)gid; return &fake_gr; }

/* ---- statfs ---- */
int statfs(const char *path, struct statfs *buf) {
    (void)path; (void)buf;
    errno = ENOSYS;
    return -1;
}
int fstatfs(int fd, struct statfs *buf) {
    (void)fd; (void)buf;
    errno = ENOSYS;
    return -1;
}

int setpriority(int which, id_t who, int prio) { (void)which; (void)who; (void)prio; return 0; }
/* chmod/fchmod：libc 有实现（恒返回 ENOSYS），nginx 侧已跳过调用 */
