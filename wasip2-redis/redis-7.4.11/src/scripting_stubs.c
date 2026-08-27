/* scripting_stubs.c — Lua/脚本功能已从 WASI 构建中移除（EVAL/SCRIPT/FUNCTION
 * 不支持，见 NOTES.md），这里是各引用点的零值桩，保证语义安全：
 * - 无脚本在运行 / 无脚本超时 / 无 ldb 子进程
 * - 脚本与函数的内存占用为 0
 * - evalScriptsDict() 返回一个空 dict（调用方会 dictSize() 它）
 */

#include "server.h"
#include "script.h"
#include "functions.h"

int scriptIsRunning(void) { return 0; }
int scriptIsEval(void) { return 0; }
int scriptIsTimedout(void) { return 0; }

int ldbPendingChildren(void) { return 0; }
void ldbKillForkedSessions(void) { }

unsigned long evalMemory(void) { return 0; }
unsigned long evalScriptsMemory(void) { return 0; }
unsigned long functionsMemory(void) { return 0; }
unsigned long functionsMemoryOverhead(void) { return 0; }
unsigned long functionsNum(void) { return 0; }
unsigned long functionsLibNum(void) { return 0; }

dict *evalScriptsDict(void) {
    static dict *d = NULL;
    if (d == NULL) d = dictCreate(&hashDictType);
    return d;
}

/* ---- 函数库上下文（RDB/AOF 的 functions 读写路径）---- */
/* 无任何函数库：GetCurrent 返回哨兵指针（struct 不透明，用哑存储），各操作空实现 */
static int dummy_lib_ctx_storage;

functionsLibCtx *functionsLibCtxGetCurrent(void) {
    return (functionsLibCtx *)&dummy_lib_ctx_storage;
}

functionsLibCtx *functionsLibCtxCreate(void) {
    return (functionsLibCtx *)&dummy_lib_ctx_storage;
}

void functionsLibCtxClearCurrent(int async) { (void)async; }
void functionsLibCtxFree(functionsLibCtx *lib_ctx) { (void)lib_ctx; }
void functionsLibCtxClear(functionsLibCtx *lib_ctx) { (void)lib_ctx; }
void functionsLibCtxSwapWithCurrent(functionsLibCtx *lib_ctx) { (void)lib_ctx; }

size_t functionsLibCtxFunctionsLen(functionsLibCtx *functions_ctx) {
    (void)functions_ctx;
    return 0;
}

dict *functionsLibGet(void) {
    static dict *d = NULL;
    if (d == NULL) d = dictCreate(&hashDictType);
    return d;
}

sds functionsCreateWithLibraryCtx(sds code, int replace, sds *err,
                                  functionsLibCtx *lib_ctx, size_t timeout) {
    (void)code; (void)replace; (void)lib_ctx; (void)timeout;
    if (err) *err = sdsnew("FUNCTION is not supported under WASI");
    return NULL;
}
