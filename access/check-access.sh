#!/bin/bash
# check-access.sh [compose root]: checks every *-compose repo against the dashboard access standard
# (intisy-compose/docs specs/2026-10-16-dashboard-access.md, ports in PORTS.md beside this file).
# Exits non-zero and names each violation.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/../.." && pwd)}
spec="$here/PORTS.md"

# Game ports are game protocols for players, not dashboards; shelf is stopped and must not change.
exempt="game shelf"

failures=0
checked=0
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

is_exempt() { [[ " $exempt " == *" $1 "* ]]; }

# The local ports the spec's table gives a stack, one per line.
table_ports() {
    awk -F'|' -v stack="$1" '$2 ~ "^ *" stack " *$" {print $5}' "$spec" | grep -oE 'localhost:[0-9]+' | cut -d: -f2
}

# Every port mapping under a `ports:` key, as written.
published_ports() {
    awk '
        /^[[:space:]]*ports:[[:space:]]*$/ { inside = 1; indent = match($0, /[^ ]/); next }
        inside && /^[[:space:]]*-/ { line = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", line); gsub(/"/, "", line); print line; next }
        inside && match($0, /[^ ]/) <= indent { inside = 0 }
    ' "$@"
}

for repo in "$root"/*-compose; do
    stack=$(basename "$repo" -compose)
    is_exempt "$stack" && continue
    compose_files=("$repo"/docker-compose*.yml)
    [ -e "${compose_files[0]}" ] || continue
    checked=$((checked + 1))

    while read -r mapping; do
        [ -n "$mapping" ] || continue
        [[ $mapping == 127.0.0.1:* ]] || fail "$stack" "publishes $mapping on more than loopback"
    done < <(published_ports "${compose_files[@]}")

    caddyfile="$repo/gateway/Caddyfile"
    [ -f "$caddyfile" ] || continue
    grep -qE '^\{\$[A-Z_]+_HOST\}:443' "$caddyfile" || continue

    local_ports=$(grep -oE '^http://:[0-9]+' "$caddyfile" | cut -d: -f3)
    [ -n "$local_ports" ] || fail "$stack" "has a tailnet site but no http://:<port> site for localhost"
    for port in $local_ports; do
        published_ports "${compose_files[@]}" | grep -qxF "127.0.0.1:$port:$port" ||
            fail "$stack" "serves localhost:$port but does not publish 127.0.0.1:$port:$port"
        table_ports "$stack" | grep -qxF "$port" ||
            fail "$stack" "localhost:$port is missing from the port table in $(basename "$spec")"
    done
done

[ "$checked" -gt 0 ] || fail "$root" "holds no *-compose repo with a compose file, so nothing was checked"
[ "$failures" -eq 0 ] && echo "all $checked stacks serve their dashboards on the tailnet and on localhost only"
exit $((failures > 0))
