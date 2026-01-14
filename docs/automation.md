# Automation options

## Railway CLI (recommended)

```bash
# Authenticate
railway login

# Create a project
railway init -n goodmem

# Add Postgres with pgvector
railway add --image pgvector/pgvector:pg17 --service postgres \
  --variables 'PORT=5432' \
  --variables 'POSTGRES_USER=postgres' \
  --variables 'POSTGRES_PASSWORD=<generate-a-password>' \
  --variables 'POSTGRES_DB=goodmem'

# Add GoodMem service from GHCR (with variables at creation time)
railway add --image ghcr.io/pair-systems-inc/goodmem/server:latest --service goodmem \
  --variables 'PORT=8080' \
  --variables 'GOODMEM_REST_TLS_ENABLED=false' \
  --variables 'GOODMEM_GRPC_TLS_ENABLED=true' \
  --variables 'DB_USER=${{postgres.POSTGRES_USER}}' \
  --variables 'DB_PASSWORD=${{postgres.POSTGRES_PASSWORD}}' \
  --variables 'DB_URL=jdbc:postgresql://${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/${{postgres.POSTGRES_DB}}?sslmode=disable'

# Optional: generate a domain for REST
railway domain --service goodmem --port 8080

# GoodMem migrations create the extension if it is available.
# If you need to verify, connect using the Postgres TCP proxy and run:
# CREATE EXTENSION IF NOT EXISTS vector;
```

Notes:
- Railway applies variable changes as staged updates; trigger a deploy in the UI
  if the service does not redeploy automatically.
- If you rename the Postgres service, update the `${{postgres.*}}` references.

## Public API (GraphQL) sketch

Endpoint: `https://backboard.railway.com/graphql/v2`

High-level flow:
1. Create a project (or reuse an existing project).
2. Create a Postgres service using the pgvector image.
3. Create a GoodMem service using the GHCR image.
4. Upsert variables on the GoodMem service.
5. Trigger a deployment or restart the service.

Minimal examples (check GraphiQL for exact inputs):

```graphql
mutation serviceCreateGoodMem {
  serviceCreate(
    input: {
      projectId: "<PROJECT_ID>"
      source: { image: "ghcr.io/pair-systems-inc/goodmem/server:latest" }
    }
  ) {
    id
  }
}
```

```graphql
mutation variableUpsertGoodMem {
  variableUpsert(
    input: {
      projectId: "<PROJECT_ID>"
      environmentId: "<ENV_ID>"
      serviceId: "<GOODMEM_SERVICE_ID>"
      name: "DB_URL"
      value: "jdbc:postgresql://${{postgres.RAILWAY_PRIVATE_DOMAIN}}:5432/${{postgres.POSTGRES_DB}}?sslmode=disable"
    }
  )
}
```

For the Postgres service, use `serviceCreate` with a Docker image source and
set `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` variables.
