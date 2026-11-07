#!/usr/bin/env bash
# tokenwar restore-settings — merge ~/.claude/settings.local.json INTO
# ~/.claude/settings.json. Run before `claude` if Claude Code wiped your
# settings on session start (known regression with new model migrations).
#
# Strategy: take the current settings.json (whatever Claude Code wrote),
# overlay every top-level key from settings.local.json. local.json wins.
# This preserves any new key Claude Code added (e.g. migration flags)
# while restoring our enabledPlugins / hooks / statusLine.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/osdetect.sh
source "${SCRIPT_DIR}/lib/osdetect.sh"

readonly CONFIG_DIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
readonly SETTINGS="${CONFIG_DIR}/settings.json"
readonly LOCAL="${CONFIG_DIR}/settings.local.json"
readonly BACKUP="${SETTINGS}.tokenwar-bak"

# Nothing to merge is not a failure: docs/operations.md chains this script
# before `claude` with &&, so a non-zero exit would stop Claude from starting.
if [[ ! -f "$LOCAL" ]]; then
    echo "[tokenwar restore] no settings.local.json at $LOCAL - nothing to merge" >&2
    exit 0
fi

if [[ ! -f "$SETTINGS" ]]; then
    echo "[tokenwar restore] settings.json missing — copying local as fresh"
    cp "$LOCAL" "$SETTINGS"
    chmod 600 "$SETTINGS"
    exit 0
fi

cp -f "$SETTINGS" "$BACKUP"

SETTINGS_PATH="$(tw_node_path "$SETTINGS")" LOCAL_PATH="$(tw_node_path "$LOCAL")" node --input-type=module -e '
    import { readFileSync, writeFileSync, renameSync } from "fs";
    const read = (p) => {
        try { return JSON.parse(readFileSync(p, "utf8")); }
        catch (e) { console.error("[tokenwar restore] " + p + " is not valid JSON, nothing changed: " + e.message); process.exit(1); }
    };
    const cur   = read(process.env.SETTINGS_PATH);
    const local = read(process.env.LOCAL_PATH);
    const merged = { ...cur, ...local };  // local wins on conflict
    // Write then rename, so a Claude Code starting in parallel never reads half a file.
    const tmp = process.env.SETTINGS_PATH + ".tokenwar-tmp";
    writeFileSync(tmp, JSON.stringify(merged, null, 2) + "\n", "utf8");
    renameSync(tmp, process.env.SETTINGS_PATH);
    const restored = Object.keys(local).filter(k => !(k in cur));
    console.log("[tokenwar restore] restored keys:", restored.length ? restored.join(", ") : "(all present, no-op)");
'
