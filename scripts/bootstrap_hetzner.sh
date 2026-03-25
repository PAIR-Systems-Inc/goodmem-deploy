#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# Hetzner bootstrap provisions a single server, volume, firewall, and SSH key,
# then uses cloud-init to launch Postgres + GoodMem on Docker.

DEPLOYMENT_NAME=""
LIST_MODE=false
DESTROY_MODE=false
DELETE_VOLUME=false
CONFIRM_DESTROY=false
LOCATION=""
LOCATION_SET=false
SIZE_TIER=""
TIER_SET=false
SERVER_TYPE=""
SERVER_TYPE_SET=false
VOLUME_SIZE_GB=10
DB_PASSWORD=""
PROFILE_NAME="hetzner"
ACCESS_CIDR=""
ACCESS_CIDR_SET=false
DOMAIN=""
CONTACT_EMAIL=""
IMAGE="ghcr.io/pair-systems-inc/goodmem/server:latest"
WAIT_FOR_READY=true
WAIT_TIMEOUT=600
WAIT_INTERVAL=5

PUBLIC_REST_PORT=443
PUBLIC_GRPC_PORT=50051
INTERNAL_REST_PORT=8080
DIRECT_REST_PORT=8080
DIRECT_GRPC_PORT=50051
DOMAIN_GRPC_PORT=9090

HCLOUD_BIN="hcloud"
STATE_ROOT="${HOME}/.goodmem"
STATE_DIR="${STATE_ROOT}/hetzner-state"
KEY_DIR="${STATE_ROOT}/hetzner-keys"
TMP_DIR=""

SERVER_NAME=""
VOLUME_NAME=""
FIREWALL_NAME=""
SSH_KEY_NAME=""
SSH_KEY_FILE=""
SSH_PUBKEY_FILE=""
STATE_FILE=""
USER_DATA_FILE=""
STATUS_FILE_REMOTE="/opt/goodmem-hetzner/status.json"
INSTANCE_IP=""
SERVER_ID=""
VOLUME_ID=""
DNS_ZONE_NAME=""
DNS_RECORD_NAME=""
DNS_MODE_USED="none"
ROOT_API_KEY=""
INIT_ALREADY=""
INIT_MESSAGE=""
SSH_USERNAME="root"

COLOR_RESET=""
COLOR_KEY=""
COLOR_ID=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_RESET=$'\033[0m'
  COLOR_KEY=$'\033[1;33m'
  COLOR_ID=$'\033[1;36m'
fi

usage() {
  cat <<'USAGE'
Usage: ./scripts/bootstrap_hetzner.sh [options]

Options:
  --name NAME               Deployment slug (default: goodmem-hetzner-<timestamp>)
  --list                    List known local Hetzner deployments and their status
  --destroy                 Delete a deployment's resources and local state
  --delete-volume           Also delete the Postgres data volume on destroy
  --yes                     Confirm destructive actions
  --location CODE           Hetzner location (prompts if unset, defaults to hil)
  --tier NAME               Size tier: small, medium, large, x-large, 2x-large, or 4x-large
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
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      DEPLOYMENT_NAME="$2"
      shift 2
      ;;
    --list)
      LIST_MODE=true
      shift
      ;;
    --destroy)
      DESTROY_MODE=true
      shift
      ;;
    --delete-volume)
      DELETE_VOLUME=true
      shift
      ;;
    --yes)
      CONFIRM_DESTROY=true
      shift
      ;;
    --location)
      LOCATION="$2"
      LOCATION_SET=true
      shift 2
      ;;
    --tier)
      SIZE_TIER="$2"
      TIER_SET=true
      shift 2
      ;;
    --server-type)
      SERVER_TYPE="$2"
      SERVER_TYPE_SET=true
      shift 2
      ;;
    --volume-size)
      VOLUME_SIZE_GB="$2"
      shift 2
      ;;
    --db-password)
      DB_PASSWORD="$2"
      shift 2
      ;;
    --profile-name)
      PROFILE_NAME="$2"
      shift 2
      ;;
    --access-cidr)
      ACCESS_CIDR="$2"
      ACCESS_CIDR_SET=true
      shift 2
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --email)
      CONTACT_EMAIL="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --no-wait)
      WAIT_FOR_READY=false
      shift
      ;;
    --wait-timeout)
      WAIT_TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  local install_hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    if [ -n "$install_hint" ]; then
      echo "Install it first: $install_hint" >&2
    fi
    exit 1
  fi
}

tty_available() {
  [ -t 0 ] || (: </dev/tty) >/dev/null 2>&1
}

json_field() {
  local expression="$1"
  python3 - "$expression" <<'PY'
import json
import sys

expr = sys.argv[1]
data = json.load(sys.stdin)
ns = {"data": data}
value = eval(expr, {"__builtins__": {}}, ns)
if value is None:
    raise SystemExit(1)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

generate_password() {
  openssl rand -hex 24
}

random_name() {
  printf 'goodmem-hetzner-%s' "$(date +%s)"
}

market_for_location() {
  case "$1" in
    fsn1|nbg1|hel1)
      printf 'eu'
      ;;
    *)
      printf 'intl'
      ;;
  esac
}

location_label() {
  case "$1" in
    hil) printf 'Hillsboro, OR, US' ;;
    ash) printf 'Ashburn, VA, US' ;;
    fsn1) printf 'Falkenstein, DE' ;;
    nbg1) printf 'Nuremberg, DE' ;;
    hel1) printf 'Helsinki, FI' ;;
    sin) printf 'Singapore' ;;
    *) printf '%s' "$1" ;;
  esac
}

apply_tier_defaults() {
  case "$SIZE_TIER" in
    small)
      if [ "$SERVER_TYPE_SET" != "true" ]; then
        case "$(market_for_location "$LOCATION")" in
          eu) SERVER_TYPE="cx23" ;;
          *) SERVER_TYPE="cpx22" ;;
        esac
      fi
      ;;
    medium)
      if [ "$SERVER_TYPE_SET" != "true" ]; then
        case "$(market_for_location "$LOCATION")" in
          eu) SERVER_TYPE="cx33" ;;
          *) SERVER_TYPE="cpx32" ;;
        esac
      fi
      ;;
    large)
      if [ "$SERVER_TYPE_SET" != "true" ]; then
        case "$(market_for_location "$LOCATION")" in
          eu) SERVER_TYPE="cx43" ;;
          *) SERVER_TYPE="cpx42" ;;
        esac
      fi
      ;;
    x-large)
      if [ "$SERVER_TYPE_SET" != "true" ]; then
        SERVER_TYPE="ccx23"
      fi
      ;;
    2x-large)
      if [ "$SERVER_TYPE_SET" != "true" ]; then
        SERVER_TYPE="ccx33"
      fi
      ;;
    4x-large)
      if [ "$SERVER_TYPE_SET" != "true" ]; then
        SERVER_TYPE="ccx43"
      fi
      ;;
    *)
      die "Unsupported tier: $SIZE_TIER (expected: small, medium, large, x-large, 2x-large, or 4x-large)"
      ;;
  esac
}

tier_summary() {
  local tier="$1"
  local market
  market="$(market_for_location "$LOCATION")"
  case "$tier:$market" in
    small:eu) printf '4 GB RAM, 2 shared vCPU, about $5/mo + self-hosted Postgres' ;;
    medium:eu) printf '8 GB RAM, 4 shared vCPU, about $8/mo + self-hosted Postgres' ;;
    large:eu) printf '16 GB RAM, 8 shared vCPU, about $14/mo + self-hosted Postgres' ;;
    x-large:eu) printf '16 GB RAM, 4 dedicated vCPU, about $37/mo + self-hosted Postgres' ;;
    2x-large:eu) printf '32 GB RAM, 8 dedicated vCPU, about $73/mo + self-hosted Postgres' ;;
    4x-large:eu) printf '64 GB RAM, 16 dedicated vCPU, about $147/mo + self-hosted Postgres' ;;
    small:*) printf '4 GB RAM, 2 shared vCPU, about $12/mo + self-hosted Postgres' ;;
    medium:*) printf '8 GB RAM, 4 shared vCPU, about $21/mo + self-hosted Postgres' ;;
    large:*) printf '16 GB RAM, 8 shared vCPU, about $39/mo + self-hosted Postgres' ;;
    x-large:*) printf '16 GB RAM, 4 dedicated vCPU, about $34/mo + self-hosted Postgres' ;;
    2x-large:*) printf '32 GB RAM, 8 dedicated vCPU, about $65/mo + self-hosted Postgres' ;;
    4x-large:*) printf '64 GB RAM, 16 dedicated vCPU, about $130/mo + self-hosted Postgres' ;;
    *)
      printf '%s' "$tier"
      ;;
  esac
}

prompt_location() {
  local tty_input=""
  local choice=""
  local prompt='Enter selection (1-6) or code [hil]: '

  if [ -t 0 ]; then
    tty_input=""
  elif tty_available; then
    tty_input="/dev/tty"
  else
    LOCATION="hil"
    LOCATION_SET=true
    log "No TTY detected; defaulting Hetzner location to ${LOCATION} ($(location_label "$LOCATION"))."
    return
  fi

  echo "Select Hetzner Cloud location:"
  echo "  1) Hillsboro, OR, US (hil)"
  echo "  2) Ashburn, VA, US (ash)"
  echo "  3) Falkenstein, DE (fsn1)"
  echo "  4) Nuremberg, DE (nbg1)"
  echo "  5) Helsinki, FI (hel1)"
  echo "  6) Singapore (sin)"

  while true; do
    if [ -n "$tty_input" ]; then
      if ! read -r -p "$prompt" choice <"$tty_input"; then
        LOCATION="hil"
        LOCATION_SET=true
        log "Unable to read from /dev/tty; defaulting Hetzner location to ${LOCATION} ($(location_label "$LOCATION"))."
        return
      fi
    else
      if ! read -r -p "$prompt" choice; then
        LOCATION="hil"
        LOCATION_SET=true
        log "Unable to read from stdin; defaulting Hetzner location to ${LOCATION} ($(location_label "$LOCATION"))."
        return
      fi
    fi
    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
    [ -z "$choice" ] && choice="hil"
    case "$choice" in
      1|hil) LOCATION="hil" ;;
      2|ash) LOCATION="ash" ;;
      3|fsn1) LOCATION="fsn1" ;;
      4|nbg1) LOCATION="nbg1" ;;
      5|hel1) LOCATION="hel1" ;;
      6|sin) LOCATION="sin" ;;
      *)
        echo "Invalid selection."
        continue
        ;;
    esac
    LOCATION_SET=true
    return
  done
}

prompt_tier() {
  local tty_input=""
  local choice=""
  local prompt='Enter selection (1-6) or name [small]: '

  default_tier() {
    SIZE_TIER="small"
    TIER_SET=true
    apply_tier_defaults
    log "$1 defaulting Hetzner tier to ${SIZE_TIER} ($(tier_summary "$SIZE_TIER"))."
  }

  if [ -t 0 ]; then
    tty_input=""
  elif tty_available; then
    tty_input="/dev/tty"
  else
    default_tier "No TTY detected;"
    return
  fi

  echo "Select Hetzner instance tier:"
  echo "  1) small    - $(tier_summary small)"
  echo "  2) medium   - $(tier_summary medium)"
  echo "  3) large    - $(tier_summary large)"
  echo "  4) x-large  - $(tier_summary x-large)"
  echo "  5) 2x-large - $(tier_summary 2x-large)"
  echo "  6) 4x-large - $(tier_summary 4x-large)"

  while true; do
    if [ -n "$tty_input" ]; then
      if ! read -r -p "$prompt" choice <"$tty_input"; then
        default_tier "Unable to read from /dev/tty;"
        return
      fi
    else
      if ! read -r -p "$prompt" choice; then
        default_tier "Unable to read from stdin;"
        return
      fi
    fi
    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
    [ -z "$choice" ] && choice="small"
    case "$choice" in
      1|small) SIZE_TIER="small" ;;
      2|medium) SIZE_TIER="medium" ;;
      3|large) SIZE_TIER="large" ;;
      4|x-large|xlarge) SIZE_TIER="x-large" ;;
      5|2x-large|2xlarge) SIZE_TIER="2x-large" ;;
      6|4x-large|4xlarge) SIZE_TIER="4x-large" ;;
      *)
        echo "Invalid selection."
        continue
        ;;
    esac
    TIER_SET=true
    apply_tier_defaults
    log "Using ${SIZE_TIER} tier ($(tier_summary "$SIZE_TIER"))."
    return
  done
}

ensure_location() {
  if [ -n "$LOCATION" ]; then
    LOCATION_SET=true
    return
  fi
  prompt_location
}

ensure_tier() {
  if [ "$SERVER_TYPE_SET" = true ]; then
    return
  fi
  if [ "$TIER_SET" = true ]; then
    apply_tier_defaults
    return
  fi
  prompt_tier
}

ensure_names() {
  [ -n "$DEPLOYMENT_NAME" ] || DEPLOYMENT_NAME="$(random_name)"
  SERVER_NAME="$DEPLOYMENT_NAME"
  VOLUME_NAME="${DEPLOYMENT_NAME}-pgdata"
  FIREWALL_NAME="${DEPLOYMENT_NAME}-fw"
  SSH_KEY_NAME="${DEPLOYMENT_NAME}-key"
  mkdir -p "$STATE_DIR" "$KEY_DIR"
  STATE_FILE="${STATE_DIR}/${DEPLOYMENT_NAME}.json"
  SSH_KEY_FILE="${KEY_DIR}/${DEPLOYMENT_NAME}-key.pem"
  SSH_PUBKEY_FILE="${SSH_KEY_FILE}.pub"
}

load_local_state() {
  if [ ! -f "$STATE_FILE" ]; then
    return
  fi

  eval "$(
    python3 - "$STATE_FILE" <<'PY'
import json
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
mapping = {
    "LOCATION": data.get("location", ""),
    "SERVER_TYPE": data.get("server_type", ""),
    "INSTANCE_IP": data.get("server_ip", ""),
    "VOLUME_ID": str(data.get("volume_id", "")),
    "DB_PASSWORD": data.get("db_password", ""),
    "DOMAIN": data.get("domain", ""),
    "DNS_ZONE_NAME": data.get("dns_zone_name", ""),
    "DNS_RECORD_NAME": data.get("dns_record_name", ""),
    "DNS_MODE_USED": data.get("dns_mode_used", "none"),
    "PROFILE_NAME": data.get("profile_name", "hetzner"),
}
for key, value in mapping.items():
    print(f"{key}={shlex.quote(value)}")
PY
  )"
}

save_local_state() {
  python3 - "$STATE_FILE" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "deployment_name": os.environ["DEPLOYMENT_NAME"],
    "location": os.environ.get("LOCATION", ""),
    "server_type": os.environ.get("SERVER_TYPE", ""),
    "server_name": os.environ.get("SERVER_NAME", ""),
    "server_ip": os.environ.get("INSTANCE_IP", ""),
    "volume_name": os.environ.get("VOLUME_NAME", ""),
    "volume_id": os.environ.get("VOLUME_ID", ""),
    "firewall_name": os.environ.get("FIREWALL_NAME", ""),
    "ssh_key_name": os.environ.get("SSH_KEY_NAME", ""),
    "db_password": os.environ.get("DB_PASSWORD", ""),
    "domain": os.environ.get("DOMAIN", ""),
    "dns_zone_name": os.environ.get("DNS_ZONE_NAME", ""),
    "dns_record_name": os.environ.get("DNS_RECORD_NAME", ""),
    "dns_mode_used": os.environ.get("DNS_MODE_USED", "none"),
    "profile_name": os.environ.get("PROFILE_NAME", "hetzner"),
}
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
}

auto_detect_access_cidr() {
  if [ "$ACCESS_CIDR_SET" = true ]; then
    return
  fi
  local ip=""
  ip="$(curl -fsSL https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  if [ -n "$ip" ]; then
    ACCESS_CIDR="${ip}/32"
    log "Using access CIDR ${ACCESS_CIDR} from public IP autodetect."
  else
    ACCESS_CIDR="0.0.0.0/0"
    warn "Could not autodetect public IP; defaulting SSH/direct access to ${ACCESS_CIDR}."
  fi
}

validate_hcloud_auth() {
  if ! "$HCLOUD_BIN" location list -o json >/dev/null 2>&1; then
    die "hcloud CLI is not authenticated or HCLOUD_TOKEN is missing."
  fi
}

server_exists() {
  "$HCLOUD_BIN" server describe "$SERVER_NAME" -o json >/dev/null 2>&1
}

volume_exists() {
  "$HCLOUD_BIN" volume describe "$VOLUME_NAME" -o json >/dev/null 2>&1
}

firewall_exists() {
  "$HCLOUD_BIN" firewall describe "$FIREWALL_NAME" -o json >/dev/null 2>&1
}

ssh_key_exists() {
  "$HCLOUD_BIN" ssh-key describe "$SSH_KEY_NAME" -o json >/dev/null 2>&1
}

refresh_server_metadata() {
  local server_json=""
  server_json="$("$HCLOUD_BIN" server describe "$SERVER_NAME" -o json)"
  SERVER_ID="$(printf '%s' "$server_json" | json_field 'data.get("server", data).get("id")')"
  INSTANCE_IP="$(printf '%s' "$server_json" | json_field 'data.get("server", data).get("public_net", {}).get("ipv4", {}).get("ip")')"
}

refresh_volume_metadata() {
  local volume_json=""
  volume_json="$("$HCLOUD_BIN" volume describe "$VOLUME_NAME" -o json)"
  VOLUME_ID="$(printf '%s' "$volume_json" | json_field 'data.get("volume", data).get("id")')"
}

server_status() {
  local server_json=""
  if ! server_json="$("$HCLOUD_BIN" server describe "$SERVER_NAME" -o json 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "$server_json" | json_field 'data.get("server", data).get("status")'
}

ensure_local_ssh_key() {
  if [ -f "$SSH_KEY_FILE" ] && [ -f "$SSH_PUBKEY_FILE" ]; then
    return
  fi
  log "Generating SSH key ${SSH_KEY_FILE}..."
  rm -f "$SSH_KEY_FILE" "$SSH_PUBKEY_FILE"
  ssh-keygen -q -t ed25519 -N '' -C "$SSH_KEY_NAME" -f "$SSH_KEY_FILE"
  chmod 600 "$SSH_KEY_FILE"
}

ensure_hcloud_ssh_key() {
  ensure_local_ssh_key
  if ssh_key_exists; then
    return
  fi
  log "Creating Hetzner SSH key ${SSH_KEY_NAME}..."
  "$HCLOUD_BIN" ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "$SSH_PUBKEY_FILE" >/dev/null
}

ensure_firewall() {
  if firewall_exists; then
    return
  fi

  log "Creating firewall ${FIREWALL_NAME}..."
  "$HCLOUD_BIN" firewall create --name "$FIREWALL_NAME" >/dev/null
  "$HCLOUD_BIN" firewall add-rule "$FIREWALL_NAME" \
    --direction in --protocol tcp --port 22 \
    --source-ips "$ACCESS_CIDR" >/dev/null

  if [ -n "$DOMAIN" ]; then
    "$HCLOUD_BIN" firewall add-rule "$FIREWALL_NAME" \
      --direction in --protocol tcp --port 80 \
      --source-ips 0.0.0.0/0 --source-ips ::/0 >/dev/null
    "$HCLOUD_BIN" firewall add-rule "$FIREWALL_NAME" \
      --direction in --protocol tcp --port 443 \
      --source-ips 0.0.0.0/0 --source-ips ::/0 >/dev/null
    "$HCLOUD_BIN" firewall add-rule "$FIREWALL_NAME" \
      --direction in --protocol tcp --port "$PUBLIC_GRPC_PORT" \
      --source-ips 0.0.0.0/0 --source-ips ::/0 >/dev/null
  else
    "$HCLOUD_BIN" firewall add-rule "$FIREWALL_NAME" \
      --direction in --protocol tcp --port "$DIRECT_REST_PORT" \
      --source-ips "$ACCESS_CIDR" >/dev/null
    "$HCLOUD_BIN" firewall add-rule "$FIREWALL_NAME" \
      --direction in --protocol tcp --port "$DIRECT_GRPC_PORT" \
      --source-ips "$ACCESS_CIDR" >/dev/null
  fi
}

ensure_volume() {
  if volume_exists; then
    refresh_volume_metadata
    return
  fi
  log "Creating volume ${VOLUME_NAME} (${VOLUME_SIZE_GB} GB)..."
  "$HCLOUD_BIN" volume create \
    --name "$VOLUME_NAME" \
    --size "$VOLUME_SIZE_GB" \
    --location "$LOCATION" \
    --format ext4 >/dev/null
  refresh_volume_metadata
}

bootstrap_app_grpc_port() {
  if [ -n "$DOMAIN" ]; then
    printf '%s' "$DOMAIN_GRPC_PORT"
  else
    printf '%s' "$DIRECT_GRPC_PORT"
  fi
}

write_user_data_file() {
  local app_grpc_port
  local enable_public_proxy
  local app_bind_host
  local rest_tls_enabled
  local grpc_tls_enabled

  app_grpc_port="$(bootstrap_app_grpc_port)"
  if [ -n "$DOMAIN" ]; then
    enable_public_proxy="true"
    app_bind_host="127.0.0.1"
    rest_tls_enabled="false"
    grpc_tls_enabled="false"
  else
    enable_public_proxy="false"
    app_bind_host="0.0.0.0"
    rest_tls_enabled="true"
    grpc_tls_enabled="true"
  fi

  USER_DATA_FILE="$(mktemp "${TMP_DIR}/hetzner-user-data-XXXX.yaml")"
  cat >"$USER_DATA_FILE" <<EOF
#cloud-config
package_update: true
write_files:
  - path: /root/goodmem-hetzner-bootstrap.sh
    permissions: '0700'
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      STATUS_DIR="/opt/goodmem-hetzner"
      STATUS_FILE="${STATUS_FILE_REMOTE}"
      GOODMEM_IMAGE="${IMAGE}"
      POSTGRES_IMAGE="pgvector/pgvector:pg17"
      DB_CONTAINER="goodmem-postgres"
      APP_CONTAINER="goodmem-server"
      NETWORK_NAME="goodmem-net"
      DB_USER="goodmem"
      DB_NAME="goodmem"
      DB_PASSWORD="${DB_PASSWORD}"
      PUBLIC_DOMAIN="${DOMAIN}"
      CONTACT_EMAIL="${CONTACT_EMAIL}"
      ENABLE_PUBLIC_PROXY="${enable_public_proxy}"
      VOLUME_DEV="/dev/disk/by-id/scsi-0HC_Volume_${VOLUME_ID}"
      MOUNT_POINT="/mnt/pgdata"
      REST_PORT=${INTERNAL_REST_PORT}
      APP_GRPC_PORT=${app_grpc_port}
      PUBLIC_GRPC_PORT=${PUBLIC_GRPC_PORT}
      APP_BIND_HOST="${app_bind_host}"
      REST_TLS_ENABLED="${rest_tls_enabled}"
      GRPC_TLS_ENABLED="${grpc_tls_enabled}"
      PROFILE_NAME="${PROFILE_NAME}"

      mkdir -p "\${STATUS_DIR}"

      write_status() {
        local state="\$1"
        local message="\$2"
        export STATUS_STATE="\${state}" STATUS_MESSAGE="\${message}" STATUS_FILE
        python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ["STATUS_FILE"])
payload = {"state": os.environ["STATUS_STATE"], "message": os.environ["STATUS_MESSAGE"]}
if path.exists():
    try:
        payload = json.loads(path.read_text()) | payload
    except Exception:
        pass
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
      }

      trap 'write_status FAILED "command failed at line \$LINENO: \$BASH_COMMAND"' ERR
      write_status STARTING "bootstrap started"

      total_mb=\$(awk '/MemTotal:/ {print int(\$2/1024)}' /proc/meminfo)
      os_reserve=\$(( total_mb * 15 / 100 ))
      [ "\${os_reserve}" -lt 384 ] && os_reserve=384
      [ "\${os_reserve}" -gt 2048 ] && os_reserve=2048
      available_mb=\$(( total_mb - os_reserve ))
      goodmem_mb=\$(( available_mb * 30 / 100 ))
      postgres_mb=\$(( available_mb - goodmem_mb ))
      jvm_ram_pct=70
      if [ "\${goodmem_mb}" -lt 768 ]; then
        jvm_ram_pct=50
      elif [ "\${goodmem_mb}" -lt 1536 ]; then
        jvm_ram_pct=65
      fi
      shared_buffers_mb=\$(( postgres_mb * 25 / 100 ))
      [ "\${shared_buffers_mb}" -lt 128 ] && shared_buffers_mb=128
      [ "\${shared_buffers_mb}" -gt 8192 ] && shared_buffers_mb=8192
      effective_cache_mb=\$(( postgres_mb * 70 / 100 ))
      work_mem_mb=4
      [ "\${postgres_mb}" -ge 2048 ] && work_mem_mb=8
      [ "\${postgres_mb}" -ge 4096 ] && work_mem_mb=16
      [ "\${postgres_mb}" -ge 8192 ] && work_mem_mb=32
      [ "\${postgres_mb}" -ge 16384 ] && work_mem_mb=64
      maint_mem_mb=64
      [ "\${postgres_mb}" -ge 2048 ] && maint_mem_mb=128
      [ "\${postgres_mb}" -ge 4096 ] && maint_mem_mb=256
      [ "\${postgres_mb}" -ge 8192 ] && maint_mem_mb=512
      [ "\${postgres_mb}" -ge 16384 ] && maint_mem_mb=1024
      [ "\${postgres_mb}" -ge 32768 ] && maint_mem_mb=2048

      swap_mb=1024
      [ "\${total_mb}" -gt 8192 ] && swap_mb=2048
      if [ ! -f /swapfile ]; then
        write_status CONFIGURING_SWAP "configuring swap"
        fallocate -l "\${swap_mb}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="\${swap_mb}"
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
      fi
      sysctl -w vm.swappiness=1 >/dev/null
      if ! grep -q '^vm.swappiness=1$' /etc/sysctl.conf; then
        echo 'vm.swappiness=1' >> /etc/sysctl.conf
      fi

      write_status WAITING_FOR_VOLUME "waiting for attached volume"
      for _ in \$(seq 1 60); do
        [ -b "\${VOLUME_DEV}" ] && break
        sleep 5
      done
      if [ ! -b "\${VOLUME_DEV}" ]; then
        echo "volume device not found: \${VOLUME_DEV}" >&2
        exit 1
      fi

      mkdir -p "\${MOUNT_POINT}"
      if ! blkid "\${VOLUME_DEV}" | grep -q 'TYPE='; then
        mkfs.ext4 "\${VOLUME_DEV}"
      fi
      if ! mountpoint -q "\${MOUNT_POINT}"; then
        mount "\${VOLUME_DEV}" "\${MOUNT_POINT}"
      fi
      if ! grep -q "\${VOLUME_DEV}" /etc/fstab; then
        echo "\${VOLUME_DEV} \${MOUNT_POINT} ext4 defaults 0 2" >> /etc/fstab
      fi

      docker network inspect "\${NETWORK_NAME}" >/dev/null 2>&1 || docker network create "\${NETWORK_NAME}" >/dev/null
      docker rm -f "\${DB_CONTAINER}" "\${APP_CONTAINER}" >/dev/null 2>&1 || true

      write_status STARTING_DATABASE "starting PostgreSQL"
      docker run -d \
        --name "\${DB_CONTAINER}" \
        --restart unless-stopped \
        --memory "\${postgres_mb}m" \
        --network "\${NETWORK_NAME}" \
        -v "\${MOUNT_POINT}:/var/lib/postgresql/data" \
        -e POSTGRES_USER="\${DB_USER}" \
        -e POSTGRES_DB="\${DB_NAME}" \
        -e POSTGRES_PASSWORD="\${DB_PASSWORD}" \
        "\${POSTGRES_IMAGE}" \
        postgres \
          -c shared_buffers="\${shared_buffers_mb}MB" \
          -c effective_cache_size="\${effective_cache_mb}MB" \
          -c work_mem="\${work_mem_mb}MB" \
          -c maintenance_work_mem="\${maint_mem_mb}MB" \
          -c max_connections=30 >/dev/null

      for _ in \$(seq 1 60); do
        if docker exec "\${DB_CONTAINER}" pg_isready -U "\${DB_USER}" -d "\${DB_NAME}" >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done
      docker exec -e PGPASSWORD="\${DB_PASSWORD}" "\${DB_CONTAINER}" \
        psql -U "\${DB_USER}" -d "\${DB_NAME}" -c 'CREATE EXTENSION IF NOT EXISTS vector;' >/dev/null

      write_status STARTING_GOODMEM "starting GoodMem"
      if [ "\${APP_BIND_HOST}" = "127.0.0.1" ]; then
        rest_publish="127.0.0.1:\${REST_PORT}:\${REST_PORT}"
        grpc_publish="127.0.0.1:\${APP_GRPC_PORT}:\${APP_GRPC_PORT}"
      else
        rest_publish="\${REST_PORT}:\${REST_PORT}"
        grpc_publish="\${APP_GRPC_PORT}:\${APP_GRPC_PORT}"
      fi

      docker run -d \
        --name "\${APP_CONTAINER}" \
        --restart unless-stopped \
        --memory "\${goodmem_mb}m" \
        --network "\${NETWORK_NAME}" \
        -p "\${rest_publish}" \
        -p "\${grpc_publish}" \
        -e PORT="\${REST_PORT}" \
        -e GOODMEM_REST_TLS_ENABLED="\${REST_TLS_ENABLED}" \
        -e GOODMEM_GRPC_TLS_ENABLED="\${GRPC_TLS_ENABLED}" \
        -e GOODMEM_GRPC_PORT="\${APP_GRPC_PORT}" \
        -e DB_URL="jdbc:postgresql://\${DB_CONTAINER}:5432/\${DB_NAME}?sslmode=disable" \
        -e JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=\${jvm_ram_pct} -XX:InitialRAMPercentage=25" \
        "\${GOODMEM_IMAGE}" >/dev/null

      if [ "\${REST_TLS_ENABLED}" = "true" ]; then
        local_ready_url="https://127.0.0.1:\${REST_PORT}/readyz"
        local_init_url="https://127.0.0.1:\${REST_PORT}/v1/system/init"
        local_curl_args=(-ksS)
      else
        local_ready_url="http://127.0.0.1:\${REST_PORT}/readyz"
        local_init_url="http://127.0.0.1:\${REST_PORT}/v1/system/init"
        local_curl_args=(-fsS)
      fi

      for _ in \$(seq 1 60); do
        if curl "\${local_curl_args[@]}" -o /dev/null "\${local_ready_url}" >/dev/null 2>&1; then
          break
        fi
        sleep 5
      done

      init_response="\$(curl "\${local_curl_args[@]}" -X POST "\${local_init_url}")"
      export INIT_RESPONSE="\${init_response}"
      eval "\$(
        python3 - <<'PY'
import json
import os
import shlex

data = json.loads(os.environ["INIT_RESPONSE"])
payload = {
    "ROOT_API_KEY": data.get("rootApiKey", ""),
    "INIT_ALREADY": "true" if data.get("alreadyInitialized") else "false",
    "INIT_MESSAGE": data.get("message", ""),
}
for key, value in payload.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
      )"

      if [ "\${ENABLE_PUBLIC_PROXY}" = "true" ]; then
        write_status CONFIGURING_PROXY "configuring public HTTPS proxy"
        apt-get install -y caddy
        mkdir -p /etc/caddy
        cat >/etc/caddy/Caddyfile <<'CADDYFILE'
{
  admin off
CADDYFILE
        if [ -n "\${CONTACT_EMAIL}" ]; then
          printf '  email %s\n' "\${CONTACT_EMAIL}" >> /etc/caddy/Caddyfile
        fi
        cat >>/etc/caddy/Caddyfile <<CADDYFILE
}

\${PUBLIC_DOMAIN} {
  encode zstd gzip
  reverse_proxy http://127.0.0.1:\${REST_PORT}
}

\${PUBLIC_DOMAIN}:\${PUBLIC_GRPC_PORT} {
  reverse_proxy 127.0.0.1:\${APP_GRPC_PORT} {
    transport http {
      versions h2c 2
    }
  }
}
CADDYFILE
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
        systemctl enable caddy
        systemctl restart caddy
      fi

      export ROOT_API_KEY INIT_ALREADY INIT_MESSAGE STATUS_FILE REST_PORT APP_GRPC_PORT PUBLIC_GRPC_PORT
      python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path(os.environ["STATUS_FILE"])
payload = {
    "state": "READY",
    "message": "bootstrap complete",
    "api_key": os.environ.get("ROOT_API_KEY", ""),
    "init_already": os.environ.get("INIT_ALREADY", "false"),
    "init_message": os.environ.get("INIT_MESSAGE", ""),
    "rest_port": int(os.environ["REST_PORT"]),
    "grpc_port": int(os.environ["APP_GRPC_PORT"]),
    "public_grpc_port": int(os.environ["PUBLIC_GRPC_PORT"]),
}
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
PY
runcmd:
  - [bash, /root/goodmem-hetzner-bootstrap.sh]
EOF
}

ensure_server() {
  if server_exists; then
    refresh_server_metadata
    return
  fi

  write_user_data_file
  log "Creating server ${SERVER_NAME} (${SERVER_TYPE} in ${LOCATION})..."
  "$HCLOUD_BIN" server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --image docker-ce \
    --location "$LOCATION" \
    --ssh-key "$SSH_KEY_NAME" \
    --firewall "$FIREWALL_NAME" \
    --user-data-from-file "$USER_DATA_FILE" >/dev/null
  refresh_server_metadata
}

ensure_volume_attached() {
  local volume_json attached_to
  volume_json="$("$HCLOUD_BIN" volume describe "$VOLUME_NAME" -o json)"
  attached_to="$(printf '%s' "$volume_json" | json_field '",".join(str(item.get("server")) for item in data.get("volume", data).get("server", []) if isinstance(item, dict) and item.get("server")) if isinstance(data.get("volume", data).get("server"), list) else ""' 2>/dev/null || true)"
  if [ -n "$attached_to" ] && [[ ",${attached_to}," == *",${SERVER_ID},"* ]]; then
    return
  fi
  log "Attaching volume ${VOLUME_NAME} to ${SERVER_NAME}..."
  "$HCLOUD_BIN" volume attach "$VOLUME_NAME" --server "$SERVER_NAME" >/dev/null || true
}

relative_record_name() {
  local domain_name="$1"
  local zone_name="$2"
  if [ "$domain_name" = "$zone_name" ]; then
    printf '@'
    return
  fi
  printf '%s' "${domain_name%.$zone_name}"
}

find_dns_zone_for_domain() {
  if [ -z "$DOMAIN" ]; then
    return
  fi

  local zone_json best_zone
  if ! zone_json="$("$HCLOUD_BIN" zone list -o json 2>/dev/null)"; then
    return
  fi

  best_zone="$(
    printf '%s' "$zone_json" | python3 - "$DOMAIN" <<'PY'
import json
import sys

domain = sys.argv[1].rstrip(".").lower()
data = json.load(sys.stdin)
zones = data.get("zones", data if isinstance(data, list) else [])
best = ""
for zone in zones:
    name = (zone.get("name") or "").rstrip(".").lower()
    if not name:
        continue
    if domain == name or domain.endswith("." + name):
        if len(name) > len(best):
            best = name
print(best)
PY
  )"

  if [ -n "$best_zone" ]; then
    DNS_ZONE_NAME="$best_zone"
    DNS_RECORD_NAME="$(relative_record_name "$DOMAIN" "$DNS_ZONE_NAME")"
  fi
}

delete_dns_rrset() {
  [ -n "$DNS_ZONE_NAME" ] || return
  [ -n "$DNS_RECORD_NAME" ] || return
  "$HCLOUD_BIN" zone rrset delete "$DNS_ZONE_NAME" --name "$DNS_RECORD_NAME" --type A >/dev/null 2>&1 || true
}

upsert_dns_rrset() {
  if [ -z "$DOMAIN" ]; then
    return
  fi
  find_dns_zone_for_domain
  if [ -z "$DNS_ZONE_NAME" ]; then
    DNS_MODE_USED="manual"
    warn "No matching Hetzner DNS zone found for ${DOMAIN}."
    warn "Create this DNS record at your DNS provider: A ${DOMAIN} -> ${INSTANCE_IP}"
    return
  fi

  log "Updating Hetzner DNS A record ${DOMAIN} -> ${INSTANCE_IP} in zone ${DNS_ZONE_NAME}..."
  delete_dns_rrset
  "$HCLOUD_BIN" zone rrset create "$DNS_ZONE_NAME" \
    --name "$DNS_RECORD_NAME" \
    --type A \
    --record "$INSTANCE_IP" >/dev/null
  DNS_MODE_USED="hetzner"
}

wait_for_running() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  local state=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state="$(server_status || true)"
    if [ "$state" = "running" ]; then
      return
    fi
    sleep "$WAIT_INTERVAL"
  done
  die "Timed out waiting for server ${SERVER_NAME} to reach running state."
}

run_ssh() {
  local remote_cmd="$1"
  ssh \
    -n \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -i "$SSH_KEY_FILE" \
    "${SSH_USERNAME}@${INSTANCE_IP}" \
    "$remote_cmd"
}

wait_for_ssh() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if run_ssh "true" >/dev/null 2>&1; then
      return
    fi
    sleep "$WAIT_INTERVAL"
  done
  die "Timed out waiting for SSH on ${INSTANCE_IP}."
}

fetch_remote_status() {
  run_ssh "cat '${STATUS_FILE_REMOTE}' 2>/dev/null || true" 2>/dev/null || true
}

wait_for_bootstrap_ready() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  local last_state=""
  local status_json=""
  local state=""
  local message=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status_json="$(fetch_remote_status)"
    if [ -n "$status_json" ]; then
      state="$(printf '%s' "$status_json" | json_field 'data.get("state", "")' 2>/dev/null || true)"
      message="$(printf '%s' "$status_json" | json_field 'data.get("message", "")' 2>/dev/null || true)"
      if [ -n "$state" ] && [ "$state" != "$last_state" ]; then
        log "Remote bootstrap state: ${state}${message:+ - ${message}}"
        last_state="$state"
      fi
      if [ "$state" = "FAILED" ]; then
        die "Remote bootstrap failed: ${message:-unknown failure}"
      fi
      if [ "$state" = "READY" ]; then
        ROOT_API_KEY="$(printf '%s' "$status_json" | json_field 'data.get("api_key", "")' 2>/dev/null || true)"
        INIT_ALREADY="$(printf '%s' "$status_json" | json_field 'data.get("init_already", "")' 2>/dev/null || true)"
        INIT_MESSAGE="$(printf '%s' "$status_json" | json_field 'data.get("init_message", "")' 2>/dev/null || true)"
        return
      fi
    fi
    sleep "$WAIT_INTERVAL"
  done
  die "Timed out waiting for remote bootstrap readiness."
}

wait_for_domain_resolution() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  local resolved=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    resolved="$(python3 - "$DOMAIN" <<'PY'
import socket
import sys

host = sys.argv[1]
try:
    print(socket.gethostbyname(host))
except Exception:
    pass
PY
)"
    if [ "$resolved" = "$INSTANCE_IP" ]; then
      return 0
    fi
    sleep "$WAIT_INTERVAL"
  done
  return 1
}

wait_for_public_https() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -fsS "https://${DOMAIN}/readyz" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$WAIT_INTERVAL"
  done
  return 1
}

wait_for_public_grpc() {
  local deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
  local code=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code="$(curl -sk --http2 --max-time 5 -o /dev/null -w '%{http_code}' "https://${DOMAIN}:${PUBLIC_GRPC_PORT}" || true)"
    if [ "$code" = "415" ]; then
      return 0
    fi
    sleep "$WAIT_INTERVAL"
  done
  return 1
}

print_no_wait_summary() {
  cat <<EOF
Bootstrap started.

Deployment:
- Name: ${DEPLOYMENT_NAME}
- Location: ${LOCATION} ($(location_label "$LOCATION"))
- Server type: ${SERVER_TYPE}
- Server IP: ${INSTANCE_IP}
- Volume: ${VOLUME_NAME}

State:
- Local state: ${STATE_FILE}
- SSH key: ${SSH_KEY_FILE}

Next:
- Re-run this command without --no-wait to wait for readiness and print the API key.
EOF

  if [ -n "$DOMAIN" ]; then
    cat <<EOF

DNS:
- Domain: ${DOMAIN}
EOF
    if [ "$DNS_MODE_USED" = "hetzner" ]; then
      cat <<EOF
- DNS was updated in Hetzner zone ${DNS_ZONE_NAME}.
EOF
    else
      cat <<EOF
- Create this DNS record manually: A ${DOMAIN} -> ${INSTANCE_IP}
EOF
    fi
  else
    cat <<EOF

Direct access:
- REST: https://${INSTANCE_IP}:${DIRECT_REST_PORT}
- gRPC: https://${INSTANCE_IP}:${DIRECT_GRPC_PORT}
- Access is restricted to ${ACCESS_CIDR}
EOF
  fi
}

print_ready_summary() {
  cat <<EOF
Bootstrap complete.

Deployment:
- Name: ${DEPLOYMENT_NAME}
- Location: ${LOCATION} ($(location_label "$LOCATION"))
- Server type: ${SERVER_TYPE}
- Server IP: ${INSTANCE_IP}
- Volume: ${VOLUME_NAME}
- Local state: ${STATE_FILE}
- SSH key: ${SSH_KEY_FILE}
EOF

  if [ -n "$DOMAIN" ]; then
    cat <<EOF

Endpoints:
- REST: https://${DOMAIN}
- gRPC: https://${DOMAIN}:${PUBLIC_GRPC_PORT}
EOF
  else
    cat <<EOF

Endpoints:
- REST: https://${INSTANCE_IP}:${DIRECT_REST_PORT}
- gRPC: https://${INSTANCE_IP}:${DIRECT_GRPC_PORT}
- Note: self-signed TLS; clients should use -k / insecure mode for first-time testing.
EOF
  fi

  if [ -n "$INIT_MESSAGE" ]; then
    cat <<EOF

Init:
- ${INIT_MESSAGE}
EOF
  fi
  if [ -n "$ROOT_API_KEY" ]; then
    cat <<EOF
- Root API key: ${COLOR_KEY}${ROOT_API_KEY}${COLOR_RESET}
EOF
  elif [ "$INIT_ALREADY" = "true" ]; then
    cat <<EOF
- System was already initialized; root API key was not returned.
EOF
  fi

  if [ -n "$ROOT_API_KEY" ]; then
    if [ -n "$DOMAIN" ]; then
      cat <<EOF

CLI example:
- goodmem --server https://${DOMAIN}:${PUBLIC_GRPC_PORT} --api-key ${ROOT_API_KEY} system health
EOF
    else
      cat <<EOF

CLI example:
- goodmem --server https://${INSTANCE_IP}:${DIRECT_GRPC_PORT} --api-key ${ROOT_API_KEY} system health
EOF
    fi
  fi
}

list_known_deployments() {
  mkdir -p "$STATE_DIR"
  shopt -s nullglob
  local state_path=""
  local name=""
  local location=""
  local domain_value=""
  local server_name_value=""
  local volume_name_value=""
  local server_state=""
  local volume_state=""

  if [ "$(find "$STATE_DIR" -maxdepth 1 -name '*.json' | wc -l)" -eq 0 ]; then
    echo "No Hetzner deployments found under ${STATE_DIR}."
    return
  fi

  for state_path in "$STATE_DIR"/*.json; do
    eval "$(
      python3 - "$state_path" <<'PY'
import json
import pathlib
import shlex
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
fields = {
    "name": data.get("deployment_name", path.stem),
    "location": data.get("location", ""),
    "domain": data.get("domain", ""),
    "server_name": data.get("server_name", ""),
    "volume_name": data.get("volume_name", ""),
    "state_path": str(path),
}
for key, value in fields.items():
    print(f"{key.upper()}={shlex.quote(str(value))}")
PY
    )"

    server_state="unknown"
    volume_state="unknown"
    if command -v "$HCLOUD_BIN" >/dev/null 2>&1; then
      server_state="$("$HCLOUD_BIN" server describe "$SERVER_NAME" -o json 2>/dev/null | json_field 'data.get("server", data).get("status")' 2>/dev/null || echo missing)"
      if "$HCLOUD_BIN" volume describe "$VOLUME_NAME" -o json >/dev/null 2>&1; then
        volume_state="present"
      else
        volume_state="missing"
      fi
    fi

    cat <<EOF
Name:       ${NAME}
Location:   ${LOCATION:-"-"}
Domain:     ${DOMAIN:-"-"}
Server:     ${SERVER_NAME:-"-"} (${server_state})
Volume:     ${VOLUME_NAME:-"-"} (${volume_state})
State file: ${STATE_PATH}

EOF
  done
}

print_destroy_confirmation() {
  cat <<EOF
About to destroy Hetzner deployment ${DEPLOYMENT_NAME}.

Resources:
- Server: ${SERVER_NAME}
- Firewall: ${FIREWALL_NAME}
- SSH key: ${SSH_KEY_NAME}
- Volume: ${VOLUME_NAME} ($(if [ "$DELETE_VOLUME" = true ]; then echo "delete"; else echo "preserve"; fi))
- Domain: ${DOMAIN:-"-"}

Re-run with:
  ./scripts/bootstrap_hetzner.sh --destroy --name ${DEPLOYMENT_NAME} $(if [ "$DELETE_VOLUME" = true ]; then echo "--delete-volume "; fi)--yes
EOF
}

destroy_dns_record_if_managed() {
  if [ "$DNS_MODE_USED" != "hetzner" ] || [ -z "$DNS_ZONE_NAME" ] || [ -z "$DNS_RECORD_NAME" ] || [ -z "$INSTANCE_IP" ]; then
    return
  fi
  delete_dns_rrset
}

destroy_deployment() {
  destroy_dns_record_if_managed
  if server_exists; then
    log "Deleting server ${SERVER_NAME}..."
    "$HCLOUD_BIN" server delete "$SERVER_NAME" >/dev/null
  fi
  if firewall_exists; then
    log "Deleting firewall ${FIREWALL_NAME}..."
    "$HCLOUD_BIN" firewall delete "$FIREWALL_NAME" >/dev/null
  fi
  if ssh_key_exists; then
    log "Deleting SSH key ${SSH_KEY_NAME}..."
    "$HCLOUD_BIN" ssh-key delete "$SSH_KEY_NAME" >/dev/null
  fi
  if [ "$DELETE_VOLUME" = true ] && volume_exists; then
    log "Deleting volume ${VOLUME_NAME}..."
    "$HCLOUD_BIN" volume delete "$VOLUME_NAME" >/dev/null
  elif volume_exists; then
    warn "Volume ${VOLUME_NAME} preserved. Reattach with --name ${DEPLOYMENT_NAME} on the next deploy."
  fi
  rm -f "$STATE_FILE" "$SSH_KEY_FILE" "$SSH_PUBKEY_FILE"
  rmdir "$STATE_DIR" "$KEY_DIR" 2>/dev/null || true
}

cleanup() {
  if [ -n "$USER_DATA_FILE" ]; then
    rm -f "$USER_DATA_FILE"
  fi
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

if [ "$LIST_MODE" = true ]; then
  list_known_deployments
  exit 0
fi

require_cmd "$HCLOUD_BIN" "https://github.com/hetznercloud/cli"
require_cmd curl
require_cmd openssl
require_cmd python3
require_cmd ssh
require_cmd ssh-keygen

ensure_names
load_local_state
validate_hcloud_auth

if [ "$DESTROY_MODE" = true ]; then
  if [ "$CONFIRM_DESTROY" != "true" ]; then
    print_destroy_confirmation
    exit 1
  fi
  destroy_deployment
  exit 0
fi

ensure_location
ensure_tier
auto_detect_access_cidr
[ -n "$DB_PASSWORD" ] || DB_PASSWORD="$(generate_password)"
TMP_DIR="$(mktemp -d)"

ensure_hcloud_ssh_key
ensure_firewall
ensure_volume
ensure_server
ensure_volume_attached
refresh_server_metadata
upsert_dns_rrset

export DEPLOYMENT_NAME LOCATION SERVER_TYPE SERVER_NAME INSTANCE_IP VOLUME_NAME VOLUME_ID FIREWALL_NAME SSH_KEY_NAME DB_PASSWORD DOMAIN DNS_ZONE_NAME DNS_RECORD_NAME DNS_MODE_USED PROFILE_NAME
save_local_state

if [ "$WAIT_FOR_READY" != "true" ]; then
  print_no_wait_summary
  exit 0
fi

wait_for_running
wait_for_ssh
wait_for_bootstrap_ready

if [ -n "$DOMAIN" ]; then
  if wait_for_domain_resolution; then
    if ! wait_for_public_https; then
      warn "Public HTTPS did not become ready within ${WAIT_TIMEOUT}s. Caddy may still be waiting on ACME."
    fi
    if ! wait_for_public_grpc; then
      warn "Public gRPC did not become ready within ${WAIT_TIMEOUT}s."
    fi
  else
    warn "DNS for ${DOMAIN} did not resolve to ${INSTANCE_IP} within ${WAIT_TIMEOUT}s."
    warn "Caddy on the instance will keep retrying certificate issuance after DNS is correct."
  fi
fi

print_ready_summary
