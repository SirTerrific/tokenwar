#!/usr/bin/env bash
# tokenwar scan — thin wrapper around the structured scanner in scan.mjs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=lib/osdetect.sh
source "${SCRIPT_DIR}/lib/osdetect.sh"

# SSH noninteractive sessions omit the user's CLI install directories on Ora.
# Include them so status.sh sees the same tools as an interactive agent shell.
if [[ -n "${HOME:-}" ]]; then
    export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
fi

command -v node >/dev/null 2>&1 || {
    printf 'tokenwar scan: node is required (v18+).\n' >&2
    exit 127
}

export TOKENWAR_STATUS_SCRIPT="${TOKENWAR_STATUS_SCRIPT:-${SCRIPT_DIR}/status.sh}"
# scan.mjs reads these paths with node; see tw_export_node_paths.
tw_export_node_paths TOKENWAR_CLAUDE_LOG_ROOT TOKENWAR_CODEX_LOG_ROOT TOKENWAR_GEMINI_LOG_ROOT     TOKENWAR_COPILOT_LOG_ROOT TOKENWAR_OPENCODE_LOG_ROOT TOKENWAR_SKILLS_DIR     TOKENWAR_PLUGIN_CACHE_DIR TOKENWAR_MCP_CONFIG TOKENWAR_STATUS_SCRIPT
# node is a native Windows binary and cannot open an MSYS path (/c/Users/...).
# MSYS rewrites such arguments on its own, unless MSYS_NO_PATHCONV switched that
# off, so convert the path-valued options explicitly.
args=()
prev=""
for arg in "$@"; do
    case "$prev" in
        --html|--history) [[ "$arg" == --* ]] || arg="$(tw_node_path "$arg")" ;;
    esac
    args+=("$arg")
    prev="$arg"
done

exec node "$(tw_node_path "${SCRIPT_DIR}/scan.mjs")" ${args[@]+"${args[@]}"}
