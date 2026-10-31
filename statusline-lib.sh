# shellcheck shell=bash
#
# Helpers shared by statusline.sh and subagent-statusline.sh. Sourced, not
# run. Pure bash: each helper sets one global instead of forking a subshell.
#
# Widths are terminal columns: East Asian wide characters count two,
# combining marks none.

_pct_color() { # 0-100 -> _c  (green calm, yellow watch, red act)
    if [ "$1" -ge 80 ]; then
        _c="$RED"
    elif [ "$1" -ge 50 ]; then
        _c="$YELLOW"
    else
        _c="$GREEN"
    fi
}

_format_tokens() { # 639600 -> 639.6k, 1000000 -> 1M -> _fmt
    local n="${1%.*}" tenths
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        _fmt="$1"
        return
    fi
    if [ "$n" -ge 1000000 ]; then
        tenths=$((n / 100000))
        _fmt="$((tenths / 10)).$((tenths % 10))M"
    elif [ "$n" -ge 1000 ]; then
        tenths=$((n / 100))
        _fmt="$((tenths / 10)).$((tenths % 10))k"
    else
        _fmt="$n"
    fi
    _fmt="${_fmt/.0M/M}"
    _fmt="${_fmt/.0k/k}"
}

_char_width() { # one character -> _cw  (0, 1 or 2 terminal columns)
    local cp
    printf -v cp '%d' "'$1"
    if ((cp >= 0x300 && cp <= 0x36F)) || ((cp >= 0x200B && cp <= 0x200F)); then
        _cw=0
    elif ((cp >= 0x1100 && cp <= 0x115F)) || ((cp >= 0x2E80 && cp <= 0xA4CF)) ||
        ((cp >= 0xAC00 && cp <= 0xD7A3)) || ((cp >= 0xF900 && cp <= 0xFAFF)) ||
        ((cp >= 0xFE30 && cp <= 0xFE4F)) || ((cp >= 0xFF00 && cp <= 0xFF60)) ||
        ((cp >= 0xFFE0 && cp <= 0xFFE6)) || ((cp >= 0x1F300 && cp <= 0x1F64F)) ||
        ((cp >= 0x1F900 && cp <= 0x1F9FF)); then
        _cw=2
    else
        _cw=1
    fi
}

_visible_len() { # string with ANSI colour escapes -> _vlen (terminal columns)
    local s="$1"
    _vlen=0
    while [[ "$s" ]]; do
        if [[ "$s" == $'\033'* ]]; then
            s="${s#*m}"
            continue
        fi
        _char_width "${s:0:1}"
        _vlen=$((_vlen + _cw))
        s="${s:1}"
    done
}

_cut() { # plain string, max columns -> _cut  (keeps the start; ends with … when cut)
    local s="$1" max="$2" i=0 total=0
    _visible_len "$s"
    if [ "$_vlen" -le "$max" ]; then
        _cut="$s"
        return
    fi
    while [ "$i" -lt "${#s}" ]; do
        _char_width "${s:$i:1}"
        if [ $((total + _cw)) -gt $((max - 1)) ]; then
            break
        fi
        total=$((total + _cw))
        i=$((i + 1))
    done
    _cut="${s:0:$i}…"
}
