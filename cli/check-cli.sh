#!/bin/bash
# check-cli.sh [compose root]: every <thing>-compose stack with a docker-compose.sh keeps it in step
# with its docker-compose.ps1 and commits it so Linux can run it. Static parsing only, no script runs:
#   - the keys of the ps1's usage table ($usage, or storage's $commands) equal the arms of the sh's
#     last top-level `case` (each alternative of `a | b)` counts, `*)` does not) less the sh's
#     `windows_only=(...)` line, which every sh declares, empty or not;
#   - every arm starts a line of the sh's `usage()` text;
#   - no committed .sh, nor docker-compose.sh or scripts/*.sh, holds a CR byte;
#   - docker-compose.sh and scripts/*.sh are committed as mode 100755.
# A stack without a docker-compose.sh passes. Exits non-zero and names each violation.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/../.." && pwd)}

failures=0
stacks=0
checked=0
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

# ps1_commands FILE: the keys of the usage hashtable, one per line.
ps1_commands() {
    tr -d '\r' <"$1" | awk '
        /^\$(usage|commands)[[:space:]]*=[[:space:]]*@\{/ { inside = 1; next }
        inside && /^\}/ { exit }
        inside && /^[[:space:]]*"[^"]+"[[:space:]]*=/ { line = $0; sub(/^[[:space:]]*"/, "", line); sub(/".*/, "", line); print line }'
}

# shellcheck disable=SC2016 # a literal $ in the pattern
has_usage_table() { tr -d '\r' <"$1" | grep -qE '^\$(usage|commands)[[:space:]]*=[[:space:]]*@\{'; }

# sh_arms FILE: every alternative of every arm of the last top-level case, at the indent of its first arm.
sh_arms() {
    tr -d '\r' <"$1" | awk -v quote="'" '
        /^case / { inside = 1; count = 0; next }
        inside && /^esac/ { inside = 0; kept = count; for (i = 1; i <= count; i++) last[i] = buffer[i]; next }
        inside { buffer[++count] = $0 }
        END {
            indent = -1
            for (i = 1; i <= kept; i++) {
                line = last[i]
                if (indent < 0) {
                    if (!match(line, /^[[:space:]]+[^[:space:]#]/)) continue
                    indent = RLENGTH - 1
                }
                if (substr(line, 1, indent) ~ /[^[:space:]]/) continue
                rest = substr(line, indent + 1)
                if (!match(rest, /^[^[:space:]()#|]+([[:space:]]*\|[[:space:]]*[^[:space:]()#|]+)*\)/)) continue
                count = split(substr(rest, 1, RLENGTH - 1), parts, /[[:space:]]*\|[[:space:]]*/)
                for (j = 1; j <= count; j++) {
                    arm = parts[j]
                    gsub(/"/, "", arm)
                    gsub(quote, "", arm)
                    if (arm != "*") print arm
                }
            }
        }'
}

# windows_only FILE: the words of the windows_only=(...) line, one per line; fails when there is none.
windows_only() {
    local line
    line=$(tr -d '\r' <"$1" | grep -E '^windows_only=\(.*\)' | tail -n 1)
    [ -n "$line" ] || return 1
    line=${line#windows_only=(}
    line=${line%%)*}
    tr -d "\"'" <<<"$line" | tr -s ' \t' '\n' | grep -v '^$' || true
}

# usage_words FILE: the first word of every line in the usage() function.
usage_words() {
    tr -d '\r' <"$1" | awk '
        /^usage\(\)/ { inside = 1; next }
        inside && /^\}/ { exit }
        inside && /^[[:space:]]+[^[:space:]]/ { print $1 }'
}

contains() {
    local word=$1
    shift
    printf '%s\n' "$@" | grep -qxF -- "$word"
}

check_commands() {
    local stack=$1 repo=$2 ps1="$2/docker-compose.ps1" sh="$2/docker-compose.sh" command
    local ps1_list sh_list windows_list usage_list
    [ -e "$ps1" ] || return 0
    if ! has_usage_table "$ps1"; then
        fail "$stack" "docker-compose.ps1 has no \$usage table, so its commands cannot be compared"
        return
    fi
    if ! windows_list=$(windows_only "$sh"); then
        fail "$stack" "docker-compose.sh declares no windows_only=(...) line, not even an empty one"
        windows_list=""
    fi
    mapfile -t ps1_list < <(ps1_commands "$ps1")
    mapfile -t sh_list < <(sh_arms "$sh")
    mapfile -t windows_list <<<"$windows_list"
    mapfile -t usage_list < <(usage_words "$sh")

    for command in "${ps1_list[@]}"; do
        contains "$command" "${sh_list[@]}" "${windows_list[@]}" ||
            fail "$stack" "docker-compose.ps1 has '$command', which docker-compose.sh neither dispatches nor lists in windows_only"
    done
    for command in "${sh_list[@]}"; do
        contains "$command" "${ps1_list[@]}" ||
            fail "$stack" "docker-compose.sh dispatches '$command', which is not in docker-compose.ps1's usage table"
        contains "$command" "${usage_list[@]}" ||
            fail "$stack" "docker-compose.sh dispatches '$command' but its usage text does not list it"
    done
    for command in "${windows_list[@]}"; do
        [ -n "$command" ] || continue
        if contains "$command" "${sh_list[@]}"; then
            fail "$stack" "'$command' is in windows_only but docker-compose.sh dispatches it"
        fi
        contains "$command" "${ps1_list[@]}" ||
            fail "$stack" "'$command' is in windows_only but not in docker-compose.ps1's usage table"
    done
}

check_files() {
    local stack=$1 repo=$2 file mode carriage_returns
    if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        fail "$stack" "is not a git checkout, so the committed modes cannot be read"
        return
    fi
    local executables=()
    for file in "$repo"/docker-compose.sh "$repo"/scripts/*.sh; do
        [ -f "$file" ] && executables+=("${file#"$repo"/}")
    done
    local scripts
    mapfile -t scripts < <({ git -C "$repo" ls-files -- '*.sh'; printf '%s\n' "${executables[@]}"; } | sort -u)
    for file in "${scripts[@]}"; do
        [ -f "$repo/$file" ] || continue
        carriage_returns=$(tr -cd '\r' <"$repo/$file" | wc -c | tr -d ' ')
        [ "$carriage_returns" -eq 0 ] || fail "$stack" "$file holds $carriage_returns CR bytes; commit it with LF endings"
    done
    for file in "${executables[@]}"; do
        mode=$(git -C "$repo" ls-files -s -- "$file" | cut -d' ' -f1)
        if [ -z "$mode" ]; then
            fail "$stack" "$file is not committed"
        elif [ "$mode" != 100755 ]; then
            fail "$stack" "$file is committed as $mode, not 100755; run git update-index --chmod=+x $file"
        fi
    done
}

for repo in "$root"/*-compose; do
    [ -d "$repo" ] || continue
    stacks=$((stacks + 1))
    [ -e "$repo/docker-compose.sh" ] || continue
    stack=$(basename "$repo" -compose)
    checked=$((checked + 1))
    check_commands "$stack" "$repo"
    check_files "$stack" "$repo"
done

[ "$stacks" -gt 0 ] || fail "$root" "holds no *-compose repo, so nothing was checked"
if [ "$failures" -eq 0 ]; then
    if [ "$checked" -eq 0 ]; then echo "no stack has a docker-compose.sh, so there is nothing to compare"
    else echo "all $checked stacks with a docker-compose.sh match their docker-compose.ps1 and are committed LF and executable"
    fi
fi
[ "$failures" -eq 0 ]
