#!/bin/bash
# check-shell.sh [compose root]: the docker-compose.sh and scripts/*.sh of every <thing>-compose stack
# are clean under `shellcheck -x` at its default severity, run from the stack's root so a
# `# shellcheck source=scripts/...` directive resolves. SHELLCHECK names another binary or wrapper.
# A stack with none of these files passes. Exits non-zero and names each stack that fails.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/../.." && pwd)}
shellcheck=${SHELLCHECK:-shellcheck}

failures=0
stacks=0
checked=0
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

# stack_scripts REPO: the stack's own shell scripts, relative to REPO, one per line.
stack_scripts() {
    local repo=$1 file
    for file in "$repo"/docker-compose.sh "$repo"/scripts/*.sh; do
        [ -f "$file" ] && printf '%s\n' "${file#"$repo"/}"
    done
}

if ! command -v "$shellcheck" >/dev/null 2>&1; then
    fail "$root" "$shellcheck is not installed, so no script was checked"
    exit 1
fi

for repo in "$root"/*-compose; do
    [ -d "$repo" ] || continue
    stacks=$((stacks + 1))
    mapfile -t scripts < <(stack_scripts "$repo")
    [ ${#scripts[@]} -gt 0 ] || continue
    stack=$(basename "$repo" -compose)
    checked=$((checked + 1))
    if ! output=$(cd "$repo" && "$shellcheck" -x "${scripts[@]}" 2>&1); then
        fail "$stack" "shellcheck -x reports findings in ${scripts[*]}"
        printf '     %s\n' "${output//$'\n'/$'\n'     }"
    fi
done

[ "$stacks" -gt 0 ] || fail "$root" "holds no *-compose repo, so nothing was checked"
if [ "$failures" -eq 0 ]; then
    if [ "$checked" -eq 0 ]; then echo "no stack has a docker-compose.sh or scripts/*.sh, so there is nothing to check"
    else echo "all $checked stacks with shell scripts are clean under shellcheck -x"
    fi
fi
[ "$failures" -eq 0 ]
