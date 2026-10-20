#!/bin/bash
# Fixture test for check-volumes.sh: builds small stacks in a scratch folder and asserts the verdicts.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check="$here/../check-volumes.sh"
shared="$here/../data-on-disk.ps1"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

failures=0
expect() {
    local name=$1 want_status=$2 want_text=$3 output status
    output=$(bash "$check" "$scratch" 2>&1)
    status=$?
    if [ "$status" -eq "$want_status" ] && { [ -z "$want_text" ] || grep -qF -- "$want_text" <<<"$output"; }; then
        echo "ok   $name"
    else
        echo "FAIL $name: exit $status, wanted $want_status containing '$want_text'"
        echo "$output" | sed 's/^/     /'
        failures=$((failures + 1))
    fi
}

new_stack() {
    rm -rf "$scratch"/*
    mkdir -p "$scratch/demo-compose/scripts"
}

new_stack
printf 'volumes:\n  demo-db:\n  demo-cache:\n' >"$scratch/demo-compose/docker-compose.yml"
printf 'x-volume-roles:\n  demo-db: rebuilt\n' >>"$scratch/demo-compose/docker-compose.yml"
expect "volume without a role fails" 1 "FAIL demo: volume 'demo-cache' has no role"

new_stack
printf 'x-volume-roles:\n  demo-db: precious\nvolumes:\n  demo-db:\n' >"$scratch/demo-compose/docker-compose.yml"
expect "role outside the allowed set fails" 1 "FAIL demo: volume 'demo-db' has role 'precious'"

new_stack
printf 'x-volume-roles:\n  demo-db: dumped\nvolumes:\n  demo-db:\n' >"$scratch/demo-compose/docker-compose.yml"
echo "# drifted" >"$scratch/demo-compose/scripts/data-on-disk.ps1"
expect "differing helper copy fails" 1 "differs from data-on-disk/data-on-disk.ps1"

new_stack
printf 'x-volume-roles:\n  demo-db: dumped\nvolumes:\n  demo-db:\n' >"$scratch/demo-compose/docker-compose.yml"
expect "dumped volume without a helper copy fails" 1 "FAIL demo: has a dumped volume but no scripts/data-on-disk.ps1"

new_stack
printf 'x-volume-roles:\n  demo-db: rebuilt\nvolumes:\n  demo-db:\n' >"$scratch/demo-compose/docker-compose.yml"
echo "# drifted" >"$scratch/demo-compose/scripts/data-on-disk.ps1"
expect "differing helper copy fails whatever the roles" 1 "differs from data-on-disk/data-on-disk.ps1"

new_stack
printf 'x-volume-roles:\n  demo-db: dumped\n  demo-cache: rebuilt\n  demo-state: self-restored\nvolumes:\n  demo-db:\n  demo-cache:\n  demo-state:\n' >"$scratch/demo-compose/docker-compose.yml"
cp "$shared" "$scratch/demo-compose/scripts/data-on-disk.ps1"
expect "complete stack passes" 0 "all 1 stacks"

new_stack
printf 'x-volume-roles:\n  demo-db: rebuilt\nvolumes:\n  demo-db:\n' >"$scratch/demo-compose/docker-compose.base.yml"
printf 'include:\n  - docker-compose.base.yml\nservices:\n  extra:\n    volumes:\n      - ./x:/x\n' >"$scratch/demo-compose/docker-compose.gpu.yml"
expect "variant files add no volumes and break nothing" 0 "all 1 stacks"

new_stack
printf 'services:\n  app:\n    volumes:\n      - ./data:/data\n' >"$scratch/demo-compose/docker-compose.yml"
expect "stack without named volumes passes" 0 "all 1 stacks"

[ "$failures" -eq 0 ] && echo "all fixture checks passed"
[ "$failures" -eq 0 ]
