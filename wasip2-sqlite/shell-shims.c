/* WASI 缺失的 POSIX API 补丁，供 sqlite3 CLI shell 链接使用。
 *
 * - WASI 无进程概念：getpid() 返回固定值（单实例够用，仅用于临时文件名）
 * - WASI 无法 spawn 进程：.system / .shell 命令直接报不可用
 */
#include <stdio.h>
#include <sys/types.h>

pid_t getpid(void) { return 1; }

int system(const char *cmd) {
    fprintf(stderr,
            "'.system' is not available under WASI (no process spawning)\n");
    return -1;
}
