#!/bin/bash
# The restore decision of data-on-disk.sh over the shared cases in cases/, which
# restore-decision.Tests.ps1 reads too, with the volume probe shadowed so no test reaches Docker;
# then the bash-only cases for the other helpers.
#
# A case file holds one "key value" line each ('#' starts a comment):
#   volume empty|cluster          what the shadowed probe answers (default empty)
#   folder present|missing        whether the dump folder exists (default present)
#   pattern GLOB                  the dump pattern (default app-*.dump)
#   dump NAME BYTES               a file in the folder
#   validator none                pass no rejection callback (default: one built from the reject lines)
#   reject NAME|* REASON          what the callback answers for that dump; any other dump is restorable
#   fresh true|false              allow-fresh (default false)
#   expect-action ACTION          Keep, Restore, Fresh or Refuse
#   expect-dump NAME              the dump to restore (default none)
#   expect-rejected NAME REASON   one line per rejected dump, in order
#   expect-validator-runs N       how often the callback ran (default unchecked)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../data-on-disk.sh
. "$here/../data-on-disk.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

volume=stack_db
probe_log="$scratch/probes"
validator_log="$scratch/validator-runs"
volume_is_empty=true
case_rejections=()

database_volume_is_empty() {
    echo "$1" >>"$probe_log"
    [ "$volume_is_empty" = true ]
}

case_rejection() {
    local name=${1##*/} rejection
    echo run >>"$validator_log"
    for rejection in "${case_rejections[@]}"; do
        if [ "${rejection%%$'\t'*}" = "*" ] || [ "${rejection%%$'\t'*}" = "$name" ]; then
            echo "${rejection#*$'\t'}"
            return 0
        fi
    done
}

failures=0
check() {
    local name=$1 want=$2 got=$3
    if [ "$want" = "$got" ]; then return 0; fi
    echo "FAIL $name: wanted"
    printf '%s\n' "$want" | sed 's/^/       /'
    echo "     got"
    printf '%s\n' "$got" | sed 's/^/       /'
    failures=$((failures + 1))
    return 1
}

lines_with() { sed -n "s/^$1 //p" <<<"$2"; }

run_case() {
    local file=$1 name key value folder pattern="app-*.dump" fresh=false validator=case_rejection
    local folder_missing=false want_action="" want_dump="" want_rejected="" want_runs="" decision line
    name=$(basename "$file" .case)
    folder="$scratch/$name"
    volume_is_empty=true
    case_rejections=()
    : >"$probe_log"
    : >"$validator_log"
    local dumps=()
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        if [ -z "$line" ] || [[ $line == \#* ]]; then continue; fi
        key=${line%% *}
        value=${line#* }
        case $key in
            volume) if [ "$value" = empty ]; then volume_is_empty=true; else volume_is_empty=false; fi ;;
            folder) [ "$value" = missing ] && folder_missing=true ;;
            pattern) pattern=$value ;;
            dump) dumps+=("$value") ;;
            validator) [ "$value" = none ] && validator="" ;;
            reject) case_rejections+=("${value%% *}"$'\t'"${value#* }") ;;
            fresh) fresh=$value ;;
            expect-action) want_action=$value ;;
            expect-dump) want_dump=$value ;;
            expect-rejected) want_rejected+="${value%% *}"$'\t'"${value#* }"$'\n' ;;
            expect-validator-runs) want_runs=$value ;;
            *) echo "FAIL $name: unknown key '$key'"; failures=$((failures + 1)); return ;;
        esac
    done <"$file"

    if [ "$folder_missing" = false ]; then
        mkdir -p "$folder"
        local dump
        for dump in "${dumps[@]}"; do head -c "${dump#* }" /dev/zero >"$folder/${dump%% *}"; done
    fi

    decision=$(restore_decision "$volume" "$folder" "$pattern" "$validator" "$fresh")
    check "$name: probed volume" "$volume" "$(cat "$probe_log")" &&
        check "$name: action" "$want_action" "$(lines_with action "$decision")" &&
        check "$name: dump" "$want_dump" "$(lines_with dump "$decision")" &&
        check "$name: rejected" "${want_rejected%$'\n'}" "$(lines_with rejected "$decision")" &&
        { [ -z "$want_runs" ] || check "$name: validator runs" "$want_runs" "$(wc -l <"$validator_log" | tr -d ' ')"; } &&
        echo "ok   $name"
}

expect_true() {
    local name=$1
    shift
    if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}

expect_false() {
    local name=$1
    shift
    if "$@"; then echo "FAIL $name"; failures=$((failures + 1)); else echo "ok   $name"; fi
}

case_count=0
for file in "$here"/cases/*.case; do
    run_case "$file"
    case_count=$((case_count + 1))
done
expect_true "finds the shared cases" test "$case_count" -gt 0

expect_true "a non-zero exit saying no such volume is missing" \
    is_missing_volume_answer 1 "Error response from daemon: get x: no such volume"
expect_true "the answer is read without regard to case" is_missing_volume_answer 1 "Error: No Such Volume"
expect_false "a daemon outage is not missing" is_missing_volume_answer 1 "error during connect: daemon is not running"
expect_false "an empty exit code is not missing" is_missing_volume_answer "" "no such volume"
expect_false "a missing docker binary is not missing" is_missing_volume_answer 127 "docker: command not found"
expect_false "a zero exit code is not missing" is_missing_volume_answer 0 "[]"

dumps="$scratch/dumps"
mkdir -p "$dumps" "$scratch/empty"
head -c 1024 /dev/zero >"$dumps/app-20261019-190000.dump"
head -c 1024 /dev/zero >"$dumps/app-20261019-200000.dump"
: >"$dumps/app-20261019-210000.dump"
head -c 1024 /dev/zero >"$dumps/app-20261019-220000.dump.tmp"
mkdir "$dumps/app-20261019-230000.dump"
check "complete_dumps lists complete dumps, newest first" \
    "app-20261019-200000.dump"$'\n'"app-20261019-190000.dump" "$(complete_dumps "$dumps" "app-*")" &&
    echo "ok   complete_dumps lists complete dumps, newest first"
check "newest_dump takes the newest complete dump" "app-20261019-200000.dump" "$(newest_dump "$dumps" "app-*.dump")" &&
    echo "ok   newest_dump takes the newest complete dump"
check "newest_dump is empty for an empty folder" "" "$(newest_dump "$scratch/empty" "app-*.dump")" &&
    echo "ok   newest_dump is empty for an empty folder"
expect_true "newest_dump succeeds on a missing folder" newest_dump "$scratch/missing" "app-*.dump"

check "a decision prints its action, its dump, then each rejection" \
    "action Restore"$'\n'"dump b.dump"$'\n'"rejected c.dump"$'\t'"why" "$(new_restore_decision Restore b.dump "c.dump"$'\t'"why")" &&
    echo "ok   a decision prints its action, its dump, then each rejection"

volume_is_empty=true
rejecting() { printf 'it holds\nno table data\n'; return 3; }
check "a callback's lines join with spaces and its exit code is ignored" \
    "app-20261019-200000.dump"$'\t'"it holds no table data" \
    "$(lines_with rejected "$(restore_decision "$volume" "$dumps" "app-*.dump" rejecting false)" | head -n 1)" &&
    echo "ok   a callback's lines join with spaces and its exit code is ignored"

reading() { cat >/dev/null; echo "read stdin"; }
check "a callback cannot swallow the dump list on stdin" \
    "2" "$(lines_with rejected "$(restore_decision "$volume" "$dumps" "app-*.dump" reading false)" | wc -l | tr -d ' ')" &&
    echo "ok   a callback cannot swallow the dump list on stdin"

refusal=$(format_restore_refusal "$(restore_decision "$volume" "$dumps" "app-*.dump" rejecting false)" "$volume" "data/backups" "up")
check "the refusal names the volume" \
    "The database volume stack_db is empty, but no dump in data/backups can be restored:" "$(head -n 1 <<<"$refusal")" &&
    echo "ok   the refusal names the volume"
check "the refusal names every rejected dump with its reason" \
    "  app-20261019-200000.dump: it holds no table data"$'\n'"  app-20261019-190000.dump: it holds no table data" \
    "$(grep '^  ' <<<"$refusal")" &&
    echo "ok   the refusal names every rejected dump with its reason"
check "the refusal says how to start fresh with the Linux CLI" \
    "or start with an empty database on purpose: ./docker-compose.sh up --fresh" "$(tail -n 1 <<<"$refusal")" &&
    echo "ok   the refusal says how to start fresh with the Linux CLI"
refusal=$(format_restore_refusal "$(restore_decision "$volume" "$dumps" "app-*.dump" rejecting false)" "$volume" "data/backups" "rebuild" "./run.sh" "--empty")
check "the refusal takes the CLI and flag spelling" \
    "or start with an empty database on purpose: ./run.sh rebuild --empty" "$(tail -n 1 <<<"$refusal")" &&
    echo "ok   the refusal takes the CLI and flag spelling"

[ "$failures" -eq 0 ] && echo "all restore decision checks passed"
[ "$failures" -eq 0 ]
