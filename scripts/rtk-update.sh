#!/usr/bin/env bash
# rtk-update.sh — install or update the RTK binary to its latest release.
#
# One implementation, used by `install.sh --with-rtk` and `tokenwar upgrade`.
#
#   Linux / macOS — rtk's official installer, from its default branch. It
#                   resolves the latest GitHub release itself.
#   Windows       — that installer refuses anything but Linux and Darwin, so
#                   this downloads the release's windows-msvc zip, checks it
#                   against the sha256 digest GitHub publishes for the asset,
#                   and replaces rtk.exe in place.
#
# Only an rtk that lives in ~/.local/bin (where both paths install it) is
# managed. One installed elsewhere — Homebrew, `cargo install` — belongs to that
# package manager, and replacing its binary behind its back would desync it.
#
# Usage: rtk-update.sh
# Exit:  0 updated, already current, or skipped on purpose; 1 on failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/osdetect.sh
source "${SCRIPT_DIR}/lib/osdetect.sh"

readonly RTK_BIN="rtk"
readonly RTK_LOCAL_BIN="${HOME}/.local/bin"
# Overridable so tests never touch the network.
readonly RTK_INSTALL_URL="${TW_RTK_INSTALL_URL:-https://raw.githubusercontent.com/rtk-ai/rtk/master/install.sh}"
readonly RTK_RELEASE_URL="${TW_RTK_RELEASE_URL:-https://api.github.com/repos/rtk-ai/rtk/releases/latest}"
readonly RTK_HTTP_TIMEOUT_SECS=60

say()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }

command -v curl >/dev/null 2>&1 || { warn "curl not found — cannot fetch RTK"; exit 1; }

# Where the managed binary lives, and whether an existing one is ours to touch.
current="$(command -v "$RTK_BIN" 2>/dev/null || true)"
if [[ -n "$current" && "$(cd "$(dirname "$current")" && pwd)" != "$(mkdir -p "$RTK_LOCAL_BIN" && cd "$RTK_LOCAL_BIN" && pwd)" ]]; then
    warn "rtk at $current was not installed into $RTK_LOCAL_BIN — update it with the tool that installed it"
    exit 0
fi
mkdir -p "$RTK_LOCAL_BIN" || { warn "cannot create $RTK_LOCAL_BIN"; exit 1; }

if ! tw_is_windows; then
    say "Installing the latest RTK via its official installer"
    curl -fsSL --max-time "$RTK_HTTP_TIMEOUT_SECS" "$RTK_INSTALL_URL" \
        | RTK_INSTALL_DIR="$RTK_LOCAL_BIN" sh || { warn "rtk installer failed — see https://github.com/rtk-ai/rtk"; exit 1; }
    exit 0
fi

# ── Windows ─────────────────────────────────────────────────────────
case "$(uname -m)" in
    x86_64|amd64)  arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) warn "unsupported architecture for RTK on Windows: $(uname -m)"; exit 1 ;;
esac
asset_name="rtk-${arch}-pc-windows-msvc.zip"

# "<tag>|<download url>|<sha256>" for our asset, from the latest release.
release="$(curl -fsSL --max-time "$RTK_HTTP_TIMEOUT_SECS" "$RTK_RELEASE_URL" 2>/dev/null \
    | ASSET="$asset_name" node -e '
        let s = "";
        process.stdin.on("data", d => s += d).on("end", () => {
            let r; try { r = JSON.parse(s); } catch { return; }
            const a = (r.assets || []).find(x => x.name === process.env.ASSET);
            if (!a) return;
            const sha = String(a.digest || "").replace(/^sha256:/, "");
            process.stdout.write([r.tag_name || "", a.browser_download_url || "", sha].join("|"));
        });
    ' 2>/dev/null)"
IFS='|' read -r tag url sha <<<"$release"
if [[ -z "${tag:-}" || -z "${url:-}" ]]; then
    warn "could not find $asset_name in the latest RTK release ($RTK_RELEASE_URL)"; exit 1
fi
# Refuse an unverifiable binary: it ends up on PATH and runs on every Bash call.
if [[ ! "${sha:-}" =~ ^[0-9a-f]{64}$ ]]; then
    warn "RTK $tag publishes no sha256 digest for $asset_name — refusing to install an unverified binary"; exit 1
fi

work="$(mktemp -d)" || { warn "mktemp failed"; exit 1; }
trap 'rm -rf "$work"' EXIT

say "Downloading RTK $tag ($asset_name)"
# curl is a native binary here: hand it a path it can open even when
# MSYS_NO_PATHCONV=1 turns the implicit /tmp rewrite off.
curl -fsSL --max-time "$RTK_HTTP_TIMEOUT_SECS" -o "$(tw_node_path "$work/rtk.zip")" "$url" \
    || { warn "download failed: $url"; exit 1; }
actual="$(sha256sum "$work/rtk.zip" | awk '{print $1}')"
if [[ "$actual" != "$sha" ]]; then
    warn "sha256 mismatch for $asset_name (expected $sha, got $actual) — not installing"; exit 1
fi

# Path traversal guard (the same CWE-22 check rtk's own installer runs).
if unzip -Z1 "$work/rtk.zip" | grep -qE '^/|^[A-Za-z]:|(^|/)\.\.(/|$)'; then
    warn "archive contains unsafe paths — refusing to extract"; exit 1
fi
unzip -q -o "$work/rtk.zip" -d "$work/x" || { warn "could not extract $asset_name"; exit 1; }
new_exe="$(find "$work/x" -type f -name 'rtk.exe' | head -1)"
[[ -n "$new_exe" ]] || { warn "rtk.exe not found in $asset_name"; exit 1; }

target="${RTK_LOCAL_BIN}/rtk.exe"
# A running exe cannot be overwritten on Windows, but it can be renamed: move
# the old one aside first, so an rtk hook firing mid-update cannot block this.
if [[ -e "$target" ]]; then
    mv -f "$target" "${target}.old" || { warn "cannot move the current $target aside"; exit 1; }
fi
if ! cp "$new_exe" "$target"; then
    [[ -e "${target}.old" ]] && mv -f "${target}.old" "$target"
    warn "cannot write $target"; exit 1
fi
rm -f "${target}.old" 2>/dev/null || true

say "RTK $("$target" --version 2>/dev/null | tw_strip_cr | awk '{print $2}') installed at $target"
