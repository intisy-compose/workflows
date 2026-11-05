#!/bin/bash
# check-access.sh [compose root]: checks every *-compose repo against the port table in PORTS.md
# beside this file (or $PORTS_TABLE) and the shared gateway in ../gateway. Exits non-zero and names
# each violation.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=${1:-$(cd "$here/../.." && pwd)}
table=${PORTS_TABLE:-$here/PORTS.md}
template=${GATEWAY_TEMPLATE:-$here/../gateway}
vendored_files="Caddyfile gateway.yml gateway.sh namespace-address.sh tailscale.sh tailnet-node.sh tailnet-node.ps1"
funnel_capable_ports=" 443 8443 10000 "

failures=0
checked=0
fail() { echo "FAIL $1: $2"; failures=$((failures + 1)); }

# "stack kind tailnet host" for every row of the port table; read once into $rows.
table_rows() {
    tr -d '\r' <"$table" | awk -F'|' 'NF == 7 {
        for (i = 2; i <= 6; i++) gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", $i)
        if ($4 != "kind" && $4 !~ /^-+$/) print $2, $4, $5, $6
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

# "address imports_tailnet sets_tls bind" for every top-level block of a Caddyfile, where bind is the
# block's first `bind` or `default_bind` line joined by commas, or "-".
caddy_sites() {
    tr -d '\r' <"$1" | awk '
        /^[[:space:]]*(#|$)/ { next }
        depth == 0 && /\{[[:space:]]*$/ { address = $0; sub(/[[:space:]]*\{[[:space:]]*$/, "", address); tailnet = 0; tls = 0; bind = "-" }
        depth == 1 && /^[[:space:]]*import[[:space:]]+tailnet[[:space:]]*$/ { tailnet = 1 }
        /^[[:space:]]*tls([[:space:]]|\{|$)/ { tls = 1 }
        bind == "-" && /^[[:space:]]*(default_)?bind([[:space:]]|$)/ { bind = $0; sub(/^[[:space:]]+/, "", bind); gsub(/[[:space:]]+/, ",", bind) }
        { opened = gsub(/\{/, "{"); closed = gsub(/\}/, "}"); depth += opened - closed }
        depth == 0 && (opened || closed) { print (address == "" ? "<global>" : address), tailnet, tls, bind }
    '
}

# The template binds every http://:<port> site to the namespace's Docker network addresses and every
# tailnet site to 127.0.0.1, because tailscale in userspace mode hands each tailnet connection to a
# port serve.json does not forward to 127.0.0.1 of this namespace: a local site listening there would
# answer on the tailnet.
check_template_binding() {
    local address imports_tailnet tls bind global_bind="" tailnet_bind=""
    while read -r address imports_tailnet tls bind; do
        [ "$address" = "<global>" ] && global_bind=$bind
        [ "$address" = "(tailnet)" ] && tailnet_bind=$bind
    done < <(caddy_sites "$template/Caddyfile")
    [ "$global_bind" = 'default_bind,{$GATEWAY_LOCAL_ADDRESSES}' ] ||
        fail gateway "workflows gateway/Caddyfile does not set 'default_bind {\$GATEWAY_LOCAL_ADDRESSES}', so local sites listen on 127.0.0.1 and the tailnet reaches them"
    [ "$tailnet_bind" = "bind,127.0.0.1" ] ||
        fail gateway "workflows gateway/Caddyfile's (tailnet) snippet does not 'bind 127.0.0.1', where serve.json forwards"
    grep -qE '^[[:space:]]*entrypoint:[[:space:]]*\["/bin/sh",[[:space:]]*"/etc/caddy/gateway\.sh"\]' "$template/gateway.yml" ||
        fail gateway "workflows gateway/gateway.yml does not start the gateway through gateway.sh, which sets GATEWAY_LOCAL_ADDRESSES"
    grep -qE '^[[:space:]]*-[[:space:]]*\./namespace-address\.sh:/etc/caddy/namespace-address\.sh:ro[[:space:]]*$' "$template/gateway.yml" ||
        fail gateway "workflows gateway/gateway.yml does not mount namespace-address.sh, which gateway.sh reads the addresses with"
}

# "service" for every service of a compose file that joins the gateway's or tailscale's namespace.
namespace_sharers() {
    tr -d '\r' <"$1" | awk '
        /^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top); next }
        top == "services" && /^  [^[:space:]#][^:]*:/ { service = substr($0, 3); sub(/:.*/, "", service); next }
        top == "services" && /^[[:space:]]+network_mode:[[:space:]]*["\047]?service:(gateway|tailscale)["\047]?[[:space:]]*$/ { print service }
    '
}

# "service port kind" for every entry of a compose file's x-namespace-listeners block.
namespace_listeners() {
    tr -d '\r' <"$1" | awk '
        /^[^[:space:]#]/ { inside = ($0 ~ /^x-namespace-listeners:[[:space:]]*$/); next }
        !inside || /^[[:space:]]*(#|$)/ { next }
        /^  [^[:space:]][^:]*:[[:space:]]*$/ { service = substr($0, 3); sub(/:.*/, "", service); print service, "-", "-"; next }
        /^    [^[:space:]]/ {
            line = $0; gsub(/["\047[:space:]]/, "", line)
            port = line; sub(/:.*/, "", port); kind = line; sub(/^[^:]*:/, "", kind); sub(/#.*/, "", kind)
            print service, port, kind; next
        }
        { print "?", "-", $0 }
    '
}

# "KEY=value" for every environment entry of one service whose name says it sets an address.
listen_settings() {
    tr -d '\r' <"$1" | awk -v wanted="$2" '
        /^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top); service = ""; next }
        top == "services" && /^  [^[:space:]#][^:]*:/ { service = substr($0, 3); sub(/:.*/, "", service); next }
        top != "services" || service != wanted { next }
        {
            line = $0; sub(/^[[:space:]]*-?[[:space:]]*/, "", line); gsub(/["\047]/, "", line)
            if (match(line, /^[A-Z][A-Z0-9_]*(ADDRESS|ADDR|LISTEN|HOST|HOSTNAME|BIND)[A-Z0-9_]*[:=]/)) {
                key = substr(line, 1, RLENGTH - 1); value = substr(line, RLENGTH + 1); sub(/^[[:space:]]+/, "", value)
                print key "=" value
            }
        }
    '
}

# An address on which tailscale's hand-off to 127.0.0.1 finds the listener: loopback, every
# address, or a bare ":port".
is_tailnet_reachable_address() {
    local address
    address=$(sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*:?-([^}]*)\}/\1/g' <<<"$1")
    [[ $address =~ ^(127\.|localhost|0\.0\.0\.0|\[::1?\]|::|:[0-9]) ]]
}

# Every service in the gateway's namespace declares, in x-namespace-listeners, each port it listens
# on: "gateway" (bound to the namespace's Docker address, which the tailnet cannot reach),
# "tailnet" (a port PORTS.md puts on the tailnet, TCP ones forwarded in serve.json), or "unbound"
# (the app cannot choose its address, so the port answers on the tailnet; the reason is recorded
# beside the entry). tailscale in userspace mode hands a tailnet connection, TCP or UDP, on any port
# serve.json does not forward to 127.0.0.1 of the namespace, so anything listening there or on every
# address is on the tailnet.
check_namespace_listeners() {
    local stack=$1 repo=$2 file service port kind spec protocol number setting sharers="" declared="" entries=""
    for file in "${compose_files[@]}"; do
        sharers+=" $(namespace_sharers "$file" | tr '\n' ' ')"
        entries+=$(namespace_listeners "$file")$'\n'
    done
    if grep -qE '^[[:space:]]+-?[[:space:]]*TS_[A-Z0-9_]*(LISTEN|ADDR_PORT|SERVER)[A-Z0-9_]*[:=]' "${compose_files[@]}"; then
        sharers+=" tailscale"
    fi
    while read -r service port kind; do
        [ -n "$service" ] || continue
        if [ "$service" = "?" ]; then
            fail "$stack" "x-namespace-listeners has the line '$kind'; write each service as '  <service>:' and each port as '    \"<port>[/udp]\": <kind>'"
            continue
        fi
        declared+=" $service "
        [ "$port" = - ] && continue
        [[ " $sharers " == *" $service "* ]] ||
            fail "$stack" "x-namespace-listeners names $service, which does not share the gateway's namespace"
        spec=${port%/*}
        protocol=tcp
        [[ $port == */udp ]] && protocol=udp
        if ! [[ $spec =~ ^[0-9]+(-[0-9]+)?$ ]] || [[ $port == */* && $port != */udp ]]; then
            fail "$stack" "x-namespace-listeners gives $service the port '$port'; write N, N-M, N/udp or N-M/udp"
            continue
        fi
        case $kind in
            gateway) ;;
            unbound) echo "NOTE $stack: $service listens on $port everywhere in the gateway's namespace, so the tailnet reaches it" ;;
            tailnet)
                for number in $(expand_ports "$spec"); do
                    [ -n "$(kind_of "$stack" tailnet "$number")" ] ||
                        { fail "$stack" "$service declares $number/$protocol on the tailnet, but PORTS.md has no tailnet row for it"; break; }
                    [ "$protocol" = udp ] || [[ $serve_found == *" $number "* ]] ||
                        { fail "$stack" "$service declares $number on the tailnet, but serve.json does not forward it"; break; }
                done
                ;;
            *) fail "$stack" "x-namespace-listeners gives $service:$port the kind '$kind'; use gateway, tailnet or unbound" ;;
        esac
    done <<<"$entries"
    for service in $(tr ' ' '\n' <<<"$sharers" | sort -u); do
        [[ $declared == *" $service "* ]] ||
            fail "$stack" "$service shares the gateway's namespace but is not in x-namespace-listeners; declare each port it listens on"
        for file in "${compose_files[@]}"; do
            while IFS= read -r setting; do
                is_tailnet_reachable_address "${setting#*=}" &&
                    fail "$stack" "$service sets ${setting%%=*} to '${setting#*=}', which tailscale reaches from the tailnet; bind the namespace's Docker address (gateway/namespace-address.sh, or the name gateway)"
            done < <(listen_settings "$file" "$service")
        done
    done
    if grep -nE '^[^#]*(reverse_proxy|to)[[:space:]]+(https?://)?(127\.|localhost|\[::1\])' "$repo/gateway/sites.caddy" >/dev/null; then
        fail "$stack" "sites.caddy proxies to a loopback upstream, which listens where tailscale hands tailnet connections; proxy to gateway:<port> and bind the app to the namespace's Docker address"
    fi
}

# Adds the tailnet ports a tailscale serve config forwards to serve_found, and those it forwards with a
# PROXY protocol header to proxied_found; a bad entry fails the stack. Only :443 reads such a header
# (the template's TAILNET_PROXY_PROTOCOL), so no other port may send one.
collect_serve_ports() {
    local stack=$1 file=$2 name entries forwards proxied port
    name="gateway/$(basename "$file")"
    if grep -qE '"(HTTPS|Web|Handlers|Proxy)"' "$file"; then
        fail "$stack" "$name terminates TLS in tailscale instead of forwarding TCP to the gateway"
    fi
    entries=$(grep -oE '"[0-9]+"[[:space:]]*:' "$file" | grep -oE '[0-9]+')
    forwards=$(grep -oE '"[0-9]+"[[:space:]]*:[[:space:]]*\{[[:space:]]*"TCPForward"[[:space:]]*:[[:space:]]*"127\.0\.0\.1:[0-9]+"[[:space:]]*(,[[:space:]]*"ProxyProtocol"[[:space:]]*:[[:space:]]*2[[:space:]]*)?\}' "$file" |
        sed -E 's/^"([0-9]+)".*"127\.0\.0\.1:([0-9]+)".*$/\1 \2/')
    proxied=$(grep -oE '"[0-9]+"[[:space:]]*:[[:space:]]*\{[^}]*"ProxyProtocol"' "$file" | grep -oE '^"[0-9]+"' | tr -d '"')
    for port in $entries; do
        if ! grep -qxE "$port $port" <<<"$forwards"; then
            fail "$stack" "$name port $port is not a TCPForward to 127.0.0.1:$port (with at most \"ProxyProtocol\": 2)"
        elif grep -qx "$port" <<<"$proxied"; then
            [ "$port" = 443 ] || fail "$stack" "$name sends port $port a PROXY protocol header, which only the gateway's :443 reads"
            proxied_found+=" $port "
        fi
        serve_found+=" $port "
    done
}

# The gateway's :443 requires a PROXY protocol header exactly when serve.json sends one: a header the
# gateway skips breaks TLS, and a header it requires but never gets refuses every caller.
check_proxy_protocol() {
    local stack=$1 requires=0
    grep -qE '^[[:space:]]*TAILNET_PROXY_PROTOCOL:[[:space:]]*["\047]?require["\047]?[[:space:]]*$' "${compose_files[@]}" && requires=1
    if [[ $proxied_found == *" 443 "* ]]; then
        [ "$requires" = 1 ] || fail "$stack" "serve.json sends 443 a PROXY protocol header but the gateway does not set TAILNET_PROXY_PROTOCOL: require"
    elif [ "$requires" = 1 ]; then
        fail "$stack" "the gateway sets TAILNET_PROXY_PROTOCOL: require but serve.json does not forward 443 with \"ProxyProtocol\": 2"
    fi
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
        sync) ;;
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
            sync) ;;
            public) [[ " $public_stacks " == *" $stack "* ]] || fail "$stack" "PORTS.md has a public row but the stack is not a public stack" ;;
            *) fail "$stack" "PORTS.md row has the unknown kind '$kind'" ;;
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
    proxied_found=""
    for file in "$repo"/gateway/*.json; do
        grep -q '"AllowFunnel"' "$file" &&
            fail "$stack" "gateway/$(basename "$file") opens Funnel itself; PUBLIC_ACCESS in config.env is the only Funnel switch"
        collect_serve_ports "$stack" "$file"
    done
    [ "$(grep -v '^[[:space:]]*$' "$repo/gateway/serve.json" | tail -n 2 | tr -d '[:space:]')" = "}}" ] ||
        fail "$stack" "gateway/serve.json does not end with the TCP block's '  }' and the closing '}' the template's tailscale.sh extends"
    check_proxy_protocol "$stack"

    while read -r address imports_tailnet tls bind; do
        [ "$tls" = 0 ] || fail "$stack" "sites.caddy sets tls itself; certificates come only from 'import tailnet'"
        [ "$bind" = - ] || fail "$stack" "sites.caddy block '$address' sets its own listener ('${bind//,/ }'); the template's Caddyfile binds every site"
        if [[ $address =~ ^\{\$TAILNET_HOST\}:([0-9]+)$ ]]; then
            port=${BASH_REMATCH[1]}
            tailnet_sites+=" $port"
            [ "$imports_tailnet" = 1 ] || fail "$stack" "tailnet site :$port does not 'import tailnet'"
            [[ $serve_found == *" $port "* ]] || fail "$stack" "tailnet site :$port is not forwarded in serve.json"
        elif [[ $address =~ ^http://:([0-9]+)$ ]]; then
            local_sites+=" ${BASH_REMATCH[1]} "
            [ "$imports_tailnet" = 0 ] ||
                fail "$stack" "local site :${BASH_REMATCH[1]} imports tailnet, which binds it to 127.0.0.1 where the tailnet reaches it"
        elif [[ $address != \(* ]]; then
            fail "$stack" "sites.caddy has the site '$address', neither {\$TAILNET_HOST}:<port> nor http://:<port>"
        fi
    done < <(caddy_sites "$repo/gateway/sites.caddy")

    for port in $(tr ' ' '\n' <<<"$serve_found" | sort -un); do
        kind=$(kind_of "$stack" tailnet "$port")
        case $kind in
            web) [[ " $tailnet_sites " == *" $port "* ]] || fail "$stack" "web port $port is forwarded on the tailnet but has no {\$TAILNET_HOST}:$port site" ;;
            protocol | sync)
                [[ $funnel_capable_ports != *" $port "* ]] ||
                    fail "$stack" "$kind port $port is one Funnel carries; PUBLIC_ACCESS would open it to the internet"
                ;;
            *) fail "$stack" "forwards tailnet port $port, which is not a web, protocol or sync port in PORTS.md" ;;
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
    check_namespace_listeners "$stack" "$repo"
}

rows=$(table_rows)
public_stacks=$(listed_stacks "Public stacks")
check_template_binding

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
