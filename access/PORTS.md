# Ports

The one list of every port a compose stack publishes on the host or exposes on the tailnet, read by
`check-access.sh`. A new port gets its row here before the stack uses it. The designs and their
reasons are in `intisy-compose/docs`: `specs/2026-10-16-dashboard-access.md` (dashboards on the
tailnet and on loopback) and `specs/2026-10-20-connect-devices-design.md` (this table and its kinds).

## Kinds

| kind | where it may listen |
|---|---|
| `web` | through the shared gateway only: a TLS site on the tailnet name and an `http://:<port>` site published as `127.0.0.1:<port>:<port>`; a UI on the tailnet has both |
| `api` | `127.0.0.1` only, published by the service itself |
| `protocol` | the tailnet only, through the gateway's `serve.json`; never on the host's other interfaces |
| `public` | anywhere; only in a stack listed under public stacks below |

Public access is one switch for every stack on the shared gateway: `PUBLIC_ACCESS=true` in its
`config.env` (default `false`) opens its tailnet sites on the ports Funnel carries (443, 8443,
10000) to the internet through Tailscale Funnel. Those ports are therefore only ever `web`, and
Funnel is switched on nowhere else.

`tailnet` is the port on the stack's `ts.net` name, `host` the port published on this host; `-`
means none. A range reserves ports a stack takes as it grows; the check accepts any port in it.

## Ports

| stack | serves | kind | tailnet | host |
|---|---|---|---|---|
| inventree | InvenTree | web | 443 | 8441 |
| storage | dashboard | web | 443 | 8442 |
| storage | Syncthing GUI, this host only (the tailnet reaches only its sync protocol) | web | - | 8443 |
| storage | Samba | protocol | 445 | - |
| storage | Syncthing sync | protocol | 22000 | - |
| storage | Syncthing sync of each further node on a host, reserved | protocol | 22001-22099 | - |
| storage | Kopia server | protocol | 51515 | - |
| storage | Syncthing GUIs and APIs of the Windows host agent's native nodes (host processes, not compose ports; their sync ports are in 22001-22099) | api | - | 8450-8469 |
| hindsight | control plane | web | 443 | 9999 |
| hindsight | API for local tools | api | - | 8888 |
| hindsight | in-stack llama | api | - | 11434 |
| graphify | graph explorer | web | 443 | 8771 |
| graphify | MCP endpoint | api | - | 8770 |
| stremio | streaming server (8446: a native Stremio app on this PC holds 11470) | web | 443 | 8446 |
| shelf | shelf.nu | web | 443 | 8444 |
| shelf | Supabase Auth and Storage for shelf.nu | web | 8443 | 8445 |
| shelf | Mailpit, which holds login codes | web | - | 8025 |
| game | Hytale (UDP) | public | - | 5520 |
| game | Minecraft Java | public | - | 25565 |
| game | Minecraft Bedrock (UDP) | public | - | 19132 |
| game | ARK: Survival Evolved game and raw (UDP) | public | - | 7777-7778 |
| game | ARK query (UDP) | public | - | 27015 |
| game | ARK: Survival Ascended (UDP) | public | - | 7779-7780 |

## Exceptions

Public stacks: `game`. Game servers are meant for players on the internet, and their ports go
through the playit or frp tunnel.
