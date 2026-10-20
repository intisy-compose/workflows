The reusable workflows of the `intisy-compose` stacks. A stack repository carries only a thin caller
that `uses:` a workflow here; anything shared with other organisations lives in
[`intisy/workflows`](https://github.com/intisy/workflows) instead.

## Workflows

| workflow | what it checks or does |
| --- | --- |
| `check-access.yml` | every port the calling stack publishes or exposes on the tailnet is in [`access/PORTS.md`](access/PORTS.md) and listens only where its kind (`web`, `api`, `protocol`, `public`) allows, the stack's gateway is the shared one in [`gateway/`](gateway), and its project, container and volume names follow the org's rules |

## The shared gateway

[`gateway/`](gateway) holds the gateway every stack with a web UI or a tailnet port uses: Caddy owns
the network namespace and serves each UI on the tailnet name, with certificates only from the
Tailscale socket, and on a `http://:<port>` site published on `127.0.0.1`; the tailscale sidecar
joins Caddy's namespace. A stack copies `Caddyfile` and `gateway.yml` into its own `gateway/` folder
byte for byte, extends both services from its compose file, and adds only its own values:
`gateway/sites.caddy` (its sites, each tailnet site with `import tailnet`), `gateway/serve.json`
(the tailnet ports, each a `TCPForward` to the same port on `127.0.0.1`), container names,
`TAILNET_HOST`, `TS_HOSTNAME` and the gateway's loopback ports. A change to the template is copied
into every stack in the same step (`Caddyfile`, `gateway.yml` and `tailscale.sh`); the check fails
on any copy that differs.

**Public access** is one switch, the same in every stack: `PUBLIC_ACCESS=true` in the stack's
`config.env` (default `false`, and anything but `true`, `1`, `yes` or `on` counts as off) makes
`tailscale.sh` add Tailscale Funnel to the serve config for every forwarded port Funnel carries
(443, 8443, 10000), so those sites answer from the internet, without a login of their own, until the
switch is off again and the stack restarted. It needs the `funnel` node attribute in the tailnet
policy. A stack never opens Funnel any other way, and the ports Funnel carries are only ever `web`
ports in `access/PORTS.md`.

## Using it

```yaml
name: Check dashboard access

on:
  workflow_dispatch:
  push:
  pull_request:

permissions:
  contents: read

jobs:
  check:
    uses: intisy-compose/workflows/.github/workflows/check-access.yml@main
```

## Running the check locally

With the stack repositories cloned next to this one:

```sh
bash workflows/access/check-access.sh
```

It checks every `*-compose` directory beside `workflows` and exits non-zero, naming each violation,
when one breaks the standard or when it finds no stack at all.

`bash workflows/access/tests/check-access.test.sh` plants each violation in a scratch stack and
asserts that the check names it.
