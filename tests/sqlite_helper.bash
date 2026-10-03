#!/usr/bin/env bash
# Shared by the bats files that need a SQLite fixture: load sqlite_helper

# Build a SQLite fixture with whichever engine this host has, mirroring the
# reader's own python3-then-node fallback. Windows ships a python3 alias that
# only opens the Microsoft Store, so probing by running is the only reliable
# test; without this the SQLite telemetry tests would skip on every Windows box —
# exactly the platform the fallback exists for.
# Usage: make_sqlite_db <db-path> <schema+seed SQL>
make_sqlite_db() {
    local db="$1" sql="$2"
    # Both engines are native binaries on Windows: hand them a path they can open.
    db="$(cygpath -m "$db" 2>/dev/null || printf '%s' "$db")"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' >/dev/null 2>&1; then
        TW_DB="$db" TW_SQL="$sql" python3 -c '
import os, sqlite3
db = sqlite3.connect(os.environ["TW_DB"])
db.executescript(os.environ["TW_SQL"])
db.commit()
'
        return $?
    fi
    if command -v node >/dev/null 2>&1 && node -e 'require("node:sqlite")' >/dev/null 2>&1; then
        TW_DB="$db" TW_SQL="$sql" node -e '
const { DatabaseSync } = require("node:sqlite");
new DatabaseSync(process.env.TW_DB).exec(process.env.TW_SQL);
'
        return $?
    fi
    return 1
}
