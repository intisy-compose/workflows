#!/bin/bash
# shellcheck disable=SC2016 # the fixtures are shell source, so their $ stays literal
# Fixture test for check-shell.sh: builds small stacks in a scratch folder, plants one finding at a
# time and asserts the verdicts. Needs shellcheck, or SHELLCHECK naming a wrapper around one.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check="$here/../check-shell.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
demo="$scratch/demo-compose"

failures=0
expect() {
    local name=$1 want_status=$2 want_text=$3 output status
    output=$(bash "$check" "$scratch" 2>&1)
    status=$?
    if [ "$status" -eq "$want_status" ] && { [ -z "$want_text" ] || grep -qF -- "$want_text" <<<"$output"; }; then
        echo "ok   $name"
    else
        echo "FAIL $name: exit $status, wanted $want_status containing '$want_text'"
        printf '     %s\n' "${output//$'\n'/$'\n'     }"
        failures=$((failures + 1))
    fi
}

new_stack() {
    rm -rf "${scratch:?}"/*
    mkdir -p "$demo/scripts"
}

write_clean_cli() {
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'here=$(cd "$(dirname "$0")" && pwd)' \
        '# shellcheck source=scripts/helper.sh' \
        '. "$here/scripts/helper.sh"' \
        'greet "${1:-world}"' >"$demo/docker-compose.sh"
    printf '%s\n' \
        '#!/bin/bash' \
        'greet() { echo "hello $1"; }' >"$demo/scripts/helper.sh"
}

new_stack
expect "stack without shell scripts passes" 0 "nothing to check"

new_stack
write_clean_cli
expect "clean CLI and sourced helper pass" 0 "all 1 stacks"

new_stack
write_clean_cli
printf '%s\n' '#!/bin/bash' 'greet() { echo hello $1; }' >"$demo/scripts/helper.sh"
expect "finding in a scripts/*.sh fails" 1 "FAIL demo: shellcheck -x reports findings"

new_stack
write_clean_cli
printf '%s\n' '#!/usr/bin/env bash' 'for file in $(ls); do echo $file; done' >"$demo/docker-compose.sh"
expect "finding in docker-compose.sh fails" 1 "SC2045"

new_stack
write_clean_cli
printf '%s\n' '#!/bin/bash' 'greet() { echo "hello $1"; }' 'unused=1' >"$demo/scripts/helper.sh"
expect "a finding in a sourced helper fails" 1 "SC2034"

new_stack
mkdir -p "$demo/tests"
printf '%s\n' '#!/bin/bash' 'echo $1' >"$demo/tests/other.sh"
expect "scripts outside docker-compose.sh and scripts/ are not checked" 0 "nothing to check"

rm -rf "${scratch:?}"/*
expect "a root without stacks fails" 1 "holds no *-compose repo"

new_stack
write_clean_cli
output=$(SHELLCHECK=no-such-shellcheck bash "$check" "$scratch" 2>&1)
status=$?
if [ "$status" -eq 1 ] && grep -qF "no-such-shellcheck is not installed" <<<"$output"; then
    echo "ok   a missing shellcheck fails"
else
    echo "FAIL a missing shellcheck fails: exit $status"
    printf '     %s\n' "${output//$'\n'/$'\n'     }"
    failures=$((failures + 1))
fi

[ "$failures" -eq 0 ]
