# woodpecker-ci-railway

The [Woodpecker CI](https://woodpecker-ci.org/) **agent**, packaged to run on
Railway. The Woodpecker **server** needs no repo — it runs from the published
`woodpeckerci/woodpecker-server:v3` image.

## Why the agent needs a repo

Woodpecker's agent ships three execution backends: Docker, Kubernetes and Local.
Railway blocks `unshare(2)`, so no container runtime can start inside a service —
the Docker and Kubernetes backends have nothing to talk to. That leaves the
**Local backend**, which runs each pipeline step as an ordinary process on the
agent container.

The published agent image is a single Go binary on Alpine (or `scratch`, on the
default `v3` tag). It has no shell, no `git`, and no `plugin-git`, so the Local
backend cannot clone a repository or run a single `commands:` step. This image
adds them, and an entrypoint that:

- prepares the one Railway volume for both the agent's registration id and the
  Local backend's workflow directories, and clears workflow directories orphaned
  by a redeploy;
- drops from root to uid 1000 with `su-exec` before exec'ing the agent, because
  Local-backend steps run as whoever the agent is;
- moves `WOODPECKER_AGENT_SECRET` out of the environment into a file, since the
  Local backend hands `os.Environ()` to every pipeline step;
- defaults `WOODPECKER_SERVER` when the cross-service reference has not resolved
  yet, which is what a first-ever template deploy looks like.

## Security note — read before pointing this at a repository

The Local backend gives pipeline steps **no isolation**. A step runs as the agent
user, on the agent's filesystem, with the agent's network access. Upstream's own
guidance is that it is for private setups where the code and the pipeline are
trusted, and that it must not be exposed to people who can push arbitrary
pipelines. Keep `WOODPECKER_OPEN=false` on the server, keep `WOODPECKER_ADMIN`
narrow, and only enable repositories you control.

## Writing pipelines for the Local backend

The `image:` field names the **shell or binary** to run, not a container image.
`image: alpine` fails; `image: bash` works. Plugins are executables resolved from
`$PATH`. Available out of the box: `bash`, `sh`, `git`, `git-lfs`, `ssh`, `curl`,
`wget`, `jq`, `make`, `tar`, `unzip`, `xz`, `openssl`, `node`, `npm`, `python3`,
`pip`. Anything else, install it in the step itself.

```yaml
# .woodpecker.yaml
steps:
  - name: test
    image: bash
    commands:
      - node --version
      - npm ci
      - npm test
```

`services:` are not supported by the Local backend.

## Environment variables

Everything below has a working default; none is required.

| Variable | Default | Purpose |
|---|---|---|
| `WOODPECKER_SERVER` | `woodpecker-server.railway.internal:9000` | gRPC address of the server |
| `WOODPECKER_AGENT_SECRET` | none | shared secret; must match the server |
| `WOODPECKER_BACKEND` | `local` | the only backend Railway can run |
| `WOODPECKER_MAX_WORKFLOWS` | `1` | workflows this agent runs in parallel |
| `WOODPECKER_HOSTNAME` | `railway-agent` | pinned, since Railway regenerates the container hostname each deploy |
| `WOODPECKER_RAILWAY_DATA_DIR` | `/var/lib/woodpecker` | volume mount path |
| `WOODPECKER_BACKEND_LOCAL_TEMP_DIR` | `<data dir>/tmp` | where workflows are cloned and run |
| `WOODPECKER_CONNECT_RETRY_COUNT` | `30` | Railway has no service ordering |
| `WOODPECKER_CONNECT_RETRY_DELAY` | `10s` | |
| `PORT` | `3000` | health check port; the agent serves `/healthz` on it |

## Licence

The Dockerfile and entrypoint in this repository are provided as-is. Woodpecker CI
itself is licensed under the Apache License 2.0 by the Woodpecker authors.
