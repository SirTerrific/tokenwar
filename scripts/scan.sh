#!/usr/bin/env bash
# tokenwar scan — thin wrapper around the structured scanner in scan.mjs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

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
exec node "${SCRIPT_DIR}/scan.mjs" "$@"
