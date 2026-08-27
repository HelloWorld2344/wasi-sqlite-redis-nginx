/* Minimal sys/wait.h shim for WASI (wasi-libc 没有，WASI 无进程概念).
 * waitpid 实际调用点都已在源码中用 #ifndef __wasi__ 守护，这里只提供
 * 编译所需的声明与状态宏。 */
#ifndef _WASI_SYS_WAIT_H
#define _WASI_SYS_WAIT_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WNOHANG   1
#define WUNTRACED 2

#define WIFEXITED(s)   (((s) & 0x7f) == 0)
#define WEXITSTATUS(s) (((s) >> 8) & 0xff)
#define WIFSIGNALED(s) (((s) & 0x7f) != 0)
#define WTERMSIG(s)    ((s) & 0x7f)

pid_t waitpid(pid_t pid, int *status, int options);

#ifdef __cplusplus
}
#endif

#endif /* _WASI_SYS_WAIT_H */
