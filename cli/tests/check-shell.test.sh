#!/bin/bash
# shellcheck disable=SC2016 # the fixtures are shell source, so their $ stays literal
# Fixture test for check-shell.sh: builds small stacks in a scratch folder, plants one finding at a
# time and asserts the verdicts. Needs the pinned shellcheck, or SHELLCHECK naming a wrapper around it.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check="$here/../check-shell.sh"
pinned_version=$(sed -n 's/^version //p' "$here/../shellcheck.pin")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
demo="$scratch/demo-compose"

failures=0
# expect NAME STATUS TEXT [SHELLCHECK]: the check's exit code is STATUS and its output holds TEXT.
expect() {
    local name=$1 want_status=$2 want_text=$3 output status
    output=$(SHELLCHECK=${4:-${SHELLCHECK:-shellcheck}} bash "$check" "$scratch" 2>&1)
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
expect "stack without shell scripts passes" 0 "no stack has a shell script to check"

new_stack
write_clean_cli
expect "clean CLI and sourced helper pass" 0 "all 1 stacks with shell scripts are clean under shellcheck $pinned_version -x"

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
write_clean_cli
mkdir -p "$demo/tests/cli"
printf '%s\n' '#!/bin/bash' 'echo $1' >"$demo/tests/cli/run.sh"
expect "finding in tests/cli/*.sh fails" 1 "In tests/cli/run.sh line 2"

new_stack
write_clean_cli
mkdir -p "$demo/tests/cli/fakes"
printf '%s\n' '#!/usr/bin/env bash' 'echo $1' >"$demo/tests/cli/fakes/docker"
expect "finding in a fake without an extension fails" 1 "In tests/cli/fakes/docker line 2"

new_stack
mkdir -p "$demo/tests"
printf '%s\n' '#!/bin/bash' 'echo $1' >"$demo/tests/other.sh"
expect "scripts outside the CLI, scripts/ and tests/cli/ are not checked" 0 "no stack has a shell script to check"

rm -rf "${scratch:?}"/*
expect "a root without stacks fails" 1 "holds no *-compose repo"

new_stack
write_clean_cli
expect "a missing shellcheck fails" 1 "no-such-shellcheck is not installed" no-such-shellcheck

new_stack
write_clean_cli
printf '%s\n' '#!/bin/bash' 'echo "version: 0.9.0"' >"$scratch/old-shellcheck"
chmod +x "$scratch/old-shellcheck"
expect "a shellcheck other than the pinned version fails" 1 \
    "is version 0.9.0, not the pinned $pinned_version" "$scratch/old-shellcheck"

[ "$failures" -eq 0 ]
