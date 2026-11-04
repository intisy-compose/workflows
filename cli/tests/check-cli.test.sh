#!/bin/bash
# shellcheck disable=SC2016 # the fixtures are shell and PowerShell source, so their $ stays literal
# Fixture test for check-cli.sh: builds a small stack with both CLIs in a scratch git repository,
# plants one mismatch at a time and asserts the verdicts. Nothing is committed: the index is what
# a commit would record, so the mode is read from it.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check="$here/../check-cli.sh"
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

write_ps1() {
    printf '%s\n' \
        'param([string]$Command = "up")' \
        '$usage = @{' \
        '    "init-config" = "Create config.env"' \
        '    "up"          = "[-Fresh]  start the stack (default)"' \
        '    "down"        = "Stop the stack"' \
        '    "attach"      = "[disk number]  pass a disk through to WSL"' \
        '    "logs"        = "[service]  follow logs"' \
        '}' \
        'switch ($Command.ToLower()) {' \
        '    "up" { Invoke-Up; break }' \
        '    default { Show-Usage -Commands $usage; exit 1 }' \
        '}' >"$demo/docker-compose.ps1"
}

write_sh() {
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'windows_only=(attach)' \
        'data_command() {' \
        '    case "${1:-status}" in' \
        '        status) git status ;;' \
        '        use) git checkout ;;' \
        '    esac' \
        '}' \
        'usage() {' \
        "    cat <<'EOF'" \
        'Usage: ./docker-compose.sh [down|init-config|logs|up]' \
        '  init-config  Create config.env' \
        '  up           [--fresh]  start the stack (default)' \
        '  down         Stop the stack' \
        '  logs         [service]  follow logs' \
        'EOF' \
        '    exit 1' \
        '}' \
        'command=${1:-up}' \
        'case "$command" in' \
        '    init-config) init_config ;;' \
        '    up)          start_stack ;;' \
        '    down)        stop_stack ;;' \
        '    logs)        docker compose logs -f "$@" ;;' \
        '    *)           usage ;;' \
        'esac' >"$demo/docker-compose.sh"
}

stage() {
    git -C "$demo" add -A
    git -C "$demo" update-index --chmod=+x docker-compose.sh
    if [ -e "$demo/scripts/prove-data.sh" ]; then git -C "$demo" update-index --chmod=+x scripts/prove-data.sh; fi
}

new_stack() {
    rm -rf "${scratch:?}"/*
    mkdir -p "$demo/scripts" "$demo/image"
    git init -q "$demo"
    git -C "$demo" config core.autocrlf false
    write_ps1
    write_sh
    printf '#!/usr/bin/env bash\necho prove\n' >"$demo/scripts/prove-data.sh"
    printf '#!/bin/sh\necho entry\n' >"$demo/image/entrypoint.sh"
    stage
}

replace_in() {
    local file=$1 from=$2 to=$3 text
    text=$(cat "$file")
    printf '%s\n' "${text/"$from"/"$to"}" >"$file"
    stage
}

new_stack
expect "conforming stack passes" 0 "all 1 stacks"

new_stack
replace_in "$demo/docker-compose.sh" '    logs)        docker compose logs -f "$@" ;;' ''
replace_in "$demo/docker-compose.sh" '  logs         [service]  follow logs' ''
expect "ps1 command without an sh arm fails" 1 "FAIL demo: docker-compose.ps1 has 'logs', which docker-compose.sh neither dispatches nor lists in windows_only"

new_stack
replace_in "$demo/docker-compose.sh" '    *)           usage ;;' "$(printf '    status)      docker compose ps ;;\n    *)           usage ;;')"
replace_in "$demo/docker-compose.sh" '  down         Stop the stack' "$(printf '  down         Stop the stack\n  status       Show the containers')"
expect "sh arm without a ps1 command fails" 1 "FAIL demo: docker-compose.sh dispatches 'status', which is not in docker-compose.ps1's usage table"

new_stack
replace_in "$demo/docker-compose.sh" 'windows_only=(attach)' 'windows_only=(attach logs)'
expect "a windows_only command the sh dispatches fails" 1 "FAIL demo: 'logs' is in windows_only but docker-compose.sh dispatches it"

new_stack
replace_in "$demo/docker-compose.sh" 'windows_only=(attach)' 'windows_only=(attach mount)'
expect "a windows_only command the ps1 lacks fails" 1 "FAIL demo: 'mount' is in windows_only but not in docker-compose.ps1's usage table"

new_stack
replace_in "$demo/docker-compose.sh" 'windows_only=(attach)' ''
expect "a missing windows_only declaration fails" 1 "FAIL demo: docker-compose.sh declares no windows_only=(...)"

new_stack
replace_in "$demo/docker-compose.sh" 'windows_only=(attach)' 'windows_only=()'
replace_in "$demo/docker-compose.ps1" '    "attach"      = "[disk number]  pass a disk through to WSL"' ''
expect "an empty windows_only declaration is a declaration" 0 "all 1 stacks"

new_stack
replace_in "$demo/docker-compose.sh" '  down         Stop the stack' ''
expect "an arm missing from the usage text fails" 1 "FAIL demo: docker-compose.sh dispatches 'down' but its usage text does not list it"

new_stack
replace_in "$demo/docker-compose.sh" '    init-config) init_config ;;' '    init-config | setup) init_config ;;'
expect "every alternative of an arm is a command" 1 "dispatches 'setup', which is not in docker-compose.ps1's usage table"

new_stack
replace_in "$demo/docker-compose.sh" '    down)        stop_stack ;;' "$(printf '    down)\n        case "${1:-}" in\n            --all) stop_all ;;\n            *) stop_stack ;;\n        esac ;;')"
expect "a case nested in an arm adds no commands" 0 "all 1 stacks"

new_stack
replace_in "$demo/docker-compose.ps1" '$usage = @{' '$commands = @{'
replace_in "$demo/docker-compose.ps1" 'Show-Usage -Commands $usage' 'Show-Usage -Commands $commands'
expect "storage's \$commands table is read like \$usage" 0 "all 1 stacks"

new_stack
printf 'param([string]$Command = "up")\nWrite-Host "Usage: up | down"\n' >"$demo/docker-compose.ps1"
stage
expect "a ps1 without a usage table fails" 1 "FAIL demo: docker-compose.ps1 has no \$usage table"

new_stack
rm "$demo/docker-compose.ps1"
stage
expect "a stack with only the sh compares no commands" 0 "all 1 stacks"

new_stack
printf 'echo crlf\r\n' >>"$demo/docker-compose.sh"
stage
expect "a CR byte in docker-compose.sh fails" 1 "FAIL demo: docker-compose.sh holds 1 CR bytes"

new_stack
printf 'echo crlf\r\n' >>"$demo/image/entrypoint.sh"
stage
expect "a CR byte in any committed .sh fails" 1 "FAIL demo: image/entrypoint.sh holds 1 CR bytes"

new_stack
git -C "$demo" update-index --chmod=-x docker-compose.sh
expect "docker-compose.sh without the executable bit fails" 1 "FAIL demo: docker-compose.sh is committed as 100644, not 100755"

new_stack
git -C "$demo" update-index --chmod=-x scripts/prove-data.sh
expect "a scripts/*.sh without the executable bit fails" 1 "FAIL demo: scripts/prove-data.sh is committed as 100644, not 100755"

new_stack
printf '#!/usr/bin/env bash\n' >"$demo/scripts/new.sh"
expect "an uncommitted scripts/*.sh fails" 1 "FAIL demo: scripts/new.sh is not committed"

new_stack
rm -rf "$demo/.git"
expect "a stack that is not a git checkout fails" 1 "FAIL demo: is not a git checkout"

rm -rf "${scratch:?}"/*
mkdir -p "$demo"
printf 'param([string]$Command = "up")\n' >"$demo/docker-compose.ps1"
expect "a stack without docker-compose.sh passes" 0 "no stack has a docker-compose.sh"

rm -rf "${scratch:?}"/*
expect "an empty root fails" 1 "holds no *-compose repo"

[ "$failures" -eq 0 ] && echo "all cases passed"
[ "$failures" -eq 0 ]
