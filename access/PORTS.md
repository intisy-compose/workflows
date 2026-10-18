# Dashboard ports

Every compose web dashboard is served on the tailnet and on this host's loopback, and nowhere else.
The design and its reasons are in `specs/2026-10-16-dashboard-access.md` of `intisy-compose/docs`;
this table is the one list of ports, read by `check-access.sh`. A new dashboard gets its row here
before its gateway is written.

| stack | UI | tailnet | local |
|---|---|---|---|
| inventree | InvenTree | `https://inventree.<tailnet>` | `http://localhost:8441` |
| storage | dashboard | `https://storage.<tailnet>` | `http://localhost:8442` |
| storage | Syncthing GUI | `https://storage.<tailnet>:8384` | `http://localhost:8443` |
| hindsight | control plane | `https://hindsight.<tailnet>` | `http://localhost:9999` |
| graphify | graph explorer | `https://graphify.<tailnet>` | `http://localhost:8771` |
| stremio | streaming server | `https://stremio.<tailnet>` | `http://localhost:11470` |
| game | none (game ports) | exempt | exempt |
| shelf | stopped | exempt | exempt |

Kopia's server (51515) and Samba (445) are protocols for clients, not dashboards, and stay
tailnet-only. hindsight's API (8888) and graphify's MCP endpoint (8770) are APIs that local tools
call; they stay on 127.0.0.1.
