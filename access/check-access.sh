#!/bin/bash
# check-access.sh [compose root]: checks every *-compose repo against the port table in PORTS.md
# beside this file (or $PORTS_TABLE) and the shared gateway in ../gateway. Exits non-zero and names
# each violation.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/../.." && pwd)}
table=${PORTS_TABLE:-$here/PORTS.md}
template="$here/../gateway"
vendored_files="Caddyfile gateway.yml tailscale.sh"
funnel_capable_ports=" 443 8443 10000 "

failures=0
checked=0
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

# "stack kind tailnet host" for every row of the port table; read once into $rows.
table_rows() {
    tr -d '\r' <"$table" | awk -F'|' 'NF == 7 {
        for (i = 2; i <= 6; i++) gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", $i)
        if ($4 ~ /^(web|api|protocol|public)$/) print $2, $4, $5, $6
    }'
}

# The stacks named on the "<label>:" line of PORTS.md, space separated.
listed_stacks() {
    tr -d '\r' <"$table" | sed -n "s/^$1:[[:space:]]*//p" | sed 's/\..*//' | grep -oE '`[a-z0-9-]+`' | tr -d '`' | tr '\n' ' '
}

# True when the port spec ("-", "N" or "N-M") holds the port.
spec_holds() {
    local spec=$1 port=$2
    [ "$spec" != - ] || return 1
    if [[ $spec == *-* ]]; then
        [ "$port" -ge "${spec%-*}" ] && [ "$port" -le "${spec#*-}" ]
    else
        [ "$port" = "$spec" ]
    fi
}

# The kind the table gives a stack's port in the tailnet or host column, or nothing.
kind_of() {
    local stack=$1 column=$2 port=$3 row_stack kind tailnet host spec
    while read -r row_stack kind tailnet host; do
        [ "$row_stack" = "$stack" ] || continue
        spec=$tailnet
        [ "$column" = host ] && spec=$host
        spec_holds "$spec" "$port" && { echo "$kind"; return; }
    done <<<"$rows"
}

# "service<TAB>mapping" for every item under a service's `ports:` key.
published_ports() {
    tr -d '\r' <"$1" | awk '
        /^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top); service = top; inside = 0; next }
        top == "services" && /^  [^[:space:]#][^:]*:/ { service = substr($0, 3); sub(/:.*/, "", service); inside = 0; next }
        /^[[:space:]]*ports:[[:space:]]*$/ { inside = 1; indent = match($0, /[^ ]/); next }
        inside && /^[[:space:]]*#/ { next }
        inside && /^[[:space:]]*-/ { line = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", line); gsub(/["\047]/, "", line); print service "\t" line; next }
        inside && match($0, /[^ ]/) <= indent { inside = 0 }
    '
}

# "address imports_tailnet sets_tls" for every top-level block of a Caddyfile.
caddy_sites() {
    tr -d '\r' <"$1" | awk '
        /^[[:space:]]*(#|$)/ { next }
        depth == 0 && /\{[[:space:]]*$/ { address = $0; sub(/[[:space:]]*\{[[:space:]]*$/, "", address); tailnet = 0; tls = 0 }
        depth == 1 && /^[[:space:]]*import[[:space:]]+tailnet[[:space:]]*$/ { tailnet = 1 }
        /^[[:space:]]*tls([[:space:]]|\{|$)/ { tls = 1 }
        { opened = gsub(/\{/, "{"); closed = gsub(/\}/, "}"); depth += opened - closed }
        depth == 0 && (opened || closed) { print (address == "" ? "<global>" : address), tailnet, tls }
    '
}

# Adds the tailnet ports a tailscale serve config forwards to serve_found; a bad entry fails the stack.
collect_serve_ports() {
    local stack=$1 file=$2 name entries forwards port
    name="gateway/$(basename "$file")"
    if grep -qE '"(HTTPS|Web|Handlers|Proxy)"' "$file"; then
        fail "$stack" "$name terminates TLS in tailscale instead of forwarding TCP to the gateway"
    fi
    entries=$(grep -oE '"[0-9]+"[[:space:]]*:' "$file" | grep -oE '[0-9]+')
    forwards=$(grep -oE '"[0-9]+"[[:space:]]*:[[:space:]]*\{[[:space:]]*"TCPForward"[[:space:]]*:[[:space:]]*"127\.0\.0\.1:[0-9]+"' "$file" |
        sed -E 's/^"([0-9]+)".*:([0-9]+)"$/\1 \2/')
    for port in $entries; do
        grep -qxE "$port $port" <<<"$forwards" ||
            fail "$stack" "$name port $port is not a TCPForward to 127.0.0.1:$port"
        serve_found+=" $port "
    done
}

# Resolves ${VAR:-default} to its default and prints "address host_port container_port".
parse_mapping() {
    local mapping parts
    mapping=$(sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:?-([^}]*)\}/\1/g; s#/(tcp|udp)$##' <<<"$1")
    [[ $mapping != *'$'* && $mapping =~ ^[0-9.:-]+$ ]] || return 1
    IFS=: read -ra parts <<<"$mapping"
    case ${#parts[@]} in
        3) echo "${parts[0]} ${parts[1]} ${parts[2]}" ;;
        2) echo "0.0.0.0 ${parts[0]} ${parts[1]}" ;;
        *) return 1 ;;
    esac
}

# Every port of every range "N" or "N-M", one per line.
expand_ports() {
    local spec=$1
    if [[ $spec == *-* ]]; then seq "${spec%-*}" "${spec#*-}"; else echo "$spec"; fi
}

check_published_port() {
    local stack=$1 service=$2 address=$3 host_port=$4 container_port=$5 kind
    kind=$(kind_of "$stack" host "$host_port")
    case $kind in
        "") fail "$stack" "$service publishes host port $host_port, which is not in PORTS.md" ;;
        web)
            [ "$service" = gateway ] || fail "$stack" "$service publishes web port $host_port; only the gateway may"
            [ "$address" = 127.0.0.1 ] && [ "$host_port" = "$container_port" ] ||
                fail "$stack" "web port $host_port is not published as 127.0.0.1:$host_port:$host_port"
            ;;
        api) [ "$address" = 127.0.0.1 ] || fail "$stack" "$service publishes api port $host_port on more than 127.0.0.1" ;;
        public) [[ " $public_stacks " == *" $stack "* ]] || fail "$stack" "publishes public port $host_port but is not a public stack" ;;
    esac
}

check_ports() {
    local stack=$1 file service mapping parsed address host_port container_port port
    shift
    published=""
    for file in "$@"; do
        while IFS=$'\t' read -r service mapping; do
            if ! parsed=$(parse_mapping "$mapping"); then
                fail "$stack" "$service maps '$mapping'; use the short form address:host:container with fixed or defaulted ports"
                continue
            fi
            read -r address host_port container_port <<<"$parsed"
            for port in $(expand_ports "$host_port"); do
                published+="$service $address $port "$'\n'
                check_published_port "$stack" "$service" "$address" "$port" "$container_port"
            done
        done < <(published_ports "$file")
    done
}

# The table itself: kinds where they belong, and no row the stack does not use.
check_table_rows() {
    local stack=$1 row_stack kind tailnet host
    while read -r row_stack kind tailnet host; do
        [ "$row_stack" = "$stack" ] || continue
        case $kind in
            web) [ "$host" != - ] || fail "$stack" "PORTS.md gives a web row no host port; a web UI is also on 127.0.0.1" ;;
            api) [ "$tailnet" = - ] || fail "$stack" "PORTS.md puts api port $host on the tailnet" ;;
            protocol) [ "$host" = - ] || fail "$stack" "PORTS.md publishes protocol port $host on the host" ;;
            public) [[ " $public_stacks " == *" $stack "* ]] || fail "$stack" "PORTS.md has a public row but the stack is not a public stack" ;;
        esac
        if [ "$host" != - ] && [[ $host != *-* ]] && ! grep -qE " $host \$" <<<"$published"; then
            fail "$stack" "PORTS.md lists host port $host but no compose file publishes it"
        fi
    done <<<"$rows"
}

stack_needs_gateway() {
    local stack=$1 row_stack kind tailnet host
    while read -r row_stack kind tailnet host; do
        [ "$row_stack" = "$stack" ] && [[ $kind == web || $tailnet != - ]] && return 0
    done <<<"$rows"
    return 1
}

check_vendored_gateway() {
    local stack=$1 repo=$2 file
    for file in $vendored_files; do
        if [ ! -e "$repo/gateway/$file" ]; then
            fail "$stack" "gateway/$file is missing; vendor it from workflows gateway/"
        elif ! cmp -s "$repo/gateway/$file" "$template/$file"; then
            fail "$stack" "gateway/$file differs from workflows gateway/$file"
        fi
    done
    for file in sites.caddy serve.json; do
        [ -e "$repo/gateway/$file" ] || fail "$stack" "gateway/$file is missing"
    done
    for service in gateway tailscale; do
        grep -qE "extends:.*file:[[:space:]]*gateway/gateway\.yml.*service:[[:space:]]*$service\b" "${compose_files[@]}" ||
            fail "$stack" "service $service does not extend gateway/gateway.yml"
    done
}

check_gateway() {
    local stack=$1 repo=$2 file port kind address imports_tailnet tls tailnet_sites="" local_sites="" row_stack tailnet host
    if grep -qE '^[[:space:]]*image:[[:space:]]*["\047]?(caddy|tailscale/tailscale)[:@]' "${compose_files[@]}"; then
        fail "$stack" "runs its own caddy or tailscale; extend gateway/gateway.yml instead"
    fi
    stack_needs_gateway "$stack" || [ -d "$repo/gateway" ] || return 0
    check_vendored_gateway "$stack" "$repo"
    [ -e "$repo/gateway/sites.caddy" ] && [ -e "$repo/gateway/serve.json" ] || return 0

    if grep -qE 'TS_SERVE_CONFIG|/config/serve\.json|/config/tailscale\.sh' "${compose_files[@]}"; then
        fail "$stack" "overrides the template's serve config; PUBLIC_ACCESS is the only Funnel switch"
    fi
    serve_found=""
    for file in "$repo"/gateway/*.json; do
        grep -q '"AllowFunnel"' "$file" &&
            fail "$stack" "gateway/$(basename "$file") opens Funnel itself; PUBLIC_ACCESS in config.env is the only Funnel switch"
        collect_serve_ports "$stack" "$file"
    done
    [ "$(grep -v '^[[:space:]]*$' "$repo/gateway/serve.json" | tail -n 2 | tr -d '[:space:]')" = "}}" ] ||
        fail "$stack" "gateway/serve.json does not end with the TCP block's '  }' and the closing '}' the template's tailscale.sh extends"

    while read -r address imports_tailnet tls; do
        [ "$tls" = 0 ] || fail "$stack" "sites.caddy sets tls itself; certificates come only from 'import tailnet'"
        if [[ $address =~ ^\{\$TAILNET_HOST\}:([0-9]+)$ ]]; then
            port=${BASH_REMATCH[1]}
            tailnet_sites+=" $port"
            [ "$imports_tailnet" = 1 ] || fail "$stack" "tailnet site :$port does not 'import tailnet'"
            [[ $serve_found == *" $port "* ]] || fail "$stack" "tailnet site :$port is not forwarded in serve.json"
        elif [[ $address =~ ^http://:([0-9]+)$ ]]; then
            local_sites+=" ${BASH_REMATCH[1]} "
        elif [[ $address != \(* ]]; then
            fail "$stack" "sites.caddy has the site '$address', neither {\$TAILNET_HOST}:<port> nor http://:<port>"
        fi
    done < <(caddy_sites "$repo/gateway/sites.caddy")

    for port in $(tr ' ' '\n' <<<"$serve_found" | sort -un); do
        kind=$(kind_of "$stack" tailnet "$port")
        case $kind in
            web) [[ " $tailnet_sites " == *" $port "* ]] || fail "$stack" "web port $port is forwarded on the tailnet but has no {\$TAILNET_HOST}:$port site" ;;
            protocol)
                [[ $funnel_capable_ports != *" $port "* ]] ||
                    fail "$stack" "protocol port $port is one Funnel carries; PUBLIC_ACCESS would open it to the internet"
                ;;
            *) fail "$stack" "forwards tailnet port $port, which is not a web or protocol port in PORTS.md" ;;
        esac
    done

    while read -r row_stack kind tailnet host; do
        [ "$row_stack" = "$stack" ] || continue
        if [ "$tailnet" != - ] && [[ $tailnet != *-* ]] && [[ $serve_found != *" $tailnet "* ]]; then
            fail "$stack" "PORTS.md lists tailnet port $tailnet but serve.json does not forward it"
        fi
        if [ "$kind" = web ] && [ "$host" != - ]; then
            [[ $local_sites == *" $host "* ]] || fail "$stack" "web port $host has no http://:$host site in sites.caddy"
        fi
    done <<<"$rows"
}

rows=$(table_rows)
public_stacks=$(listed_stacks "Public stacks")

for repo in "$root"/*-compose; do
    stack=$(basename "$repo" -compose)
    compose_files=("$repo"/docker-compose*.yml)
    [ -e "${compose_files[0]}" ] || continue
    checked=$((checked + 1))

    check_ports "$stack" "${compose_files[@]}"
    check_table_rows "$stack"
    check_gateway "$stack" "$repo"
done

[ "$checked" -gt 0 ] || fail "$root" "holds no *-compose repo with a compose file, so nothing was checked"
[ "$failures" -eq 0 ] && echo "all $checked stacks publish only the ports in PORTS.md, each where its kind allows, through the shared gateway"
exit $((failures > 0))
