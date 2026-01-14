# GoodMem on Railway

This repo documents a Railway template layout for running GoodMem with a
managed Postgres instance. It uses the official GoodMem server image from GHCR
and Railway's Postgres plugin, wired together with Railway reference variables.

## Quick start (CLI)

Use the bootstrap script to create a project, add Postgres + GoodMem services,
and wire the variables.

```bash
# Bootstrap a new project (will prompt for Railway login if needed)
./bootstrap.sh --project-name goodmem

# If Railway CLI is not installed:
# ./bootstrap.sh --install-cli --project-name goodmem

# If this repo is already linked to a project:
# ./bootstrap.sh --skip-init
```

Then enable pgvector:

GoodMem runs a migration that creates the extension when it is available. If
you want to verify manually, connect to the Postgres service using its TCP
proxy (Railway UI) and run:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

## Template layout

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
- GoodMem defaults to REST on 8080 and gRPC on 9090. This template sets
  `GOODMEM_GRPC_PORT=50051` to use the standard gRPC port. Railway provides a
  single Railway-provided domain per service, so use it for REST and expose
  gRPC via a TCP proxy targeting port 50051.
- The bootstrap script prints step-by-step instructions to create a TCP proxy
  in the Railway UI.
- GoodMem requires the `vector` extension. This template uses the pgvector
  Postgres image so the extension is available.
- If GoodMem logs `DB_USER` missing, redeploy after variables are set or check
  that the Postgres service name matches the `postgres.` reference.

## Create the template in Railway (UI)

1. Create a new template from your Railway workspace.
2. Add a service sourced from a Docker image:
   - Image: `ghcr.io/pair-systems-inc/goodmem/server:latest`
   - Service name: `goodmem`
3. Add a Postgres service from an image:
   - Image: `pgvector/pgvector:pg17`
   - Service name: `postgres`
4. Configure GoodMem variables (see `.env.example` for copy/paste).
5. Enable public networking for `goodmem` and set the target port to `8080`.
6. Set healthcheck path to `/health`.
7. Deploy.
8. Ensure pgvector is available:
   - `railway connect postgres`
   - `CREATE EXTENSION IF NOT EXISTS vector;`

## Scriptable automation

See `docs/automation.md` for CLI and API automation flows.
