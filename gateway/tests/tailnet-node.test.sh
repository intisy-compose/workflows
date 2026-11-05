#!/bin/bash
# shellcheck disable=SC2016 # bash -c scripts take their values as arguments
# The bash twin of the tailnet node helper against a fake curl that plays the Tailscale API over a
# list of devices, so no real API is called. Plain bash: an `ok` or `FAIL` line per case, non-zero
# exit on any failure.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
helper="$here/../tailnet-node.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fakes="$scratch/fakes"
api="$scratch/api"
folder="$scratch/stack/data/tailscale"
config="$scratch/stack/config.env"
token=tskey-api-k123-SECRET456

mkdir -p "$fakes"
# The fake curl: a token on its command line is logged and fails; otherwise it logs the method, URL and
# the header from its config on stdin, and answers DELETE /device/ID with 200 while that device is in
# $api/devices (removing it), 404 when it is not, or the status in $api/status when that file exists.
cat >"$fakes/curl" <<'EOF'
#!/bin/bash
api=${FAKE_API_DIR:?}
for argument in "$@"; do
    case "$argument" in
        *Bearer* | *tskey-*) echo "CREDENTIAL ON ARGV $argument" >>"$api/calls"; exit 99 ;;
    esac
done
method=GET
previous=""
for argument in "$@"; do
    [ "$previous" = -X ] && method=$argument
    previous=$argument
done
url=${!#}
header=$(sed -n 's/^header = "\(.*\)"$/\1/p')
echo "$method $url $header" >>"$api/calls"
if [ -f "$api/status" ]; then
    code=$(cat "$api/status")
    printf '%s' "$code"
    [ "$code" != 000 ] || exit 7
    exit 0
fi
node=${url##*/device/}
if [ "$method" = DELETE ] && grep -q "^$node " "$api/devices"; then
    grep -v "^$node " "$api/devices" >"$api/devices.next"
    mv "$api/devices.next" "$api/devices"
    printf 200
else
    printf 404
fi
EOF
chmod +x "$fakes/curl"

failures=0
case_name=""
case_failed=false
output=""
status=0

begin() {
    case_name=$1
    case_failed=false
    rm -rf "$scratch/stack" "$api"
    mkdir -p "$folder" "$api"
    : >"$api/calls"
    printf '%s\n' "nOURS123CNTRL inventree" "nOTHER45CNTRL inventree" "nDESK678CNTRL desktop" >"$api/devices"
    printf '%s\n' "# Tailscale" TS_HOSTNAME=inventree "TS_API_TOKEN=$token" >"$config"
    write_state nOURS123CNTRL
}

finish() {
    if $case_failed; then
        failures=$((failures + 1))
        printf '     %s\n' "${output//$'\n'/$'\n'     }"
    else
        echo "ok   $case_name"
    fi
}

check() {
    local description=$1
    shift
    if ! "$@"; then
        $case_failed || echo "FAIL $case_name"
        echo "     - $description"
        case_failed=true
    fi
}

# write_state NODE_ID: a tailscaled.state whose current profile is NODE_ID's, beside an older profile
# of another node, as tailscaled keeps every profile it ever logged in with.
write_state() {
    local current profiles
    current=$(printf 'profile-ab12' | base64 | tr -d '\n')
    profiles=$(printf '{"cd34":{"ID":"cd34","Key":"profile-cd34","NodeID":"nOLDER99CNTRL"},"ab12":{"ID":"ab12","Key":"profile-ab12","NodeID":"%s"}}' "$1" | base64 | tr -d '\n')
    printf '{"_current-profile":"%s","_profiles":"%s","_machinekey":"cHJpdmtleQ=="}\n' "$current" "$profiles" >"$folder/tailscaled.state"
}

run_helper() {
    output=$(cd "$scratch" && PATH="$fakes:$PATH" FAKE_API_DIR="$api" bash -c '. "$1"; shift; "$@"' _ "$helper" "$@" 2>&1)
    status=$?
}

status_is() { [ "$status" -eq "$1" ]; }
said() { grep -qF -- "$1" <<<"$output"; }
not_said() { ! said "$1"; }
called() { grep -qE -- "$1" "$api/calls"; }
not_called() { ! called "$1"; }
device_left() { grep -q "^$1 " "$api/devices"; }

begin "the node ID is the current profile's, not an older profile's"
run_helper tailnet_node_id <"$folder/tailscaled.state"
check "prints the current node" [ "$output" = nOURS123CNTRL ]
finish

begin "a state that is not JSON, or names no current node, gives no node ID"
for text in 'not json' '{}' '{"_current-profile":"cHJvZmlsZS16eg==","_profiles":"e30="}'; do
    printf '%s' "$text" >"$folder/tailscaled.state"
    run_helper tailnet_node_id <"$folder/tailscaled.state"
    check "'$text' gives nothing" [ -z "$output" ]
done
finish

begin "a node ID that would change the API URL is refused"
write_state 'n1/../../tailnet'
run_helper tailnet_node_id <"$folder/tailscaled.state"
check "gives nothing" [ -z "$output" ]
finish

begin "delete removes the node with the state's ID, then the state folder"
run_helper remove_tailnet_identity "$folder" inventree.tail-test.ts.net "$config"
check "exits 0" status_is 0
check "deletes the device by its ID" called "^DELETE https://api.tailscale.com/api/v2/device/nOURS123CNTRL Authorization: Bearer $token$"
check "our node is gone" bash -c '! grep -q "^nOURS123CNTRL " "$1"' _ "$api/devices"
check "says so" said "Removed inventree.tail-test.ts.net from the tailnet."
check "the state folder is gone" [ ! -e "$folder" ]
check "says the next up joins fresh" said "the next up joins the tailnet fresh."
finish

begin "a node with the same name is left alone"
run_helper remove_tailnet_identity "$folder" inventree "$config"
check "exits 0" status_is 0
check "the other inventree stays" device_left nOTHER45CNTRL
check "the desktop stays" device_left nDESK678CNTRL
check "one API call, for our ID only" [ "$(wc -l <"$api/calls")" -eq 1 ]
check "never the older profile's node" not_called nOLDER99CNTRL
finish

begin "the token is never on curl's command line"
run_helper remove_tailnet_identity "$folder" inventree "$config"
check "no credential on argv" not_called "CREDENTIAL ON ARGV"
check "the fake would catch one" bash -c 'FAKE_API_DIR="$1" "$2/curl" -H "Authorization: Bearer x" https://api.tailscale.com/api/v2/device/n1 </dev/null >/dev/null; [ $? -eq 99 ]' _ "$api" "$fakes"
check "and the token never in the output" not_said "$token"
finish

begin "without TS_API_TOKEN the manual step is printed and the folder still goes"
printf '%s\n' TS_HOSTNAME=inventree "TS_API_TOKEN=" >"$config"
run_helper remove_tailnet_identity "$folder" inventree.tail-test.ts.net "$config"
check "exits 0" status_is 0
check "no API call" not_called .
check "says the node stays" said "No TS_API_TOKEN in config.env, so inventree.tail-test.ts.net stays in the tailnet."
check "names the Machines page, the node and its ID" said "Remove inventree.tail-test.ts.net (node ID nOURS123CNTRL) on the Machines page: https://login.tailscale.com/admin/machines"
check "the state folder is gone" [ ! -e "$folder" ]
check "the node is still in the tailnet" device_left nOURS123CNTRL
finish

begin "a config without the line at all counts as no token"
printf '%s\n' TS_HOSTNAME=inventree >"$config"
run_helper remove_tailnet_node nOURS123CNTRL inventree "$config"
check "returns 2" status_is 2
check "no API call" not_called .
finish

begin "a quoted token with CRLF endings is read"
printf '%s\r\n' TS_HOSTNAME=inventree "TS_API_TOKEN=\"$token\"" >"$config"
run_helper remove_tailnet_node nOURS123CNTRL inventree "$config"
check "returns 0" status_is 0
check "sends the bare token" called "Authorization: Bearer $token$"
finish

for code in 401 403 500 000; do
    begin "an API answer of $code removes nothing locally and says so"
    printf '%s' "$code" >"$api/status"
    run_helper remove_tailnet_identity "$folder" inventree "$config"
    check "exits 1" status_is 1
    check "the state folder is kept" [ -f "$folder/tailscaled.state" ]
    check "says it is kept" said "is kept, so delete can run again."
    check "names the manual step" said "Remove inventree (node ID nOURS123CNTRL) on the Machines page"
    check "never claims a removal" not_said "Removed inventree"
    case $code in
        000) check "says the API did not answer" said "The Tailscale API did not answer, so inventree was not removed." ;;
        500) check "names the status" said "The Tailscale API answered HTTP 500, so inventree was not removed." ;;
        *) check "names the token" said "The Tailscale API refused TS_API_TOKEN (HTTP $code)" ;;
    esac
    finish
done

begin "a node the tailnet no longer has counts as gone"
printf '%s\n' "nOTHER45CNTRL inventree" >"$api/devices"
run_helper remove_tailnet_identity "$folder" inventree "$config"
check "exits 0" status_is 0
check "says there is nothing to remove" said "The tailnet has no node nOURS123CNTRL any more, so there is nothing to remove."
check "the state folder is gone" [ ! -e "$folder" ]
check "the same-name node stays" device_left nOTHER45CNTRL
finish

begin "a token that would break curl's config is refused before any call"
printf '%s\n' 'TS_API_TOKEN=tskey" -o /tmp/x' >"$config"
run_helper remove_tailnet_identity "$folder" inventree "$config"
check "exits 1" status_is 1
check "no API call" not_called .
check "says so" said "TS_API_TOKEN in config.env is not a Tailscale API token"
check "the state folder is kept" [ -f "$folder/tailscaled.state" ]
finish

begin "a state that names no node removes nothing, here or in the tailnet"
printf '{}' >"$folder/tailscaled.state"
run_helper remove_tailnet_identity "$folder" inventree "$config"
check "exits 1" status_is 1
check "no API call" not_called .
check "the state folder is kept" [ -f "$folder/tailscaled.state" ]
check "names the manual way" said "Remove inventree on the Machines page, https://login.tailscale.com/admin/machines, then delete"
finish

begin "no state at all removes no node and clears the folder"
rm "$folder/tailscaled.state"
: >"$folder/tailscaled.log1.txt"
run_helper remove_tailnet_identity "$folder" inventree "$config"
check "exits 0" status_is 0
check "no API call" not_called .
check "says so" said "No node identity in"
check "the folder is gone" [ ! -e "$folder" ]
finish

begin "no state folder at all is fine"
rm -rf "$folder"
run_helper remove_tailnet_identity "$folder" inventree "$config"
check "exits 0" status_is 0
check "no API call" not_called .
finish

echo
if [ "$failures" -eq 0 ]; then echo "all cases pass"; else echo "$failures cases fail"; fi
[ "$failures" -eq 0 ]
