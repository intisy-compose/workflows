#!/bin/bash
# check-volumes.sh [compose root]: every named volume of every <thing>-compose stack declares its role
# (rebuilt | dumped | self-restored) under the top-level x-volume-roles, and every vendored
# scripts/data-on-disk.ps1 and scripts/data-on-disk.sh is byte-identical to the shared one. A stack
# with a dumped volume vendors the ps1; one that also has a docker-compose.sh and vendors the ps1
# vendors the sh too. Exits non-zero and names each violation.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/../.." && pwd)}
shared="$here/data-on-disk.ps1"
shared_sh="$here/data-on-disk.sh"

failures=0
checked=0
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

# block_entries KEY FILE: prints "name value" for each entry at two-space indent under the top-level KEY.
block_entries() {
    local key=$1 file=$2
    tr -d '\r' <"$file" | awk -v key="$key" '
        /^[^[:space:]#]/ { inside = ($0 == key ":"); next }
        inside && /^  [^[:space:]#]/ {
            line = substr($0, 3)
            name = line; sub(/:.*/, "", name)
            value = line; sub(/^[^:]*:[[:space:]]*/, "", value); sub(/[[:space:]]*(#.*)?$/, "", value)
            print name, value
        }'
}

for repo in "$root"/*-compose; do
    stack=$(basename "$repo" -compose)
    compose_files=("$repo"/docker-compose*.yml)
    [ -e "${compose_files[0]}" ] || continue
    checked=$((checked + 1))

    declared=" "
    for file in "${compose_files[@]}"; do
        while read -r name _; do
            declared+="$name "
        done < <(block_entries volumes "$file")
    done

    roles=()
    has_dumped=false
    for file in "${compose_files[@]}"; do
        while read -r name role; do
            roles+=("$name")
            case $role in
                rebuilt | self-restored) ;;
                dumped) has_dumped=true ;;
                *) fail "$stack" "volume '$name' has role '$role', not rebuilt, dumped or self-restored" ;;
            esac
        done < <(block_entries x-volume-roles "$file")
    done

    for name in $declared; do
        [[ " ${roles[*]-} " == *" $name "* ]] || fail "$stack" "volume '$name' has no role"
    done

    copy="$repo/scripts/data-on-disk.ps1"
    if [ -e "$copy" ]; then
        cmp -s "$copy" "$shared" || fail "$stack" "scripts/data-on-disk.ps1 differs from data-on-disk/data-on-disk.ps1"
    elif $has_dumped; then
        fail "$stack" "has a dumped volume but no scripts/data-on-disk.ps1"
    fi

    copy_sh="$repo/scripts/data-on-disk.sh"
    if [ -e "$copy_sh" ]; then
        cmp -s "$copy_sh" "$shared_sh" || fail "$stack" "scripts/data-on-disk.sh differs from data-on-disk/data-on-disk.sh"
    elif [ -e "$repo/docker-compose.sh" ] && { [ -e "$copy" ] || $has_dumped; }; then
        fail "$stack" "has a docker-compose.sh but no scripts/data-on-disk.sh"
    fi
done

[ "$checked" -gt 0 ] || fail "$root" "holds no *-compose repo with a compose file, so nothing was checked"
[ "$failures" -eq 0 ] && echo "all $checked stacks declare every volume's role and carry the shared data-on-disk helper"
[ "$failures" -eq 0 ]
