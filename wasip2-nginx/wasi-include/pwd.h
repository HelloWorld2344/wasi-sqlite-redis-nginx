/* pwd.h stub — WASI 无用户数据库。getpwnam 等恒返回 NULL（未配置 user 指令时不涉及） */
#ifndef _WASI_PWD_H
#define _WASI_PWD_H
#include <sys/types.h>
struct passwd {
    char *pw_name; char *pw_passwd; uid_t pw_uid; gid_t pw_gid;
    char *pw_gecos; char *pw_dir; char *pw_shell;
};
struct passwd *getpwnam(const char *name);
struct passwd *getpwuid(uid_t uid);
struct passwd *getpwent(void);
void setpwent(void);
void endpwent(void);
#endif
