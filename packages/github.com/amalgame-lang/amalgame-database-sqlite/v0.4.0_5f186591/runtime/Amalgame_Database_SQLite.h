/*
 * Amalgame Standard Library — Amalgame.Database.SQLite
 * Copyright (c) 2026 Bastien MOUGET
 * https://github.com/amalgame-lang/Amalgame
 *
 * SQLite 3 binding. The amalgamation
 * (`runtime/Amalgame_Database/sqlite/sqlite3.c` +
 *  `runtime/Amalgame_Database/sqlite/sqlite3.h`)
 * is vendored from sqlite.org under SQLite's public-domain
 * dedication — no external `libsqlite3-dev` needed on any of the
 * supported OSes. User projects that import
 * `Amalgame.Database.SQLite` link the vendored sqlite3.c directly
 * into their binary; the compiler itself never imports this header
 * so amc's own build doesn't pull in 9 MB of C.
 *
 * Sibling backends (Postgres, DuckDB, MySQL, …) will live as
 * `Amalgame_Database_<Engine>.h` next to this one; the namespace
 * convention `Amalgame.Database.<Engine>` keeps user code explicit
 * about which engine they're talking to.
 *
 * v1 surface: open / close, exec (no-result SQL), query (returns
 * a List<List<string>> with column values as text), last-insert-id,
 * row-changes, last-error. Parameter binding via `?` placeholders
 * + a List<string> of values is the next ask (tracked alongside
 * other database vendoring in the roadmap).
 *
 * SQLite handles concurrency internally via threading-mode at
 * compile time; the amalgamation is built with SQLITE_THREADSAFE=1
 * by default, which is what we want for the typical service-loop
 * caller. No mutex on our side — the AmalgameSQLite struct is single-
 * owner and immutable past Amalgame_Database_SQLite_Open.
 */

#ifndef AMALGAME_DATABASE_SQLITE_H
#define AMALGAME_DATABASE_SQLITE_H

#include "_runtime.h"
#include "Amalgame_Collections.h"
#include "Amalgame_Database/sqlite/sqlite3.h"
#include <string.h>
#include <stdlib.h>

typedef struct AmalgameSQLite {
    sqlite3* handle;
    char*    last_error;  /* GC-strdup'd snapshot of the last error message */
} AmalgameSQLite;

static inline code_string Amalgame_SQLite_strdup_err(const char* msg) {
    if (!msg) return NULL;
    size_t n = strlen(msg);
    char* p = (char*) code_alloc(n + 1);
    memcpy(p, msg, n + 1);
    return p;
}

/* Open a SQLite database at `path`. The special path `:memory:`
 * opens a transient in-memory database (great for tests). Returns
 * a non-NULL `AmalgameSQLite*` even on failure — call `Db.IsOpen()`
 * to check, or `Db.LastError()` for the message. */
static inline AmalgameSQLite* Amalgame_Database_SQLite_Open(code_string path) {
    AmalgameSQLite* db = (AmalgameSQLite*) code_alloc(sizeof(AmalgameSQLite));
    db->handle     = NULL;
    db->last_error = NULL;
    int rc = sqlite3_open(path ? path : ":memory:", &db->handle);
    if (rc != SQLITE_OK) {
        const char* msg = db->handle ? sqlite3_errmsg(db->handle) : "open failed";
        db->last_error  = Amalgame_SQLite_strdup_err(msg);
        if (db->handle) {
            sqlite3_close(db->handle);
            db->handle = NULL;
        }
    }
    return db;
}

/* Close the underlying SQLite handle. Idempotent — calling twice
 * (or on a never-opened handle) is a no-op. The wrapper struct
 * itself is GC-managed; we don't free it here. */
static inline void Amalgame_Database_SQLite_Close(AmalgameSQLite* db) {
    if (db && db->handle) {
        sqlite3_close(db->handle);
        db->handle = NULL;
    }
}

static inline code_bool Amalgame_Database_SQLite_IsOpen(AmalgameSQLite* db) {
    return (db && db->handle) ? 1 : 0;
}

/* Snapshot of the most recent error message (open failure,
 * malformed SQL, constraint violation, etc.). Empty string if
 * no error has been recorded. */
static inline code_string Amalgame_Database_SQLite_LastError(AmalgameSQLite* db) {
    if (!db) return "";
    if (db->last_error) return db->last_error;
    if (db->handle) {
        const char* msg = sqlite3_errmsg(db->handle);
        if (!msg) return "";
        /* Copy out of the SQLite-owned storage so the caller can
         * hold onto the pointer past the next sqlite3 call.
         * Also sheds the `const` qualifier cleanly. */
        return Amalgame_SQLite_strdup_err(msg);
    }
    return "";
}

/* Run a no-result SQL statement (CREATE / INSERT / UPDATE /
 * DELETE / PRAGMA / etc.). Returns true on success, false on
 * any error (check `Db.LastError()`). Multiple statements
 * separated by `;` are accepted in one call — sqlite3_exec
 * loops over them internally. */
static inline code_bool Amalgame_Database_SQLite_Exec(AmalgameSQLite* db, code_string sql) {
    if (!db || !db->handle) return 0;
    char* errmsg = NULL;
    int rc = sqlite3_exec(db->handle, sql ? sql : "", NULL, NULL, &errmsg);
    if (rc != SQLITE_OK) {
        if (errmsg) {
            db->last_error = Amalgame_SQLite_strdup_err(errmsg);
            sqlite3_free(errmsg);
        } else {
            db->last_error = Amalgame_SQLite_strdup_err(sqlite3_errmsg(db->handle));
        }
        return 0;
    }
    return 1;
}

/* Run a SELECT (or any statement that returns rows) and collect
 * every result into a `List<List<string>>` — outer list is rows,
 * inner list is columns. Every column value is converted to text
 * via `sqlite3_column_text` regardless of the declared type; NULL
 * columns become empty strings. Returns an empty list on prepare/
 * step error; check `Db.LastError()` to distinguish a real empty
 * result from a failure. */
static inline AmalgameList* Amalgame_Database_SQLite_QueryAll(AmalgameSQLite* db, code_string sql) {
    AmalgameList* rows = AmalgameList_new();
    if (!db || !db->handle) return rows;
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2(db->handle, sql ? sql : "", -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        db->last_error = Amalgame_SQLite_strdup_err(sqlite3_errmsg(db->handle));
        if (stmt) sqlite3_finalize(stmt);
        return rows;
    }
    int ncols = sqlite3_column_count(stmt);
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        AmalgameList* row = AmalgameList_new();
        for (int i = 0; i < ncols; i++) {
            const unsigned char* t = sqlite3_column_text(stmt, i);
            const char* s = t ? (const char*) t : "";
            size_t n = strlen(s);
            char* copy = (char*) code_alloc(n + 1);
            memcpy(copy, s, n + 1);
            AmalgameList_add(row, (void*) copy);
        }
        AmalgameList_add(rows, (void*) row);
    }
    if (rc != SQLITE_DONE) {
        db->last_error = Amalgame_SQLite_strdup_err(sqlite3_errmsg(db->handle));
    }
    sqlite3_finalize(stmt);
    return rows;
}

/* Rowid of the most recent successful INSERT against this connection.
 * Useful for AUTO_INCREMENT-style retrieval (`SELECT last_insert_rowid()`
 * without the round-trip). Returns 0 if there hasn't been an
 * insert yet on this handle. */
static inline i64 Amalgame_Database_SQLite_LastInsertId(AmalgameSQLite* db) {
    if (!db || !db->handle) return 0;
    return (i64) sqlite3_last_insert_rowid(db->handle);
}

/* Number of rows modified by the most recent INSERT / UPDATE /
 * DELETE on this connection. Same caveats as SQLite's
 * sqlite3_changes — only counts the immediate statement, not
 * cascades inside triggers. */
static inline i64 Amalgame_Database_SQLite_Changes(AmalgameSQLite* db) {
    if (!db || !db->handle) return 0;
    return (i64) sqlite3_changes(db->handle);
}

/* ────────────────────────────────────────────────────────────────
 * v2 surface — parameter binding + transactions.
 *
 * Parameter binding uses positional `?` placeholders (1-indexed in
 * SQLite, 0-indexed on the Amalgame side). Every binding goes
 * through `sqlite3_bind_text` (with SQLITE_TRANSIENT so the C side
 * snapshots the bytes before we return to AM); NULL list entries
 * bind as SQL NULL. SQLite's flexible type affinity converts the
 * text to INTEGER / REAL / NUMERIC per the destination column's
 * declared type, so the same `List<string>` shape works for SELECTs
 * with WHERE on a numeric column, INSERTs into mixed-type rows, etc.
 * A type-safe variant accepting `SqlParam` discriminated values
 * (and exposing bytes / typed-column accessors) is the v3 ask.
 *
 * Transactions wrap `BEGIN`, `COMMIT`, `ROLLBACK` through the
 * existing Exec path so the same `db.LastError()` surfaces any
 * failure (e.g. nested transactions return "cannot start a
 * transaction within a transaction").
 * ──────────────────────────────────────────────────────────────── */

/* Shared binding step: prepare + bind every param then return the
 * stmt to the caller for stepping. Returns NULL on prepare or bind
 * failure (db->last_error already populated). */
static inline sqlite3_stmt* Amalgame_SQLite_prepare_bound(
    AmalgameSQLite* db, code_string sql, AmalgameList* params)
{
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2(db->handle, sql ? sql : "", -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        db->last_error = Amalgame_SQLite_strdup_err(sqlite3_errmsg(db->handle));
        if (stmt) sqlite3_finalize(stmt);
        return NULL;
    }
    int n = params ? (int) AmalgameList_size(params) : 0;
    int wanted = sqlite3_bind_parameter_count(stmt);
    if (n != wanted) {
        /* Surface arity mismatches explicitly — SQLite would
         * otherwise bind partial params and return surprising
         * SQL semantics (NULL fills the rest, leading to
         * silently wrong queries). */
        char buf[128];
        snprintf(buf, sizeof(buf),
            "param count mismatch: got %d, sql expects %d", n, wanted);
        db->last_error = Amalgame_SQLite_strdup_err(buf);
        sqlite3_finalize(stmt);
        return NULL;
    }
    for (int i = 0; i < n; i++) {
        code_string v = (code_string) AmalgameList_get(params, i);
        int br;
        if (v) {
            br = sqlite3_bind_text(stmt, i + 1, v, -1, SQLITE_TRANSIENT);
        } else {
            br = sqlite3_bind_null(stmt, i + 1);
        }
        if (br != SQLITE_OK) {
            db->last_error = Amalgame_SQLite_strdup_err(sqlite3_errmsg(db->handle));
            sqlite3_finalize(stmt);
            return NULL;
        }
    }
    return stmt;
}

/* Run a no-result SQL statement with `?` placeholders bound from
 * `params`. Same return semantics as `Exec`. Use for parameterised
 * INSERT / UPDATE / DELETE — defends against SQL injection without
 * the caller having to escape inputs by hand. */
static inline code_bool Amalgame_Database_SQLite_ExecBind(
    AmalgameSQLite* db, code_string sql, AmalgameList* params)
{
    if (!db || !db->handle) return 0;
    sqlite3_stmt* stmt = Amalgame_SQLite_prepare_bound(db, sql, params);
    if (!stmt) return 0;
    int rc = sqlite3_step(stmt);
    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
        db->last_error = Amalgame_SQLite_strdup_err(sqlite3_errmsg(db->handle));
        sqlite3_finalize(stmt);
        return 0;
    }
    sqlite3_finalize(stmt);
    return 1;
}

/* Run a SELECT (or any row-returning statement) with `?` placeholders
 * bound from `params`. Same `List<List<string>>` shape as `QueryAll`
 * — NULL columns become empty strings, every value goes through
 * sqlite3_column_text. Returns an empty list on error; check
 * `db.LastError()` to distinguish failure from a real empty result. */
static inline AmalgameList* Amalgame_Database_SQLite_QueryBindAll(
    AmalgameSQLite* db, code_string sql, AmalgameList* params)
{
    AmalgameList* rows = AmalgameList_new();
    if (!db || !db->handle) return rows;
    sqlite3_stmt* stmt = Amalgame_SQLite_prepare_bound(db, sql, params);
    if (!stmt) return rows;
    int ncols = sqlite3_column_count(stmt);
    int rc;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        AmalgameList* row = AmalgameList_new();
        for (int i = 0; i < ncols; i++) {
            const unsigned char* t = sqlite3_column_text(stmt, i);
            const char* s = t ? (const char*) t : "";
            size_t n = strlen(s);
            char* copy = (char*) code_alloc(n + 1);
            memcpy(copy, s, n + 1);
            AmalgameList_add(row, (void*) copy);
        }
        AmalgameList_add(rows, (void*) row);
    }
    if (rc != SQLITE_DONE) {
        db->last_error = Amalgame_SQLite_strdup_err(sqlite3_errmsg(db->handle));
    }
    sqlite3_finalize(stmt);
    return rows;
}

/* Begin a transaction. Returns true on success, false if a
 * transaction is already active (SQLite refuses nested BEGIN).
 * Pairs with Commit / Rollback. */
static inline code_bool Amalgame_Database_SQLite_Begin(AmalgameSQLite* db) {
    return Amalgame_Database_SQLite_Exec(db, "BEGIN");
}

/* Commit the current transaction. Returns true on success; false
 * (with db.LastError populated) if no transaction is active or
 * the commit hits a constraint that survived to flush time. */
static inline code_bool Amalgame_Database_SQLite_Commit(AmalgameSQLite* db) {
    return Amalgame_Database_SQLite_Exec(db, "COMMIT");
}

/* Roll back the current transaction. Returns true on success;
 * false (with LastError populated) if no transaction is active. */
static inline code_bool Amalgame_Database_SQLite_Rollback(AmalgameSQLite* db) {
    return Amalgame_Database_SQLite_Exec(db, "ROLLBACK");
}

#endif /* AMALGAME_DATABASE_SQLITE_H */
