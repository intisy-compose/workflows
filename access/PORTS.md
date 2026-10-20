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

`tailnet` is the port on the stack's `ts.net` name, `host` the port published on this host; `-`
means none. A range reserves ports a stack takes as it grows; the check accepts any port in it.

## Ports

| stack | serves | kind | tailnet | host |
|---|---|---|---|---|
| inventree | InvenTree | web | 443 | 8441 |
| storage | dashboard | web | 443 | 8442 |
| storage | Syncthing GUI | web | 8384 | 8443 |
| storage | Samba | protocol | 445 | - |
| storage | Syncthing sync | protocol | 22000 | - |
| storage | Syncthing sync of each further node on a host, reserved | protocol | 22001-22099 | - |
| storage | Kopia server | protocol | 51515 | - |
| hindsight | control plane | web | 443 | 9999 |
| hindsight | API for local tools | api | - | 8888 |
| hindsight | in-stack llama | api | - | 11434 |
| graphify | graph explorer | web | 443 | 8771 |
| graphify | MCP endpoint | api | - | 8770 |
| stremio | streaming server | web | 443 | 11470 |
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

Funnel stacks: `stremio`. `PUBLIC_ACCESS=true` in its `config.env` serves the tailnet site through
Tailscale Funnel (`gateway/funnel.json`) to share it with friends outside the tailnet; it is off by
default.
