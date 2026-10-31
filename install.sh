#!/usr/bin/env bash
#
# Link this folder into the places Claude Code reads from, then print the
# settings.json entries that point at the links.
#
#   ./install.sh [--dry-run]
#
# Idempotent: run it on a new machine and after any file is renamed. Targets
# go under $CLAUDE_CONFIG_DIR (default ~/.claude).
#
# A target that is already a link is relinked. A regular file is replaced
# only when it is identical to the source here. Anything else is left alone
# and reported, so nothing is overwritten unseen.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
dry_run=0

for arg in "$@"; do
    case "$arg" in
    --dry-run)
        dry_run=1
        ;;
    -h | --help)
        # The help is this file's header comment: everything after the
        # shebang, up to the first line that is not a comment.
        awk 'NR == 1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); if (!seen && $0 == "") next; seen = 1; print; next } { exit }' "$0"
        exit 0
        ;;
    *)
        echo "unknown argument: $arg" >&2
        exit 2
        ;;
    esac
done

# link SRC DST: make DST a symlink to SRC.
link() {
    local src="$1" dst="$2"
    if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
        echo "ok       $dst"
        return 0
    fi
    if [ -L "$dst" ]; then
        echo "relink   $dst (was $(readlink "$dst"))"
        if [ "$dry_run" -eq 0 ]; then
            rm -f "$dst"
        fi
    elif [ -e "$dst" ]; then
        if ! cmp -s "$src" "$dst"; then
            echo "skip     $dst differs from $src; merge by hand, then rerun" >&2
            return 1
        fi
        echo "replace  $dst (identical copy becomes a link)"
        if [ "$dry_run" -eq 0 ]; then
            rm -f "$dst"
        fi
    else
        echo "link     $dst"
    fi
    if [ "$dry_run" -eq 0 ]; then
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
    fi
}

status=0
link "$here/CLAUDE.md" "$claude_dir/CLAUDE.md" || status=1
link "$here/statusline.sh" "$claude_dir/statusline-command.sh" || status=1
link "$here/subagent-statusline.sh" "$claude_dir/subagent-statusline.sh" || status=1

cat <<SETTINGS

settings.json in $claude_dir:
  "statusLine": {
    "type": "command",
    "command": "bash $claude_dir/statusline-command.sh",
    "refreshInterval": 2
  },
  "subagentStatusLine": {
    "type": "command",
    "command": "bash $claude_dir/subagent-statusline.sh"
  }
SETTINGS
exit "$status"
