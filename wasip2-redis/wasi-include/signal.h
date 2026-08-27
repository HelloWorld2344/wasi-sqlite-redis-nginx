/* signal.h stub for WASI（遮蔽 wasip2 sysroot 的头，它不声明 sigaction 等）。
 *
 * - signal()/raise()/psignal()/strsignal() 由 -lwasi-emulated-signal 提供
 * - sigaction/sigemptyset 等在 wasi_stubs.c 里给 no-op 实现（guest 收不到信号）
 */
#ifndef _WASI_SIGNAL_H
#define _WASI_SIGNAL_H

#define __NEED_sigset_t
#define __NEED_size_t
#define __NEED_pid_t
#include <bits/alltypes.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 信号编号（POSIX/Linux 值，仅为编译；永远不会真的投递） */
#define SIGHUP    1
#define SIGINT    2
#define SIGQUIT   3
#define SIGILL    4
#define SIGTRAP   5
#define SIGABRT   6
#define SIGBUS    7
#define SIGFPE    8
#define SIGKILL   9
#define SIGUSR1   10
#define SIGSEGV   11
#define SIGUSR2   12
#define SIGPIPE   13
#define SIGALRM   14
#define SIGTERM   15
#define SIGCHLD   17
#define SIGCONT   18
#define SIGSTOP   19
#define SIGTSTP   20

#define SIG_BLOCK   0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2

#define SIG_DFL ((void (*)(int))0)
#define SIG_IGN ((void (*)(int))1)
#define SIG_ERR ((void (*)(int))-1)

typedef struct {
    int si_signo;
    int si_code;
    int si_errno;
    void *si_addr;
    pid_t si_pid;
    unsigned int si_uid;
} siginfo_t;

#define SI_USER 0

typedef void (*sighandler_t)(int);

struct sigaction {
    union {
        sighandler_t sa_handler;
        void (*sa_sigaction)(int, siginfo_t *, void *);
    } __sa_handler;
    sigset_t sa_mask;
    int sa_flags;
    void (*sa_restorer)(void);
};
#define sa_handler   __sa_handler.sa_handler
#define sa_sigaction __sa_handler.sa_sigaction

/* SA_* 标志位（Linux 值） */
#define SA_NOCLDSTOP 1
#define SA_NOCLDWAIT 2
#define SA_SIGINFO   4
#define SA_RESTART   0x10000000
#define SA_NODEFER   0x40000000
#define SA_RESETHAND 0x80000000

typedef int sig_atomic_t;

sighandler_t signal(int signum, sighandler_t handler);
int raise(int sig);
void psignal(int sig, const char *msg);
char *strsignal(int sig);

int sigemptyset(sigset_t *set);
int sigfillset(sigset_t *set);
int sigaddset(sigset_t *set, int signum);
int sigdelset(sigset_t *set, int signum);
int sigismember(const sigset_t *set, int signum);
int sigprocmask(int how, const sigset_t *set, sigset_t *oldset);
int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact);
/* pthread 变体（实现在 wasi_stubs.c，同样 no-op） */
int pthread_sigmask(int how, const sigset_t *set, sigset_t *oldset);

#ifdef __cplusplus
}
#endif

#endif /* _WASI_SIGNAL_H */
