#!/bin/bash
# Fixture test for check-access.sh: builds small stacks in a scratch folder, plants one violation at a
# time and asserts the verdicts.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
check="$here/../check-access.sh"
template="$here/../../gateway"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export PORTS_TABLE="$scratch/PORTS.md"

failures=0
expect() {
    local name=$1 want_status=$2 want_text=$3 output status
    output=$(bash "$check" "$scratch/stacks" 2>&1)
    status=$?
    if [ "$status" -eq "$want_status" ] && { [ -z "$want_text" ] || grep -qF -- "$want_text" <<<"$output"; }; then
        echo "ok   $name"
    else
        echo "FAIL $name: exit $status, wanted $want_status containing '$want_text'"
        echo "$output" | sed 's/^/     /'
        failures=$((failures + 1))
    fi
}

write_table() {
    cat >"$PORTS_TABLE" <<'EOF'
| stack | serves | kind | tailnet | host |
|---|---|---|---|---|
| demo | dashboard | web | 443 | 8401 |
| demo | API | api | - | 8402 |
| demo | sync | protocol | 22000 | - |
| demo | sync of further nodes, reserved | protocol | 22001-22099 | - |
| arcade | game | public | - | 25565 |

Public stacks: `arcade`.
EOF
}

# A demo stack that follows every rule, and a public stack with no gateway.
new_stacks() {
    rm -rf "$scratch/stacks"
    write_table
    local demo="$scratch/stacks/demo-compose" arcade="$scratch/stacks/arcade-compose"
    mkdir -p "$demo/gateway" "$arcade"
    cp "$template/Caddyfile" "$template/gateway.yml" "$template/tailscale.sh" "$demo/gateway/"
    cat >"$demo/docker-compose.yml" <<'EOF'
services:
  api:
    image: demo
    ports:
      - "127.0.0.1:${API_PORT:-8402}:8080"
  gateway:
    extends: { file: gateway/gateway.yml, service: gateway }
    container_name: demo-gateway
    ports:
      - "127.0.0.1:8401:8401"
  tailscale:
    extends: { file: gateway/gateway.yml, service: tailscale }
    container_name: demo-tailscale
EOF
    printf '{\n  "TCP": {\n    "443": { "TCPForward": "127.0.0.1:443" },\n    "22000": { "TCPForward": "127.0.0.1:22000" }\n  }\n}\n' >"$demo/gateway/serve.json"
    printf '(app) {\n\treverse_proxy api:8080\n}\n\n{$TAILNET_HOST}:443 {\n\timport tailnet\n\timport app\n}\n\nhttp://:8401 {\n\timport app\n}\n' >"$demo/gateway/sites.caddy"
    printf 'services:\n  server:\n    image: game\n    ports:\n      - "25565:25565"\n' >"$arcade/docker-compose.yml"
}
demo="$scratch/stacks/demo-compose"

publish_extra() {
    printf '  extra:\n    image: extra\n    ports:\n      - "%s"\n' "$1" >>"$demo/docker-compose.yml"
}

new_stacks
expect "conforming stacks pass" 0 "all 2 stacks"

new_stacks
publish_extra "127.0.0.1:9000:9000"
expect "port missing from the table fails" 1 "FAIL demo: extra publishes host port 9000, which is not in PORTS.md"

new_stacks
sed -i 's/127.0.0.1:${API_PORT/${API_PORT/' "$demo/docker-compose.yml"
expect "api on every interface fails" 1 "FAIL demo: api publishes api port 8402 on more than 127.0.0.1"

new_stacks
sed -i 's/"127.0.0.1:8401:8401"/"8401:8401"/' "$demo/docker-compose.yml"
expect "web port on every interface fails" 1 "web port 8401 is not published as 127.0.0.1:8401:8401"

new_stacks
sed -i 's/${API_PORT:-8402}:8080/8401:8401/' "$demo/docker-compose.yml"
expect "web port published around the gateway fails" 1 "FAIL demo: api publishes web port 8401; only the gateway may"

new_stacks
publish_extra "127.0.0.1:22000:22000"
expect "protocol port on the host fails" 1 "publishes host port 22000, which is not in PORTS.md"

new_stacks
sed -i 's/^Public stacks:.*/Public stacks: `none`./' "$PORTS_TABLE"
expect "public port outside a public stack fails" 1 "FAIL arcade: publishes public port 25565 but is not a public stack"

new_stacks
publish_extra "127.0.0.1:8403:8080"
sed -i 's/^| demo | API | api | - | 8402 |$/&\n| demo | API2 | api | 8403 | 8403 |/' "$PORTS_TABLE"
expect "api row on the tailnet fails" 1 "PORTS.md puts api port 8403 on the tailnet"

new_stacks
sed -i 's/^| demo | sync | protocol | 22000 | - |$/| demo | sync | protocol | 22000 | 22000 |/' "$PORTS_TABLE"
expect "protocol row on the host fails" 1 "PORTS.md publishes protocol port 22000 on the host"

new_stacks
printf '| demo | old UI | api | - | 8499 |\n' >>"$PORTS_TABLE"
expect "stale table row fails" 1 "PORTS.md lists host port 8499 but no compose file publishes it"

new_stacks
echo "# drifted" >>"$demo/gateway/Caddyfile"
expect "drifted vendored Caddyfile fails" 1 "gateway/Caddyfile differs from workflows gateway/Caddyfile"

new_stacks
rm "$demo/gateway/gateway.yml"
expect "missing vendored gateway.yml fails" 1 "gateway/gateway.yml is missing"

new_stacks
sed -i 's/extends: { file: gateway\/gateway.yml, service: tailscale }/image: tailscale\/tailscale:v1.102.4/' "$demo/docker-compose.yml"
expect "own tailscale fails" 1 "runs its own caddy or tailscale"
expect "own tailscale also misses the extends" 1 "service tailscale does not extend gateway/gateway.yml"

new_stacks
printf '{\n  "TCP": { "443": { "HTTPS": true } },\n  "Web": { "${TS_CERT_DOMAIN}:443": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:8080" } } } }\n}\n' >"$demo/gateway/serve.json"
expect "tailscale serve terminating TLS fails" 1 "gateway/serve.json terminates TLS in tailscale"

new_stacks
sed -i 's/"443": { "TCPForward": "127.0.0.1:443" }/"443": { "TCPForward": "127.0.0.1:8080" }/' "$demo/gateway/serve.json"
expect "forward to another port fails" 1 "gateway/serve.json port 443 is not a TCPForward to 127.0.0.1:443"

new_stacks
sed -i 's/"22000": { "TCPForward": "127.0.0.1:22000" }/"22000": { "TCPForward": "127.0.0.1:22000" },\n    "8384": { "TCPForward": "127.0.0.1:8384" }/' "$demo/gateway/serve.json"
expect "tailnet port missing from the table fails" 1 "forwards tailnet port 8384, which is not a web or protocol port in PORTS.md"

new_stacks
sed -i '/"22000"/d; s/"127.0.0.1:443" },/"127.0.0.1:443" }/' "$demo/gateway/serve.json"
expect "table tailnet port not forwarded fails" 1 "PORTS.md lists tailnet port 22000 but serve.json does not forward it"

new_stacks
sed -i 's/^\timport tailnet$/\ttls internal/' "$demo/gateway/sites.caddy"
expect "own tls fails" 1 "sites.caddy sets tls itself"
expect "tailnet site without import fails" 1 "tailnet site :443 does not 'import tailnet'"

new_stacks
printf '\nlocalhost:8401 {\n\timport app\n}\n' >>"$demo/gateway/sites.caddy"
expect "other site address fails" 1 "sites.caddy has the site 'localhost:8401'"

new_stacks
sed -i 's/^http:\/\/:8401 {$/http:\/\/:8409 {/' "$demo/gateway/sites.caddy"
expect "web port without its local site fails" 1 "web port 8401 has no http://:8401 site in sites.caddy"

new_stacks
printf '{\n  "TCP": { "443": { "TCPForward": "127.0.0.1:443" } },\n  "AllowFunnel": { "${TS_CERT_DOMAIN}:443": true }\n}\n' >"$demo/gateway/funnel.json"
expect "funnel in a stack's own serve config fails" 1 "gateway/funnel.json opens Funnel itself"

new_stacks
printf '    volumes:\n      - ./gateway/funnel.json:/config/serve.json:ro\n' >>"$demo/docker-compose.yml"
expect "overriding the template's serve config fails" 1 "overrides the template's serve config"

new_stacks
sed -i 's/"22000": { "TCPForward": "127.0.0.1:22000" }/"8443": { "TCPForward": "127.0.0.1:8443" }/' "$demo/gateway/serve.json"
sed -i 's/^| demo | sync | protocol | 22000 | - |$/| demo | sync | protocol | 8443 | - |/' "$PORTS_TABLE"
expect "protocol on a port Funnel carries fails" 1 "protocol port 8443 is one Funnel carries"

new_stacks
printf '{ "TCP": { "443": { "TCPForward": "127.0.0.1:443" }, "22000": { "TCPForward": "127.0.0.1:22000" } } }\n' >"$demo/gateway/serve.json"
expect "serve.json the toggle cannot extend fails" 1 "gateway/serve.json does not end with"

new_stacks
echo "# drifted" >>"$demo/gateway/tailscale.sh"
expect "drifted vendored tailscale.sh fails" 1 "gateway/tailscale.sh differs"

new_stacks
publish_extra "8080"
expect "a mapping without a host port fails" 1 "maps '8080'; use the short form"

rm -rf "$scratch/stacks"/*
expect "an empty root fails" 1 "holds no *-compose repo"

[ "$failures" -eq 0 ] && echo "all cases passed"
[ "$failures" -eq 0 ]
