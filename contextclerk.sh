#!/usr/bin/env bash
# ContextClerk - https://github.com/MechRosey/ContextClerk
# Monitors Claude Code session transcripts and appends structured summaries
# to ContextLog.md in each project repo.
#
# Linux/bash port of contextclerk.ps1. Designed to run via a systemd user
# timer (see install.sh) every 5 minutes.
#
# Requires: claude CLI (for summarisation) and jq (for JSON parsing).
#
# Usage:
#   ./contextclerk.sh                 normal incremental pass
#   ./contextclerk.sh --force         backfill all projects from scratch
#   ./contextclerk.sh --throttle 4    cap parallel claude calls (default 4)

set -u

FORCE=0
THROTTLE_LIMIT=4

while [ $# -gt 0 ]; do
    case "$1" in
        --force|-Force|-f) FORCE=1 ;;
        --throttle) shift; THROTTLE_LIMIT="${1:-4}" ;;
        --throttle=*) THROTTLE_LIMIT="${1#*=}" ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

STATE_FILE="$HOME/.claude/contextclerk-state.json"
PROJECTS_ROOT="$HOME/.claude/projects"
TOOL_REPO='https://github.com/MechRosey/ContextClerk'

CLAUDE_EXE="$(command -v claude 2>/dev/null || true)"
[ -z "$CLAUDE_EXE" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_EXE="$HOME/.local/bin/claude"

if ! command -v jq >/dev/null 2>&1; then
    echo "[ContextClerk] ERROR: jq is required but not found. Install it with: sudo apt install jq" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ----------------------------------------------------------------------
# State helpers (state file is a single JSON object):
#   { "<jsonl path>": {"lastLine": N}, ...,
#     "_sessions": {"<cwd>": "<sessionId>"},
#     "_lastWeeklyCleanup": "YYYY-MM-DD",
#     "_lastMonthlyArchive": "YYYY-MM" }
# We keep the live state in $TMP/state.json and rewrite it at the end.
# ----------------------------------------------------------------------

if [ -f "$STATE_FILE" ] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    cp "$STATE_FILE" "$TMP/state.json"
else
    echo '{}' > "$TMP/state.json"
fi

state_get_lastline() { # path
    jq -r --arg p "$1" '(.[$p].lastLine // 0) | floor' "$TMP/state.json"
}
state_set_lastline() { # path total
    jq --arg p "$1" --argjson n "$2" '.[$p] = {lastLine: $n}' "$TMP/state.json" > "$TMP/state.next" \
        && mv "$TMP/state.next" "$TMP/state.json"
}
state_get_session() { # cwd
    jq -r --arg c "$1" '(._sessions[$c] // "")' "$TMP/state.json"
}
state_set_session() { # cwd sessionId
    jq --arg c "$1" --arg s "$2" '._sessions = ((._sessions // {}) + {($c): $s})' "$TMP/state.json" > "$TMP/state.next" \
        && mv "$TMP/state.next" "$TMP/state.json"
}
state_get_maint() { # key (_lastWeeklyCleanup | _lastMonthlyArchive)
    jq -r --arg k "$1" '(.[$k] // "")' "$TMP/state.json"
}
state_set_maint() { # key value
    jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$TMP/state.json" > "$TMP/state.next" \
        && mv "$TMP/state.next" "$TMP/state.json"
}

DIRTY=0

[ -d "$PROJECTS_ROOT" ] || exit 0

# Prune stale worktree session keys recorded before worktree cwds were remapped to project roots.
if jq -e '(._sessions // {}) | keys[] | select(test("/\\.claude/worktrees/"))' "$TMP/state.json" >/dev/null 2>&1; then
    jq '._sessions = ((._sessions // {}) | with_entries(select(.key | test("/\\.claude/worktrees/") | not)))' \
        "$TMP/state.json" > "$TMP/state.next" && mv "$TMP/state.next" "$TMP/state.json"
    DIRTY=1
fi

# ----------------------------------------------------------------------
# Derive our own project directory and delete sdk-cli agent files left
# there each run (these are short transcripts from the summarisation calls).
# ----------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_HASH="${SCRIPT_DIR//\//-}"
SELF_DIR="$PROJECTS_ROOT/$SELF_HASH"
if [ -d "$SELF_DIR" ]; then
    cnt_cleaned=0
    for f in "$SELF_DIR"/*.jsonl; do
        [ -e "$f" ] || continue
        sz=$(stat -c%s "$f")
        (( sz < 102400 )) || continue
        ep=$(head -n 10 "$f" | jq -R 'fromjson? // empty' \
                | jq -rs '[.[] | .entrypoint // empty] | map(select(. != "")) | (.[0] // "")' 2>/dev/null)
        if [ "$ep" = "sdk-cli" ]; then rm -f "$f"; cnt_cleaned=$((cnt_cleaned+1)); fi
    done
    (( cnt_cleaned > 0 )) && echo "  Cleaned $cnt_cleaned sdk-cli files from self project dir"
fi

NOW_EPOCH=$(date +%s)
if [ -f "$STATE_FILE" ]; then STATE_AGE=$(stat -c%Y "$STATE_FILE"); else STATE_AGE=0; fi
FORCE_CUTOFF=$(( NOW_EPOCH - 90*86400 ))

# ----------------------------------------------------------------------
# The jq program that extracts everything we need from a slice of new
# transcript lines (already parsed, one object per line). Output is a
# single JSON object with metadata, file/commit sets, compaction count,
# and the coalesced conversation text.
# ----------------------------------------------------------------------
read -r -d '' EXTRACT_JQ <<'JQEOF' || true
def trim: gsub("^\\s+|\\s+$"; "");

def usertext($c):
  if ($c|type) == "string" then ($c | trim)
  else ([ $c[]? | select(.type == "text") ] | (if length > 0 then (.[0].text | trim) else "" end))
  end;

def userparts:
  .message.content as $c
  | ( if ($c|type) == "array" then
        [ $c[] | select(.type == "tool_result")
          | ( if (.content|type) == "string" then .content
              elif (.content|type) == "array" then ([ .content[] | select(.type=="text") ] | (if length>0 then .[0].text else "" end))
              else "" end ) as $rt
          | if ($rt|length) == 0 then empty
            else
              ( [ $rt | split("\n")[] | gsub("\r";"") | trim
                  | if test("(Passed|Failed)!.*Failed:\\s+\\d+.*Passed:\\s+\\d+") then ("Tests: " + .[0:150])
                    elif test("^Build (succeeded|FAILED)") then ("Build: " + .)
                    elif test("error [A-Z]+\\d+:") then ("Error: " + .[0:200])
                    else empty end ]
                | (if length > 0 then .[0] else empty end) )
            end ]
      else [] end ) as $tr
  | ( (usertext($c)) as $t
      | if ($t|length) > 3
           and ($t | test("^This session is being continued") | not)
           and ($t | test("^# ") | not)
           and ($t | test("^<system-reminder>") | not)
        then ["User: " + $t[0:300]] else [] end ) as $up
  | $tr + $up;

def asnippets($c):
  [ $c[] | select(.type == "text" and (.text|length) > 20) ] as $tbs
  | ( reduce $tbs[] as $tb ({used:0, out:[]};
        (8000 - .used) as $avail
        | if $avail <= 0 then .
          else
            ([4000, $avail] | min) as $maxBlock
            | ($tb.text) as $t
            | ( if ($t|length) <= $maxBlock then $t
                else
                  ([500, (($maxBlock * 0.3) | floor)] | min) as $tailLen
                  | ($maxBlock - $tailLen - 5) as $headLen
                  | (if $headLen > 0 then ($t[0:$headLen] + " ... " + $t[(($t|length) - $tailLen):]) else $t[0:$maxBlock] end)
                end ) as $snip
            | {used: (.used + ($snip|length)), out: (.out + ["Claude: " + $snip])}
          end) ).out;

def acommits($c):
  [ $c[] | select(.type == "tool_use" and .name == "Bash")
    | (.input.command // "")
    | select(test("git\\s+commit"))
    | if test("-m\\s+\"[^\"]{10,}\"")
      then (capture("-m\\s+\"(?<m>[^\"]{10,})\"") | .m | trim | "Committed: " + .)
      else empty end ];

def commitmsg($cmd):
  if ($cmd | test("<<'EOF'")) and ($cmd | test("<<'EOF'[\\s\\S]*?EOF"))
  then ( $cmd | capture("<<'EOF'\\n(?<m>[\\s\\S]*?)\\n[ \\t]*EOF") | .m
         | split("\n") | map(trim) | map(select(length > 0 and (test("^Co-Authored") | not)))
         | (if length > 0 then .[0] else "" end) )
  elif ($cmd | test("-m\\s+\"[^\"]{10,}\""))
  then ( $cmd | capture("-m\\s+\"(?<m>[^\"]{10,})\"") | .m | trim )
  else "" end;

reduce .[] as $o (
  {cwd:null, branch:null, sessionId:null, firstTs:null, title:null,
   files:[], commits:[], comp:0, segs:[], cur:[]};
    (if ($o.cwd != null and .cwd == null) then .cwd = $o.cwd else . end)
  | (if ($o.gitBranch != null) then .branch = $o.gitBranch else . end)
  | (if ($o.sessionId != null and .sessionId == null) then .sessionId = $o.sessionId else . end)
  | (if ($o.timestamp != null and .firstTs == null) then .firstTs = $o.timestamp else . end)
  | (if ($o.type == "ai-title" or $o.type == "custom-title")
       then (($o.title // $o.aiTitle) as $t | if $t != null then .title = $t else . end)
       else . end)
  | (if ($o.type == "assistant") and (($o.message.content|type) == "array") then
       ($o.message.content) as $c
       | .files = (.files + [ $c[] | select(.type == "tool_use")
            | if (.name == "Write" or .name == "Edit" or .name == "MultiEdit") and (.input.file_path != null) then .input.file_path
              elif .name == "NotebookEdit" and (.input.notebook_path != null) then .input.notebook_path
              else empty end ])
       | .commits = (.commits + [ $c[] | select(.type == "tool_use" and .name == "Bash")
            | (.input.command // "") | select(test("git\\s+commit"))
            | commitmsg(.) | select(length >= 10) ])
     else . end)
  | (if ($o.type == "system" and $o.subtype == "compact_boundary") then
        (if ($o.compactMetadata != null) then .comp = (.comp + 1) else . end)
        | (if (.cur|length) > 0 then (.segs = (.segs + [.cur]) | .cur = []) else . end)
     elif ($o.type == "user") then
        .cur = (.cur + ($o | userparts))
     elif ($o.type == "assistant") and (($o.message.content|type) == "array") then
        .cur = (.cur + asnippets($o.message.content) + acommits($o.message.content))
     else . end)
)
| (if (.cur|length) > 0 then .segs = (.segs + [.cur]) else . end)
| { cwd, branch, sessionId, firstTs, title,
    files: (.files | unique),
    commits: (.commits | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)),
    compactionCount: .comp,
    convText: (if (.segs|length) > 0 then ([ .segs[] | join("\n") ] | join("\n---\n")) else null end) }
JQEOF

# ----------------------------------------------------------------------
# Prompt builder - emits the LLM prompt for one file's new content.
# ----------------------------------------------------------------------
build_prompt() { # convText logPath  -> stdout
    local convText="$1" logPath="$2" existingContext=""
    if [ -n "$logPath" ] && [ -f "$logPath" ]; then
        existingContext="$(tail -n 25 "$logPath")"
    fi
    cat <<EOF
You are writing a brief progress entry for ContextLog.md, a Claude Code session development log.

Session log so far (for context only):
---
$existingContext
---

Activity in this session:
---
$convText
---

Write as many bullets as the session warrants (typically 2-5 for an active session). Each bullet can be as long as needed to capture the root cause fully.
Code and git diffs record what changed; ContextLog should capture what the code cannot show - the hidden constraint, API quirk, platform behaviour, or reasoning that forced this specific approach.
For each bullet: state what changed, why it changed, and the mechanism when non-obvious (e.g. "fixed pixel corruption - GDI+ LockBits returns full-row stride regardless of locked region width, so using region.Width * bpp as stride silently zeroed every pixel").
If Claude tried multiple failing approaches before finding the working solution (e.g. wrong path, missing tool, incorrect invocation), note the successful approach explicitly so it can be recalled without repeating the search (e.g. "msbuild found at X - not on PATH by default").
Prefer insights and decisions that would not be obvious from reading the code or git diff. Skip test counts and build results unless the outcome was unexpected, or the passing tests confirmed that a non-obvious refactor was safe.
If the session ended mid-task or left something incomplete, add one final line starting with "Next:" describing what was interrupted or planned next.
Rules: use plain "- item" bullets only. No markdown headers, bold, italics, or nested structure. ASCII only - no em dashes, curly quotes, or any non-ASCII characters.
An empty response is perfectly valid. If nothing significant happened, respond with exactly: (nothing to log)
EOF
}

# ----------------------------------------------------------------------
# Phase 1: collect work items.
# No LLM calls here so log context is read before any writes happen.
# ----------------------------------------------------------------------
WORK="$TMP/work"
mkdir -p "$WORK"

cnt_total=0
cnt_recent=0
cnt_newlines=0
total_newlines=0
item_idx=0
phase1_start=$(date +%s.%N)

# Candidate files: all *.jsonl under projects root, excluding subagent transcripts, oldest mtime first.
mapfile -t CANDIDATES < <(find "$PROJECTS_ROOT" -type f -name '*.jsonl' ! -path '*/subagents/*' \
    -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -n)

cnt_total=${#CANDIDATES[@]}

for entry in "${CANDIDATES[@]}"; do
    mtime_f="${entry%%	*}"; rest="${entry#*	}"
    size="${rest%%	*}"; jsonl="${rest#*	}"
    mtime_i="${mtime_f%.*}"

    (( size < 10240 )) && continue
    if (( FORCE == 1 )); then
        (( mtime_i < FORCE_CUTOFF )) && continue
    else
        (( mtime_i <= STATE_AGE )) && continue
    fi

    cnt_recent=$((cnt_recent+1))

    if (( FORCE == 1 )); then last_line=0; else last_line=$(state_get_lastline "$jsonl"); fi

    total=$(wc -l < "$jsonl")
    # wc -l counts newlines; a final line without trailing newline is undercounted.
    # Claude transcripts always terminate lines, so this matches the PowerShell line count.
    (( total <= last_line )) && continue

    cnt_newlines=$((cnt_newlines+1))
    total_newlines=$(( total_newlines + total - last_line ))

    tail -n +"$((last_line+1))" "$jsonl" \
        | jq -R 'fromjson? // empty' \
        | jq -s "$EXTRACT_JQ" > "$TMP/meta.json" 2>/dev/null || { echo '{}' > "$TMP/meta.json"; }

    cwd=$(jq -r '.cwd // ""' "$TMP/meta.json")
    # Remap worktree cwds to the parent project root.
    case "$cwd" in
        */.claude/worktrees/*) cwd="${cwd%%/.claude/worktrees/*}" ;;
    esac

    convText=$(jq -r '.convText // ""' "$TMP/meta.json")

    d="$WORK/$(printf '%05d' "$item_idx")"
    mkdir -p "$d"
    item_idx=$((item_idx+1))

    printf '%s' "$jsonl"  > "$d/jsonlPath"
    printf '%s' "$total"  > "$d/total"
    printf '%s' "$cwd"    > "$d/cwd"
    jq -r '.branch // ""'           "$TMP/meta.json" > "$d/branch"
    jq -r '.sessionId // ""'        "$TMP/meta.json" > "$d/sessionId"
    jq -r '.firstTs // ""'          "$TMP/meta.json" > "$d/firstTs"
    jq -r '.title // ""'            "$TMP/meta.json" > "$d/title"
    jq -r '.files[]?'               "$TMP/meta.json" > "$d/files"
    jq -r '.commits[]?'             "$TMP/meta.json" > "$d/commits"
    jq -r '.compactionCount // 0'   "$TMP/meta.json" > "$d/compactions"

    if [ -n "$convText" ] && [ -n "$cwd" ]; then
        build_prompt "$convText" "$cwd/ContextLog.md" > "$d/prompt"
    fi
done

phase1_end=$(date +%s.%N)
phase1_elapsed=$(awk "BEGIN{printf \"%.2f\", $phase1_end - $phase1_start}")

with_prompt=0
for d in "$WORK"/*/; do [ -f "${d}prompt" ] && with_prompt=$((with_prompt+1)); done
[ -d "$WORK" ] && [ -z "$(ls -A "$WORK")" ] && with_prompt=0

echo "[ContextClerk] $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Files found        : $cnt_total"
echo "  Recently changed   : $cnt_recent"
echo "  With new lines     : $cnt_newlines  (total new lines: $total_newlines)"
echo "  Work items queued  : $item_idx  (with LLM prompt: $with_prompt)"
echo "  Phase 1 elapsed    : ${phase1_elapsed}s"

# ----------------------------------------------------------------------
# Order work items chronologically by session start time.
# ----------------------------------------------------------------------
ORDERED=()
if (( item_idx > 0 )); then
    mapfile -t ORDERED < <(
        for d in "$WORK"/*/; do
            ts=$(cat "${d}firstTs" 2>/dev/null)
            ep=$(date -d "$ts" +%s 2>/dev/null || echo 0)
            printf '%s\t%s\n' "$ep" "${d%/}"
        done | sort -n | cut -f2-
    )
fi

# ----------------------------------------------------------------------
# Phase 2+3: summarise. One claude call per item, throttled in parallel.
# ----------------------------------------------------------------------
clean_summary() { # reads stdin, writes cleaned summary to stdout
    awk '
    {
        line = $0; t = line
        sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
        if (t == "(nothing to log)") next
        if (t ~ /^#/) next
        if (t ~ /^\*\*/) next
        print line
    }' | sed -e ':a' -e '/^[[:space:]]*$/{$d;N;ba}' -e '/^[[:space:]]*$/d' 2>/dev/null
}

summarise_item() { # item dir
    local d="$1" out
    out=$("$CLAUDE_EXE" --print --no-session-persistence --model haiku < "${d}/prompt" 2>/dev/null)
    printf '%s' "$out" | clean_summary > "${d}/summary"
}

if [ -n "$CLAUDE_EXE" ] && [ -x "$CLAUDE_EXE" ]; then
    for d in "${ORDERED[@]}"; do
        [ -f "$d/prompt" ] || continue
        while (( $(jobs -rp | wc -l) >= THROTTLE_LIMIT )); do wait -n 2>/dev/null || break; done
        summarise_item "$d" &
    done
    wait
fi

# ----------------------------------------------------------------------
# update_last_block: merge new bullets/files into the last "## " block.
# Returns 0 on success, 1 if no block found (caller writes a fresh block).
# Inputs via files: $1 logPath, $2 bullets file, $3 files file.
# ----------------------------------------------------------------------
update_last_block() {
    local logPath="$1" bulletsFile="$2" filesFile="$3"
    mapfile -t lines < "$logPath"
    local n=${#lines[@]} i blockStart=-1
    for (( i=n-1; i>=0; i-- )); do
        case "${lines[i]}" in "## "*) blockStart=$i; break ;; esac
    done
    (( blockStart < 0 )) && return 1

    local -a existingBullets=() existingFiles=()
    local inProgress=0 inFiles=0 l
    for (( i=blockStart+1; i<n; i++ )); do
        l="${lines[i]}"
        case "$l" in
            "### Progress"*)       inProgress=1; inFiles=0; continue ;;
            "### Files Modified"*) inFiles=1; inProgress=0; continue ;;
            "### "*)               inProgress=0; inFiles=0; continue ;;
        esac
        if (( inProgress )) && [ -n "${l//[[:space:]]/}" ]; then existingBullets+=("$l"); fi
        if (( inFiles )); then
            case "$l" in "  - "*) existingFiles+=("${l:4}") ;; esac
        fi
    done

    local -a newBullets=() newFiles=()
    [ -f "$bulletsFile" ] && mapfile -t newBullets < "$bulletsFile"
    [ -f "$filesFile" ]   && mapfile -t newFiles   < "$filesFile"

    # Regular bullets accumulate; the Next: line always moves to the end, latest wins.
    local nextLine="" b
    local -a merged=()
    for b in "${existingBullets[@]:-}"; do
        [ -z "$b" ] && continue
        case "$b" in Next:*) nextLine="$b" ;; *) merged+=("$b") ;; esac
    done
    for b in "${newBullets[@]:-}"; do
        [ -z "${b//[[:space:]]/}" ] && continue
        case "$b" in
            Next:*) nextLine="$b" ;;
            *)
                local dup=0 m
                for m in "${merged[@]:-}"; do [ "$m" = "$b" ] && { dup=1; break; }; done
                (( dup == 0 )) && merged+=("$b")
                ;;
        esac
    done
    [ -n "$nextLine" ] && merged+=("$nextLine")

    # Files: case-insensitive unique, sorted.
    local -a allFiles=()
    for b in "${existingFiles[@]:-}" "${newFiles[@]:-}"; do
        b="${b#"${b%%[![:space:]]*}"}"; b="${b%"${b##*[![:space:]]}"}"
        [ -n "$b" ] && allFiles+=("$b")
    done
    local -a sortedFiles=()
    if (( ${#allFiles[@]} > 0 )); then
        mapfile -t sortedFiles < <(printf '%s\n' "${allFiles[@]}" | sort -fu)
    fi

    {
        (( blockStart > 0 )) && printf '%s\n' "${lines[@]:0:blockStart}"
        printf '%s\n' "${lines[blockStart]}"
        if (( ${#merged[@]} > 0 )); then
            printf '\n### Progress\n'
            printf '%s\n' "${merged[@]}"
        fi
        if (( ${#sortedFiles[@]} > 0 )); then
            printf '\n### Files Modified\n'
            printf '  - %s\n' "${sortedFiles[@]}"
        fi
    } > "$logPath"
    return 0
}

# ----------------------------------------------------------------------
# Phase 4: write ContextLog.md entries in chronological order.
# ----------------------------------------------------------------------
declare -A RESET_LOGS=()

for d in "${ORDERED[@]}"; do
    jsonl=$(cat "$d/jsonlPath")
    total=$(cat "$d/total")
    cwd=$(cat "$d/cwd")
    branch=$(cat "$d/branch")
    sessionId=$(cat "$d/sessionId")
    firstTs=$(cat "$d/firstTs")
    title=$(cat "$d/title")
    compactions=$(cat "$d/compactions")
    summary=""
    [ -f "$d/summary" ] && summary=$(cat "$d/summary")

    nFiles=0;   [ -s "$d/files" ]   && nFiles=$(grep -c . "$d/files")
    nCommits=0; [ -s "$d/commits" ] && nCommits=$(grep -c . "$d/commits")
    hasSummary=0; [ -n "${summary//[[:space:]]/}" ] && hasSummary=1

    if (( hasSummary == 0 && nFiles == 0 && nCommits == 0 && compactions == 0 )); then
        state_set_lastline "$jsonl" "$total"; DIRTY=1; continue
    fi
    if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
        state_set_lastline "$jsonl" "$total"; DIRTY=1; continue
    fi

    logPath="$cwd/ContextLog.md"
    # Migrate legacy log names.
    [ -f "$cwd/SESSION_LOG.md" ]  && [ ! -f "$logPath" ] && mv "$cwd/SESSION_LOG.md"  "$logPath"
    [ -f "$cwd/ContextClerk.md" ] && [ ! -f "$logPath" ] && mv "$cwd/ContextClerk.md" "$logPath"

    logExists=0; [ -f "$logPath" ] && logExists=1
    firstWrite=0
    if (( logExists == 0 )); then firstWrite=1
    elif (( FORCE == 1 )) && [ -z "${RESET_LOGS[$logPath]:-}" ]; then firstWrite=1; fi

    if (( firstWrite )); then
        cat > "$logPath" <<EOF
## *ContextLog | $cwd*

[ContextClerk]($TOOL_REPO) monitors Claude sessions and updates this file every five minutes when changes occur.

EOF
        (( FORCE == 1 )) && RESET_LOGS[$logPath]=1

        if (( logExists == 0 )); then
            git -C "$cwd" check-ignore -q "$logPath" 2>/dev/null
            if (( $? != 0 )); then
                gitignore="$cwd/.gitignore"
                if [ -f "$gitignore" ]; then
                    grep -q 'ContextLog\.md' "$gitignore" || printf '\nContextLog.md\n' >> "$gitignore"
                else
                    printf 'ContextLog.md\n' > "$gitignore"
                fi
            fi
        fi
    fi

    # Relativise modified files to project-relative paths.
    cwdNorm="${cwd%/}"
    : > "$d/projfiles"
    if [ -s "$d/files" ]; then
        while IFS= read -r fp; do
            [ -z "$fp" ] && continue
            case "$fp" in
                "$cwdNorm"/*) printf '%s\n' "${fp#$cwdNorm/}" ;;
            esac
        done < "$d/files" | sort -u > "$d/projfiles"
    fi
    nProjFiles=0; [ -s "$d/projfiles" ] && nProjFiles=$(grep -c . "$d/projfiles")

    # Append to the existing session block unless a compaction wiped context.
    sessForCwd=$(state_get_session "$cwd")
    isSameSession=0; [ -n "$sessForCwd" ] && [ "$sessForCwd" = "$sessionId" ] && isSameSession=1
    shouldAppend=0
    if (( isSameSession == 1 && compactions == 0 && logExists == 1 && firstWrite == 0 )); then shouldAppend=1; fi

    if (( shouldAppend )); then
        : > "$d/bullets"
        if (( hasSummary )); then
            grep -v '^[[:space:]]*$' "$d/summary" > "$d/bullets"
        fi
        nBullets=0; [ -s "$d/bullets" ] && nBullets=$(grep -c . "$d/bullets")

        appended=0
        if (( nBullets > 0 || nProjFiles > 0 )); then
            if update_last_block "$logPath" "$d/bullets" "$d/projfiles"; then appended=1; fi
        else
            appended=1
        fi

        if (( appended )); then
            state_set_session "$cwd" "$sessionId"
            state_set_lastline "$jsonl" "$total"
            DIRTY=1
            continue
        fi
    fi

    # New block.
    dateStr="unknown"
    if [ -n "$firstTs" ]; then
        dateStr=$(date -d "$firstTs" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)
    fi
    branchPart=""; [ -n "$branch" ] && [ "$branch" != "HEAD" ] && branchPart=" [branch: $branch]"
    titlePart="";  [ -n "$title" ] && titlePart=" - $title"

    {
        printf '## %s%s%s\n' "$dateStr" "$branchPart" "$titlePart"
        if (( hasSummary )); then
            printf '\n### Progress\n'
            printf '%s\n' "$summary"
        fi
        if (( nCommits > 0 && hasSummary == 0 )); then
            printf '\n### Commits\n'
            tail -n 3 "$d/commits" | while IFS= read -r c; do [ -n "$c" ] && printf '  - %s\n' "$c"; done
        fi
        if (( nProjFiles > 0 )); then
            printf '\n### Files Modified\n'
            while IFS= read -r f; do [ -n "$f" ] && printf '  - %s\n' "$f"; done < "$d/projfiles"
        fi
        printf '\n'
    } >> "$logPath"

    state_set_session "$cwd" "$sessionId"
    state_set_lastline "$jsonl" "$total"
    DIRTY=1
done

# ----------------------------------------------------------------------
# Known project cwds (those with a recorded session and a live directory).
# ----------------------------------------------------------------------
mapfile -t KNOWN_CWDS < <(
    jq -r '(._sessions // {}) | keys[]' "$TMP/state.json" 2>/dev/null | while IFS= read -r c; do
        [ -d "$c" ] && printf '%s\n' "$c"
    done
)

# ----------------------------------------------------------------------
# Phase 5a: weekly cleanup - strip Files Modified/Commits/Next: from
# entries older than 7 days. Runs Mondays, once per day.
# ----------------------------------------------------------------------
invoke_weekly_cleanup() {
    local cutoff cleaned=0 cwd logPath
    cutoff=$(date -d '7 days ago' +%s)
    for cwd in "${KNOWN_CWDS[@]:-}"; do
        [ -z "$cwd" ] && continue
        logPath="$cwd/ContextLog.md"
        [ -f "$logPath" ] || continue
        mapfile -t L < "$logPath"
        local n=${#L[@]} i changed=0
        : > "$TMP/cleaned"
        local inStrip=0 blockEpoch="" isData=0
        for (( i=0; i<n; i++ )); do
            local line="${L[i]}"
            case "$line" in
                "## "*)
                    inStrip=0
                    if [[ "$line" == "## *ContextLog"* || "$line" == "## Archive ["* ]]; then
                        isData=0; blockEpoch=""
                    elif [[ "$line" =~ ^##\ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}) ]]; then
                        isData=1; blockEpoch=$(date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null || echo "")
                    else
                        isData=0; blockEpoch=""
                    fi
                    printf '%s\n' "$line" >> "$TMP/cleaned"
                    continue
                    ;;
            esac
            # Inside a block.
            if (( isData == 1 )) && [ -n "$blockEpoch" ] && (( blockEpoch < cutoff )); then
                case "$line" in
                    "### Files Modified"*|"### Commits"*) inStrip=1; changed=1; continue ;;
                    "### "*) inStrip=0 ;;
                esac
                (( inStrip )) && { changed=1; continue; }
                if [[ "$line" =~ ^[[:space:]]*(-[[:space:]]+)?Next: ]]; then changed=1; continue; fi
            fi
            printf '%s\n' "$line" >> "$TMP/cleaned"
        done
        if (( changed )); then
            # Trim trailing blank lines.
            sed -e :a -e '/^[[:space:]]*$/{$d;N;ba}' "$TMP/cleaned" > "$logPath"
            cleaned=$((cleaned+1))
        fi
    done
    (( cleaned > 0 )) && echo "  Weekly cleanup     : $cleaned log(s) pruned"
}

# ----------------------------------------------------------------------
# Phase 5b: monthly archive - summarise a target month's session blocks
# into a single two-part (Arc + Insights) archive entry. Runs once/month;
# archive blocks are never re-processed.
# ----------------------------------------------------------------------
invoke_monthly_archive() { # targetMonth (YYYY-MM)
    local targetMonth="$1"
    [ -n "$CLAUDE_EXE" ] && [ -x "$CLAUDE_EXE" ] || return 0

    local archiveLabel archiveHeader cwd logPath
    archiveLabel=$(date -d "${targetMonth}-01" '+%B %Y' 2>/dev/null) || return 0
    archiveHeader="## Archive [$archiveLabel]"

    for cwd in "${KNOWN_CWDS[@]:-}"; do
        [ -z "$cwd" ] && continue
        logPath="$cwd/ContextLog.md"
        [ -f "$logPath" ] || continue
        grep -qF "$archiveHeader" "$logPath" && continue

        mapfile -t L < "$logPath"
        local n=${#L[@]} i
        # Identify target-month blocks; collect their text and remember positions.
        : > "$TMP/sessions"
        local -a blockType=()      # one entry per line: 'pre' | block index
        local curBlock=-1 curIsTarget=0 anyTarget=0
        local -a startOfTargetRun=()
        # First pass: tag each line with whether it belongs to a target block.
        local -a lineTarget=()
        for (( i=0; i<n; i++ )); do
            local line="${L[i]}"
            case "$line" in
                "## "*)
                    if [[ "$line" == "## *ContextLog"* || "$line" == "## Archive ["* ]]; then
                        curIsTarget=0
                    elif [[ "$line" =~ ^##\ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
                        local bmonth="${BASH_REMATCH[1]:0:7}"
                        if [ "$bmonth" = "$targetMonth" ]; then curIsTarget=1; anyTarget=1; else curIsTarget=0; fi
                    else
                        curIsTarget=0
                    fi
                    ;;
            esac
            lineTarget[i]=$curIsTarget
            if (( curIsTarget )); then printf '%s\n' "$line" >> "$TMP/sessions"; fi
        done
        (( anyTarget )) || continue

        local sessionText; sessionText=$(cat "$TMP/sessions")
        [ -n "${sessionText//[[:space:]]/}" ] || continue

        cat > "$TMP/archive_prompt" <<EOF
You are writing a monthly archive entry for ContextLog.md, a Claude Code session development log.
This archive entry permanently replaces the individual session entries for $archiveLabel.
It will never be summarised again.

The following session entries cover ${archiveLabel}:
---
$sessionText
---

### Arc
The arc of this month's work: how understanding evolved, what failed and what unlocked progress, key decisions made and why.
Loosely chronological. Focus on the project-specific narrative -- what was attempted, what broke, what was discovered.
Every bullet must answer "what was non-obvious here?" -- if a bullet describes routine cleanup, documentation updates, or work with no decision or surprise, drop it.
Preserve attribution accurately: if the source says the user caught or requested something, it was the agent that made the mistake, not the user.
If the month had no significant decisions or surprises, write nothing here.

### Insights
Portable lessons from this month: non-obvious API, tool, platform, or language behaviours that would help on a different project with a similar problem.
Not "we did X" -- "X is how this class of thing works."
Before writing each Insights bullet, check whether the same mechanism already appears in Arc in any form -- if it does, omit it from Insights entirely.
If nothing portable was learned, write nothing here.

IMPORTANT: ASCII characters only throughout. Do not use em dashes (--), curly quotes, or any non-ASCII character. Use a plain hyphen or comma instead.

Rules for both sections:
- Plain "- item" bullets only
- Do not pad thin sections -- an empty section is better than a vague bullet
- If a section has no bullets, still output the header followed by a blank line

Output exactly these two headers, each followed by bullets or a blank line:
### Arc
### Insights
EOF

        local rawOutput
        rawOutput=$("$CLAUDE_EXE" --print --no-session-persistence --model haiku < "$TMP/archive_prompt" 2>/dev/null)
        rawOutput="${rawOutput#"${rawOutput%%[![:space:]]*}"}"
        rawOutput="${rawOutput%"${rawOutput##*[![:space:]]}"}"
        [ -n "$rawOutput" ] || continue

        # Rebuild the log: replace the first target block run with the archive entry, drop the rest.
        local firstInserted=0
        : > "$TMP/rebuilt"
        for (( i=0; i<n; i++ )); do
            if (( ${lineTarget[i]} == 1 )); then
                if (( firstInserted == 0 )); then
                    printf '%s\n\n%s\n' "$archiveHeader" "$rawOutput" >> "$TMP/rebuilt"
                    firstInserted=1
                fi
            else
                printf '%s\n' "${L[i]}" >> "$TMP/rebuilt"
            fi
        done
        sed -e :a -e '/^[[:space:]]*$/{$d;N;ba}' "$TMP/rebuilt" > "$logPath"
        echo "  Monthly archive    : archived $archiveLabel in $cwd"
    done
}

# ----------------------------------------------------------------------
# Phase 5 driver.
# ----------------------------------------------------------------------
today_dow=$(date +%u)   # 1 = Monday
today_date=$(date +%Y-%m-%d)
needs_weekly=0
if [ "$today_dow" = "1" ]; then
    lastWeekly=$(state_get_maint "_lastWeeklyCleanup")
    if [ -z "$lastWeekly" ] || [ "$lastWeekly" \< "$today_date" ]; then needs_weekly=1; fi
fi
prev_month=$(date -d "$(date +%Y-%m-15) -2 months" +%Y-%m)
last_monthly=$(state_get_maint "_lastMonthlyArchive")
needs_monthly=0; [ "$last_monthly" != "$prev_month" ] && needs_monthly=1

if (( needs_weekly || needs_monthly )); then
    if (( needs_weekly )); then
        invoke_weekly_cleanup
        state_set_maint "_lastWeeklyCleanup" "$today_date"; DIRTY=1
    fi
    if (( needs_monthly )); then
        invoke_monthly_archive "$prev_month"
        state_set_maint "_lastMonthlyArchive" "$prev_month"; DIRTY=1
    fi
fi

# ----------------------------------------------------------------------
# Persist state.
# ----------------------------------------------------------------------
if (( DIRTY || needs_weekly || needs_monthly )); then
    cp "$TMP/state.json" "$STATE_FILE"
fi
