/* sqlite WASI micro-benchmark: insert N rows in a txn, then read them back */
#include "sqlite3.h"
#include <stdio.h>
#include <time.h>

#define N 100000

int main(void) {
    sqlite3 *db;
    clock_t t0, t1;
    char *err = NULL;
    int i;

    if (sqlite3_open("bench.db", &db) != SQLITE_OK) {
        printf("open failed: %s\n", sqlite3_errmsg(db));
        return 1;
    }
    if (sqlite3_exec(db,
        "PRAGMA locking_mode=EXCLUSIVE; PRAGMA journal_mode=MEMORY; PRAGMA cache_size=20000; PRAGMA synchronous=OFF;"
        "DROP TABLE IF EXISTS t; CREATE TABLE t(a INT, b TEXT);"
        "CREATE INDEX idx_t_a ON t(a);",
        NULL, NULL, &err) != SQLITE_OK) { printf("ddl failed: %s\n", err); return 1; }

    if (sqlite3_exec(db, "BEGIN;", NULL, NULL, &err) != SQLITE_OK) {
        printf("begin failed: %s\n", err); return 1;
    }
    sqlite3_stmt *ins;
    sqlite3_prepare_v2(db, "INSERT INTO t VALUES(?, 'hello-wasm');", -1, &ins, NULL);
    t0 = clock();
    for (i = 0; i < N; i++) {
        sqlite3_bind_int(ins, 1, i);
        if (sqlite3_step(ins) != SQLITE_DONE) { printf("insert failed\n"); return 1; }
        sqlite3_reset(ins);
    }
    sqlite3_finalize(ins);
    if (sqlite3_exec(db, "COMMIT;", NULL, NULL, &err) != SQLITE_OK) {
        printf("commit failed: %s\n", err); return 1;
    }
    t1 = clock();
    printf("INSERT %d rows: %.2f ms (%.0f rows/s)\n",
           N, 1000.0 * (t1 - t0) / CLOCKS_PER_SEC, N / ((double)(t1 - t0) / CLOCKS_PER_SEC));

    sqlite3_stmt *sel;
    sqlite3_prepare_v2(db, "SELECT b FROM t WHERE a=?;", -1, &sel, NULL);
    t0 = clock();
    for (i = 0; i < N; i++) {
        sqlite3_bind_int(sel, 1, i);
        sqlite3_step(sel);
        sqlite3_reset(sel);
    }
    t1 = clock();
    printf("SELECT %d rows: %.2f ms (%.0f rows/s)\n",
           N, 1000.0 * (t1 - t0) / CLOCKS_PER_SEC, N / ((double)(t1 - t0) / CLOCKS_PER_SEC));

    sqlite3_finalize(sel);
    sqlite3_close(db);
    return 0;
}
