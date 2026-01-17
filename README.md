# GoodMem on Railway

This repo is centered on `scripts/bootstrap_railway.sh`, which provisions GoodMem on Railway
with a Postgres service backed by `pgvector/pgvector:pg17` and wires all
required variables for you.

## Quick start (scripts/bootstrap_railway.sh)

The script creates a Railway project (unless you skip init), adds the GoodMem
and Postgres services, and configures environment variables. It will prompt
for Railway login if needed, and can optionally install the Railway CLI.

```bash
# Bootstrap a new project (will prompt for Railway login if needed)
./scripts/bootstrap_railway.sh --project-name goodmem

# If Railway CLI is not installed:
# ./scripts/bootstrap_railway.sh --install-cli --project-name goodmem

# If this repo is already linked to a project:
# ./scripts/bootstrap_railway.sh --skip-init
```

After it finishes:
- Follow the script output to create the gRPC TCP proxy.
- Run `goodmem init --server https://<TCP_PROXY_DOMAIN>:<TCP_PROXY_PORT> --save-config=false`
  to create the root user and master API key.

## What the script creates

Services:
- goodmem (Docker image): `ghcr.io/pair-systems-inc/goodmem/server:latest`
- postgres (Docker image): `pgvector/pgvector:pg17`

Ports:
- REST: 8080 (public)
- gRPC: 50051 (optional; public via TCP proxy)

GoodMem service variables (use reference variables for Postgres):
- `PORT=8080`
- `GOODMEM_REST_TLS_ENABLED=false`
- `GOODMEM_GRPC_TLS_ENABLED=true`
- `GOODMEM_GRPC_PORT=50051`
- `DB_USER=${{postgres.POSTGRES_USER}}`
- `DB_PASSWORD=${{postgres.POSTGRES_PASSWORD}}`
- `DB_URL=jdbc:postgresql://${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/${{postgres.POSTGRES_DB}}?sslmode=disable`

Notes:
- If you name the Postgres service differently, update the `postgres.` prefix.
- The script attaches a Railway volume to the Postgres service at `/var/lib/postgresql/data`
  and sets `PGDATA=/var/lib/postgresql/data/pgdata` so Postgres uses the volume.
  If the Postgres service already exists, re-run with `--attach-existing-postgres-volume`
  to attach a volume (this can hide existing data).
- Railway defaults to your plan's per-service limits (Free 0.5 GB RAM, Trial 1 GB, Hobby 8 GB, Pro 32 GB, Enterprise 48 GB).
  For parity with Fly's 1 GB defaults, set GoodMem and Postgres memory limits to 1 GB in
  the Railway UI (Service -> Settings -> Deploy -> Resource Limits).
- GoodMem defaults to REST on 8080 and gRPC on 9090. This script sets
  `GOODMEM_GRPC_PORT=50051` to use the standard gRPC port. Railway provides a
  single Railway-provided domain per service, so use it for REST and expose
  gRPC via a TCP proxy targeting port 50051.
- The bootstrap script prints step-by-step instructions to create a TCP proxy
  in the Railway UI.
- The Postgres service is private by default; create a TCP proxy if you need
  to connect manually.
- GoodMem requires the `vector` extension. This template uses the pgvector
  Postgres image so the extension is available.
- If GoodMem logs `DB_USER` missing, redeploy after variables are set or check
  that the Postgres service name matches the `postgres.` reference.
