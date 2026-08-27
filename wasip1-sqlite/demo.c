/* sqlite WASI demo: runs inside wasmtime */
#include "sqlite3.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    sqlite3 *db;
    int rc;
    const char *err = NULL;

    printf("SQLite version: %s (compiled %s)\n",
           sqlite3_libversion(), sqlite3_sourceid() ? "from amalgamation" : "");

    rc = sqlite3_open("demo.db", &db);
    if (rc != SQLITE_OK) {
        printf("open failed: %s\n", sqlite3_errmsg(db));
        return 1;
    }

    rc = sqlite3_exec(db,
        "CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v INTEGER);"
        "INSERT OR REPLACE INTO kv VALUES('wasm',1),('redis',2),('nginx',3);",
        NULL, NULL, (char**)&err);
    if (rc != SQLITE_OK) { printf("exec failed: %s\n", err); return 1; }

    sqlite3_stmt *stmt;
    rc = sqlite3_prepare_v2(db, "SELECT k, v FROM kv ORDER BY v;", -1, &stmt, NULL);
    if (rc != SQLITE_OK) { printf("prepare failed: %s\n", sqlite3_errmsg(db)); return 1; }

    printf("--- query result (from disk-backed db) ---\n");
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        printf("  %s => %d\n",
               sqlite3_column_text(stmt, 0), sqlite3_column_int(stmt, 1));
    }
    if (rc != SQLITE_DONE) { printf("step failed: %s\n", sqlite3_errmsg(db)); return 1; }

    sqlite3_finalize(stmt);
    sqlite3_close(db);
    printf("--- done: check demo.db persisted on host fs ---\n");
    return 0;
}
