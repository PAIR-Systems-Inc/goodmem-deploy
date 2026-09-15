# Hetzner Cloud Bootstrap Script — Specification

> **Historical design draft (March 2026).** Preserved as research and design
> history; this is not the current operating guide. The implemented script is
> `scripts/bootstrap_hetzner.sh`, and its supported tiers and domain defaults
> differ from this draft. Provider details and prices below have not been
> revalidated.

This document captures all research and design decisions for building
`bootstrap_hetzner.sh`, a one-command deployment script for GoodMem on
Hetzner Cloud.

## Architecture Overview

A single Hetzner Cloud server runs three containers:

1. **GoodMem** — Java 21 application serving REST (port 8080) and gRPC
   (port 9090 or 50051)
2. **PostgreSQL 17 + pgvector** — `pgvector/pgvector:pg17` Docker image,
   data stored on a Hetzner Volume
3. **Caddy** (domain mode only) — reverse proxy for TLS termination via
   Let's Encrypt

The server uses the `docker-ce` app image (Ubuntu 24.04 with Docker and
Docker Compose pre-installed). Provisioning target: **2–5 minutes**
end-to-end, compared to ~15 minutes on Lightsail.

There is **no managed PostgreSQL** on Hetzner. Postgres runs as a Docker
container on the same server. This is the same pattern used by the Fly.io
bootstrap script.

---

## Server Types and Availability

### Location Constraints

CX (cheap x86) and CAX (ARM) are **EU-only**. US locations only have CPX
and CCX.

| Location        | Code   | Region      | CX  | CAX | CPX | CCX |
|-----------------|--------|-------------|-----|-----|-----|-----|
| Falkenstein, DE | `fsn1` | Germany     | Yes | Yes | Yes | Yes |
| Nuremberg, DE   | `nbg1` | Germany     | Yes | Yes | Yes | Yes |
| Helsinki, FI    | `hel1` | Finland     | Yes | Yes | Yes | Yes |
| Ashburn, VA     | `ash`  | US East     | No  | No  | Yes | Yes |
| Hillsboro, OR   | `hil`  | US West     | No  | No  | Yes | Yes |
| Singapore       | `sin`  | Asia        | No  | No  | Yes | Yes |

### Server Type Families

**CX (Shared vCPU, Cost-Optimized) — EU only:**

| Type | vCPU | RAM   | Disk   | Traffic | ~USD/mo (post-Apr 2026) |
|------|------|-------|--------|---------|------------------------|
| CX23 | 2    | 4 GB  | 40 GB  | 20 TB   | ~$4.70                 |
| CX33 | 4    | 8 GB  | 80 GB  | 20 TB   | ~$7.60                 |
| CX43 | 8    | 16 GB | 160 GB | 20 TB   | ~$14.10                |
| CX53 | 16   | 32 GB | 320 GB | 20 TB   | ~$26.40                |

**CAX (Shared vCPU, ARM / Ampere Altra) — EU only:**

| Type  | vCPU | RAM   | Disk   | Traffic | ~USD/mo (post-Apr 2026) |
|-------|------|-------|--------|---------|------------------------|
| CAX11 | 2    | 4 GB  | 40 GB  | 20 TB   | ~$5.30                 |
| CAX21 | 4    | 8 GB  | 80 GB  | 20 TB   | ~$10.00                |
| CAX31 | 8    | 16 GB | 160 GB | 20 TB   | ~$19.40                |
| CAX41 | 16   | 32 GB | 320 GB | 20 TB   | ~$37.00                |

ARM requires a multi-arch GoodMem Docker image (`linux/arm64`). If the
image is amd64-only, CAX plans cannot be used.

**CPX (Shared vCPU, AMD EPYC Genoa) — All locations:**

| Type  | vCPU | RAM   | Disk   | Traffic (EU/US) | ~USD/mo EU | ~USD/mo US |
|-------|------|-------|--------|-----------------|------------|------------|
| CPX22 | 2    | 4 GB  | 80 GB  | 20 TB / 1 TB   | ~$9.40     | ~$12.00    |
| CPX32 | 4    | 8 GB  | 160 GB | 20 TB / 2 TB   | ~$16.40    | ~$21.00    |
| CPX42 | 8    | 16 GB | 320 GB | 20 TB / 3 TB   | ~$30.00    | ~$39.00    |
| CPX52 | 12   | 24 GB | 480 GB | 20 TB / 4 TB   | ~$42.90    | ~$56.00    |
| CPX62 | 16   | 32 GB | 640 GB | 20 TB / 5 TB   | ~$59.30    | ~$78.00    |

**CCX (Dedicated vCPU, AMD EPYC) — All locations:**

| Type  | vCPU | RAM    | Disk   | Traffic (EU/US) | ~USD/mo EU | ~USD/mo US |
|-------|------|--------|--------|-----------------|------------|------------|
| CCX13 | 2    | 8 GB   | 80 GB  | 20 TB / 1 TB   | ~$18.80    | ~$20.00    |
| CCX23 | 4    | 16 GB  | 160 GB | 20 TB / 2 TB   | ~$37.00    | ~$34.00    |
| CCX33 | 8    | 32 GB  | 240 GB | 30 TB / 3 TB   | ~$73.40    | ~$65.00    |
| CCX43 | 16   | 64 GB  | 360 GB | 40 TB / 4 TB   | ~$146.90   | ~$130.00   |
| CCX53 | 32   | 128 GB | 600 GB | 50 TB / 6 TB   | ~$293.70   | ~$260.00   |
| CCX63 | 48   | 192 GB | 960 GB | 60 TB / 8 TB   | ~$440.00   | ~$460.00   |

US traffic allowances were cut significantly in December 2024 (from 20 TB
to 1–8 TB). EU locations still include 20+ TB.

---

## Tier System

### Design

The `--tier` flag maps to human-readable names. The underlying server type
is selected automatically based on location. Show RAM, vCPU, and
approximate monthly cost in the picker — not Hetzner type names.

### Recommended Mapping

| Tier     | EU type | US type | vCPU   | RAM   | ~USD/mo (EU) | ~USD/mo (US) |
|----------|---------|---------|--------|-------|--------------|--------------|
| small    | CX23    | CPX22   | 2 sh   | 4 GB  | ~$5          | ~$12         |
| medium   | CX33    | CPX32   | 4 sh   | 8 GB  | ~$8          | ~$21         |
| large    | CX43    | CPX42   | 8 sh   | 16 GB | ~$14         | ~$39         |
| x-large  | CCX23   | CCX23   | 4 ded  | 16 GB | ~$37         | ~$34         |
| 2x-large | CCX33   | CCX33   | 8 ded  | 32 GB | ~$73         | ~$65         |
| 4x-large | CCX43   | CCX43   | 16 ded | 64 GB | ~$147        | ~$130        |

Notes:
- "sh" = shared vCPU, "ded" = dedicated vCPU.
- x-large and above use dedicated CPU (CCX) regardless of location.
- The tier picker should ask for region first (since it affects which
  types are available and what they cost), then show the appropriate
  tier menu.
- Non-interactive fallback: default to `small`.

### Interactive Prompt Design

```
Select Hetzner Cloud location:
  1) Hillsboro, OR, US (hil)
  2) Ashburn, VA, US (ash)
  3) Falkenstein, DE (fsn1)
  4) Nuremberg, DE (nbg1)
  5) Helsinki, FI (hel1)
  6) Singapore (sin)
Enter selection (1-6) or code [hil]:

Select instance tier:
  1) small    - 4 GB RAM, 2 shared vCPU, about $12/mo + DB self-hosted
  2) medium   - 8 GB RAM, 4 shared vCPU, about $21/mo + DB self-hosted
  3) large    - 16 GB RAM, 8 shared vCPU, about $39/mo + DB self-hosted
  4) x-large  - 16 GB RAM, 4 dedicated vCPU, about $34/mo + DB self-hosted
Enter selection (1-4) or name [small]:
```

Prices shown should reflect the selected location. For EU locations, show
the lower EU prices. The `+ DB self-hosted` suffix reminds the user there
is no separate database charge.

### Querying Available Types

`hcloud server-type list` does not have a `--location` filter. To
determine availability per location, use:

```bash
hcloud server-type list -o json
```

The JSON response includes a `prices` array with per-location pricing.
Only types with pricing for the target location are available there.
Alternatively, hard-code the known availability matrix (CX/CAX = EU only,
CPX/CCX = all locations).

---

## RAM Allocation: GoodMem + PostgreSQL on One Server

### Principle

Give PostgreSQL the larger share. pgvector HNSW indexes benefit enormously
from being cached in RAM, and Postgres relies on the Linux page cache by
design. The JVM's heap needs are relatively modest for an API server.

**Rule: ~70% to Postgres, ~30% to JVM, 10–15% reserved for
OS/Docker/Caddy.**

### Allocation Table

| Server RAM | OS/Docker/Caddy | GoodMem container | JVM heap% | Postgres container | shared_buffers | effective_cache_size | work_mem | maint_work_mem |
|-----------|----------------|-------------------|-----------|-------------------|---------------|---------------------|----------|---------------|
| 4 GB      | 512 MB         | 1 GB              | 65%       | 2.5 GB            | 512 MB        | 1.5 GB              | 8 MB     | 128 MB        |
| 8 GB      | 768 MB         | 2 GB              | 65%       | 5.2 GB            | 1 GB          | 3.5 GB              | 16 MB    | 256 MB        |
| 16 GB     | 1 GB           | 4 GB              | 70%       | 11 GB             | 2 GB          | 8 GB                | 32 MB    | 512 MB        |
| 32 GB     | 1.5 GB         | 8 GB              | 70%       | 22.5 GB           | 4 GB          | 16 GB               | 64 MB    | 1 GB          |
| 64 GB     | 2 GB           | 16 GB             | 70%       | 46 GB             | 8 GB (cap)    | 32 GB               | 64 MB    | 2 GB          |

### Dynamic Computation in Cloud-Init

The cloud-init script should detect total RAM from `/proc/meminfo` and
compute the split at boot time. This avoids hard-coding allocations per
tier.

```bash
calculate_allocations() {
  local total_mb="$1"

  # Reserve for OS/Docker/Caddy: 15% of total, min 384 MB, max 2048 MB
  local os_reserve=$(( total_mb * 15 / 100 ))
  [ "$os_reserve" -lt 384 ] && os_reserve=384
  [ "$os_reserve" -gt 2048 ] && os_reserve=2048

  local available=$(( total_mb - os_reserve ))

  # GoodMem gets 30% of available, Postgres gets 70%
  local goodmem_mb=$(( available * 30 / 100 ))
  local postgres_mb=$(( available - goodmem_mb ))

  # JVM MaxRAMPercentage: lower on small containers due to fixed overhead
  local jvm_ram_pct=70
  [ "$goodmem_mb" -lt 768 ] && jvm_ram_pct=50
  [ "$goodmem_mb" -lt 1536 ] && [ "$goodmem_mb" -ge 768 ] && jvm_ram_pct=65

  # shared_buffers: 25% of Postgres container, min 128 MB, max 8 GB
  local shared_buffers_mb=$(( postgres_mb * 25 / 100 ))
  [ "$shared_buffers_mb" -lt 128 ] && shared_buffers_mb=128
  [ "$shared_buffers_mb" -gt 8192 ] && shared_buffers_mb=8192

  # effective_cache_size: 70% of Postgres container
  local effective_cache_mb=$(( postgres_mb * 70 / 100 ))

  # work_mem: scale from 4 to 64 MB
  local work_mem_mb=4
  [ "$postgres_mb" -ge 2048 ] && work_mem_mb=8
  [ "$postgres_mb" -ge 4096 ] && work_mem_mb=16
  [ "$postgres_mb" -ge 8192 ] && work_mem_mb=32
  [ "$postgres_mb" -ge 16384 ] && work_mem_mb=64

  # maintenance_work_mem: scale from 64 MB to 2 GB
  local maint_mem_mb=64
  [ "$postgres_mb" -ge 2048 ] && maint_mem_mb=128
  [ "$postgres_mb" -ge 4096 ] && maint_mem_mb=256
  [ "$postgres_mb" -ge 8192 ] && maint_mem_mb=512
  [ "$postgres_mb" -ge 16384 ] && maint_mem_mb=1024
  [ "$postgres_mb" -ge 32768 ] && maint_mem_mb=2048
}
```

### JVM Configuration

Set via `JAVA_TOOL_OPTIONS` environment variable in the GoodMem container:

```
JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=${jvm_ram_pct} -XX:InitialRAMPercentage=25
```

The JVM (Java 10+) automatically detects Docker memory limits via
`-XX:+UseContainerSupport` (on by default). `MaxRAMPercentage` calculates
against the container's `--memory` limit, not total host RAM.

### Postgres Configuration

Key settings to inject via environment variables or a custom
`postgresql.conf`:

```
shared_buffers = ${shared_buffers_mb}MB
effective_cache_size = ${effective_cache_mb}MB
work_mem = ${work_mem_mb}MB
maintenance_work_mem = ${maint_mem_mb}MB
max_connections = 30
```

For servers >= 8 GB, also set:

```
huge_pages = try
```

### Docker Memory Limits

Always set hard limits on both containers:

```bash
docker run --memory=${goodmem_mb}m ...  # GoodMem
docker run --memory=${postgres_mb}m ... # Postgres
```

Without memory limits, both containers can consume all host RAM and the
Linux OOM killer will act unpredictably (often killing Postgres, which
risks data corruption).

### Swap

Enable a small swap partition as a safety net:

- Servers <= 8 GB: 1 GB swap
- Servers > 8 GB: 2 GB swap
- Set `vm.swappiness=1` (swap only under extreme pressure)

---

## Persistent Storage: Hetzner Volumes

### Why

Hetzner server local disks do not persist across server deletion. Postgres
data must be on a Hetzner Volume to survive server recreation.

### Provisioning

```bash
# Create volume (must be in same location as server)
hcloud volume create \
  --name "${DEPLOYMENT}-pgdata" \
  --size 10 \
  --location "${LOCATION}" \
  --format ext4

# Attach to server
hcloud volume attach "${DEPLOYMENT}-pgdata" --server "${DEPLOYMENT}"
```

The volume appears at `/dev/disk/by-id/scsi-0HC_Volume_<numeric-id>`.

### Cloud-Init Mount

```bash
VOLUME_DEV="/dev/disk/by-id/scsi-0HC_Volume_${VOLUME_ID}"
MOUNT_POINT="/mnt/pgdata"

mkdir -p "$MOUNT_POINT"

# Format only if not already formatted
if ! blkid "$VOLUME_DEV" | grep -q 'TYPE='; then
  mkfs.ext4 "$VOLUME_DEV"
fi

mount "$VOLUME_DEV" "$MOUNT_POINT"

# Persist across reboots
if ! grep -q "$VOLUME_DEV" /etc/fstab; then
  echo "$VOLUME_DEV $MOUNT_POINT ext4 defaults 0 2" >> /etc/fstab
fi
```

### Docker Bind Mount

```bash
docker run \
  --memory=${postgres_mb}m \
  -v /mnt/pgdata:/var/lib/postgresql/data \
  -e POSTGRES_USER=goodmem \
  -e POSTGRES_DB=goodmem \
  -e POSTGRES_PASSWORD="${DB_PASSWORD}" \
  pgvector/pgvector:pg17
```

### Pricing

~$0.057/GB/month (post-April 2026). A 10 GB volume costs ~$0.57/mo.

### Destroy Behavior

The `--destroy` command should default to **keeping the volume** (data
preservation). Add `--delete-volume` for full cleanup:

```
--destroy --name X --yes                  # deletes server, keeps volume
--destroy --name X --yes --delete-volume  # deletes server AND volume
```

---

## DNS Management

Two modes. No Route53 integration for the Hetzner script.

### Mode 1: Hetzner DNS

If the domain's NS records point to Hetzner's nameservers, the script can
manage DNS records directly via `hcloud`:

```bash
# Check if zone exists
hcloud dns zone list -o json | python3 -c '
import json, sys
domain = sys.argv[1]
zones = json.load(sys.stdin)["dns_zones"]
# find best matching zone...
' "$DOMAIN"

# Create/update A record
hcloud dns record create \
  --zone "${ZONE_ID}" \
  --name "${RECORD_NAME}" \
  --type A \
  --value "${INSTANCE_IP}"
```

Hetzner DNS is free. No per-query charges.

**Limitation:** All DNS API calls go to the Hetzner DNS API, which is
separate from the Cloud API. The `hcloud` CLI added DNS support
(`hcloud dns zone`, `hcloud dns record`) — verify the exact subcommand
syntax against the current CLI version.

### Mode 2: Manual

Print the required DNS record and let the user create it at their provider:

```
[WARN] Create this DNS record at your DNS provider: A app.example.com -> 1.2.3.4
```

Caddy will retry certificate issuance until DNS propagates.

### Auto-Detection

1. If `--domain` is set, check for a matching Hetzner DNS zone.
2. If found, upsert the A record automatically.
3. If not found, fall back to manual mode with instructions.

### Cleanup

On `--destroy`, delete the Hetzner DNS record only if it still points at
this deployment's IP (same conservative approach as the Lightsail script's
Route53 cleanup).

---

## TLS and Reverse Proxy (Caddy)

### When Domain Mode Is Active

Install Caddy on the instance and configure it as a reverse proxy:

```
{
  admin off
  email ${CONTACT_EMAIL}
}

${DOMAIN} {
  encode zstd gzip
  reverse_proxy http://127.0.0.1:${REST_PORT}
}

${DOMAIN}:${PUBLIC_GRPC_PORT} {
  reverse_proxy 127.0.0.1:${GRPC_PORT} {
    transport http {
      versions h2c 2
    }
  }
}
```

- REST: public 443 → internal 8080
- gRPC: public 50051 → internal 9090

This is the same Caddy configuration used in the Lightsail domain-mode
path. The internal gRPC port must differ from the public Caddy port to
avoid the bind collision discovered during Lightsail testing.

### When No Domain Is Set

No Caddy. GoodMem serves directly with self-signed TLS on its ports. The
firewall restricts access to `--access-cidr` only.

### Caddy RAM Usage

Caddy typically uses 20–50 MB RSS. This is within the OS/Docker/Caddy
reserve in the allocation table. No special sizing needed.

---

## Firewall Configuration

Hetzner Cloud Firewalls are reusable profiles managed via CLI:

```bash
hcloud firewall create --name "${DEPLOYMENT}-fw"

# SSH (always)
hcloud firewall add-rule "${DEPLOYMENT}-fw" \
  --direction in --protocol tcp --port 22 \
  --source-ips "${ACCESS_CIDR}"

# Domain mode: public HTTP/HTTPS/gRPC
if domain_enabled; then
  hcloud firewall add-rule "${DEPLOYMENT}-fw" \
    --direction in --protocol tcp --port 80 \
    --source-ips 0.0.0.0/0 --source-ips ::/0
  hcloud firewall add-rule "${DEPLOYMENT}-fw" \
    --direction in --protocol tcp --port 443 \
    --source-ips 0.0.0.0/0 --source-ips ::/0
  hcloud firewall add-rule "${DEPLOYMENT}-fw" \
    --direction in --protocol tcp --port 50051 \
    --source-ips 0.0.0.0/0 --source-ips ::/0
fi

# Non-domain mode: direct access restricted to CIDR
if ! domain_enabled; then
  hcloud firewall add-rule "${DEPLOYMENT}-fw" \
    --direction in --protocol tcp --port "${REST_PORT}" \
    --source-ips "${ACCESS_CIDR}"
  hcloud firewall add-rule "${DEPLOYMENT}-fw" \
    --direction in --protocol tcp --port "${GRPC_PORT}" \
    --source-ips "${ACCESS_CIDR}"
fi

# Apply to server
hcloud firewall apply-to-resource "${DEPLOYMENT}-fw" \
  --type server --server "${DEPLOYMENT}"
```

Unlike Lightsail, the firewall can be created and configured before the
server exists, then applied at creation time via `--firewall`.

The two-phase firewall approach from Lightsail (SSH-only initially, then
reconcile after bootstrap reports ports) is not needed here because the
bootstrap script controls the port assignments directly — there is no
external installer choosing ports.

---

## Cloud-Init / User-Data

Hetzner supports cloud-init on all images including `docker-ce`. Pass via
`--user-data-from-file`:

```bash
hcloud server create \
  --name "${DEPLOYMENT}" \
  --type "${SERVER_TYPE}" \
  --image docker-ce \
  --location "${LOCATION}" \
  --ssh-key "${DEPLOYMENT}-key" \
  --firewall "${DEPLOYMENT}-fw" \
  --user-data-from-file "${USER_DATA_FILE}"
```

### Known Caveat

The `--user-data-from-file` flag has had issues with content that contains
strings resembling CLI flags (e.g., `sudo -u` being interpreted as `-u`).
Workaround: base64-encode the user-data and pass it via the API, or test
carefully with the raw file approach.

### Cloud-Init Script Outline

The user-data script runs as root at first boot. Docker is already
installed (from the `docker-ce` image). The script needs to:

1. Detect total RAM, compute allocation splits
2. Set up swap (1–2 GB, swappiness=1)
3. Mount the Hetzner Volume for Postgres data
4. Start the Postgres container with memory limits and tuned config
5. Wait for Postgres to accept connections
6. Create the pgvector extension (`CREATE EXTENSION IF NOT EXISTS vector`)
7. Start the GoodMem container with memory limits and DB connection URL
8. Wait for GoodMem to become ready (`/readyz`)
9. Call `/v1/system/init` to get the root API key
10. If domain mode: install and configure Caddy
11. Write a status file (same pattern as Lightsail:
    `/opt/goodmem-hetzner/status.json`)

### Postgres Connection URL

Since both containers run on the same host, the connection uses Docker
networking:

```
jdbc:postgresql://host.docker.internal:5432/goodmem
```

Or use a Docker network:

```bash
docker network create goodmem-net
docker run --network goodmem-net --name postgres ... pgvector/pgvector:pg17
docker run --network goodmem-net -e DB_URL=jdbc:postgresql://postgres:5432/goodmem ... goodmem
```

The Docker network approach is cleaner — containers reference each other
by name.

---

## Script Structure

### CLI Flags

Match the Lightsail script's patterns where applicable:

```
Usage: ./scripts/bootstrap_hetzner.sh [options]

Options:
  --name NAME               Deployment slug (default: goodmem-hetzner-<timestamp>)
  --list                    List known local Hetzner deployments and their status
  --destroy                 Delete a deployment's resources and local state
  --delete-volume           Also delete the Postgres data volume on destroy
  --yes                     Confirm destructive actions
  --location CODE           Hetzner location (default: hil; prompts if unset)
  --tier NAME               Size tier (prompts if unset)
  --server-type TYPE        Explicit Hetzner server type (overrides --tier)
  --volume-size GB          Postgres volume size in GB (default: 10)
  --db-password PASS        Postgres password (generated if omitted)
  --profile-name NAME       GoodMem CLI profile name (default: hetzner)
  --access-cidr CIDR        CIDR for SSH/direct access (auto-detected if omitted)
  --domain DOMAIN           Public domain for HTTPS + gRPC (Caddy)
  --email EMAIL             Contact email for ACME/TLS
  --image IMAGE             GoodMem server image
  --no-wait                 Exit after provisioning
  --wait-timeout SECONDS    Overall wait timeout (default: 600)
  -h, --help                Show this help
```

Note the shorter default `--wait-timeout` (600s vs Lightsail's 3600s)
since there is no managed database provisioning delay.

### Main Flow

```
1. Parse args
2. require_cmd hcloud, curl, openssl, python3, ssh
3. Resolve location (prompt if needed)
4. Resolve tier → server type (prompt if needed, location-aware)
5. Compute deployment names
6. Load local state (if re-run)
7. Generate DB password (if new)
8. Create SSH key (hcloud ssh-key create)
9. Create firewall (hcloud firewall create + add-rule)
10. Create volume (hcloud volume create)
11. Generate cloud-init user-data file
12. Create server (hcloud server create --image docker-ce)
13. Get server IP
14. Prepare DNS (Hetzner DNS auto-detect or manual)
15. Save local state
16. If --no-wait: print summary and exit
17. Wait for SSH
18. Wait for cloud-init bootstrap READY status
19. If domain mode: wait for DNS resolution, wait for public HTTPS
20. Print final summary with endpoints and API key
```

### Local State

Same pattern as Lightsail:

```
~/.goodmem/hetzner-state/${DEPLOYMENT_NAME}.json
~/.goodmem/hetzner-keys/${DEPLOYMENT_NAME}-key.pem
```

State file contents:

```json
{
  "deployment_name": "...",
  "location": "hil",
  "server_type": "cpx22",
  "server_name": "...",
  "server_ip": "...",
  "volume_name": "...",
  "volume_id": "...",
  "firewall_name": "...",
  "ssh_key_name": "...",
  "db_password": "...",
  "domain": "",
  "dns_mode_used": "none"
}
```

### Destroy Flow

```
1. Parse --destroy --name X --yes [--delete-volume]
2. Load local state
3. If domain + Hetzner DNS: delete A record if it still points to this IP
4. Delete server (hcloud server delete)
5. Delete firewall (hcloud firewall delete)
6. Delete SSH key (hcloud ssh-key delete)
7. If --delete-volume: delete volume (hcloud volume delete)
   Else: log "Volume ${name} preserved. Reattach with --name on next deploy."
8. Remove local state/key files
```

---

## Comparison: Lightsail vs Hetzner Bootstrap

| Aspect                    | Lightsail                         | Hetzner                          |
|---------------------------|-----------------------------------|----------------------------------|
| Managed Postgres          | Yes (~$15/mo)                     | No (self-hosted Docker)          |
| Provisioning time         | ~15 min (DB: ~10 min)             | ~2–5 min                         |
| Minimum cost              | ~$27/mo                           | ~$5/mo (EU) / ~$12/mo (US)      |
| Docker pre-installed      | No (apt-get in user-data)         | Yes (`docker-ce` image)          |
| TLS (domain mode)         | Caddy on instance                 | Caddy on instance                |
| gRPC                      | Full control                      | Full control                     |
| DNS                       | Route53 auto-detect + manual      | Hetzner DNS auto-detect + manual |
| Persistent DB storage     | Managed by Lightsail              | Hetzner Volume (~$0.57/mo 10GB)  |
| US availability           | All AWS regions                   | Ashburn + Hillsboro only         |
| Script complexity         | ~2000 lines                       | ~800–1200 lines (estimated)      |
| DB backup                 | Managed (automatic)               | DIY (pg_dump cron or WAL-G)      |
| SSH browser access        | Yes (Lightsail console)           | No                               |
| Firewall                  | JSON port-infos file              | CLI rules, reusable profiles     |
| Two-phase firewall needed | Yes (ports unknown until boot)    | No (ports known at script time)  |

---

## Estimated Script Size

~800–1200 lines. The major savings over Lightsail come from:

- No managed database lifecycle (create, wait 10 min, get endpoint, get
  port) — Postgres is a Docker container started in cloud-init
- No two-phase firewall — ports are known at script time
- Simpler CLI — `hcloud` commands are more concise than `aws lightsail`
- No jq dependency — `hcloud -o json` + python3 is sufficient

The major additions compared to Lightsail:

- Volume lifecycle management (create, attach, format, mount, optional
  delete)
- RAM detection and allocation computation in cloud-init
- Docker network setup in cloud-init
- Postgres container management in cloud-init (start, wait, create
  extension)
