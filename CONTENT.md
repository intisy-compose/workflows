The reusable workflows of the `intisy-compose` stacks. A stack repository carries only a thin caller
that `uses:` a workflow here; anything shared with other organisations lives in
[`intisy/workflows`](https://github.com/intisy/workflows) instead.

## Workflows

| workflow | what it checks or does |
| --- | --- |
| `check-access.yml` | every web dashboard of the calling stack is published on 127.0.0.1 only, each tailnet site has a matching `http://localhost:<port>` site, and every local port is listed in [`access/PORTS.md`](access/PORTS.md) |

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
