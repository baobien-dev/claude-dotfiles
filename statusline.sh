#!/usr/bin/env bash
#
# Claude Code status line.
#
# A boxed card rendered from the JSON Claude Code writes to stdin, so every
# number matches the built-in footer and /context. Two values come from
# outside that JSON, each behind a short cache so a busy session never waits
# on them: the git state of the current directory, and the plan tier from
# Claude Code's account file.
#
# Widths are terminal columns, by the Unicode table in statusline-lib.sh:
# wide characters count two, combining and format characters none. The
# directory row is cut to the terminal width; the other rows are as wide as
# their content, so a terminal narrower than the widest row wraps the card.
#
# Field schema: https://code.claude.com/docs/en/statusline

# -u only: most probes below are allowed to fail, and show an empty value.
set -u
# ${#var} must count characters, not bytes, for the box to line up, and printf
# must parse "22.8" with a dot. Scoped to this process only.
export LC_ALL=C.UTF-8

# The helpers live beside this file's real path, so the link in the config
# directory finds them.
# shellcheck source=statusline-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/statusline-lib.sh"

input=$(cat)
NOW=$(date +%s)
CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}" # per-user 0700 where XDG exists

RST=$'\033[0m' BOLD=$'\033[1m' DIM=$'\033[2m'
RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m'
MAGENTA=$'\033[35m' CYAN=$'\033[36m' WHITE=$'\033[97m' GRAY=$'\033[90m'
ORANGE=$'\033[1;38;2;255;140;0m'

# ------------------------------------------------------------------ input --
# Declared up front so nothing is ever unset; one jq pass fills them. @sh
# quotes every value, so a path or a session name cannot inject into the eval.
model="Claude" cur_dir="" session_id="" session_name="" version=""
used_pct="" used_tokens="" context_size=""
cost_usd="" duration_ms="" lines_add="" lines_del=""
rl_5h="" rl_5h_reset="" rl_7d="" rl_7d_reset=""
spend_pct="" spend_used="" spend_limit=""
effort="" fast_mode="" vim_mode="" agent_name=""
pr_number="" pr_state="" worktree=""
cache_warm="" cache_hit="" cache_ttl="" cache_expires=""
eval "$(jq -r '
  def s: (. // "" | tostring | @sh);
  def b: (if . == null then "" else tostring end | @sh);
  "model="        + (.model.display_name // "Claude" | @sh),
  "cur_dir="      + (.workspace.current_dir // .cwd | s),
  "session_id="   + (.session_id | s),
  "session_name=" + (.session_name | s),
  "version="      + (.version | s),
  "used_pct="     + (.context_window.used_percentage | s),
  "used_tokens="  + (.context_window.total_input_tokens | s),
  "context_size=" + (.context_window.context_window_size | s),
  "cost_usd="     + (.cost.total_cost_usd | s),
  "duration_ms="  + (.cost.total_duration_ms | s),
  "lines_add="    + (.cost.total_lines_added | s),
  "lines_del="    + (.cost.total_lines_removed | s),
  "rl_5h="        + (.rate_limits.five_hour.used_percentage | s),
  "rl_5h_reset="  + (.rate_limits.five_hour.resets_at | s),
  "rl_7d="        + (.rate_limits.seven_day.used_percentage | s),
  "rl_7d_reset="  + (.rate_limits.seven_day.resets_at | s),
  "spend_pct="    + (.rate_limits.spend_limit.used_percentage | s),
  "spend_used="   + (.rate_limits.spend_limit.used_usd | s),
  "spend_limit="  + (.rate_limits.spend_limit.limit_usd | s),
  "effort="       + (.effort.level | s),
  "fast_mode="    + (.fast_mode | b),
  "vim_mode="     + (.vim.mode | s),
  "agent_name="   + (.agent.name | s),
  "pr_number="    + (.pr.number | s),
  "pr_state="     + (.pr.review_state | s),
  "worktree="     + (.workspace.git_worktree // .worktree.name | s),
  "cache_warm="   + (.prompt_cache.warm | b),
  "cache_hit="    + (.prompt_cache.hit_ratio | s),
  "cache_ttl="    + (.prompt_cache.ttl | s),
  "cache_expires=" + (.prompt_cache.expires_at | s)
' <<<"$input" 2>/dev/null)" 2>/dev/null
: "${model:=Claude}"

# ---------------------------------------------------------------- helpers --
# Pure bash. Each sets one global instead of forking a subshell.

_repeat() { # char count -> _rep
    local count="$2"
    if [ "$count" -lt 0 ]; then
        count=0
    fi
    printf -v _rep '%*s' "$count" ''
    _rep="${_rep// /$1}"
}

_build_bar() { # pct width colour -> _bar
    local filled=$(($1 * $2 / 100))
    _repeat "█" "$filled"
    _bar="${DIM}[${RST}${3}${_rep}${GRAY}"
    _repeat "░" "$(($2 - filled))"
    _bar+="${_rep}${DIM}]${RST}"
}

_time_until() { # epoch -> "2h13m" | "9m" | "3d" | "now" | "" -> _time
    local reset="${1%.*}" diff
    _time=""
    if ! [[ "$reset" =~ ^[0-9]+$ ]]; then
        return
    fi
    diff=$((reset - NOW))
    if [ "$diff" -le 0 ]; then
        _time="now"
    elif [ "$diff" -ge 86400 ]; then
        _time="$((diff / 86400))d"
    elif [ "$diff" -ge 3600 ]; then
        _time="$((diff / 3600))h$(((diff % 3600) / 60))m"
    else
        _time="$((diff / 60))m"
    fi
}

_format_duration() { # ms -> "1h30m" | "12m" | "45s" | "" -> _dur
    local ms="${1%.*}" s
    _dur=""
    if ! [[ "$ms" =~ ^[0-9]+$ ]]; then
        return
    fi
    s=$((ms / 1000))
    if [ "$s" -ge 3600 ]; then
        _dur="$((s / 3600))h$(((s % 3600) / 60))m"
    elif [ "$s" -ge 60 ]; then
        _dur="$((s / 60))m"
    else
        _dur="${s}s"
    fi
}

_cut_tail() { # plain string, max columns -> _cut  (keeps the end; starts with … when cut)
    local s="$1" max="$2" i total=0
    _visible_len "$s"
    if [ "$_vlen" -le "$max" ]; then
        _cut="$s"
        return
    fi
    i=${#s}
    while [ "$i" -gt 0 ]; do
        _char_width "${s:$((i - 1)):1}"
        if [ $((total + _cw)) -gt $((max - 1)) ]; then
            break
        fi
        total=$((total + _cw))
        i=$((i - 1))
    done
    _cut="…${s:$i}"
}

_shorten_path() { # path budget -> _path  (keeps the tail, cut on a slash)
    local tail
    _cut_tail "$1" "$2"
    if [ "$_cut" = "$1" ]; then
        _path="$1"
        return
    fi
    tail="${_cut#…}"
    if [[ "$tail" != /* && "$tail" == */* ]]; then
        tail="/${tail#*/}"
    fi
    _path="…${tail}"
}

_lead() { # colour label -> _lead  (the first ten columns of a row)
    printf -v _lead ' %s%s%-8s%s ' "$1" "$BOLD" "$2" "$RST"
}

seg=""
_piece() { # text -> appends to seg behind a separator
    if [ -n "$seg" ]; then
        seg+="  ${DIM}·${RST}  "
    fi
    seg+="$1"
}

# ------------------------------------------------------------------- git ---
# One probe per 5 s per session. The cache records the directory it describes,
# so a cd mid-session invalidates it. Each git call is bounded by `timeout`
# where that exists, so a huge or network-mounted repo cannot stall the line.
_git() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 1 git -C "$cur_dir" "$@"
    else
        git -C "$cur_dir" "$@"
    fi
}

_probe_git() { # fills g_branch g_staged g_modified g_ahead g_behind
    g_branch="" g_staged=0 g_modified=0 g_ahead=0 g_behind=0
    if ! g_branch=$(_git symbolic-ref --short -q HEAD 2>/dev/null); then
        g_branch=$(_git rev-parse --short HEAD 2>/dev/null) || g_branch=""
    fi
    if [ -z "$g_branch" ]; then
        return
    fi
    g_staged=$(_git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    g_modified=$(_git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    read -r g_behind g_ahead < <(_git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null) || true
}

g_dir="" g_branch="" g_staged=0 g_modified=0 g_ahead=0 g_behind=0
if [ -n "$cur_dir" ] && [ -d "$cur_dir" ]; then
    git_cache="$CACHE_DIR/claude_statusline_git_${UID}_${session_id:-nosession}"
    fresh=0
    if [ -f "$git_cache" ]; then
        cache_mtime=$(stat -c %Y "$git_cache" 2>/dev/null || stat -f %m "$git_cache" 2>/dev/null || echo 0)
        if [ $((NOW - cache_mtime)) -lt 5 ]; then
            IFS='|' read -r g_dir g_branch g_staged g_modified g_ahead g_behind <"$git_cache"
            if [ "$g_dir" = "$cur_dir" ]; then
                fresh=1
            fi
        fi
    fi
    if [ "$fresh" -eq 0 ]; then
        _probe_git
        printf '%s|%s|%s|%s|%s|%s' "$cur_dir" "$g_branch" "${g_staged:-0}" "${g_modified:-0}" "${g_ahead:-0}" "${g_behind:-0}" >"$git_cache" 2>/dev/null || true
    fi
fi
for counter in g_staged g_modified g_ahead g_behind; do
    if ! [[ "${!counter}" =~ ^[0-9]+$ ]]; then
        printf -v "$counter" 0
    fi
done

# ------------------------------------------------------------- plan tier ---
# Read from Claude Code's own account record, so it tracks the live plan.
# CLAUDE_CONFIG_DIR moves that file for a second account, so resolve it per
# instance and key the cache to it. 5 min TTL: the tier almost never changes
# but the file churns constantly. A tier the table below doesn't name shows
# no badge, and that empty answer is cached like any other.
acct="${HOME:-}/.claude.json"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/.claude.json" ]; then
    acct="$CLAUDE_CONFIG_DIR/.claude.json"
fi
tier_cache="$CACHE_DIR/claude_statusline_tier_${UID}_${acct//\//_}"
tier_text="" tier_fresh=0
if [ -f "$tier_cache" ]; then
    cache_mtime=$(stat -c %Y "$tier_cache" 2>/dev/null || stat -f %m "$tier_cache" 2>/dev/null || echo 0)
    if [ $((NOW - cache_mtime)) -lt 300 ]; then
        IFS= read -r tier_text <"$tier_cache"
        tier_fresh=1
    fi
fi
if [ "$tier_fresh" -eq 0 ]; then
    tier=$(jq -r '.oauthAccount.organizationRateLimitTier // .oauthAccount.userRateLimitTier // ""' "$acct" 2>/dev/null)
    case "$tier" in
    *max_20x*) tier_text="Max 20x" ;;
    *max_5x*) tier_text="Max 5x" ;;
    *pro*) tier_text="Pro" ;;
    *free*) tier_text="Free" ;;
    *team*) tier_text="Team" ;;
    *enterprise*) tier_text="Enterprise" ;;
    esac
    printf '%s' "$tier_text" >"$tier_cache" 2>/dev/null || true
fi

# ---------------------------------------------------------------- header ---
# Effort levels differ by model. Known ones get a colour; anything else that
# is non-empty is shown as-is rather than hidden.
case "$effort" in
max | ultracode) effort_styled="${BOLD}${RED}${effort}${RST}" ;;
xhigh) effort_styled="${BOLD}${MAGENTA}xhigh${RST}" ;;
high) effort_styled="${ORANGE}high${RST}" ;;
medium) effort_styled="${BOLD}${YELLOW}medium${RST}" ;;
low) effort_styled="${BOLD}${GREEN}low${RST}" ;;
"") effort_styled="" ;;
*) effort_styled="${BOLD}${CYAN}${effort}${RST}" ;;
esac

badges=""
_badge() { # text -> appends to badges behind a dot
    if [ -z "$1" ]; then
        return
    fi
    if [ -n "$badges" ]; then
        badges+=" ${DIM}·${RST} "
    fi
    badges+="$1"
}
_badge "$effort_styled"
[ "$fast_mode" = "true" ] && _badge "${YELLOW}fast${RST}"
[ -n "$vim_mode" ] && _badge "${CYAN}${vim_mode}${RST}"
[ -n "$agent_name" ] && _badge "${MAGENTA}⚙ ${agent_name}${RST}"
[ -n "$tier_text" ] && _badge "${GREEN}${tier_text}${RST}"
hdr_left="${BOLD}${WHITE}${model}${RST}"
hdr_right="$badges"

ftr_right=""
[ -n "$version" ] && ftr_right="${DIM}v${version}${RST}"

# ------------------------------------------------------------------ rows ---
# Claude Code sets COLUMNS to the terminal width before running the script.
# The directory is the only row of unbounded length, so it gets whatever
# width is left after the borders, the UI's own margin, and the git segment.
cap=96
if [[ "${COLUMNS:-}" =~ ^[0-9]+$ ]] && [ "$COLUMNS" -gt 50 ]; then
    cap=$((COLUMNS - 6))
fi

# cwd: directory, then the branch with its state, then an open PR.
git_seg=""
_git_count() { # count colour symbol -> appends " <symbol><count>" when count > 0
    if [ "$1" -gt 0 ]; then
        git_seg+=" ${2}${3}${1}${RST}"
    fi
}
if [ -n "$g_branch" ]; then
    _cut "$g_branch" 24
    git_seg="  ${MAGENTA}⎇ ${_cut}${RST}"
    _git_count "$g_staged" "$GREEN" "+"
    _git_count "$g_modified" "$YELLOW" "~"
    _git_count "$g_ahead" "$CYAN" "↑"
    _git_count "$g_behind" "$CYAN" "↓"
    [ -n "$worktree" ] && git_seg+=" ${DIM}⌂ ${worktree}${RST}"
fi
if [ -n "$pr_number" ]; then
    case "$pr_state" in
    approved) pr_color="$GREEN" ;;
    changes_requested) pr_color="$RED" ;;
    draft) pr_color="$GRAY" ;;
    *) pr_color="$YELLOW" ;;
    esac
    git_seg+="  ${pr_color}PR#${pr_number}${RST}"
fi
_visible_len "$git_seg"
tilde='~'
disp_dir="${cur_dir/#"${HOME:-/nonexistent}"/$tilde}"
[ -z "$disp_dir" ] && disp_dir="?"
_shorten_path "$disp_dir" "$((cap - 10 - _vlen))"
_lead "$BLUE" cwd
row_cwd="${_lead}${WHITE}${_path}${RST}${git_seg}"

# context: exact token count when present, derived from the percentage otherwise.
_lead "$CYAN" context
if [[ "$used_pct" =~ ^[0-9.]+$ ]] && [[ "$context_size" =~ ^[0-9]+$ ]]; then
    printf -v used_int '%.0f' "$used_pct" 2>/dev/null || used_int=0
    _pct_color "$used_int"
    _build_bar "$used_int" 12 "$_c"
    [[ "$used_tokens" =~ ^[0-9]+$ ]] || used_tokens=$((used_int * context_size / 100))
    _format_tokens "$used_tokens"
    used_fmt="$_fmt"
    _format_tokens "$context_size"
    printf -v row_context '%s%s %s%3d%%%s  %s%s%s/%s%s' \
        "$_lead" "$_bar" "$_c" "$used_int" "$RST" "$WHITE" "$used_fmt" "$GRAY" "$_fmt" "$RST"
else
    row_context="${_lead} ${GRAY}—${RST}"
fi

# limits: subscription windows and, behind a gateway, the spend limit. Only
# present after the first API response, so the row is dropped until then.
_window() { # label pct reset -> one limits piece
    local pct piece
    printf -v pct '%.0f' "$2" 2>/dev/null || pct=0
    _pct_color "$pct"
    _time_until "$3"
    printf -v piece '%s%s%s %s%2d%%%s' "$GRAY" "$1" "$RST" "$_c" "$pct" "$RST"
    [ -n "$_time" ] && piece+=" ${DIM}⟳${_time}${RST}"
    _piece "$piece"
}
seg=""
[ -n "$rl_5h" ] && _window 5h "$rl_5h" "$rl_5h_reset"
[ -n "$rl_7d" ] && _window 7d "$rl_7d" "$rl_7d_reset"
if [ -n "$spend_pct" ]; then
    printf -v pct '%.0f' "$spend_pct" 2>/dev/null || pct=0
    _pct_color "$pct"
    if [[ "$spend_used" =~ ^[0-9.]+$ ]] && [[ "$spend_limit" =~ ^[0-9.]+$ ]]; then
        printf -v piece '%sspend%s %s$%.0f%s%s/$%.0f%s' "$GRAY" "$RST" "$_c" "$spend_used" "$RST" "$GRAY" "$spend_limit" "$RST"
    else
        printf -v piece '%sspend%s %s%d%%%s' "$GRAY" "$RST" "$_c" "$pct" "$RST"
    fi
    _piece "$piece"
fi
row_limits=""
if [ -n "$seg" ]; then
    _lead "$MAGENTA" limits
    row_limits="${_lead}${seg}"
fi

# session: cost (an estimate at list price on a subscription, hence "est"),
# wall-clock time, lines changed, and the prompt cache: its TTL, hit rate,
# warm or cold, and how long until the warm prefix expires.
seg=""
cost_fmt="\$0.00"
if [ -n "$cost_usd" ]; then
    printf -v cost_fmt "\$%.2f" "$cost_usd" 2>/dev/null || cost_fmt="\$0.00"
fi
_piece "${WHITE}${cost_fmt}${RST} ${DIM}est${RST}"
_format_duration "$duration_ms"
[ -n "$_dur" ] && _piece "${WHITE}${_dur}${RST}"
added="${lines_add%.*}" removed="${lines_del%.*}"
[[ "$added" =~ ^[0-9]+$ ]] || added=0
[[ "$removed" =~ ^[0-9]+$ ]] || removed=0
if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
    _piece "${GREEN}+${added}${RST} ${RED}-${removed}${RST}"
fi
if [[ "$cache_hit" =~ ^[0-9.]+$ ]]; then
    printf -v hit_pct '%.0f' "${cache_hit}e2" 2>/dev/null || hit_pct=0 # ratio -> percent, no fork
    piece="${GRAY}cache${cache_ttl:+ $cache_ttl}${RST} ${WHITE}${hit_pct}%${RST}"
    if [ "$cache_warm" = "true" ]; then
        piece+=" ${GREEN}warm${RST}"
        _time_until "$cache_expires"
        [ -n "$_time" ] && piece+=" ${DIM}⟳${_time}${RST}"
    else
        piece+=" ${GRAY}cold${RST}"
    fi
    _piece "$piece"
fi
_lead "$GREEN" session
row_session="${_lead}${seg}"

# ---------------------------------------------------------------- render ---
rows=("$row_cwd" "$row_context")
[ -n "$row_limits" ] && rows+=("$row_limits")
rows+=("$row_session")

_frame_min() { # left right -> _min  (columns the frame text needs, plus one dash)
    local left=0 right=0
    if [ -n "$1" ]; then
        _visible_len "$1"
        left=$((_vlen + 2))
    fi
    if [ -n "$2" ]; then
        _visible_len "$2"
        right=$((_vlen + 2))
    fi
    _min=$((left + right + 1))
}

inner_w=44
_frame_min "$hdr_left" "$hdr_right"
[ "$_min" -gt "$inner_w" ] && inner_w="$_min"
_frame_min "" "$ftr_right"
[ "$_min" -gt "$inner_w" ] && inner_w="$_min"
for row in "${rows[@]}"; do # plus one column, so the widest row never touches the border
    _visible_len "$row"
    [ $((_vlen + 1)) -gt "$inner_w" ] && inner_w=$((_vlen + 1))
done

# The session name takes whatever width the card already has and never
# widens it: the inner width, minus the version with its dash, minus the two
# spaces around the name.
ftr_left=""
if [ -n "$session_name" ]; then
    _frame_min "" "$ftr_right"
    budget=$((inner_w - _min - 2))
    if [ "$budget" -ge 4 ]; then
        _cut "$session_name" "$budget"
        ftr_left="${DIM}${_cut}${RST}"
    fi
fi

_frame() { # left-corner right-corner left-text right-text
    local left="" right=""
    [ -n "$3" ] && left=" $3 "
    [ -n "$4" ] && right=" $4 "
    _visible_len "$left$right"
    _repeat "─" "$((inner_w - _vlen))"
    printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$DIM" "$1" "$RST" "$left" "$DIM" "$_rep" "$RST" "$right" "$DIM" "$2" "$RST"
}

_row() { # text -> one padded line between the side borders
    local pad
    _visible_len "$1"
    pad=$((inner_w - _vlen))
    [ "$pad" -lt 0 ] && pad=0
    printf '%s│%s%s%*s%s│%s\n' "$DIM" "$RST" "$1" "$pad" '' "$DIM" "$RST"
}

_frame "┌" "┐" "$hdr_left" "$hdr_right"
for row in "${rows[@]}"; do
    _row "$row"
done
_frame "└" "┘" "$ftr_left" "$ftr_right"
