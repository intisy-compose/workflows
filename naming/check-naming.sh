#!/bin/bash
# check-naming.sh [compose root]: every <thing>-compose repo runs as the Docker Compose project
# <thing>-compose (the folder name, or a `name:` that repeats it), and every container is <thing>-<role>.
# Exits non-zero and names each violation.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/../.." && pwd)}

failures=0
checked=0
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

for repo in "$root"/*-compose; do
    stack=$(basename "$repo" -compose)
    compose_files=("$repo"/docker-compose*.yml)
    [ -e "${compose_files[0]}" ] || continue
    checked=$((checked + 1))

    while read -r project; do
        [ "$project" = "$stack-compose" ] || fail "$stack" "is named '$project' instead of '$stack-compose'"
    done < <(sed -n 's/^name:[[:space:]]*//p' "${compose_files[@]}" | tr -d "\"'\r")

    while read -r container; do
        [[ $container == "$stack"-?* ]] || fail "$stack" "container '$container' is not $stack-<role>"
    done < <(sed -n 's/^[[:space:]]*container_name:[[:space:]]*//p' "${compose_files[@]}" | tr -d "\"'\r")
done

[ "$checked" -gt 0 ] || fail "$root" "holds no *-compose repo with a compose file, so nothing was checked"
[ "$failures" -eq 0 ] && echo "all $checked stacks are <thing>-compose projects with <thing>-<role> containers"
[ "$failures" -eq 0 ]
