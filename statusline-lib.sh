# shellcheck shell=bash
#
# Helpers shared by statusline.sh and subagent-statusline.sh. Sourced, not
# run. Pure bash: each helper sets one global instead of forking a subshell.
#
# Widths are terminal columns, by the rule of wcwidth(3): a character is 2
# columns when Unicode lists it as wide or fullwidth, 0 when it is a
# combining mark, a format character, or a conjoining Hangul jamo, and 1
# otherwise. The ranges come from width-table.sh, which gen-width-table.py
# writes from Python's Unicode data.

# shellcheck source=width-table.sh
source "$(dirname "${BASH_SOURCE[0]}")/width-table.sh"

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

_in_ranges() { # table-name code-point -> _in  (1 when the point is inside a range)
    local -n _table="$1"
    local cp="$2" lo=0 hi=$((${#_table[@]} / 2 - 1)) mid
    _in=0
    while ((lo <= hi)); do
        mid=$(((lo + hi) / 2))
        if ((cp < _table[mid * 2])); then
            hi=$((mid - 1))
        elif ((cp > _table[mid * 2 + 1])); then
            lo=$((mid + 1))
        else
            _in=1
            return
        fi
    done
}

_char_width() { # one character -> _cw  (0, 1 or 2 terminal columns)
    local cp
    printf -v cp '%d' "'$1"
    if ((cp < 0x300)); then # nothing below U+0300 is wide or zero width
        _cw=1
        return
    fi
    _in_ranges ZERO_RANGES "$cp"
    if ((_in)); then
        _cw=0
        return
    fi
    _in_ranges WIDE_RANGES "$cp"
    _cw=$((_in ? 2 : 1))
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
