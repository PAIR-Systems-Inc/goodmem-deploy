#!/usr/bin/env bash

# Bootstrap GoodMem on AWS Lightsail by creating:
# - one Ubuntu instance
# - one Lightsail managed PostgreSQL database
# - one static IP
# - minimal firewall rules
# - optional public DNS + TLS termination via Caddy
#
# Prerequisites:
# - AWS CLI installed and authenticated
# - permission to manage Lightsail instances, static IPs, key pairs, and databases
# - permission to manage Route 53 records if auto-DNS is desired
#
# Local state:
# - ~/.goodmem/lightsail-keys/<deployment>-key.pem stores the Lightsail SSH key pair
# - ~/.goodmem/lightsail-state/<deployment>.json stores values needed for safe reruns,
#   notably the generated database password
set -euo pipefail
trap 'echo "Error: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

REGION="us-west-2"
REGION_SET=false
AVAILABILITY_ZONE=""
INSTANCE_BLUEPRINT="ubuntu_24_04"
INSTANCE_BUNDLE="small_3_0"
DB_BLUEPRINT="postgres_17"
DB_BUNDLE="micro_2_0"
DEPLOYMENT_NAME=""
DB_MASTER_DATABASE="goodmem"
DB_MASTER_USERNAME="goodmemadmin"
DB_MASTER_PASSWORD=""
PROFILE_NAME="lightsail"
GOODMEM_IMAGE="ghcr.io/pair-systems-inc/goodmem/server:latest"
ACCESS_CIDR=""
WAIT_TIMEOUT=3600
WAIT_INTERVAL=10
DNS_WAIT_TIMEOUT=600
DNS_WAIT_INTERVAL=15
DOMAIN=""
CONTACT_EMAIL=""
PREFERRED_REST_PORT=8080
PUBLIC_GRPC_PORT=50051
WAIT_FOR_READY=true
LIST_MODE=false
DESTROY_MODE=false
CONFIRM_DESTROY=false
SIZE_TIER=""
TIER_SET=false
INSTANCE_BUNDLE_SET=false
DB_BUNDLE_SET=false

INSTANCE_NAME=""
DB_RESOURCE_NAME=""
STATIC_IP_NAME=""
KEY_PAIR_NAME=""
KEY_PAIR_FILE=""
STATE_DIR_LOCAL=""
STATE_FILE_LOCAL=""

STATUS_DIR_REMOTE="/opt/goodmem-lightsail"
STATUS_FILE_REMOTE="${STATUS_DIR_REMOTE}/status.json"
BOOTSTRAP_LOG_REMOTE="/var/log/goodmem-lightsail-bootstrap.log"

USER_DATA_FILE=""
PORT_INFOS_FILE=""
SSH_KEY_FILE=""
SSH_CERT_FILE=""
INSTANCE_IP=""
SSH_USERNAME=""
REST_PORT=""
GRPC_PORT=""
ROOT_API_KEY=""
LOCAL_REST_SCHEME="https"

HOSTED_ZONE_ID=""
HOSTED_ZONE_NAME=""
ROUTE53_CHANGE_ID=""
DNS_MODE_USED="none"
DNS_RESOLVED="false"
PUBLIC_READY="false"

PUBLIC_REST_URL=""
PUBLIC_GRPC_URL=""
PUBLIC_CONSOLE_URL=""

usage() {
  cat <<'USAGE'
Usage: ./scripts/bootstrap_lightsail.sh [options]

Options:
  --name NAME               Deployment slug (default: goodmem-lightsail-<timestamp>)
  --list                    List known local Lightsail deployments and their AWS status
  --destroy                 Delete a deployment's AWS resources and local state (requires --name --yes)
  --yes                     Confirm destructive actions for --destroy
  --region REGION           Lightsail region (default: us-west-2)
  --availability-zone AZ    Lightsail availability zone (default: first DB-capable AZ in region)
  --tier NAME               Size tier: small, medium, large, or x-large (prompts if unset)
  --instance-blueprint ID   Instance blueprint (default: ubuntu_24_04)
  --instance-bundle ID      Instance bundle (default: small_3_0)
  --db-blueprint ID         Relational DB blueprint (default: postgres_17)
  --db-bundle ID            Relational DB bundle (default: micro_2_0)
  --db-master-database NAME Initial PostgreSQL database name (default: goodmem)
  --db-master-username NAME PostgreSQL master username (default: goodmemadmin)
  --db-master-password PASS PostgreSQL master password (generated if omitted)
  --profile-name NAME       GoodMem CLI profile name on the instance (default: lightsail)
  --access-cidr CIDR        CIDR allowed to reach SSH, or SSH only when --domain is set
  --domain DOMAIN           Public domain for HTTPS + gRPC (Caddy on 80/443/50051)
  --email EMAIL             Contact email for ACME/TLS notices
  --image IMAGE             GoodMem server image (default: ghcr.io/pair-systems-inc/goodmem/server:latest)
  --no-wait                 Exit after provisioning instead of waiting for bootstrap/readiness
  --wait-timeout SECONDS    Overall wait timeout (default: 3600)
  --dns-wait-timeout SEC    Time to wait for public DNS/TLS (default: 600)
  -h, --help                Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      DEPLOYMENT_NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      REGION_SET=true
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
    --yes)
      CONFIRM_DESTROY=true
      shift
      ;;
    --availability-zone)
      AVAILABILITY_ZONE="$2"
      shift 2
      ;;
    --tier)
      SIZE_TIER="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
      TIER_SET=true
      shift 2
      ;;
    --instance-blueprint)
      INSTANCE_BLUEPRINT="$2"
      shift 2
      ;;
    --instance-bundle)
      INSTANCE_BUNDLE="$2"
      INSTANCE_BUNDLE_SET=true
      shift 2
      ;;
    --db-blueprint)
      DB_BLUEPRINT="$2"
      shift 2
      ;;
    --db-bundle)
      DB_BUNDLE="$2"
      DB_BUNDLE_SET=true
      shift 2
      ;;
    --db-master-database)
      DB_MASTER_DATABASE="$2"
      shift 2
      ;;
    --db-master-username)
      DB_MASTER_USERNAME="$2"
      shift 2
      ;;
    --db-master-password)
      DB_MASTER_PASSWORD="$2"
      shift 2
      ;;
    --profile-name)
      PROFILE_NAME="$2"
      shift 2
      ;;
    --access-cidr)
      ACCESS_CIDR="$2"
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
      GOODMEM_IMAGE="$2"
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
    --dns-wait-timeout)
      DNS_WAIT_TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    if [ "$1" = "aws" ]; then
      echo "Install the AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
    fi
    exit 1
  fi
}

generate_password() {
  if [ -n "$DB_MASTER_PASSWORD" ]; then
    printf '%s' "$DB_MASTER_PASSWORD"
    return
  fi
  openssl rand -hex 24
}

format_elapsed() {
  local total_seconds="$1"
  local minutes=$(( total_seconds / 60 ))
  local seconds=$(( total_seconds % 60 ))
  printf '%dm%02ds' "$minutes" "$seconds"
}

tier_summary() {
  case "$1" in
    small)
      printf 'VM 2 GB / 2 vCPU, DB 1 GB / 2 vCPU, about $27/mo'
      ;;
    medium)
      printf 'VM 4 GB / 2 vCPU, DB 2 GB / 2 vCPU, about $54/mo'
      ;;
    large)
      printf 'VM 8 GB / 2 vCPU, DB 4 GB / 2 vCPU, about $104/mo'
      ;;
    x-large|xlarge)
      printf 'VM 16 GB / 4 vCPU, DB 8 GB / 2 vCPU, about $199/mo'
      ;;
    *)
      return 1
      ;;
  esac
}

tier_detail() {
  case "$1" in
    small)
      printf 'small_3_0 (2 GB RAM, 2 vCPU, 60 GB SSD, $12/mo) + micro_2_0 (1 GB RAM, 2 vCPU, 40 GB SSD, $15/mo)'
      ;;
    medium)
      printf 'medium_3_0 (4 GB RAM, 2 vCPU, 80 GB SSD, $24/mo) + small_2_0 (2 GB RAM, 2 vCPU, 80 GB SSD, $30/mo)'
      ;;
    large)
      printf 'large_3_0 (8 GB RAM, 2 vCPU, 160 GB SSD, $44/mo) + medium_2_0 (4 GB RAM, 2 vCPU, 120 GB SSD, $60/mo)'
      ;;
    x-large|xlarge)
      printf 'xlarge_3_0 (16 GB RAM, 4 vCPU, 320 GB SSD, $84/mo) + large_2_0 (8 GB RAM, 2 vCPU, 240 GB SSD, $115/mo)'
      ;;
    *)
      return 1
      ;;
  esac
}

apply_tier_defaults() {
  if [ "$TIER_SET" != "true" ]; then
    return
  fi

  case "$SIZE_TIER" in
    small)
      if [ "$INSTANCE_BUNDLE_SET" != "true" ]; then
        INSTANCE_BUNDLE="small_3_0"
      fi
      if [ "$DB_BUNDLE_SET" != "true" ]; then
        DB_BUNDLE="micro_2_0"
      fi
      ;;
    medium)
      if [ "$INSTANCE_BUNDLE_SET" != "true" ]; then
        INSTANCE_BUNDLE="medium_3_0"
      fi
      if [ "$DB_BUNDLE_SET" != "true" ]; then
        DB_BUNDLE="small_2_0"
      fi
      ;;
    large)
      if [ "$INSTANCE_BUNDLE_SET" != "true" ]; then
        INSTANCE_BUNDLE="large_3_0"
      fi
      if [ "$DB_BUNDLE_SET" != "true" ]; then
        DB_BUNDLE="medium_2_0"
      fi
      ;;
    x-large|xlarge)
      if [ "$INSTANCE_BUNDLE_SET" != "true" ]; then
        INSTANCE_BUNDLE="xlarge_3_0"
      fi
      if [ "$DB_BUNDLE_SET" != "true" ]; then
        DB_BUNDLE="large_2_0"
      fi
      ;;
    *)
      echo "Unsupported tier: $SIZE_TIER (expected: small, medium, large, or x-large)" >&2
      exit 1
      ;;
  esac
}

prompt_tier() {
  local tty_input=""
  local summary=""
  local detail=""
  if [ -t 0 ]; then
    tty_input=""
  elif [ -r /dev/tty ]; then
    tty_input="/dev/tty"
  else
    SIZE_TIER="small"
    TIER_SET=true
    apply_tier_defaults
    summary="$(tier_summary "$SIZE_TIER")"
    echo "No TTY detected; defaulting Lightsail tier to ${SIZE_TIER} (${summary})."
    return
  fi

  echo "Select Lightsail tier for the GoodMem VM and managed PostgreSQL:"
  echo "  1) small   - $(tier_summary small)"
  echo "  2) medium  - $(tier_summary medium)"
  echo "  3) large   - $(tier_summary large)"
  echo "  4) x-large - $(tier_summary x-large)"

  local choice=""
  while true; do
    if [ -n "$tty_input" ]; then
      read -r -p "Enter selection (1-4) or name [small]: " choice <"$tty_input"
    else
      read -r -p "Enter selection (1-4) or name [small]: " choice
    fi
    choice="$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$choice" ]; then
      choice="small"
    fi
    case "$choice" in
      1|small)
        SIZE_TIER="small"
        break
        ;;
      2|medium)
        SIZE_TIER="medium"
        break
        ;;
      3|large)
        SIZE_TIER="large"
        break
        ;;
      4|x-large|xlarge)
        SIZE_TIER="x-large"
        break
        ;;
      *)
        echo "Invalid selection."
        ;;
    esac
  done

  TIER_SET=true
  apply_tier_defaults
  detail="$(tier_detail "$SIZE_TIER")"
  echo "Using ${SIZE_TIER} tier: ${detail}."
}

ensure_tier() {
  if [ "$TIER_SET" = "true" ]; then
    apply_tier_defaults
    return
  fi

  if [ "$INSTANCE_BUNDLE_SET" = "true" ] || [ "$DB_BUNDLE_SET" = "true" ]; then
    return
  fi

  prompt_tier
}

domain_enabled() {
  [ -n "$DOMAIN" ]
}

refresh_public_urls() {
  PUBLIC_REST_URL=""
  PUBLIC_GRPC_URL=""
  PUBLIC_CONSOLE_URL=""
  if domain_enabled; then
    DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"
    PUBLIC_REST_URL="https://${DOMAIN}"
    PUBLIC_GRPC_URL="https://${DOMAIN}:${PUBLIC_GRPC_PORT}"
    PUBLIC_CONSOLE_URL="https://${DOMAIN}/console/"
  fi
}

ensure_names() {
  if [ -z "$DEPLOYMENT_NAME" ]; then
    DEPLOYMENT_NAME="goodmem-lightsail-$(date +%s)"
  fi
  INSTANCE_NAME="$DEPLOYMENT_NAME"
  DB_RESOURCE_NAME="${DEPLOYMENT_NAME}-pg"
  STATIC_IP_NAME="${DEPLOYMENT_NAME}-ip"
  KEY_PAIR_NAME="${DEPLOYMENT_NAME}-key"
  KEY_PAIR_FILE="${HOME}/.goodmem/lightsail-keys/${KEY_PAIR_NAME}.pem"
  # The local state file is the rerun anchor for generated values such as the DB password.
  STATE_DIR_LOCAL="${HOME}/.goodmem/lightsail-state"
  STATE_FILE_LOCAL="${STATE_DIR_LOCAL}/${DEPLOYMENT_NAME}.json"
  refresh_public_urls
}

json_get() {
  local field="$1"
  python3 -c '
import json
import sys

field = sys.argv[1]
data = json.load(sys.stdin)
value = data.get(field, "")
if value is None:
    value = ""
if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
' "$field"
}

resolve_availability_zone() {
  if [ -n "$AVAILABILITY_ZONE" ]; then
    return
  fi
  AVAILABILITY_ZONE="$(
    aws lightsail get-regions \
      --region "$REGION" \
      --include-availability-zones \
      --include-relational-database-availability-zones \
      --query "regions[?name=='${REGION}'].relationalDatabaseAvailabilityZones[0].zoneName" \
      --output text
  )"
  if [ -z "$AVAILABILITY_ZONE" ] || [ "$AVAILABILITY_ZONE" = "None" ]; then
    echo "Unable to determine a relational-database availability zone for region $REGION" >&2
    exit 1
  fi
}

resolve_access_cidr() {
  if [ -n "$ACCESS_CIDR" ]; then
    return
  fi
  local public_ip=""
  public_ip="$(curl -fsSL https://checkip.amazonaws.com | tr -d '\r\n')"
  if [ -z "$public_ip" ]; then
    echo "Unable to determine current public IP. Pass --access-cidr explicitly." >&2
    exit 1
  fi
  ACCESS_CIDR="${public_ip}/32"
}

instance_exists() {
  aws lightsail get-instance \
    --region "$REGION" \
    --instance-name "$INSTANCE_NAME" >/dev/null 2>&1
}

db_exists() {
  aws lightsail get-relational-database \
    --region "$REGION" \
    --relational-database-name "$DB_RESOURCE_NAME" >/dev/null 2>&1
}

static_ip_exists() {
  aws lightsail get-static-ip \
    --region "$REGION" \
    --static-ip-name "$STATIC_IP_NAME" >/dev/null 2>&1
}

key_pair_exists() {
  aws lightsail get-key-pair \
    --region "$REGION" \
    --key-pair-name "$KEY_PAIR_NAME" >/dev/null 2>&1
}

load_local_state() {
  if [ ! -f "$STATE_FILE_LOCAL" ]; then
    return
  fi
  local state_json=""
  state_json="$(cat "$STATE_FILE_LOCAL")"
  if [ "$REGION_SET" != "true" ]; then
    local state_region=""
    state_region="$(printf '%s' "$state_json" | json_get region)"
    if [ -n "$state_region" ]; then
      REGION="$state_region"
    fi
  fi
  if [ -z "$DB_MASTER_PASSWORD" ]; then
    DB_MASTER_PASSWORD="$(printf '%s' "$state_json" | json_get db_master_password)"
  fi
  if [ -z "$DOMAIN" ]; then
    DOMAIN="$(printf '%s' "$state_json" | json_get domain)"
  fi
  if [ -z "$INSTANCE_IP" ]; then
    INSTANCE_IP="$(printf '%s' "$state_json" | json_get instance_ip)"
  fi
  if [ -z "$HOSTED_ZONE_ID" ]; then
    HOSTED_ZONE_ID="$(printf '%s' "$state_json" | json_get hosted_zone_id)"
  fi
  if [ -z "$HOSTED_ZONE_NAME" ]; then
    HOSTED_ZONE_NAME="$(printf '%s' "$state_json" | json_get hosted_zone_name)"
  fi
  if [ "$DNS_MODE_USED" = "none" ]; then
    local state_dns_mode=""
    state_dns_mode="$(printf '%s' "$state_json" | json_get dns_mode_used)"
    if [ -n "$state_dns_mode" ]; then
      DNS_MODE_USED="$state_dns_mode"
    fi
  fi
  refresh_public_urls
}

save_local_state() {
  mkdir -p "$STATE_DIR_LOCAL"
  chmod 700 "$STATE_DIR_LOCAL"
  python3 - "$STATE_FILE_LOCAL" "$DEPLOYMENT_NAME" "$REGION" "$INSTANCE_NAME" "$DB_RESOURCE_NAME" "$STATIC_IP_NAME" "$KEY_PAIR_NAME" "$DB_MASTER_PASSWORD" "$DOMAIN" "$INSTANCE_IP" "$DNS_MODE_USED" "$HOSTED_ZONE_ID" "$HOSTED_ZONE_NAME" <<'PY'
import json
import os
import sys

path = sys.argv[1]
payload = {
    "deployment_name": sys.argv[2],
    "region": sys.argv[3],
    "instance_name": sys.argv[4],
    "db_resource_name": sys.argv[5],
    "static_ip_name": sys.argv[6],
    "key_pair_name": sys.argv[7],
    "db_master_password": sys.argv[8],
    "domain": sys.argv[9],
    "instance_ip": sys.argv[10],
    "dns_mode_used": sys.argv[11],
    "hosted_zone_id": sys.argv[12],
    "hosted_zone_name": sys.argv[13],
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
os.chmod(path, 0o600)
PY
}

have_aws_cli() {
  command -v aws >/dev/null 2>&1
}

describe_instance_state() {
  local region="$1"
  local instance_name="$2"
  local state=""
  if ! have_aws_cli || [ -z "$instance_name" ]; then
    printf 'not checked'
    return
  fi
  state="$(
    aws lightsail get-instance \
      --region "$region" \
      --instance-name "$instance_name" \
      --query 'instance.state.name' \
      --output text 2>/dev/null || true
  )"
  if [ -z "$state" ] || [ "$state" = "None" ]; then
    printf 'missing'
    return
  fi
  printf '%s' "$state"
}

describe_db_state() {
  local region="$1"
  local db_name="$2"
  local state=""
  if ! have_aws_cli || [ -z "$db_name" ]; then
    printf 'not checked'
    return
  fi
  state="$(
    aws lightsail get-relational-database \
      --region "$region" \
      --relational-database-name "$db_name" \
      --query 'relationalDatabase.state' \
      --output text 2>/dev/null || true
  )"
  if [ -z "$state" ] || [ "$state" = "None" ]; then
    printf 'missing'
    return
  fi
  printf '%s' "$state"
}

describe_static_ip() {
  local region="$1"
  local static_ip_name="$2"
  local details=""
  local ip=""
  local attached_to=""
  if ! have_aws_cli || [ -z "$static_ip_name" ]; then
    printf 'not checked'
    return
  fi
  details="$(
    aws lightsail get-static-ip \
      --region "$region" \
      --static-ip-name "$static_ip_name" \
      --query '[staticIp.ipAddress, staticIp.attachedTo]' \
      --output text 2>/dev/null || true
  )"
  if [ -z "$details" ] || [ "$details" = "None" ]; then
    printf 'missing'
    return
  fi
  ip="$(printf '%s\n' "$details" | awk '{print $1}')"
  attached_to="$(printf '%s\n' "$details" | awk '{print $2}')"
  if [ -z "$attached_to" ] || [ "$attached_to" = "None" ]; then
    printf '%s (unattached)' "$ip"
    return
  fi
  printf '%s (attached to %s)' "$ip" "$attached_to"
}

describe_key_pair_state() {
  local region="$1"
  local key_pair_name="$2"
  if ! have_aws_cli || [ -z "$key_pair_name" ]; then
    printf 'not checked'
    return
  fi
  if aws lightsail get-key-pair \
    --region "$region" \
    --key-pair-name "$key_pair_name" >/dev/null 2>&1; then
    printf 'present'
    return
  fi
  printf 'missing'
}

list_deployments() {
  local state_dir="${HOME}/.goodmem/lightsail-state"
  local listed_any="false"
  if [ ! -d "$state_dir" ]; then
    echo "No local Lightsail deployment state found at $state_dir"
    return
  fi

  while IFS=$'\x1f' read -r deployment region instance_name db_name static_ip_name key_pair_name domain state_file; do
    [ -n "$deployment" ] || continue
    listed_any="true"
    local instance_state="not checked"
    local db_state="not checked"
    local static_ip_state="not checked"
    local key_pair_state="not checked"
    if have_aws_cli; then
      instance_state="$(describe_instance_state "$region" "$instance_name")"
      db_state="$(describe_db_state "$region" "$db_name")"
      static_ip_state="$(describe_static_ip "$region" "$static_ip_name")"
      key_pair_state="$(describe_key_pair_state "$region" "$key_pair_name")"
    fi
    cat <<EOF
- ${deployment}
  Region:     ${region}
  Domain:     ${domain:--}
  Instance:   ${instance_name} [${instance_state}]
  Database:   ${db_name} [${db_state}]
  Static IP:  ${static_ip_name} [${static_ip_state}]
  Key pair:   ${key_pair_name} [${key_pair_state}]
  State file: ${state_file}
  Re-run:     ./scripts/bootstrap_lightsail.sh --name ${deployment} --region ${region}
  Destroy:    ./scripts/bootstrap_lightsail.sh --destroy --name ${deployment} --region ${region} --yes
EOF
  done < <(
    python3 - "$state_dir" <<'PY'
import json
import pathlib
import sys

state_dir = pathlib.Path(sys.argv[1])
for path in sorted(state_dir.glob("*.json")):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        continue
    row = [
        data.get("deployment_name") or path.stem,
        data.get("region", ""),
        data.get("instance_name", ""),
        data.get("db_resource_name", ""),
        data.get("static_ip_name", ""),
        data.get("key_pair_name", ""),
        data.get("domain", ""),
        str(path),
    ]
    print("\x1f".join(str(v or "") for v in row))
PY
  )

  if [ "$listed_any" != "true" ]; then
    echo "No local Lightsail deployment state found at $state_dir"
    return
  fi
  if ! have_aws_cli; then
    echo
    echo "AWS CLI not found; resource status was not checked."
  fi
}

wait_for_db_available() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local started_at="$SECONDS"
  local last_state=""
  local last_report=-1
  while (( SECONDS < deadline )); do
    local state=""
    state="$(
      aws lightsail get-relational-database \
        --region "$REGION" \
        --relational-database-name "$DB_RESOURCE_NAME" \
        --query 'relationalDatabase.state' \
        --output text
    )"
    if [ "$state" = "available" ]; then
      return
    fi
    if [ "$state" = "failed" ]; then
      echo "Relational database entered failed state." >&2
      exit 1
    fi
    local elapsed=$((SECONDS - started_at))
    if [ "$state" != "$last_state" ] || (( last_report < 0 || elapsed - last_report >= 60 )); then
      log "Still waiting for relational database \"$DB_RESOURCE_NAME\"... state: $state, elapsed: $(format_elapsed "$elapsed")"
      last_state="$state"
      last_report="$elapsed"
    fi
    sleep "$WAIT_INTERVAL"
  done
  echo "Timed out waiting for relational database to become available." >&2
  exit 1
}

get_db_endpoint() {
  aws lightsail get-relational-database \
    --region "$REGION" \
    --relational-database-name "$DB_RESOURCE_NAME" \
    --query 'relationalDatabase.masterEndpoint.address' \
    --output text
}

get_db_port() {
  aws lightsail get-relational-database \
    --region "$REGION" \
    --relational-database-name "$DB_RESOURCE_NAME" \
    --query 'relationalDatabase.masterEndpoint.port' \
    --output text
}

ensure_key_pair() {
  mkdir -p "$(dirname "$KEY_PAIR_FILE")"
  chmod 700 "$(dirname "$KEY_PAIR_FILE")"

  if key_pair_exists; then
    if [ ! -f "$KEY_PAIR_FILE" ]; then
      echo "Lightsail key pair \"$KEY_PAIR_NAME\" exists, but local private key is missing at $KEY_PAIR_FILE" >&2
      exit 1
    fi
    chmod 600 "$KEY_PAIR_FILE"
    return
  fi

  log "Creating Lightsail key pair \"$KEY_PAIR_NAME\"..."
  local key_json=""
  key_json="$(
    aws lightsail create-key-pair \
      --region "$REGION" \
      --key-pair-name "$KEY_PAIR_NAME" \
      --output json
  )"
  python3 -c '
import base64
import json
import sys

value = json.load(sys.stdin)["privateKeyBase64"]
if value.startswith("-----BEGIN "):
    sys.stdout.write(value)
else:
    sys.stdout.write(base64.b64decode(value).decode("utf-8"))
' <<<"$key_json" >"$KEY_PAIR_FILE"
  chmod 600 "$KEY_PAIR_FILE"
}

wait_for_instance_running() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local started_at="$SECONDS"
  local last_state=""
  local last_report=-1
  while (( SECONDS < deadline )); do
    local state=""
    state="$(
      aws lightsail get-instance \
        --region "$REGION" \
        --instance-name "$INSTANCE_NAME" \
        --query 'instance.state.name' \
        --output text
    )"
    if [ "$state" = "running" ]; then
      return
    fi
    if [ "$state" = "stopped" ] || [ "$state" = "terminated" ]; then
      echo "Instance entered unexpected state: $state" >&2
      exit 1
    fi
    local elapsed=$((SECONDS - started_at))
    if [ "$state" != "$last_state" ] || (( last_report < 0 || elapsed - last_report >= 60 )); then
      log "Still waiting for instance \"$INSTANCE_NAME\"... state: $state, elapsed: $(format_elapsed "$elapsed")"
      last_state="$state"
      last_report="$elapsed"
    fi
    sleep "$WAIT_INTERVAL"
  done
  echo "Timed out waiting for instance to become running." >&2
  exit 1
}

ensure_static_ip() {
  local attached_to=""
  if ! static_ip_exists; then
    log "Creating static IP \"$STATIC_IP_NAME\"..."
    aws lightsail allocate-static-ip \
      --region "$REGION" \
      --static-ip-name "$STATIC_IP_NAME" >/dev/null
  fi
  attached_to="$(
    aws lightsail get-static-ip \
      --region "$REGION" \
      --static-ip-name "$STATIC_IP_NAME" \
      --query 'staticIp.attachedTo' \
      --output text
  )"
  if [ "$attached_to" = "$INSTANCE_NAME" ]; then
    log "Static IP \"$STATIC_IP_NAME\" is already attached to \"$INSTANCE_NAME\"."
  else
    if [ -n "$attached_to" ] && [ "$attached_to" != "None" ]; then
      warn "Static IP \"$STATIC_IP_NAME\" is attached to \"$attached_to\"; reattaching to \"$INSTANCE_NAME\"."
    else
      log "Attaching static IP \"$STATIC_IP_NAME\" to \"$INSTANCE_NAME\"..."
    fi
    aws lightsail attach-static-ip \
      --region "$REGION" \
      --static-ip-name "$STATIC_IP_NAME" \
      --instance-name "$INSTANCE_NAME" >/dev/null
  fi
  INSTANCE_IP="$(
    aws lightsail get-static-ip \
      --region "$REGION" \
      --static-ip-name "$STATIC_IP_NAME" \
      --query 'staticIp.ipAddress' \
      --output text
  )"
}

current_static_ip_address() {
  aws lightsail get-static-ip \
    --region "$REGION" \
    --static-ip-name "$STATIC_IP_NAME" \
    --query 'staticIp.ipAddress' \
    --output text 2>/dev/null || true
}

current_static_ip_attachment() {
  aws lightsail get-static-ip \
    --region "$REGION" \
    --static-ip-name "$STATIC_IP_NAME" \
    --query 'staticIp.attachedTo' \
    --output text 2>/dev/null || true
}

wait_for_instance_deleted() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local started_at="$SECONDS"
  local last_state=""
  local last_report=-1
  while (( SECONDS < deadline )); do
    if ! instance_exists; then
      return
    fi
    local state=""
    state="$(
      aws lightsail get-instance \
        --region "$REGION" \
        --instance-name "$INSTANCE_NAME" \
        --query 'instance.state.name' \
        --output text 2>/dev/null || true
    )"
    if [ -z "$state" ] || [ "$state" = "None" ]; then
      return
    fi
    local elapsed=$((SECONDS - started_at))
    if [ "$state" != "$last_state" ] || (( last_report < 0 || elapsed - last_report >= 60 )); then
      log "Still waiting for instance \"$INSTANCE_NAME\" to delete... state: $state, elapsed: $(format_elapsed "$elapsed")"
      last_state="$state"
      last_report="$elapsed"
    fi
    sleep "$WAIT_INTERVAL"
  done
  warn "Timed out waiting for instance \"$INSTANCE_NAME\" to delete."
}

wait_for_db_deleted() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local started_at="$SECONDS"
  local last_state=""
  local last_report=-1
  while (( SECONDS < deadline )); do
    if ! db_exists; then
      return
    fi
    local state=""
    state="$(
      aws lightsail get-relational-database \
        --region "$REGION" \
        --relational-database-name "$DB_RESOURCE_NAME" \
        --query 'relationalDatabase.state' \
        --output text 2>/dev/null || true
    )"
    if [ -z "$state" ] || [ "$state" = "None" ]; then
      return
    fi
    local elapsed=$((SECONDS - started_at))
    if [ "$state" != "$last_state" ] || (( last_report < 0 || elapsed - last_report >= 60 )); then
      log "Still waiting for relational database \"$DB_RESOURCE_NAME\" to delete... state: $state, elapsed: $(format_elapsed "$elapsed")"
      last_state="$state"
      last_report="$elapsed"
    fi
    sleep "$WAIT_INTERVAL"
  done
  warn "Timed out waiting for relational database \"$DB_RESOURCE_NAME\" to delete."
}

get_route53_a_record_json() {
  local hosted_zone_id="$1"
  local domain_name="$2"
  aws route53 list-resource-record-sets \
    --hosted-zone-id "$hosted_zone_id" \
    --output json | python3 - "$domain_name" <<'PY'
import json
import sys

needle = sys.argv[1].rstrip(".").lower() + "."
for record in json.load(sys.stdin).get("ResourceRecordSets", []):
    if record.get("Type") != "A":
        continue
    if record.get("Name", "").rstrip(".").lower() + "." != needle:
        continue
    print(json.dumps(record))
    break
PY
}

delete_route53_record_if_safe() {
  if ! domain_enabled; then
    return
  fi
  if [ -z "$INSTANCE_IP" ] && static_ip_exists; then
    INSTANCE_IP="$(current_static_ip_address)"
  fi
  if [ -z "$INSTANCE_IP" ]; then
    warn "Skipping Route 53 cleanup for ${DOMAIN}: no instance IP available to verify the record target."
    return
  fi
  if [ -z "$HOSTED_ZONE_ID" ]; then
    find_matching_public_hosted_zone
  fi
  if [ -z "$HOSTED_ZONE_ID" ]; then
    warn "Skipping Route 53 cleanup for ${DOMAIN}: no matching public hosted zone found."
    return
  fi

  local record_json=""
  record_json="$(get_route53_a_record_json "$HOSTED_ZONE_ID" "$DOMAIN" || true)"
  if [ -z "$record_json" ]; then
    log "No Route 53 A record found for ${DOMAIN}; skipping DNS cleanup."
    return
  fi

  if ! printf '%s' "$record_json" | python3 - "$INSTANCE_IP" <<'PY'
import json
import sys

record = json.load(sys.stdin)
expected_ip = sys.argv[1]
values = [item.get("Value", "") for item in record.get("ResourceRecords", [])]
if record.get("AliasTarget") is not None:
    raise SystemExit(1)
if len(values) != 1 or values[0] != expected_ip:
    raise SystemExit(1)
PY
  then
    warn "Skipping Route 53 cleanup for ${DOMAIN}: existing A record does not match ${INSTANCE_IP} exactly."
    return
  fi

  local batch_file=""
  batch_file="$(mktemp)"
  printf '%s' "$record_json" | python3 - "$DEPLOYMENT_NAME" >"$batch_file" <<'PY'
import json
import sys

deployment_name = sys.argv[1]
record = json.load(sys.stdin)
print(json.dumps({
    "Comment": f"Delete GoodMem Lightsail DNS record for {deployment_name}",
    "Changes": [
        {
            "Action": "DELETE",
            "ResourceRecordSet": record,
        }
    ],
}))
PY
  log "Deleting Route 53 A record ${DOMAIN} from hosted zone ${HOSTED_ZONE_NAME:-$HOSTED_ZONE_ID}..."
  local change_json=""
  change_json="$(
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$HOSTED_ZONE_ID" \
      --change-batch "file://${batch_file}" \
      --output json
  )"
  rm -f "$batch_file"
  ROUTE53_CHANGE_ID="$(printf '%s' "$change_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ChangeInfo"]["Id"], end="")')"
  wait_for_route53_change_insync
}

print_destroy_confirmation() {
  cat <<EOF
Destroying this deployment will delete:
- Lightsail instance: ${INSTANCE_NAME}
- Lightsail relational database: ${DB_RESOURCE_NAME} (without a final snapshot)
- Lightsail static IP: ${STATIC_IP_NAME}
- Lightsail key pair: ${KEY_PAIR_NAME}
- Local state/key files for ${DEPLOYMENT_NAME}
EOF
  if domain_enabled; then
    cat <<EOF
- Route 53 A record for ${DOMAIN}, but only if it still points exactly at this deployment's IP
EOF
  fi
  cat <<EOF

Re-run with:
  ./scripts/bootstrap_lightsail.sh --destroy --name ${DEPLOYMENT_NAME} --region ${REGION} --yes
EOF
}

destroy_deployment() {
  local deleted_instance="false"
  local deleted_db="false"

  log "Destroying deployment: $DEPLOYMENT_NAME"
  log "Region: $REGION"

  delete_route53_record_if_safe

  if static_ip_exists; then
    local attached_to=""
    attached_to="$(current_static_ip_attachment)"
    if [ -n "$attached_to" ] && [ "$attached_to" != "None" ]; then
      log "Detaching static IP \"$STATIC_IP_NAME\" from \"$attached_to\"..."
      aws lightsail detach-static-ip \
        --region "$REGION" \
        --static-ip-name "$STATIC_IP_NAME" >/dev/null
    fi
    log "Releasing static IP \"$STATIC_IP_NAME\"..."
    aws lightsail release-static-ip \
      --region "$REGION" \
      --static-ip-name "$STATIC_IP_NAME" >/dev/null
  else
    log "Static IP \"$STATIC_IP_NAME\" not found; skipping."
  fi

  if instance_exists; then
    log "Deleting instance \"$INSTANCE_NAME\"..."
    aws lightsail delete-instance \
      --region "$REGION" \
      --instance-name "$INSTANCE_NAME" >/dev/null
    deleted_instance="true"
  else
    log "Instance \"$INSTANCE_NAME\" not found; skipping."
  fi

  if db_exists; then
    log "Deleting relational database \"$DB_RESOURCE_NAME\" without a final snapshot..."
    aws lightsail delete-relational-database \
      --region "$REGION" \
      --relational-database-name "$DB_RESOURCE_NAME" \
      --skip-final-snapshot >/dev/null
    deleted_db="true"
  else
    log "Relational database \"$DB_RESOURCE_NAME\" not found; skipping."
  fi

  if key_pair_exists; then
    log "Deleting Lightsail key pair \"$KEY_PAIR_NAME\"..."
    aws lightsail delete-key-pair \
      --region "$REGION" \
      --key-pair-name "$KEY_PAIR_NAME" >/dev/null
  else
    log "Lightsail key pair \"$KEY_PAIR_NAME\" not found; skipping."
  fi

  if [ "$deleted_instance" = "true" ]; then
    wait_for_instance_deleted
  fi
  if [ "$deleted_db" = "true" ]; then
    wait_for_db_deleted
  fi

  rm -f "$STATE_FILE_LOCAL" "$KEY_PAIR_FILE"
  rmdir "$(dirname "$KEY_PAIR_FILE")" 2>/dev/null || true
  rmdir "$STATE_DIR_LOCAL" 2>/dev/null || true

  cat <<EOF
Destroy complete.

Deployment: $DEPLOYMENT_NAME
Region:     $REGION
State file: ${STATE_FILE_LOCAL} (removed if present)
Key file:   ${KEY_PAIR_FILE} (removed if present)
EOF
}

write_port_infos_file() {
  local mode="${1:-initial}"
  local rest_port="${2:-${PREFERRED_REST_PORT}}"
  local grpc_port="${3:-${PUBLIC_GRPC_PORT}}"

  PORT_INFOS_FILE="$(mktemp)"
  # Domain mode exposes fixed public ports. Direct-IP mode does not know the real
  # app ports until remote bootstrap finishes, so it starts SSH-only and
  # reconciles the firewall later with the reported runtime ports.
  if domain_enabled; then
    # Preserve Lightsail browser SSH alongside direct SSH from ACCESS_CIDR.
    cat >"$PORT_INFOS_FILE" <<EOF
[
  {
    "fromPort": 22,
    "toPort": 22,
    "protocol": "tcp",
    "cidrs": ["$ACCESS_CIDR"],
    "cidrListAliases": ["lightsail-connect"]
  },
  {
    "fromPort": 80,
    "toPort": 80,
    "protocol": "tcp",
    "cidrs": ["0.0.0.0/0"],
    "ipv6Cidrs": ["::/0"]
  },
  {
    "fromPort": 443,
    "toPort": 443,
    "protocol": "tcp",
    "cidrs": ["0.0.0.0/0"],
    "ipv6Cidrs": ["::/0"]
  },
  {
    "fromPort": ${PUBLIC_GRPC_PORT},
    "toPort": ${PUBLIC_GRPC_PORT},
    "protocol": "tcp",
    "cidrs": ["0.0.0.0/0"],
    "ipv6Cidrs": ["::/0"]
  }
]
EOF
  else
    if [ "$mode" = "initial" ] && [ "$WAIT_FOR_READY" = "true" ]; then
      # Preserve Lightsail browser SSH alongside direct SSH from ACCESS_CIDR.
      cat >"$PORT_INFOS_FILE" <<EOF
[
  {
    "fromPort": 22,
    "toPort": 22,
    "protocol": "tcp",
    "cidrs": ["$ACCESS_CIDR"],
    "cidrListAliases": ["lightsail-connect"]
  }
]
EOF
      return
    fi

    # Preserve Lightsail browser SSH alongside direct SSH from ACCESS_CIDR.
    cat >"$PORT_INFOS_FILE" <<EOF
[
  {
    "fromPort": 22,
    "toPort": 22,
    "protocol": "tcp",
    "cidrs": ["$ACCESS_CIDR"],
    "cidrListAliases": ["lightsail-connect"]
  },
  {
    "fromPort": ${rest_port},
    "toPort": ${rest_port},
    "protocol": "tcp",
    "cidrs": ["$ACCESS_CIDR"]
  },
  {
    "fromPort": ${grpc_port},
    "toPort": ${grpc_port},
    "protocol": "tcp",
    "cidrs": ["$ACCESS_CIDR"]
  }
]
EOF
  fi
}

configure_instance_ports() {
  local mode="${1:-initial}"
  local rest_port="${2:-${PREFERRED_REST_PORT}}"
  local grpc_port="${3:-${PUBLIC_GRPC_PORT}}"

  if [ -n "${PORT_INFOS_FILE:-}" ] && [ -f "$PORT_INFOS_FILE" ]; then
    rm -f "$PORT_INFOS_FILE"
  fi
  write_port_infos_file "$mode" "$rest_port" "$grpc_port"
  if domain_enabled; then
    log "Configuring instance firewall for SSH from $ACCESS_CIDR and public HTTP/HTTPS/gRPC..."
  elif [ "$mode" = "initial" ] && [ "$WAIT_FOR_READY" = "true" ]; then
    log "Configuring instance firewall for SSH only until bootstrap reports actual ports..."
  else
    log "Configuring instance firewall to allow SSH/REST/gRPC from $ACCESS_CIDR on ports ${rest_port}/${grpc_port}..."
  fi
  aws lightsail put-instance-public-ports \
    --region "$REGION" \
    --instance-name "$INSTANCE_NAME" \
    --port-infos "file://${PORT_INFOS_FILE}" >/dev/null
}

find_matching_public_hosted_zone() {
  HOSTED_ZONE_ID=""
  HOSTED_ZONE_NAME=""
  if ! domain_enabled; then
    return
  fi
  local zones_json=""
  zones_json="$(aws route53 list-hosted-zones --output json)"
  local match=""
  match="$(
    python3 -c '
import json
import sys

domain = sys.argv[1].rstrip(".").lower()
best = None
for zone in json.load(sys.stdin).get("HostedZones", []):
    if zone.get("Config", {}).get("PrivateZone", False):
        continue
    zone_name = zone.get("Name", "").rstrip(".").lower()
    if not zone_name:
        continue
    if domain == zone_name or domain.endswith("." + zone_name):
        candidate = (len(zone_name), zone.get("Id", "").split("/")[-1], zone_name)
        if best is None or candidate[0] > best[0]:
            best = candidate
if best is not None:
    print(best[1])
    print(best[2])
' "$DOMAIN" <<<"$zones_json"
  )"
  if [ -n "$match" ]; then
    HOSTED_ZONE_ID="$(printf '%s\n' "$match" | sed -n '1p')"
    HOSTED_ZONE_NAME="$(printf '%s\n' "$match" | sed -n '2p')"
  fi
}

wait_for_route53_change_insync() {
  if [ -z "$ROUTE53_CHANGE_ID" ]; then
    return
  fi
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  while (( SECONDS < deadline )); do
    local status=""
    status="$(
      aws route53 get-change \
        --id "$ROUTE53_CHANGE_ID" \
        --query 'ChangeInfo.Status' \
        --output text
    )"
    if [ "$status" = "INSYNC" ]; then
      return
    fi
    sleep 5
  done
  warn "Timed out waiting for Route 53 change ${ROUTE53_CHANGE_ID} to become INSYNC."
}

upsert_route53_record() {
  local batch_file=""
  batch_file="$(mktemp)"
  cat >"$batch_file" <<EOF
{
  "Comment": "GoodMem Lightsail bootstrap ${DEPLOYMENT_NAME}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          { "Value": "${INSTANCE_IP}" }
        ]
      }
    }
  ]
}
EOF
  local change_json=""
  change_json="$(
    aws route53 change-resource-record-sets \
      --hosted-zone-id "$HOSTED_ZONE_ID" \
      --change-batch "file://${batch_file}" \
      --output json
  )"
  rm -f "$batch_file"
  ROUTE53_CHANGE_ID="$(printf '%s' "$change_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ChangeInfo"]["Id"], end="")')"
  wait_for_route53_change_insync
}

prepare_domain_routing() {
  if ! domain_enabled; then
    DNS_MODE_USED="none"
    return
  fi

  find_matching_public_hosted_zone
  if [ -n "$HOSTED_ZONE_ID" ]; then
    DNS_MODE_USED="route53"
    log "Found matching Route 53 hosted zone \"$HOSTED_ZONE_NAME\". Upserting A record for ${DOMAIN} -> ${INSTANCE_IP}..."
    upsert_route53_record
    return
  fi

  DNS_MODE_USED="manual"
  warn "No matching public Route 53 hosted zone found for ${DOMAIN}."
  warn "Create this DNS record at your DNS provider: A ${DOMAIN} -> ${INSTANCE_IP}"
}

domain_ipv4s() {
  local name="$1"
  python3 - "$name" <<'PY'
import socket
import sys

name = sys.argv[1]
ips = set()
try:
    for entry in socket.getaddrinfo(name, None, socket.AF_INET, socket.SOCK_STREAM):
        ips.add(entry[4][0])
except socket.gaierror:
    pass

for ip in sorted(ips):
    print(ip)
PY
}

domain_points_to_instance_ip() {
  local ips=""
  ips="$(domain_ipv4s "$DOMAIN" || true)"
  if [ -z "$ips" ]; then
    return 1
  fi
  printf '%s\n' "$ips" | grep -Fxq "$INSTANCE_IP"
}

wait_for_domain_resolution() {
  DNS_RESOLVED="false"
  if ! domain_enabled; then
    return 0
  fi
  local deadline=$((SECONDS + DNS_WAIT_TIMEOUT))
  while (( SECONDS < deadline )); do
    if domain_points_to_instance_ip; then
      DNS_RESOLVED="true"
      return 0
    fi
    sleep "$DNS_WAIT_INTERVAL"
  done
  return 1
}

write_user_data_file() {
  local db_host="$1"
  local db_port="$2"
  local db_user_urlencoded=""
  local db_password_urlencoded=""
  local db_master_username_q=""
  local db_master_password_q=""
  local profile_name_q=""
  local goodmem_image_q=""
  local domain_q=""
  local email_q=""
  local enable_public_proxy="false"
  local app_tls_disabled_line=""

  db_user_urlencoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DB_MASTER_USERNAME")"
  db_password_urlencoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$DB_MASTER_PASSWORD")"
  printf -v db_master_username_q '%q' "$DB_MASTER_USERNAME"
  printf -v db_master_password_q '%q' "$DB_MASTER_PASSWORD"
  printf -v profile_name_q '%q' "$PROFILE_NAME"
  printf -v goodmem_image_q '%q' "$GOODMEM_IMAGE"
  printf -v domain_q '%q' "$DOMAIN"
  printf -v email_q '%q' "$CONTACT_EMAIL"
  if domain_enabled; then
    enable_public_proxy="true"
    # The app stays plaintext on localhost because Caddy terminates public TLS.
    app_tls_disabled_line='install_cmd+=(--tls-disabled)'
  fi

  USER_DATA_FILE="$(mktemp)"
  # This heredoc is rendered locally, then executed by cloud-init remotely.
  # ${...} expands now on the caller machine; \${...} is preserved for the
  # remote script. We re-exec under bash because user-data starts under /bin/sh.
  cat >"$USER_DATA_FILE" <<EOF
#!/bin/sh
exec /bin/bash <<'GOODMEM_BOOTSTRAP'
set -euo pipefail
exec > >(tee -a ${BOOTSTRAP_LOG_REMOTE}) 2>&1

STATUS_DIR="${STATUS_DIR_REMOTE}"
STATUS_FILE="${STATUS_FILE_REMOTE}"
PROFILE_NAME=${profile_name_q}
PUBLIC_DOMAIN=${domain_q}
CONTACT_EMAIL=${email_q}
ENABLE_PUBLIC_PROXY=${enable_public_proxy}
mkdir -p "\${STATUS_DIR}"
chmod 700 "\${STATUS_DIR}"

write_status() {
  local state="\$1"
  local message="\$2"
  local details_json="\${3:-{}}"
  python3 - "\${STATUS_FILE}" "\${state}" "\${message}" "\${details_json}" <<'PY'
import json
import os
import sys

path = sys.argv[1]
state = sys.argv[2]
message = sys.argv[3]
details = json.loads(sys.argv[4])
payload = {"state": state, "message": message}
payload.update(details)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
os.chmod(path, 0o600)
PY
}

trap 'code=\$?; write_status FAILED "bootstrap failed" "{\"exit_code\":\$code}"; exit \$code' ERR

write_status STARTING "bootstrap started"

export HOME=/root
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y curl ca-certificates postgresql-client python3

DB_URL_PSQL="postgresql://${db_user_urlencoded}:${db_password_urlencoded}@${db_host}:${db_port}/${DB_MASTER_DATABASE}?sslmode=require"
DB_URL_JDBC="jdbc:postgresql://${db_host}:${db_port}/${DB_MASTER_DATABASE}?sslmode=require"

for _ in \$(seq 1 90); do
  if PGPASSWORD=${db_master_password_q} psql "\${DB_URL_PSQL}" -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  sleep 10
done

PGPASSWORD=${db_master_password_q} psql "\${DB_URL_PSQL}" -v ON_ERROR_STOP=1 \
  -c 'CREATE EXTENSION IF NOT EXISTS vector;' >/dev/null

write_status INSTALLING "running GoodMem installer"

curl -fsSL https://get.goodmem.ai/install.sh -o /tmp/goodmem-install.sh
install_cmd=(
  bash /tmp/goodmem-install.sh /usr/local/bin
  --handsfree
  --no-sudo
  --profile-name ${profile_name_q}
  --remote-db
  --rest-port ${PREFERRED_REST_PORT}
  --grpc-port ${PUBLIC_GRPC_PORT}
  --db-url "\${DB_URL_JDBC}"
  --db-user ${db_master_username_q}
  --db-password ${db_master_password_q}
  --image ${goodmem_image_q}
)
${app_tls_disabled_line}
"\${install_cmd[@]}"

# Python emits shell-escaped KEY=value lines, so eval only imports structured values
# from trusted local files produced by the installer.
eval "\$(
python3 - <<'PY'
import json
import pathlib
import shlex
import tomllib

config_path = pathlib.Path("/root/.goodmem/config.toml")
install_config_path = pathlib.Path(f"/root/.goodmem/installs/local-docker/${PROFILE_NAME}/install-config.json")
cfg = tomllib.loads(config_path.read_text(encoding="utf-8"))
install_cfg = json.loads(install_config_path.read_text(encoding="utf-8"))
profile = cfg["profiles"]["${PROFILE_NAME}"]
server_url = profile.get("server_url", "")
local_rest_scheme = "http" if server_url.startswith("http://") else "https"

values = {
    "REST_PORT": install_cfg.get("rest_port", ${PREFERRED_REST_PORT}),
    "GRPC_PORT": install_cfg.get("grpc_port", ${PUBLIC_GRPC_PORT}),
    "INSTALL_DIR": str(install_config_path.parent),
    "SERVER_URL": server_url,
    "LOCAL_REST_SCHEME": local_rest_scheme,
    "PROFILE_API_KEY": profile.get("api_key", ""),
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
)"

LOCAL_READY_URL="\${LOCAL_REST_SCHEME}://127.0.0.1:\${REST_PORT}/readyz"
LOCAL_INIT_URL="\${LOCAL_REST_SCHEME}://127.0.0.1:\${REST_PORT}/v1/system/init"
local_curl_args=(-sS --fail)
if [ "\${LOCAL_REST_SCHEME}" = "https" ]; then
  local_curl_args+=(-k)
fi

for _ in \$(seq 1 60); do
  if curl "\${local_curl_args[@]}" -o /dev/null "\${LOCAL_READY_URL}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

INIT_RESPONSE="\$(curl "\${local_curl_args[@]}" -X POST "\${LOCAL_INIT_URL}")"

# Python emits shell-escaped KEY=value lines, so eval only imports structured values
# from the JSON response of /v1/system/init.
eval "\$(
python3 -c '
import json
import shlex
import sys

data = json.load(sys.stdin)
values = {
    "ROOT_API_KEY": data.get("rootApiKey", ""),
    "INIT_ALREADY": "true" if data.get("alreadyInitialized") else "false",
    "INIT_MESSAGE": data.get("message", ""),
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
' <<<"\${INIT_RESPONSE}"
)"

if [ -z "\${ROOT_API_KEY}" ] || [ "\${ROOT_API_KEY}" = "None" ]; then
  ROOT_API_KEY="\${PROFILE_API_KEY:-}"
fi

if [ "\${ENABLE_PUBLIC_PROXY}" = "true" ]; then
  write_status CONFIGURING_PROXY "configuring public HTTPS proxy"
  apt-get install -y caddy
  mkdir -p /etc/caddy
  PUBLIC_GRPC_PORT=${PUBLIC_GRPC_PORT}
  cat >/etc/caddy/Caddyfile <<'CADDYFILE'
{
  admin off
CADDYFILE
  if [ -n "\${CONTACT_EMAIL}" ]; then
    printf '  email %s\n' "\${CONTACT_EMAIL}" >>/etc/caddy/Caddyfile
  fi
  cat >>/etc/caddy/Caddyfile <<CADDYFILE
}

\${PUBLIC_DOMAIN} {
  encode zstd gzip
  reverse_proxy http://127.0.0.1:\${REST_PORT}
}

\${PUBLIC_DOMAIN}:\${PUBLIC_GRPC_PORT} {
  # Keep gRPC on its own public port to match Fly.io and avoid assuming that
  # every client will successfully negotiate shared-port REST/gRPC routing.
  reverse_proxy 127.0.0.1:\${GRPC_PORT} {
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

export ROOT_API_KEY INIT_ALREADY INIT_MESSAGE REST_PORT GRPC_PORT INSTALL_DIR SERVER_URL LOCAL_REST_SCHEME PUBLIC_DOMAIN PROFILE_API_KEY

python3 - <<'PY'
import json
import os
import pathlib

status_path = pathlib.Path("${STATUS_FILE_REMOTE}")
payload = {
    "state": "READY",
    "message": "bootstrap complete",
    "api_key": os.environ.get("ROOT_API_KEY", ""),
    "init_already": os.environ.get("INIT_ALREADY", "false"),
    "init_message": os.environ.get("INIT_MESSAGE", ""),
    "rest_port": int(os.environ["REST_PORT"]),
    "grpc_port": int(os.environ["GRPC_PORT"]),
    "install_dir": os.environ["INSTALL_DIR"],
    "server_url": os.environ["SERVER_URL"],
    "local_rest_scheme": os.environ["LOCAL_REST_SCHEME"],
    "public_domain": os.environ.get("PUBLIC_DOMAIN", ""),
}
status_path.write_text(json.dumps(payload), encoding="utf-8")
os.chmod(status_path, 0o600)
PY
GOODMEM_BOOTSTRAP
EOF
}

create_db_if_needed() {
  if db_exists; then
    log "Reusing relational database \"$DB_RESOURCE_NAME\"..."
    return
  fi
  log "Creating relational database \"$DB_RESOURCE_NAME\"..."
  aws lightsail create-relational-database \
    --region "$REGION" \
    --relational-database-name "$DB_RESOURCE_NAME" \
    --availability-zone "$AVAILABILITY_ZONE" \
    --relational-database-blueprint-id "$DB_BLUEPRINT" \
    --relational-database-bundle-id "$DB_BUNDLE" \
    --master-database-name "$DB_MASTER_DATABASE" \
    --master-username "$DB_MASTER_USERNAME" \
    --master-user-password "$DB_MASTER_PASSWORD" \
    --no-publicly-accessible \
    --tags "key=managed-by,value=goodmem-deploy" "key=goodmem-deployment,value=$DEPLOYMENT_NAME" >/dev/null
}

create_instance_if_needed() {
  local db_host="$1"
  local db_port="$2"
  if instance_exists; then
    log "Reusing instance \"$INSTANCE_NAME\"..."
    return
  fi
  write_user_data_file "$db_host" "$db_port"
  local user_data_content=""
  user_data_content="$(cat "$USER_DATA_FILE")"
  log "Creating Lightsail instance \"$INSTANCE_NAME\"..."
  aws lightsail create-instances \
    --region "$REGION" \
    --instance-names "$INSTANCE_NAME" \
    --availability-zone "$AVAILABILITY_ZONE" \
    --blueprint-id "$INSTANCE_BLUEPRINT" \
    --bundle-id "$INSTANCE_BUNDLE" \
    --key-pair-name "$KEY_PAIR_NAME" \
    --user-data "$user_data_content" \
    --tags "key=managed-by,value=goodmem-deploy" "key=goodmem-deployment,value=$DEPLOYMENT_NAME" >/dev/null
}

refresh_ssh_access() {
  if [ -f "$KEY_PAIR_FILE" ]; then
    SSH_KEY_FILE="$KEY_PAIR_FILE"
    SSH_CERT_FILE=""
    SSH_USERNAME="$(
      aws lightsail get-instance-access-details \
        --region "$REGION" \
        --instance-name "$INSTANCE_NAME" \
        --protocol ssh \
        --query 'accessDetails.username' \
        --output text
    )"
    if [ -z "$INSTANCE_IP" ]; then
      INSTANCE_IP="$(
        aws lightsail get-instance \
          --region "$REGION" \
          --instance-name "$INSTANCE_NAME" \
          --query 'instance.publicIpAddress' \
          --output text
      )"
    fi
    return
  fi

  local access_json=""
  access_json="$(
    aws lightsail get-instance-access-details \
      --region "$REGION" \
      --instance-name "$INSTANCE_NAME" \
      --protocol ssh \
      --output json
  )"
  SSH_USERNAME="$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["accessDetails"]["username"])' <<<"$access_json")"
  local private_key=""
  local cert_key=""
  private_key="$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["accessDetails"]["privateKey"])' <<<"$access_json")"
  cert_key="$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["accessDetails"].get("certKey", ""))' <<<"$access_json")"
  if [ -z "$INSTANCE_IP" ]; then
    INSTANCE_IP="$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["accessDetails"]["ipAddress"])' <<<"$access_json")"
  fi
  if [ -n "${SSH_KEY_FILE:-}" ] && [ -f "$SSH_KEY_FILE" ]; then
    rm -f "$SSH_KEY_FILE"
  fi
  if [ -n "${SSH_CERT_FILE:-}" ] && [ -f "$SSH_CERT_FILE" ]; then
    rm -f "$SSH_CERT_FILE"
  fi
  SSH_KEY_FILE="$(mktemp)"
  printf '%s\n' "$private_key" >"$SSH_KEY_FILE"
  chmod 600 "$SSH_KEY_FILE"
  if [ -n "$cert_key" ]; then
    SSH_CERT_FILE="$(mktemp)"
    printf '%s\n' "$cert_key" >"$SSH_CERT_FILE"
    chmod 600 "$SSH_CERT_FILE"
  else
    SSH_CERT_FILE=""
  fi
}

run_ssh() {
  local remote_cmd="$1"
  local -a ssh_args=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
    -i "$SSH_KEY_FILE"
  )
  if [ -n "${SSH_CERT_FILE:-}" ]; then
    ssh_args+=(-o "CertificateFile=$SSH_CERT_FILE")
  fi
  ssh \
    "${ssh_args[@]}" \
    "${SSH_USERNAME}@${INSTANCE_IP}" \
    "$remote_cmd"
}

wait_for_ssh() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  while (( SECONDS < deadline )); do
    refresh_ssh_access
    if run_ssh "echo ssh-ready" >/dev/null 2>&1; then
      return
    fi
    sleep "$WAIT_INTERVAL"
  done
  echo "Timed out waiting for SSH access to instance." >&2
  exit 1
}

extract_status_field() {
  local field="$1"
  python3 -c '
import json
import sys

field = sys.argv[1]
data = json.load(sys.stdin)
value = data.get(field, "")
if value is None:
    value = ""
print(value)
' "$field"
}

wait_for_bootstrap_ready() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local started_at="$SECONDS"
  local last_state=""
  local last_report=-1
  # The remote user-data script writes a small JSON status file as it progresses.
  while (( SECONDS < deadline )); do
    local status_json=""
    if status_json="$(run_ssh "sudo cat ${STATUS_FILE_REMOTE} 2>/dev/null" 2>/dev/null || true)"; then
      if [ -n "$status_json" ]; then
        local state=""
        state="$(printf '%s' "$status_json" | extract_status_field state)"
        if [ "$state" = "READY" ]; then
          ROOT_API_KEY="$(printf '%s' "$status_json" | extract_status_field api_key)"
          REST_PORT="$(printf '%s' "$status_json" | extract_status_field rest_port)"
          GRPC_PORT="$(printf '%s' "$status_json" | extract_status_field grpc_port)"
          LOCAL_REST_SCHEME="$(printf '%s' "$status_json" | extract_status_field local_rest_scheme)"
          if [ -z "$LOCAL_REST_SCHEME" ]; then
            LOCAL_REST_SCHEME="https"
          fi
          return
        fi
        if [ "$state" = "FAILED" ]; then
          warn "Remote bootstrap failed. Showing tail of ${BOOTSTRAP_LOG_REMOTE}:"
          run_ssh "sudo tail -200 ${BOOTSTRAP_LOG_REMOTE}" || true
          exit 1
        fi
        local elapsed=$((SECONDS - started_at))
        if [ "$state" != "$last_state" ] || (( last_report < 0 || elapsed - last_report >= 60 )); then
          log "Still waiting for remote bootstrap... state: $state, elapsed: $(format_elapsed "$elapsed")"
          last_state="$state"
          last_report="$elapsed"
        fi
      fi
    fi
    sleep "$WAIT_INTERVAL"
  done
  warn "Timed out waiting for remote bootstrap to report READY. Showing tail of bootstrap log:"
  run_ssh "sudo tail -200 ${BOOTSTRAP_LOG_REMOTE}" || true
  exit 1
}

wait_for_rest_ready() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local url="${LOCAL_REST_SCHEME}://127.0.0.1:${REST_PORT}/readyz"
  local -a curl_args=(-sS -o /dev/null -w '%{http_code}' --max-time 5)
  if [ "$LOCAL_REST_SCHEME" = "https" ]; then
    curl_args=(-sSk -o /dev/null -w '%{http_code}' --max-time 5)
  fi
  while (( SECONDS < deadline )); do
    local code=""
    local remote_cmd=""
    printf -v remote_cmd '%q ' curl "${curl_args[@]}" "$url"
    remote_cmd="${remote_cmd% }"
    code="$(run_ssh "$remote_cmd" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
      return
    fi
    sleep "$WAIT_INTERVAL"
  done
  echo "Timed out waiting for REST readiness at $url" >&2
  exit 1
}

wait_for_public_https() {
  if ! domain_enabled || [ "$DNS_RESOLVED" != "true" ]; then
    return 0
  fi
  local deadline=$((SECONDS + DNS_WAIT_TIMEOUT))
  local url="${PUBLIC_REST_URL}/readyz"
  while (( SECONDS < deadline )); do
    local code=""
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
      PUBLIC_READY="true"
      return 0
    fi
    sleep "$DNS_WAIT_INTERVAL"
  done
  return 1
}

goodmem_cli_available() {
  command -v goodmem >/dev/null 2>&1
}

wait_for_public_grpc() {
  if ! domain_enabled || [ "$DNS_RESOLVED" != "true" ] || [ "$PUBLIC_READY" != "true" ]; then
    return 0
  fi
  if ! goodmem_cli_available || [ -z "$ROOT_API_KEY" ]; then
    return 0
  fi
  local deadline=$((SECONDS + DNS_WAIT_TIMEOUT))
  while (( SECONDS < deadline )); do
    local output=""
    if output="$(goodmem --server "$PUBLIC_GRPC_URL" --api-key "$ROOT_API_KEY" system health 2>/dev/null || true)"; then
      if printf '%s\n' "$output" | grep -Fq 'SERVING'; then
        return 0
      fi
    fi
    sleep "$DNS_WAIT_INTERVAL"
  done
  return 1
}

cleanup() {
  if [ -n "${USER_DATA_FILE:-}" ] && [ -f "$USER_DATA_FILE" ]; then
    rm -f "$USER_DATA_FILE"
  fi
  if [ -n "${PORT_INFOS_FILE:-}" ] && [ -f "$PORT_INFOS_FILE" ]; then
    rm -f "$PORT_INFOS_FILE"
  fi
  if [ -n "${SSH_KEY_FILE:-}" ] && [ -f "$SSH_KEY_FILE" ] && [ "$SSH_KEY_FILE" != "$KEY_PAIR_FILE" ]; then
    rm -f "$SSH_KEY_FILE"
  fi
  if [ -n "${SSH_CERT_FILE:-}" ] && [ -f "$SSH_CERT_FILE" ]; then
    rm -f "$SSH_CERT_FILE"
  fi
}

trap cleanup EXIT

if [ "$LIST_MODE" = "true" ] && [ "$DESTROY_MODE" = "true" ]; then
  echo "--list and --destroy cannot be used together." >&2
  exit 1
fi

if [ "$LIST_MODE" = "true" ]; then
  require_cmd python3
  list_deployments
  exit 0
fi

if [ "$DESTROY_MODE" = "true" ] && [ -z "$DEPLOYMENT_NAME" ]; then
  echo "--destroy requires --name." >&2
  exit 1
fi

# Management mode: teardown a named deployment and exit.
if [ "$DESTROY_MODE" = "true" ]; then
  require_cmd aws
  require_cmd python3
  ensure_names
  load_local_state
  if [ "$CONFIRM_DESTROY" != "true" ]; then
    print_destroy_confirmation
    exit 1
  fi
  destroy_deployment
  exit 0
fi

# Local prerequisites and rerun state.
require_cmd aws
require_cmd curl
require_cmd openssl
require_cmd python3
require_cmd ssh

ensure_tier
ensure_names
resolve_availability_zone
resolve_access_cidr
load_local_state
if db_exists; then
  if [ -z "$DB_MASTER_PASSWORD" ]; then
    echo "Relational database \"$DB_RESOURCE_NAME\" already exists, but no password is available locally. Pass --db-master-password explicitly or remove the database." >&2
    exit 1
  fi
else
  DB_MASTER_PASSWORD="$(generate_password)"
fi
ensure_key_pair
save_local_state

# Provision AWS resources first so the instance can bootstrap against a real DB endpoint.
log "Deployment: $DEPLOYMENT_NAME"
log "Region: $REGION"
log "Availability zone: $AVAILABILITY_ZONE"
if [ "$TIER_SET" = "true" ]; then
  log "Tier: $SIZE_TIER ($(tier_summary "$SIZE_TIER"))"
fi
log "Instance bundle: $INSTANCE_BUNDLE"
log "DB bundle: $DB_BUNDLE"
log "Profile name: $PROFILE_NAME"
log "SSH CIDR: $ACCESS_CIDR"
if domain_enabled; then
  log "Public domain: $DOMAIN"
fi

create_db_if_needed
log "Waiting for relational database \"$DB_RESOURCE_NAME\" to become available..."
wait_for_db_available
DB_HOST="$(get_db_endpoint)"
DB_PORT="$(get_db_port)"
log "Database endpoint: ${DB_HOST}:${DB_PORT}"

create_instance_if_needed "$DB_HOST" "$DB_PORT"
log "Waiting for instance \"$INSTANCE_NAME\" to become running..."
wait_for_instance_running
ensure_static_ip
prepare_domain_routing
save_local_state
configure_instance_ports initial

if [ "$WAIT_FOR_READY" != "true" ]; then
  if domain_enabled; then
    cat <<EOF_MSG
Provisioning complete. Bootstrap is continuing in the background.

Deployment: $DEPLOYMENT_NAME
Instance:   $INSTANCE_NAME
Static IP:  $INSTANCE_IP
Database:   $DB_RESOURCE_NAME
Domain:     $DOMAIN
REST URL:   ${PUBLIC_REST_URL} (pending bootstrap/DNS/TLS)
gRPC URL:   ${PUBLIC_GRPC_URL} (pending bootstrap/DNS/TLS)
Console:    ${PUBLIC_CONSOLE_URL} (pending bootstrap/DNS/TLS)

Notes:
- Route 53/manual DNS setup has already been applied for this run.
- Re-run this command without --no-wait to wait for readiness and print the API key.
- Remote bootstrap log: $BOOTSTRAP_LOG_REMOTE
- Remote status file:   $STATUS_FILE_REMOTE
EOF_MSG
  else
    cat <<EOF_MSG
Provisioning complete. Bootstrap is continuing in the background.

Deployment: $DEPLOYMENT_NAME
Instance:   $INSTANCE_NAME
Static IP:  $INSTANCE_IP
Database:   $DB_RESOURCE_NAME
Expected REST URL:   https://${INSTANCE_IP}:${PREFERRED_REST_PORT} (preferred install port)
Expected gRPC URL:   https://${INSTANCE_IP}:${PUBLIC_GRPC_PORT} (preferred install port)

Notes:
- SSH is open now; REST/gRPC are temporarily exposed on the preferred install ports until you re-run without --no-wait and the script reconciles the firewall to the actual runtime ports.
- Remote bootstrap log: $BOOTSTRAP_LOG_REMOTE
- Remote status file:   $STATUS_FILE_REMOTE
EOF_MSG
  fi
  exit 0
fi

# Once the instance is reachable, switch to SSH-driven bootstrap and readiness checks.
log "Waiting for SSH access to $INSTANCE_IP..."
wait_for_ssh
log "Waiting for remote bootstrap status..."
wait_for_bootstrap_ready
if ! domain_enabled; then
  configure_instance_ports runtime "$REST_PORT" "$GRPC_PORT"
fi
log "Waiting for local REST readiness on port $REST_PORT..."
wait_for_rest_ready

if domain_enabled; then
  log "Waiting for public DNS for ${DOMAIN}..."
  if wait_for_domain_resolution; then
    log "Domain ${DOMAIN} resolves to ${INSTANCE_IP}."
    log "Waiting for public HTTPS readiness..."
    if ! wait_for_public_https; then
      warn "Public HTTPS did not become ready at ${PUBLIC_REST_URL} within ${DNS_WAIT_TIMEOUT}s."
    fi
    if [ "$PUBLIC_READY" = "true" ]; then
      if ! wait_for_public_grpc; then
        warn "Public gRPC did not become ready at ${PUBLIC_GRPC_URL} within ${DNS_WAIT_TIMEOUT}s."
      fi
    fi
  else
    warn "Domain ${DOMAIN} does not yet resolve to ${INSTANCE_IP}."
    warn "Caddy is installed and will keep retrying certificate issuance after DNS is correct."
  fi
fi

if domain_enabled; then
  rest_line="${PUBLIC_REST_URL} (public 443 -> internal ${REST_PORT})"
  grpc_line="${PUBLIC_GRPC_URL} (public ${PUBLIC_GRPC_PORT} -> internal ${GRPC_PORT})"
  console_line="${PUBLIC_CONSOLE_URL}"
  if [ "$DNS_RESOLVED" != "true" ] || [ "$PUBLIC_READY" != "true" ]; then
    rest_line="${PUBLIC_REST_URL} (pending DNS/TLS)"
    grpc_line="${PUBLIC_GRPC_URL} (pending DNS/TLS)"
    console_line="${PUBLIC_CONSOLE_URL} (pending DNS/TLS)"
  fi
  dns_line="$DNS_MODE_USED"
  if [ "$DNS_MODE_USED" = "route53" ] && [ -n "$HOSTED_ZONE_NAME" ]; then
    dns_line="route53 (${HOSTED_ZONE_NAME})"
  fi
  cat <<EOF_MSG
Bootstrap complete.

Deployment: $DEPLOYMENT_NAME
Instance:   $INSTANCE_NAME
Static IP:  $INSTANCE_IP
Database:   $DB_RESOURCE_NAME
Domain:     $DOMAIN
DNS mode:   $dns_line
REST URL:   $rest_line
gRPC URL:   $grpc_line
Console:    $console_line
API Key:    $ROOT_API_KEY

Notes:
- Instance firewall exposes only 80/443/${PUBLIC_GRPC_PORT} publicly, plus SSH from $ACCESS_CIDR.
- Remote bootstrap log: $BOOTSTRAP_LOG_REMOTE
- Remote status file:   $STATUS_FILE_REMOTE
EOF_MSG
  if [ "$DNS_RESOLVED" != "true" ] || [ "$PUBLIC_READY" != "true" ]; then
    cat <<EOF_MSG
- If DNS is manual, create or verify: A $DOMAIN -> $INSTANCE_IP
- Once DNS is correct, Caddy on the instance will obtain the certificate automatically.
- SSH tunnel fallback:
  ssh -L 18080:127.0.0.1:${REST_PORT} -L 19090:127.0.0.1:${GRPC_PORT} -i ${KEY_PAIR_FILE} ${SSH_USERNAME}@${INSTANCE_IP}
  REST:  ${LOCAL_REST_SCHEME}://localhost:18080
  gRPC:  $(if [ "$LOCAL_REST_SCHEME" = "http" ]; then printf 'http'; else printf 'https'; fi)://localhost:19090
EOF_MSG
  fi
else
  cat <<EOF_MSG
Bootstrap complete.

Deployment: $DEPLOYMENT_NAME
Instance:   $INSTANCE_NAME
Static IP:  $INSTANCE_IP
Database:   $DB_RESOURCE_NAME
REST URL:   ${LOCAL_REST_SCHEME}://${INSTANCE_IP}:${REST_PORT}
gRPC URL:   $(if [ "$LOCAL_REST_SCHEME" = "http" ]; then printf 'http'; else printf 'https'; fi)://${INSTANCE_IP}:${GRPC_PORT}
Console:    ${LOCAL_REST_SCHEME}://${INSTANCE_IP}:${REST_PORT}/console/
API Key:    $ROOT_API_KEY

Notes:
- TLS is self-signed by the GoodMem installer on the instance. Use curl -k and allow self-signed gRPC fallback in the CLI.
- Firewall access is restricted to $ACCESS_CIDR (plus Lightsail browser SSH on port 22).
- Remote bootstrap log: $BOOTSTRAP_LOG_REMOTE
- Remote status file:   $STATUS_FILE_REMOTE
EOF_MSG
fi
