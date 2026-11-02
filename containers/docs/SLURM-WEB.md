# Slurm REST API and Slurm-web

This adds to the cluster:

- `slurmrestd`: the Slurm REST API, with JWT authentication (`compose.yml`).
  Slurm master provides REST API v0.0.43 to v0.0.46; Slurm-web 7.0.0 uses v0.0.45
- [Slurm-web](https://github.com/rackslab/Slurm-web) 7.0.0: a web dashboard that reads the cluster through that API (`compose.slurm-web.yml`)

```
browser ──> slurm-web-gateway :5011 ──> slurm-web-agent :5012 ──JWT──> slurmrestd :6820 ──> slurmctld / slurmdbd
```

## What changed

| File | Change |
|------|--------|
| `Dockerfile` | Installs `libjwt-devel` (EPEL) and builds Slurm with `--enable-slurmrestd --with-jwt`; adds the `slurmrestd` user (slurmrestd refuses to run as root or `slurm`) |
| `slurm.conf`, `slurmdbd.conf` | `AuthAltTypes=auth/jwt`, `AuthAltParameters=jwt_key=/etc/slurm/jwt_hs256.key` |
| `entrypoint.sh` | Creates `/etc/slurm/jwt_hs256.key` on first start; new `slurmrestd` command |
| `compose.yml` | New `slurmrestd` container, port 6820 (also on `127.0.0.1:6820` of the host) |
| `compose.slurm-web.yml` | Slurm-web `slurm-web-init` (one-shot, prepares keys), `slurm-web-agent`, `slurm-web-gateway` |
| `slurm-web/*.ini` | Slurm-web agent, gateway and RBAC policy configuration |

## 1. Rebuild and recreate the cluster

The image must be rebuilt (Slurm is recompiled with JWT support).

The Slurm configuration lives in the `etc_slurm` volume, which is filled from the image
only when it is first created. An existing cluster keeps its old `slurm.conf`, so either
recreate the volumes (this also deletes `/home` and the accounting database):

```bash
docker compose down -v
docker compose build --no-cache
docker compose up -d
```

or keep the volumes and copy the new configuration in:

```bash
docker compose build
docker compose up -d --force-recreate
bin/update_slurmfiles.sh slurm.conf slurmdbd.conf
```

## 2. Check the REST API

```bash
docker exec -it login bash
export $(scontrol token)
curl -s -H "X-SLURM-USER-TOKEN: $SLURM_JWT" http://slurmrestd:6820/slurm/v0.0.45/diag | jq .meta
curl -s -H "X-SLURM-USER-TOKEN: $SLURM_JWT" http://slurmrestd:6820/slurm/v0.0.45/nodes | jq '.nodes[].name'
curl -s -H "X-SLURM-USER-TOKEN: $SLURM_JWT" http://slurmrestd:6820/slurmdb/v0.0.45/diag | jq .meta
```

`meta.plugin.data_parser` should be `data_parser/v0.0.45`. From the host, use
`http://localhost:6820` with a token printed by `docker exec login scontrol token`.

A JSON error `Authentication failure` or HTTP 401 means the token was not accepted:
check `docker logs slurmrestd` and `docker logs slurmctld`
(`auth/jwt` must be loaded, and `/etc/slurm/jwt_hs256.key` must exist).

## 3. Start Slurm-web

```bash
docker compose -f compose.yml -f compose.slurm-web.yml up -d
docker logs slurm-web-init          # lists slurmrestd.key, jwt.key, session.key
docker compose -f compose.yml -f compose.slurm-web.yml run --rm slurm-web-agent connect-check
```

Open <http://localhost:5011>. Authentication is disabled; every visitor gets the
read-only `anonymous` role from `slurm-web/policy.ini`.

Add `-f compose.slurm-web.yml` to the other add-ons as needed, e.g.
`docker compose -f compose.yml -f compose.ibm.yml -f compose.slurm-web.yml up -d`.

Stop Slurm-web only:

```bash
docker compose -f compose.yml -f compose.slurm-web.yml stop slurm-web-gateway slurm-web-agent
```

## Notes

- `SLURM_TAG=master` builds the Slurm development branch. Slurm-web 7.0.0 tries REST API
  v0.0.45 first, then older ones; if a future master drops v0.0.45, pin `SLURM_TAG` to a
  release or update Slurm-web to a version that supports the newer API.
- `slurm-web-agent` and `slurm-web-gateway` wait for `slurm-web-init` to finish
  (`depends_on: condition: service_completed_successfully`). Old `podman-compose`
  releases ignore the condition; the two services then restart until the keys exist
  (`restart: unless-stopped`).

- The Slurm-web images (`ghcr.io/rackslab/slurm-web-*`) are published for `linux/amd64`
  only. On Apple silicon they run under emulation (Docker Desktop: Rosetta; Podman:
  `qemu-user-static` in the Podman machine). `compose.slurm-web.yml` explains how to build
  native images from the Slurm-web repository instead.
- If you open the UI on another address than `http://localhost:5011`, change `[ui] host`
  in `slurm-web/gateway.ini` and the published port of `slurm-web-gateway`.
- The agent signs a 1-hour token for the `slurm` user (SlurmUser) whenever it needs one,
  with `slurmrestd.key`, a copy of the Slurm JWT key. Anyone with that key can act as any
  Slurm user: keep it to this local test cluster.
