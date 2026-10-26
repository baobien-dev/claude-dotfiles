#!/usr/bin/env bash
#
# Claude Code subagent status line.
#
# Claude Code runs this once per refresh tick with every subagent visible in
# the agent panel, as one JSON object on stdin. For each task it prints one
# JSON line back, {"id": ..., "content": ...}, and the panel shows that
# content in place of the default "name · description · tokens" row.
#
# A row: name and agent type, model and effort, context share as
# "21% 42.1k/200k", elapsed time, then what the subagent is doing now. The
# panel draws its own status marker in front of the row, so the row adds a
# status word only when the subagent failed or was killed. The step is cut to
# fit; if the fixed part alone overflows, effort, model, agent type, and time
# drop in that order.
#
# Widths are terminal columns: East Asian wide characters count two,
# combining marks none.
#
# The model comes from the subagent's own transcript when that file exists,
# because the panel's model field is fixed at spawn: after a model fallback
# the subagent runs on another model, and the row then shows
# "Opus 4.8 ← Fable 5.1".
#
# Field schema: https://code.claude.com/docs/en/statusline#subagent-status-lines

set -u
export LC_ALL=C.UTF-8

input=$(cat)

# Milliseconds since the epoch. %N is GNU; elsewhere fall back to seconds.
now_ns=$(date +%s%N 2>/dev/null)
if [[ "$now_ns" =~ ^[0-9]{13,}$ ]]; then
    now_ms=$((now_ns / 1000000))
else
    now_ms=$(($(date +%s) * 1000))
fi

RST=$'\033[0m' BOLD=$'\033[1m' DIM=$'\033[2m'
RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' CYAN=$'\033[36m'
WHITE=$'\033[97m' GRAY=$'\033[90m'

columns="" transcript_path=""
IFS=$'\x1f' read -r columns transcript_path < <(jq -r '[(.columns // 0), (.transcript_path // "")] | map(tostring) | join("\u001f")' <<<"$input" 2>/dev/null)
if ! [[ "$columns" =~ ^[0-9]+$ ]] || [ "$columns" -lt 20 ]; then
    columns=120
fi
# Subagent transcripts sit beside the session transcript, one file per task.
subagents_dir=""
if [ -n "$transcript_path" ]; then
    subagents_dir="${transcript_path%.jsonl}/subagents"
fi

# ---------------------------------------------------------------- helpers --

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

_format_tokens() { # 42100 -> 42.1k, 1000000 -> 1M -> _fmt
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

_pct_color() { # 0-100 -> _c  (green calm, yellow watch, red act)
    if [ "$1" -ge 80 ]; then
        _c="$RED"
    elif [ "$1" -ge 50 ]; then
        _c="$YELLOW"
    else
        _c="$GREEN"
    fi
}

_since() { # start in ms -> _elapsed  "45s" | "3m12s" | "1h02m" | ""
    local start="${1%.*}" s
    _elapsed=""
    if ! [[ "$start" =~ ^[0-9]+$ ]] || [ "$start" -eq 0 ]; then
        return
    fi
    s=$(((now_ms - start) / 1000))
    if [ "$s" -lt 0 ]; then
        s=0
    fi
    if [ "$s" -ge 3600 ]; then
        printf -v _elapsed '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
    elif [ "$s" -ge 60 ]; then
        printf -v _elapsed '%dm%02ds' $((s / 60)) $((s % 60))
    else
        _elapsed="${s}s"
    fi
}

_model_name() { # claude-opus-5-5 -> Opus 5.5, claude-haiku-5-5[1m] -> Haiku 5.5 1M -> _model
    local id="$1" family="" version="" suffix="" part
    local -a parts
    _model=""
    if [ -z "$id" ]; then
        return
    fi
    if [[ "$id" != *claude* ]]; then
        _model="$id"
        return
    fi
    id="${id%%@*}" # Vertex ids carry @date
    if [[ "$id" == *"[1m]"* ]]; then
        suffix=" 1M"
        id="${id//\[1m\]/}"
    fi
    IFS='-' read -ra parts <<<"${id#claude-}"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^[0-9]{1,2}$ ]]; then
            version+="${version:+.}$part"
        elif [ -z "$family" ] && [[ "$part" =~ ^[a-z]+$ ]] && [ "$part" != "claude" ]; then
            family="${part^}"
        fi
    done
    if [ -z "$family" ]; then
        _model="$1"
        return
    fi
    _model="${family}${version:+ $version}${suffix}"
}

_live_model() { # task id -> _live  (model of the subagent's last response, or "")
    local file="$subagents_dir/agent-$1.jsonl"
    _live=""
    if [ -z "$subagents_dir" ] || [ ! -r "$file" ]; then
        return
    fi
    _live=$(tail -n 40 "$file" 2>/dev/null |
        jq -r 'select(.type == "assistant" and .message.model != null and .message.model != "<synthetic>") | .message.model' 2>/dev/null |
        tail -n 1)
}

_compose() { # title pieces[] -> content, pieces joined by a dim dot
    local piece
    content="$title"
    for piece in ${pieces[@]+"${pieces[@]}"}; do
        [ -n "$piece" ] && content+=" ${DIM}·${RST} ${piece}"
    done
}

# ------------------------------------------------------------------- rows --
# One jq pass turns every task into one line, fields split by the ASCII unit
# separator: `read` never collapses it, so an empty field keeps its position.
# Tabs and newlines inside a field become spaces, so the line stays one line.
US=$'\x1f'

while IFS="$US" read -r id name agent_type status label start_ms model effort ctx_size tokens; do
    status_piece=""
    case "$status" in
    failed) status_piece="${RED}failed${RST}" ;;
    killed) status_piece="${GRAY}killed${RST}" ;;
    esac

    _cut "${name:-${agent_type:-agent}}" 24
    plain_name="$_cut"
    short_title="${BOLD}${WHITE}${plain_name}${RST}"
    title="$short_title"
    if [ -n "$name" ] && [ -n "$agent_type" ] && [ "$name" != "$agent_type" ]; then
        title+=" ${DIM}${agent_type}${RST}"
    fi

    # The model that answered last, when the transcript says so; it differs
    # from the spawn model after a model fallback.
    _live_model "$id"
    _model_name "$model"
    spawn_name="$_model"
    if [ -n "$_live" ]; then
        _model_name "$_live"
    fi
    model_piece=""
    model_plain=""
    if [ -n "$_model" ]; then
        model_plain="${CYAN}${_model}${RST}"
        model_piece="$model_plain"
        if [ -n "$spawn_name" ] && [ "$_model" != "$spawn_name" ]; then
            model_piece+=" ${DIM}← ${spawn_name}${RST}"
        fi
        model_piece+="${effort:+ ${DIM}${effort}${RST}}"
    fi

    _format_tokens "$tokens"
    ctx_piece="${WHITE}${_fmt}${RST}"
    if [[ "$ctx_size" =~ ^[0-9]+$ ]] && [ "$ctx_size" -gt 0 ] && [[ "$tokens" =~ ^[0-9]+$ ]]; then
        tokens_fmt="$_fmt"
        _format_tokens "$ctx_size"
        _pct_color "$((tokens * 100 / ctx_size))"
        ctx_piece="${_c}$((tokens * 100 / ctx_size))%${RST} ${GRAY}${tokens_fmt}/${_fmt}${RST}"
    fi

    _since "$start_ms"
    time_piece=""
    if [ -n "$_elapsed" ]; then
        time_piece="${WHITE}${_elapsed}${RST}"
    fi

    # Fit the panel: the model's decorations, then the model, then the agent
    # type, then the time go before giving up.
    pieces=("$status_piece" "$model_piece" "$ctx_piece" "$time_piece")
    _compose
    _visible_len "$content"
    if [ "$_vlen" -gt "$columns" ] && [ "$model_piece" != "$model_plain" ]; then
        pieces[1]="$model_plain"
        _compose
        _visible_len "$content"
    fi
    if [ "$_vlen" -gt "$columns" ]; then
        pieces[1]=""
        _compose
        _visible_len "$content"
    fi
    if [ "$_vlen" -gt "$columns" ]; then
        title="$short_title"
        _compose
        _visible_len "$content"
    fi
    if [ "$_vlen" -gt "$columns" ]; then
        pieces[3]=""
        _compose
        _visible_len "$content"
    fi
    if [ "$_vlen" -gt "$columns" ]; then
        pieces[2]=""
        _compose
        _visible_len "$content"
    fi
    if [ "$_vlen" -gt "$columns" ]; then
        _cut "$plain_name" "$columns"
        title="${BOLD}${WHITE}${_cut}${RST}"
        _compose
        _visible_len "$content"
    fi

    # The step takes whatever width is left, and is dropped when that is tiny.
    budget=$((columns - _vlen - 3))
    if [ -n "$label" ] && [ "$budget" -ge 8 ]; then
        _cut "$label" "$budget"
        content+=" ${DIM}·${RST} ${DIM}${_cut}${RST}"
    fi

    jq -cn --arg id "$id" --arg content "$content" '{id: $id, content: $content}'
done < <(jq -r '
  .tasks[]? | [
    .id,
    (.name // ""),
    (.agentType // ""),
    (.status // ""),
    (.label // .description // ""),
    (.startTime // 0),
    (.model // ""),
    (.effort // ""),
    (.contextWindowSize // 0),
    (.tokenCount // 0)
  ] | map(tostring | gsub("[\t\r\n\u001f]+"; " ")) | join("\u001f")
' <<<"$input" 2>/dev/null)
