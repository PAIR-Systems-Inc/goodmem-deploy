# DigitalOcean Bootstrap Script — Specification

> **Unimplemented design draft (March 2026).** Preserved as research for a
> proposed DigitalOcean bootstrap script. This repository does not currently
> contain `scripts/bootstrap_digitalocean.sh`. Provider details, prices, and
> provisioning estimates below have not been revalidated.

This document captures all research and design decisions for building
`bootstrap_digitalocean.sh`, a one-command deployment script for GoodMem
on DigitalOcean.

## Architecture Overview

**Recommended default: Single Droplet with Docker Postgres** (Option B),
matching the Hetzner pattern. A managed Postgres option (Option A) can be
offered via `--managed-db` but should not be the default due to slower
provisioning and higher cost.

A single DigitalOcean Droplet runs three containers:

1. **GoodMem** — Java 21 application serving REST (port 8080) and gRPC
   (port 9090 or 50051)
2. **PostgreSQL 17 + pgvector** — `pgvector/pgvector:pg17` Docker image,
   data stored on a DigitalOcean Volume
3. **Caddy** (domain mode, which is the default via sslip.io) — reverse
   proxy for TLS termination via Let's Encrypt

Provisioning target: **2–4 minutes** end-to-end.

### Why Not App Platform?

DigitalOcean App Platform does not support exposing native gRPC on a
custom port (50051). It only supports HTTP/HTTPS on port 443. GoodMem
needs both REST and gRPC as separate public endpoints, so a Droplet is
required.

---

## Droplet Types and Pricing

### Basic Droplets (Shared CPU)

Suitable for dev/staging. Shared vCPUs can be noisy neighbors.

| Slug             | vCPU | RAM   | Disk   | Transfer | $/mo |
|------------------|------|-------|--------|----------|------|
| `s-1vcpu-2gb`    | 1    | 2 GB  | 50 GB  | 2 TB     | $12  |
| `s-2vcpu-2gb`    | 2    | 2 GB  | 60 GB  | 3 TB     | $18  |
| `s-2vcpu-4gb`    | 2    | 4 GB  | 80 GB  | 4 TB     | $24  |
| `s-4vcpu-8gb`    | 4    | 8 GB  | 160 GB | 5 TB     | $48  |
| `s-8vcpu-16gb`   | 8    | 16 GB | 320 GB | 6 TB     | $96  |

Basic tops out at 16 GB / 8 shared vCPU.

### General Purpose Droplets (Dedicated CPU, 4:1 RAM:vCPU)

Best for production. Dedicated CPU cores, balanced memory.

| Slug              | vCPU | RAM    | Disk   | Transfer | $/mo  |
|-------------------|------|--------|--------|----------|-------|
| `g-2vcpu-8gb`     | 2    | 8 GB   | 25 GB  | 4 TB     | $63   |
| `g-4vcpu-16gb`    | 4    | 16 GB  | 50 GB  | 5 TB     | $126  |
| `g-8vcpu-32gb`    | 8    | 32 GB  | 100 GB | 6 TB     | $252  |
| `g-16vcpu-64gb`   | 16   | 64 GB  | 200 GB | 7 TB     | $504  |
| `g-32vcpu-128gb`  | 32   | 128 GB | 400 GB | 8 TB     | $1008 |

Premium variants (slug prefix `gd-`) add NVMe SSD and faster networking
at slightly higher prices.

### CPU-Optimized Droplets (Dedicated CPU, 2:1 RAM:vCPU)

| Slug   | vCPU | RAM   | Disk   | Transfer | $/mo |
|--------|------|-------|--------|----------|------|
| `c-2`  | 2    | 4 GB  | 25 GB  | 4 TB     | $42  |
| `c-4`  | 4    | 8 GB  | 50 GB  | 5 TB     | $84  |
| `c-8`  | 8    | 16 GB | 100 GB | 6 TB     | $168 |
| `c-16` | 16   | 32 GB | 200 GB | 7 TB     | $336 |
| `c-32` | 32   | 64 GB | 400 GB | 8 TB     | $672 |

### Memory-Optimized Droplets (Dedicated CPU, 8:1 RAM:vCPU)

Best for large pgvector workloads.

| Slug              | vCPU | RAM    | Disk   | Transfer | $/mo  |
|-------------------|------|--------|--------|----------|-------|
| `m-2vcpu-16gb`    | 2    | 16 GB  | 50 GB  | 4 TB     | $84   |
| `m-4vcpu-32gb`    | 4    | 32 GB  | 100 GB | 5 TB     | $168  |
| `m-8vcpu-64gb`    | 8    | 64 GB  | 200 GB | 6 TB     | $336  |
| `m-16vcpu-128gb`  | 16   | 128 GB | 400 GB | 7 TB     | $672  |

### Billing

Per-second billing with a minimum of 60 seconds or $0.01. Billing
continues while powered off.

---

## Tier System

### Design

Follow the Hetzner pattern: `--tier` maps to human-readable names. Show
RAM, vCPU, and approximate monthly cost. The underlying droplet slug is
an implementation detail.

### Recommended Mapping

The script should support two families: Basic (shared, budget) and
General Purpose (dedicated, production).

| Tier     | Droplet Slug    | vCPU   | RAM   | $/mo  |
|----------|-----------------|--------|-------|-------|
| small    | `s-2vcpu-4gb`   | 2 sh   | 4 GB  | ~$25  |
| medium   | `s-4vcpu-8gb`   | 4 sh   | 8 GB  | ~$49  |
| large    | `s-8vcpu-16gb`  | 8 sh   | 16 GB | ~$97  |
| x-large  | `g-4vcpu-16gb`  | 4 ded  | 16 GB | ~$127 |
| 2x-large | `g-8vcpu-32gb`  | 8 ded  | 32 GB | ~$253 |

Notes:
- "sh" = shared vCPU, "ded" = dedicated vCPU.
- Prices include 10 GB volume ($1/mo) and reserved IP (free when
  assigned).
- x-large and above use dedicated CPU (General Purpose) for production
  stability.
- Non-interactive fallback: default to `small`.

### Interactive Prompt Design

```
Select DigitalOcean region:
  1) New York 3 (nyc3)
  2) San Francisco 3 (sfo3)
  3) Toronto (tor1)
  4) Amsterdam 3 (ams3)
  5) Frankfurt (fra1)
  6) London (lon1)
  7) Singapore (sgp1)
  8) Bangalore (blr1)
  9) Sydney (syd1)
Enter selection (1-9) or code [nyc3]:

Select instance tier:
  1) small    - 4 GB RAM, 2 shared vCPU, about $25/mo
  2) medium   - 8 GB RAM, 4 shared vCPU, about $49/mo
  3) large    - 16 GB RAM, 8 shared vCPU, about $97/mo
  4) x-large  - 16 GB RAM, 4 dedicated vCPU, about $127/mo
Enter selection (1-4) or name [small]:
```

Unlike Hetzner, all droplet types are available in all regions — no
need for location-dependent tier mapping.

---

## RAM Allocation

Same formula as Hetzner — both run JVM + Postgres on one box.

**Rule: ~70% to Postgres, ~30% to JVM, 10–15% reserved for
OS/Docker/Caddy.**

| Server RAM | OS/Docker/Caddy | GoodMem container | JVM heap% | Postgres container | shared_buffers | effective_cache_size |
|-----------|----------------|-------------------|-----------|-------------------|---------------|---------------------|
| 4 GB      | 512 MB         | 1 GB              | 65%       | 2.5 GB            | 512 MB        | 1.5 GB              |
| 8 GB      | 768 MB         | 2 GB              | 65%       | 5.2 GB            | 1 GB          | 3.5 GB              |
| 16 GB     | 1 GB           | 4 GB              | 70%       | 11 GB             | 2 GB          | 8 GB                |
| 32 GB     | 1.5 GB         | 8 GB              | 70%       | 22.5 GB           | 4 GB          | 16 GB               |
| 64 GB     | 2 GB           | 16 GB             | 70%       | 46 GB             | 8 GB (cap)    | 32 GB               |

The dynamic computation function from the Hetzner spec applies
identically here. Detect total RAM from `/proc/meminfo` in cloud-init.

---

## Managed PostgreSQL (Optional: `--managed-db`)

DigitalOcean offers managed PostgreSQL with pgvector support. This is
the optional "Option A" path, not the default.

### Pricing (Single Node)

| Slug              | vCPU | RAM   | Disk   | Connections | $/mo   |
|-------------------|------|-------|--------|-------------|--------|
| `db-s-1vcpu-1gb`  | 1    | 1 GB  | 10 GB  | 25          | $15    |
| `db-s-1vcpu-2gb`  | 1    | 2 GB  | 25 GB  | 50          | $30    |
| `db-s-2vcpu-4gb`  | 2    | 4 GB  | 38 GB  | 100         | $60    |
| `db-s-4vcpu-8gb`  | 4    | 8 GB  | 115 GB | 200         | $120   |
| `db-s-6vcpu-16gb` | 6    | 16 GB | 270 GB | 400         | $240   |

HA: add standby nodes at the same per-node price (2-node HA = 2x cost).

### pgvector Support

Fully supported. Extension name is `vector` (not `pgvector`):

```sql
CREATE EXTENSION vector;
```

Available on PostgreSQL 13–18. No support ticket needed.

### Provisioning Time

3–5 minutes. The `doctl databases create` command does **not** have a
`--wait` flag — the script must poll `doctl databases get <id>` until
status is `online`.

### Private Networking

Managed databases support VPC private endpoints. When created in the
same VPC as the Droplet, a private hostname is available:

```bash
doctl databases connection <cluster-id> --private
```

### Trusted Sources (DB Firewall)

Restrict access to specific droplets:

```bash
doctl databases firewalls append <cluster-id> --rule droplet:<droplet-id>
```

### Backups

- Daily automatic backups included in price
- 7-day retention
- Point-in-time recovery available
- Restore via fork: `doctl databases create --restore-from-cluster-name`

### Connection Pooling

Built-in PgBouncer included at no extra cost. Transaction mode
recommended. Up to 21 pools per cluster.

### When to Use `--managed-db`

- Production deployments where automated backups and HA matter
- Users who don't want to manage Postgres themselves
- Adds ~3–5 minutes to provisioning and ~$15+/mo to cost

---

## Persistent Storage: DigitalOcean Volumes

### Why

Droplet local disks persist across reboots but are lost on droplet
deletion. Postgres data must be on a Volume for durability across
droplet recreation.

### Pricing

$0.10/GiB/month. A 10 GB volume costs $1.00/mo.

### Provisioning

```bash
doctl compute volume create "${DEPLOYMENT}-pgdata" \
  --region "${REGION}" \
  --size 10GiB \
  --fs-type ext4
```

Volumes attach at `/dev/disk/by-id/scsi-0DO_Volume_<name>`.

### Cloud-Init Mount

```bash
VOLUME_DEV="/dev/disk/by-id/scsi-0DO_Volume_${VOLUME_NAME}"
MOUNT_POINT="/mnt/pgdata"

mkdir -p "$MOUNT_POINT"

if ! blkid "$VOLUME_DEV" | grep -q 'TYPE='; then
  mkfs.ext4 "$VOLUME_DEV"
fi

mount "$VOLUME_DEV" "$MOUNT_POINT"

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

### Destroy Behavior

Same as Hetzner: default to **keeping the volume**, with
`--delete-volume` for full cleanup.

---

## DNS Management

Three modes:

### Mode 1: DigitalOcean DNS

If the domain's NS records point to DigitalOcean's nameservers
(`ns1.digitalocean.com`, `ns2.digitalocean.com`, `ns3.digitalocean.com`):

```bash
# Check if domain exists
doctl compute domain list --format Domain --no-header

# Create A record
doctl compute domain records create "${DOMAIN_ZONE}" \
  --record-type A \
  --record-name "${RECORD_NAME}" \
  --record-data "${INSTANCE_IP}" \
  --record-ttl 300
```

DigitalOcean DNS is free. No per-query charges.

### Mode 2: sslip.io (Default)

When no `--domain` is passed, auto-generate a sslip.io hostname from the
droplet's IP: `<ip-with-dashes>.sslip.io`. This provides instant HTTPS
with zero DNS configuration.

### Mode 3: Manual

Print the required DNS record and let the user create it at their
provider:

```
[WARN] Create this DNS record at your DNS provider: A app.example.com -> 1.2.3.4
```

### Auto-Detection

1. If `--domain` is set, check for a matching DigitalOcean DNS zone.
2. If found, upsert the A record automatically.
3. If not found, fall back to manual mode with instructions.
4. If no `--domain` is set, use sslip.io.

### Cleanup

On `--destroy`, delete the DigitalOcean DNS record only if it still
points at this deployment's IP.

---

## TLS and Reverse Proxy (Caddy)

Identical to Hetzner. Caddy is the default (sslip.io auto-domain).

### Caddyfile

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
  reverse_proxy 127.0.0.1:${APP_GRPC_PORT} {
    transport http {
      versions h2c 2
    }
  }
}
```

- REST: public 443 → internal 8080
- gRPC: public 50051 → internal 9090

---

## Firewall Configuration

DigitalOcean Cloud Firewalls use a different syntax from Hetzner but
equivalent functionality.

```bash
# Create firewall with all rules in one command
doctl compute firewall create \
  --name "${DEPLOYMENT}-fw" \
  --droplet-ids "${DROPLET_ID}" \
  --inbound-rules \
    "protocol:tcp,ports:22,address:${ACCESS_CIDR} \
     protocol:tcp,ports:80,address:0.0.0.0/0,address:::/0 \
     protocol:tcp,ports:443,address:0.0.0.0/0,address:::/0 \
     protocol:tcp,ports:50051,address:0.0.0.0/0,address:::/0" \
  --outbound-rules \
    "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 \
     protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 \
     protocol:icmp,address:0.0.0.0/0,address:::/0"
```

Rules are space-separated `key:value` strings within a quoted argument.

### Gotcha

The firewall requires the droplet ID, which is only available after
droplet creation. The firewall must be created after the droplet, or
applied via `doctl compute firewall add-droplets` after the fact. This
differs from Hetzner where the firewall can be created first and
referenced at server creation time.

### Non-Domain Mode

When no domain is set, restrict REST and gRPC ports to `ACCESS_CIDR`
only:

```bash
"protocol:tcp,ports:8080,address:${ACCESS_CIDR} \
 protocol:tcp,ports:50051,address:${ACCESS_CIDR}"
```

---

## Reserved IPs

DigitalOcean reserved IPs (formerly floating IPs) provide a static
IPv4 address that survives droplet recreation.

| State              | Cost    |
|--------------------|---------|
| Assigned to droplet | Free    |
| Unassigned          | $5/mo   |

```bash
# Create and assign to droplet
doctl compute reserved-ip create --droplet-id "${DROPLET_ID}"

# Or create first, assign later
doctl compute reserved-ip create --region "${REGION}"
doctl compute reserved-ip-action assign "${IP}" "${DROPLET_ID}"
```

For the sslip.io auto-domain to work, the reserved IP must be assigned
before the cloud-init script runs (it detects the IP for the Caddy
config). Since `doctl compute droplet create --wait` returns after
the droplet has an IP, the flow is:

1. Create droplet with `--wait`
2. Get the droplet's public IP
3. Create reserved IP and assign it
4. The cloud-init script detects the reserved IP at boot

**Important:** If the reserved IP is assigned after cloud-init has
already started, the sslip.io domain will use the droplet's original
ephemeral IP. The reserved IP must be assigned quickly or the cloud-init
script must detect the reserved IP specifically.

---

## Docker Image

### Marketplace vs Ubuntu + Docker Install

The DigitalOcean Docker marketplace image slug is `docker-20-04`. It is
based on Ubuntu 20.04 (not 24.04). This is older than ideal.

**Recommendation:** Use `ubuntu-24-04-x64` as the base image and install
Docker via cloud-init:

```yaml
runcmd:
  - curl -fsSL https://get.docker.com | sh
```

This adds ~20–30 seconds but avoids dependence on an aging marketplace
slug and ensures a current Ubuntu LTS base. The Hetzner script can use
`docker-ce` because Hetzner keeps that image on Ubuntu 24.04.

Alternatively, discover the current Docker image dynamically:

```bash
doctl compute image list-application --format Slug,Name --no-header \
  | grep -i docker
```

---

## Cloud-Init / User-Data

DigitalOcean supports cloud-init on all images:

```bash
doctl compute droplet create "${DEPLOYMENT}" \
  --image ubuntu-24-04-x64 \
  --size "${DROPLET_SIZE}" \
  --region "${REGION}" \
  --ssh-keys "${SSH_KEY_FINGERPRINT}" \
  --user-data-file "${USER_DATA_FILE}" \
  --wait
```

The `--wait` flag blocks until the droplet API status is `active`
(typically 30–60 seconds). Cloud-init continues running after that, so
the SSH wait loop is still needed.

### Cloud-Init Script Outline

Same as Hetzner:

1. Detect total RAM, compute allocation splits
2. Set up swap (1–2 GB, swappiness=1)
3. Install Docker (if using `ubuntu-24-04-x64` base image)
4. Mount the volume for Postgres data
5. Start Postgres container with memory limits and tuned config
6. Wait for Postgres, create pgvector extension
7. Start GoodMem container with memory limits and DB connection
8. Wait for GoodMem readiness (`/readyz`)
9. Call `/v1/system/init` for root API key
10. Detect public IP, generate sslip.io domain
11. Install and configure Caddy
12. Write status file (`/opt/goodmem-digitalocean/status.json`)

---

## Regions

DigitalOcean operates 14 datacenters. All support Droplets, Managed
Databases, Volumes, and Firewalls.

| Slug   | City          | Country     | Geography |
|--------|---------------|-------------|-----------|
| `nyc1` | New York      | US          | East      |
| `nyc2` | New York      | US          | East      |
| `nyc3` | New York      | US          | East      |
| `sfo2` | San Francisco | US          | West      |
| `sfo3` | San Francisco | US          | West      |
| `tor1` | Toronto       | Canada      | N. America|
| `ams3` | Amsterdam     | Netherlands | Europe    |
| `lon1` | London        | UK          | Europe    |
| `fra1` | Frankfurt     | Germany     | Europe    |
| `sgp1` | Singapore     | Singapore   | Asia      |
| `blr1` | Bangalore     | India       | Asia      |
| `syd1` | Sydney        | Australia   | Oceania   |
| `atl1` | Atlanta       | US          | Southeast |
| `ric1` | Richmond      | US          | East      |

### Recommended Subset for Picker

- US: `nyc3`, `sfo3`
- Canada: `tor1`
- Europe: `ams3`, `fra1`, `lon1`
- Asia-Pacific: `sgp1`, `blr1`, `syd1`

Unlike Hetzner, all droplet types are available in all regions — no
location-dependent tier mapping needed.

---

## Script Structure

### CLI Flags

```
Usage: ./scripts/bootstrap_digitalocean.sh [options]

Options:
  --name NAME               Deployment slug (default: goodmem-do-<timestamp>)
  --list                    List known local DO deployments and their status
  --destroy                 Delete a deployment's resources and local state
  --delete-volume           Also delete the Postgres data volume on destroy
  --yes                     Confirm destructive actions
  --region CODE             DO region (default: nyc3; prompts if unset)
  --tier NAME               Size tier (prompts if unset)
  --droplet-size SLUG       Explicit droplet size slug (overrides --tier)
  --managed-db              Use DO Managed PostgreSQL instead of Docker Postgres
  --db-size SLUG            Managed DB size slug (default: db-s-1vcpu-1gb)
  --volume-size GB          Postgres volume size in GB (default: 10)
  --db-password PASS        Postgres password (generated if omitted)
  --profile-name NAME       GoodMem CLI profile name (default: digitalocean)
  --access-cidr CIDR        CIDR for SSH/direct access (auto-detected)
  --domain DOMAIN           Public domain for HTTPS + gRPC (sslip.io default)
  --email EMAIL             Contact email for ACME/TLS
  --image IMAGE             GoodMem server image
  --no-wait                 Exit after provisioning
  --wait-timeout SECONDS    Overall wait timeout (default: 600)
  -h, --help                Show this help
```

### Main Flow (Option B — Docker Postgres, Default)

```
1.  Parse args
2.  require_cmd doctl, curl, ssh, openssl, python3
3.  Validate doctl auth (doctl account get)
4.  Resolve region (prompt if needed)
5.  Resolve tier → droplet size (prompt if needed)
6.  Compute deployment names
7.  Load local state (if re-run)
8.  Generate DB password (if new)
9.  ensure_ssh_key (generate locally + doctl compute ssh-key import)
10. ensure_volume (doctl compute volume create)
11. Generate cloud-init user-data file
12. ensure_droplet (doctl compute droplet create --wait)
13. Attach volume if not auto-attached
14. ensure_reserved_ip (doctl compute reserved-ip create --droplet-id)
15. ensure_firewall (doctl compute firewall create --droplet-ids)
16. Finalize domain (sslip.io or --domain with DO DNS)
17. Save local state
18. If --no-wait: print summary and exit
19. wait_for_ssh
20. wait_for_bootstrap_ready (poll remote status.json)
21. If domain: wait for public HTTPS + gRPC
22. Print final summary with endpoints and API key
```

Note: firewall creation happens after droplet creation because `doctl`
requires the droplet ID to apply firewall rules. This differs from
Hetzner where the firewall can be pre-created.

### Main Flow (Option A — Managed Postgres, `--managed-db`)

Insert between steps 9 and 10:

```
9a. ensure_managed_db (doctl databases create, poll for online)
9b. Get DB connection details (doctl databases connection --private)
9c. Add trusted source (doctl databases firewalls append)
```

Skip volume creation (step 10) since Postgres data is managed.
The cloud-init script uses the managed DB connection string instead
of starting a Docker Postgres container.

### Local State

```
~/.goodmem/digitalocean-state/${DEPLOYMENT_NAME}.json
~/.goodmem/digitalocean-keys/${DEPLOYMENT_NAME}-key.pem
```

State file contents:

```json
{
  "deployment_name": "...",
  "region": "nyc3",
  "droplet_size": "s-2vcpu-4gb",
  "droplet_id": "...",
  "droplet_name": "...",
  "instance_ip": "...",
  "reserved_ip": "...",
  "volume_name": "...",
  "volume_id": "...",
  "firewall_name": "...",
  "firewall_id": "...",
  "ssh_key_name": "...",
  "ssh_key_fingerprint": "...",
  "db_password": "...",
  "domain": "",
  "dns_mode_used": "sslip",
  "managed_db": false,
  "managed_db_id": "",
  "managed_db_host": ""
}
```

### Destroy Flow

```
1.  Parse --destroy --name X --yes [--delete-volume]
2.  Load local state
3.  If domain + DO DNS: delete A record if it still points to this IP
4.  Delete reserved IP (doctl compute reserved-ip delete)
5.  Delete firewall (doctl compute firewall delete)
6.  Delete droplet (doctl compute droplet delete)
7.  If --managed-db state: delete managed DB (doctl databases delete)
8.  Delete SSH key (doctl compute ssh-key delete)
9.  If --delete-volume: delete volume (doctl compute volume delete)
    Else: log "Volume preserved. Reattach on next deploy."
10. Remove local state/key files
```

---

## Key Differences from Hetzner Script

| Aspect                    | Hetzner                              | DigitalOcean                         |
|---------------------------|--------------------------------------|--------------------------------------|
| Docker image              | `docker-ce` (Ubuntu 24.04)           | `ubuntu-24-04-x64` + install Docker  |
| Firewall timing           | Created before server                | Created after droplet (needs ID)     |
| Firewall syntax           | `hcloud firewall add-rule`           | Quoted `key:value` strings           |
| Reserved/static IP        | Included with server                 | Separate resource, free when assigned|
| Volume device path        | `/dev/disk/by-id/scsi-0HC_Volume_*`  | `/dev/disk/by-id/scsi-0DO_Volume_*`  |
| DNS CLI                   | `hcloud dns zone/record`             | `doctl compute domain/records`       |
| Managed DB option         | Not available                        | Available via `--managed-db`         |
| Region restrictions       | CX/CAX EU-only                       | All types in all regions             |
| Pricing                   | ~$10–33/mo for 16 GB                 | ~$97–127/mo for 16 GB               |
| CLI auth env var          | `HCLOUD_TOKEN`                       | `DIGITALOCEAN_ACCESS_TOKEN`          |

---

## Cost Comparison

| Deployment Configuration            | Monthly Cost |
|--------------------------------------|-------------|
| **DO small** (4 GB droplet + volume) | ~$25        |
| **DO medium** (8 GB droplet + vol)   | ~$49        |
| **DO large** (16 GB droplet + vol)   | ~$97        |
| **DO + managed PG** (4 GB + 1 GB DB) | ~$39        |
| **Lightsail small** (2 GB + mgd DB)  | ~$27        |
| **Hetzner large EU** (16 GB + vol)   | ~$10        |
| **Hetzner large US** (16 GB + vol)   | ~$33        |

DigitalOcean's entry-level pricing is competitive with Lightsail — the
small tier ($25/mo self-hosted) is actually cheaper than Lightsail small
($27/mo) and gives 4 GB RAM vs 2 GB. With managed Postgres ($39/mo),
it's ~1.4x Lightsail. Both are significantly more expensive than Hetzner
EU. At larger tiers, DO's dedicated-CPU plans diverge from Lightsail's
shared-CPU pricing, but these are not apples-to-apples comparisons.

---

## Estimated Script Size and Development

~1200–1400 lines. Heavy reuse from `bootstrap_hetzner.sh`:

- Cloud-init/user-data generation: nearly identical
- RAM allocation: identical
- Caddy/TLS: identical
- SSH wait loop: identical
- Status polling: identical
- State management: same pattern

Unique to DO:
- `doctl` command syntax for all resources
- Firewall created after droplet (different ordering)
- Reserved IP as separate resource
- Optional `--managed-db` path (~200 additional lines)
- Docker install in cloud-init (if not using marketplace image)

---

## Estimated Provisioning Time

| Phase                               | Option B (Docker PG) | Option A (Managed PG) |
|--------------------------------------|---------------------|-----------------------|
| SSH key + volume creation            | ~5s                 | ~5s                   |
| Droplet creation (`--wait`)          | 30–60s              | 30–60s                |
| Docker install (if ubuntu base)      | 20–30s              | 20–30s                |
| Managed DB provisioning              | N/A                 | 3–5 min               |
| Cloud-init (pull + start + Caddy)    | 60–120s             | 60–90s                |
| **Total**                            | **~2–4 min**        | **~5–8 min**          |
