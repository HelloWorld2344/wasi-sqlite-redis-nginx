/* grp.h stub — WASI 无用户组数据库 */
#ifndef _WASI_GRP_H
#define _WASI_GRP_H
#include <sys/types.h>
struct group {
    char *gr_name; char *gr_passwd; gid_t gr_gid; char **gr_mem;
};
struct group *getgrnam(const char *name);
struct group *getgrgid(gid_t gid);
int initgroups(const char *user, gid_t group);
#endif
