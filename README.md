# workflows

Shared GitHub Actions workflows for the intisy-compose stacks: reusable workflows that every stack repository calls instead of carrying its own logic.

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
into every stack in the same step; the check fails on any copy that differs.

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
