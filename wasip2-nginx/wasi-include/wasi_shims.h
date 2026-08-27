/* wasi_shims.h — nginx 移植的 WASI 补丁声明/宏（-include 强制包含） */
#ifndef _WASI_SHIMS_H
#define _WASI_SHIMS_H

#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h> /* 部分头文件直接用 struct cmsghdr 但不 include socket.h */

/* cmsghdr/CMSG_* 被 wasi-libc 藏在 __wasilibc_unmodified_upstream 门后
 * （msghdr 在 bits/socket.h 里有 wasi 版本，不缺） */
#include <sys/uio.h>
struct cmsghdr {
    socklen_t cmsg_len;
    int cmsg_level;
    int cmsg_type;
};
#ifndef MSG_CTRUNC
#define MSG_CTRUNC 0x08
#endif
#ifndef SCM_RIGHTS
#define SCM_RIGHTS 0x01
#endif
/* 信号编号（Linux 值；guest 收不到信号，仅编译用） */
#ifndef SIGWINCH
#define SIGWINCH 28
#define SIGIO    29
#define SIGSYS   31
#endif
/* fcntl 命令（异步 IO 通知，wasi 不生效） */
#ifndef F_SETOWN
#define F_SETOWN 8
#define FIOASYNC 0x5452
#endif
/* 进程控制声明（实现见 nginx_stubs.c，恒失败） */
pid_t fork(void);
int execve(const char *path, char *const argv[], char *const envp[]);
int kill(pid_t pid, int sig);
#define __CMSG_LEN(cmsg) (((cmsg)->cmsg_len + sizeof(long) - 1) & ~(long)(sizeof(long) - 1))
#define __CMSG_NEXT(cmsg) ((unsigned char *)(cmsg) + __CMSG_LEN(cmsg))
#define __MHDR_END(mhdr) ((unsigned char *)(mhdr)->msg_control + (mhdr)->msg_controllen)
#define CMSG_ALIGN(len) (((len) + sizeof(size_t) - 1) & (size_t) ~(sizeof(size_t) - 1))
#define CMSG_DATA(cmsg) ((unsigned char *) (((struct cmsghdr *)(cmsg)) + 1))
#define CMSG_NXTHDR(mhdr, cmsg) \
    ((cmsg)->cmsg_len < sizeof(struct cmsghdr) || \
     (size_t)__CMSG_LEN(cmsg) + sizeof(struct cmsghdr) >= \
        (size_t)(__MHDR_END(mhdr) - (unsigned char *)(cmsg)) \
     ? 0 : (struct cmsghdr *)__CMSG_NEXT(cmsg))
#define CMSG_FIRSTHDR(mhdr) \
    ((size_t)(mhdr)->msg_controllen >= sizeof(struct cmsghdr) \
     ? (struct cmsghdr *)(mhdr)->msg_control : (struct cmsghdr *)0)
#define CMSG_SPACE(len) (CMSG_ALIGN(len) + CMSG_ALIGN(sizeof(struct cmsghdr)))
#define CMSG_LEN(len)   (CMSG_ALIGN(sizeof(struct cmsghdr)) + (len))
ssize_t recvmsg(int, struct msghdr *, int);
ssize_t sendmsg(int, const struct msghdr *, int);

/* AF_UNIX/sockaddr_un：wasi:sockets 无 Unix 域 socket。抢占 _SYS_UN_H 防护，
 * 提供完整定义（含 sun_path）供编译；运行时 unix: 监听会 bind 失败并报错 */
#ifndef AF_UNIX
#define AF_UNIX 1
#endif
#ifndef _SYS_UN_H
#define _SYS_UN_H
struct sockaddr_un {
    sa_family_t sun_family;
    char sun_path[108];
};
#endif

/* Linux 特有 errno（取同名值，仅用于编译；wasi 下比较不会命中） */
#ifndef ESOCKTNOSUPPORT
#define ESOCKTNOSUPPORT 94
#endif
#ifndef EPFNOSUPPORT
#define EPFNOSUPPORT 96
#endif
/* 其余 Linux 特有 errno（同名值；wasi 下这些错误不会发生） */
#ifndef ENONET
#define ENONET 64
#endif
#ifndef EREMOTE
#define EREMOTE 66
#endif
#ifndef ENOTUNIQ
#define ENOTUNIQ 76
#endif
#ifndef EHOSTDOWN
#define EHOSTDOWN 112
#endif
#ifndef EREMOTEIO
#define EREMOTEIO 121
#endif
#ifndef EPROTO
#define EPROTO 71
#endif

mode_t umask(mode_t mask);
void tzset(void);

int mkstemp(char *template);
int mkostemp(char *template, int flags);

/* ---- wasi-libc 在 __wasilibc_unmodified_upstream 门后藏起来的结构体，
 * 这里补全（实现见 nginx_stubs.c） ---- */
#include <sys/resource.h>
/* 注意：ngx_auto_config.h 会自 typedef int rlim_t，这里不用该名字 */
struct rlimit {
    unsigned long long rlim_cur;
    unsigned long long rlim_max;
};
/* RLIMIT_* 在 wasi 构建下不可见，取 Linux 值 */
#ifndef RLIMIT_NOFILE
#define RLIMIT_CPU     0
#define RLIMIT_FSIZE   1
#define RLIMIT_DATA    2
#define RLIMIT_STACK   3
#define RLIMIT_CORE    4
#define RLIMIT_RSS     5
#define RLIMIT_NPROC   6
#define RLIMIT_NOFILE  7
#define RLIMIT_MEMLOCK 8
#define RLIMIT_AS      9
#endif
#ifndef SO_SNDLOWAT
#define SO_RCVLOWAT 18
#define SO_SNDLOWAT 19
#endif
int getrlimit(int resource, struct rlimit *rlim);
int setrlimit(int resource, const struct rlimit *rlim);

/* wasi-libc 未声明的身份/所有权 API（实现见 nginx_stubs.c） */
int chown(const char *path, uid_t owner, gid_t group);
int fchown(int fd, uid_t owner, gid_t group);
int lchown(const char *path, uid_t owner, gid_t group);
/* wasi-libc 未声明的身份 API（实现见 nginx_stubs.c） */
pid_t getppid(void);
uid_t getuid(void);
uid_t geteuid(void);
gid_t getgid(void);
gid_t getegid(void);

#include <sys/time.h>
struct itimerval {
    struct timeval it_interval;
    struct timeval it_value;
};
#define ITIMER_REAL    0
#define ITIMER_VIRTUAL 1
#define ITIMER_PROF    2
int setitimer(int which, const struct itimerval *new_value, struct itimerval *old_value);

#endif /* _WASI_SHIMS_H */

/* statvfs（ngx 临时路径磁盘检查用；实现恒返回错误） */
struct statvfs {
    unsigned long f_bsize;
    unsigned long f_frsize;
    unsigned long long f_blocks;
    unsigned long long f_bfree;
    unsigned long long f_bavail;
    unsigned long long f_files;
    unsigned long long f_ffree;
    unsigned long long f_favail;
    unsigned long f_fsid;
    unsigned long f_flag;
    unsigned long f_namemax;
};
int statvfs(const char *path, struct statvfs *buf);
int fstatvfs(int fd, struct statvfs *buf);
int socketpair(int domain, int type, int protocol, int sv[2]);
pid_t setsid(void);
pid_t setsid(void);
int setuid(uid_t uid);
int setgid(gid_t gid);
int setpriority(int which, id_t who, int prio);
#define PRIO_PROCESS 0
int sigsuspend(const sigset_t *mask);
#ifndef SO_LINGER
#define SO_LINGER 13
#endif
