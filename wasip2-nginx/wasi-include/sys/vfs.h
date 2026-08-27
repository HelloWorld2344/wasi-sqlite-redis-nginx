/* sys/vfs.h stub — statfs() 无 WASI 语义，恒返回错误 */
#ifndef _WASI_SYS_VFS_H
#define _WASI_SYS_VFS_H
#include <sys/types.h>
struct statfs {
    long f_type; long f_bsize; unsigned long f_blocks; unsigned long f_bfree;
    unsigned long f_bavail; unsigned long f_files; unsigned long f_ffree;
    long f_fsid[2]; long f_namelen; long f_frsize; long f_flags; long f_spare[4];
};
int statfs(const char *path, struct statfs *buf);
int fstatfs(int fd, struct statfs *buf);
#endif
