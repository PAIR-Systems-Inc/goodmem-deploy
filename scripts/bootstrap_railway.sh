#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

PROJECT_NAME=""
WORKSPACE=""
POSTGRES_SERVICE="postgres"
GOODMEM_SERVICE="goodmem"
IMAGE="ghcr.io/pair-systems-inc/goodmem/server:latest"
POSTGRES_IMAGE="pgvector/pgvector:pg17"
POSTGRES_USER="postgres"
POSTGRES_DB="goodmem"
POSTGRES_MEMORY_MB=1024
GOODMEM_MEMORY_MB=1024
POSTGRES_VOLUME_MOUNT="/var/lib/postgresql/data"
POSTGRES_DATA_DIR="/var/lib/postgresql/data/pgdata"
REST_PORT=8080
GRPC_PORT=50051
SKIP_INIT=false
SKIP_DOMAIN=false
INSTALL_CLI=false
WAIT_FOR_READY=true
READY_WAIT_TIMEOUT=120
READY_WAIT_INTERVAL=5
ATTACH_EXISTING_POSTGRES_VOLUME=false
ROOT_API_KEY=""
ROOT_USER_ID=""
INIT_ALREADY=""
INIT_MESSAGE=""
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
Usage: ./scripts/bootstrap_railway.sh [options]

Options:
  --project-name NAME      Project name for railway init
  --workspace NAME|ID      Workspace name or ID for railway init
  --postgres-service NAME  Postgres service name (default: postgres)
  --postgres-image IMAGE   Postgres image (default: pgvector/pgvector:pg17)
  --postgres-user NAME     Postgres user (default: postgres)
  --postgres-db NAME       Postgres database (default: goodmem)
  --postgres-memory MB     Postgres memory limit in MB (default: 1024)
  --goodmem-service NAME   GoodMem service name (default: goodmem)
  --image IMAGE            GoodMem image (default: ghcr.io/pair-systems-inc/goodmem/server:latest)
  --goodmem-memory MB      GoodMem memory limit in MB (default: 1024)
  --attach-existing-postgres-volume
                           Attach a volume even if the Postgres service exists
                           (may hide existing data)
  --install-cli            Install Railway CLI if missing
  --skip-init              Skip railway init (use if repo already linked)
  --skip-domain            Skip domain creation
  --no-wait                Skip waiting for readiness (/startupz)
  --wait-timeout SECONDS   Readiness wait timeout (default: 120)
  -h, --help               Show this help
USAGE
}

random_name_prefix() {
  local -a adjectives=(
    bold bright cosmic dusk eager foggy funky gentle hidden icy
    lucky mellow neon nimble quiet radiant salty subtle vivid
    wavy wild zesty blursed
  )
  local -a nouns=(
    hippo komodo lemon mango nebula otter panda quasar rocket
    sailor sparrow sprout strawberry sunset tornado tulip urchin
    valley zephyr
  )
  local adj="${adjectives[RANDOM % ${#adjectives[@]}]}"
  local noun="${nouns[RANDOM % ${#nouns[@]}]}"
  printf '%s-%s' "$adj" "$noun"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    --postgres-service)
      POSTGRES_SERVICE="$2"
      shift 2
      ;;
    --postgres-image)
      POSTGRES_IMAGE="$2"
      shift 2
      ;;
    --postgres-user)
      POSTGRES_USER="$2"
      shift 2
      ;;
    --postgres-db)
      POSTGRES_DB="$2"
      shift 2
      ;;
    --postgres-memory)
      POSTGRES_MEMORY_MB="$2"
      shift 2
      ;;
    --goodmem-service)
      GOODMEM_SERVICE="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --goodmem-memory)
      GOODMEM_MEMORY_MB="$2"
      shift 2
      ;;
    --attach-existing-postgres-volume)
      ATTACH_EXISTING_POSTGRES_VOLUME=true
      shift
      ;;
    --install-cli)
      INSTALL_CLI=true
      shift
      ;;
    --skip-init)
      SKIP_INIT=true
      shift
      ;;
    --skip-domain)
      SKIP_DOMAIN=true
      shift
      ;;
    --no-wait)
      WAIT_FOR_READY=false
      shift
      ;;
    --wait-timeout)
      READY_WAIT_TIMEOUT="$2"
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

if [ -z "$PROJECT_NAME" ] && [ "$SKIP_INIT" = false ]; then
  PROJECT_NAME="goodmem-$(random_name_prefix)"
  echo "Using generated Railway project name: ${PROJECT_NAME}"
fi

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$attempts" ]; then
      return 1
    fi
    attempt=$((attempt + 1))
    sleep "$delay"
  done
}

tty_available() {
  [ -t 0 ] || [ -r /dev/tty ]
}

run_with_tty() {
  if [ -t 0 ]; then
    "$@"
  elif [ -r /dev/tty ]; then
    "$@" </dev/tty
  else
    "$@"
  fi
}

ensure_cli() {
  if command -v railway >/dev/null 2>&1; then
    return
  fi

  if [ "$INSTALL_CLI" = true ]; then
    if command -v curl >/dev/null 2>&1; then
      echo "Installing Railway CLI..."
      bash <(curl -fsSL cli.new)
    else
      echo "curl is required to install the Railway CLI automatically." >&2
      exit 1
    fi
  else
    echo "railway CLI not found. Install it first: https://docs.railway.com/guides/cli" >&2
    echo "Tip: re-run with --install-cli to auto-install via cli.new." >&2
    exit 1
  fi

  if ! command -v railway >/dev/null 2>&1; then
    echo "Railway CLI install did not complete successfully." >&2
    exit 1
  fi
}

ensure_login() {
  if [ -n "${RAILWAY_API_TOKEN:-}" ]; then
    return
  fi
  if [ -n "${RAILWAY_TOKEN:-}" ]; then
    if [ "$SKIP_INIT" = false ]; then
      echo "RAILWAY_TOKEN is project-scoped and cannot run railway init." >&2
      echo "Use --skip-init or set RAILWAY_API_TOKEN instead." >&2
      exit 1
    fi
    return
  fi

  if railway whoami >/dev/null 2>&1; then
    return
  fi

  if tty_available; then
    run_with_tty railway login
  else
    echo "Not logged in to Railway and no TTY available." >&2
    echo "Run 'railway login' interactively or set RAILWAY_API_TOKEN." >&2
    exit 1
  fi

  if ! railway whoami >/dev/null 2>&1; then
    echo "Railway login did not complete successfully." >&2
    exit 1
  fi
}

ensure_cli
ensure_login

service_exists() {
  local service="$1"
  railway variables --service "$service" --json >/dev/null 2>&1
}

wait_for_service() {
  local service="$1"
  if retry 5 2 service_exists "$service"; then
    return 0
  fi
  return 1
}

find_service_id() {
  local name="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg name "$name" \
      '.. | objects | select(.name? == $name and (.id? != null)) | .id' \
      | head -n1
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$name" <<'PY'
import json
import sys

name = sys.argv[1]

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

def walk(node):
    if isinstance(node, dict):
        if node.get("name") == name and node.get("id"):
            return node["id"]
        for value in node.values():
            found = walk(value)
            if found:
                return found
    elif isinstance(node, list):
        for item in node:
            found = walk(item)
            if found:
                return found
    return None

result = walk(data)
if result:
    sys.stdout.write(str(result))
PY
    return
  fi
  return 1
}

postgres_service_id() {
  local status_json=""
  local service_id=""

  if status_json="$(railway status --json 2>/dev/null)"; then
    service_id="$(printf '%s' "$status_json" | find_service_id "$POSTGRES_SERVICE")"
    if [ -n "$service_id" ]; then
      printf '%s' "$service_id"
      return 0
    fi
  fi

  if status_json="$(railway service status --json --all 2>/dev/null)"; then
    service_id="$(printf '%s' "$status_json" | find_service_id "$POSTGRES_SERVICE")"
    if [ -n "$service_id" ]; then
      printf '%s' "$service_id"
      return 0
    fi
  fi

  return 1
}

volume_list_nonempty() {
  local json="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 - <<'PY'
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

if isinstance(data, list) and data:
    sys.exit(0)
sys.exit(1)
PY
    return
  fi
  printf '%s' "$json" | grep -q "{"
}

postgres_volume_attached() {
  local volumes_json=""
  local service_id=""
  service_id="$(postgres_service_id 2>/dev/null || true)"
  if [ -n "$service_id" ] && volumes_json="$(railway volume --service "$service_id" list --json 2>/dev/null)"; then
    if volume_list_nonempty "$volumes_json"; then
      return 0
    fi
    return 1
  fi

  if volumes_json="$(railway volume list --json 2>/dev/null)"; then
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$volumes_json" | jq -e \
        --arg service "$POSTGRES_SERVICE" \
        --arg serviceId "$service_id" \
        --arg mount "$POSTGRES_VOLUME_MOUNT" \
        'map(select((.serviceName? == $service) or (.serviceId? == $serviceId) or (.serviceId? == $service) or (.service? == $service) or (.mountPath? == $mount) or (.mount_path? == $mount))) | length > 0' \
        >/dev/null 2>&1
      return
    fi
    if command -v python3 >/dev/null 2>&1; then
      printf '%s' "$volumes_json" | python3 - "$POSTGRES_SERVICE" "$service_id" "$POSTGRES_VOLUME_MOUNT" <<'PY'
import json
import sys

service = sys.argv[1]
service_id = sys.argv[2]
mount = sys.argv[3]

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

if not isinstance(data, list):
    sys.exit(1)

def matches(item):
    if not isinstance(item, dict):
        return False
    if mount and str(item.get("mountPath", "")) == mount:
        return True
    if mount and str(item.get("mount_path", "")) == mount:
        return True
    for key in ("service", "serviceId", "serviceID", "serviceName", "service_name", "service_id"):
        value = item.get(key)
        if value is not None and str(value) == service:
            return True
        if service_id and value is not None and str(value) == service_id:
            return True
    return False

if any(matches(item) for item in data):
    sys.exit(0)
sys.exit(1)
PY
      return
    fi
    printf '%s' "$volumes_json" | grep -q "$POSTGRES_VOLUME_MOUNT"
    return
  fi

  return 1
}

ensure_postgres_volume() {
  local created="$1"
  if postgres_volume_attached; then
    return
  fi

  if [ "$created" = true ] || [ "$ATTACH_EXISTING_POSTGRES_VOLUME" = true ]; then
    echo "Attaching volume to Postgres service \"$POSTGRES_SERVICE\"..."
    local service_id=""
    local volume_output=""
    local -a volume_cmd=()
    service_id="$(postgres_service_id 2>/dev/null || true)"
    if [ -n "$service_id" ]; then
      volume_cmd=(railway volume --service "$service_id" add --mount-path "$POSTGRES_VOLUME_MOUNT")
    elif tty_available; then
      volume_cmd=(railway volume add --mount-path "$POSTGRES_VOLUME_MOUNT")
    else
      cat <<EOF_WARN
Warning: Unable to resolve Railway service ID for "$POSTGRES_SERVICE" and no TTY is available.
Attach a volume manually:
  railway volume --service "$POSTGRES_SERVICE" add --mount-path "$POSTGRES_VOLUME_MOUNT"
  railway variables --service "$POSTGRES_SERVICE" --set "PGDATA=${POSTGRES_DATA_DIR}"
EOF_WARN
      return
    fi

    if ! volume_output="$("${volume_cmd[@]}" 2>&1)"; then
      if printf '%s' "$volume_output" | grep -qiE 'already|exists|has a volume'; then
        echo "Postgres volume already attached; continuing."
        return
      fi
      if printf '%s' "$volume_output" | grep -qiE 'panicked|unwrap'; then
        cat <<EOF_WARN
Railway CLI crashed while attaching the volume. Upgrade the CLI and rerun:
  railway upgrade
  railway volume --service "$POSTGRES_SERVICE" add --mount-path "$POSTGRES_VOLUME_MOUNT"
  railway variables --service "$POSTGRES_SERVICE" --set "PGDATA=${POSTGRES_DATA_DIR}"
EOF_WARN
        printf '%s\n' "$volume_output" >&2
        exit 1
      fi
      printf '%s\n' "$volume_output" >&2
      exit 1
    fi
    return
  fi

  cat <<EOF_WARN
Warning: Postgres service "$POSTGRES_SERVICE" has no volume attached.
Attach one manually or re-run with --attach-existing-postgres-volume (may hide existing data):
  railway volume --service "$POSTGRES_SERVICE" add --mount-path "$POSTGRES_VOLUME_MOUNT"
  railway variables --service "$POSTGRES_SERVICE" --set "PGDATA=${POSTGRES_DATA_DIR}"
EOF_WARN
}

goodmem_cli_available() {
  command -v goodmem >/dev/null 2>&1
}

json_value() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r ".$key // empty"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$key" <<'PY'
import json
import sys

key = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)

value = data.get(key, "")
if value is None:
    value = ""
if isinstance(value, bool):
    sys.stdout.write("true" if value else "false")
else:
    sys.stdout.write(str(value))
PY
    return
  fi
  return 1
}

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
    return
  fi
  date +%s%N | sha256sum | awk '{print substr($1,1,48)}'
}

ensure_postgres_service() {
  local created=false
  if service_exists "$POSTGRES_SERVICE"; then
    created=false
  else
    created=true
    echo "Creating Postgres service \"$POSTGRES_SERVICE\"..."
    postgres_password="$(generate_password)"
    railway add --image "$POSTGRES_IMAGE" --service "$POSTGRES_SERVICE" \
      --variables "PORT=5432" \
      --variables "POSTGRES_USER=${POSTGRES_USER}" \
      --variables "POSTGRES_PASSWORD=${postgres_password}" \
      --variables "POSTGRES_DB=${POSTGRES_DB}" \
      --variables "PGDATA=${POSTGRES_DATA_DIR}"

    if ! wait_for_service "$POSTGRES_SERVICE"; then
      echo "Postgres service \"$POSTGRES_SERVICE\" not found after creation." >&2
      echo "If your Postgres service uses a different name, re-run with --postgres-service." >&2
      exit 1
    fi
  fi

  ensure_postgres_volume "$created"
}

ensure_goodmem_service() {
  if service_exists "$GOODMEM_SERVICE"; then
    return
  fi

  echo "Creating GoodMem service \"$GOODMEM_SERVICE\"..."
  railway add --image "$IMAGE" --service "$GOODMEM_SERVICE" \
    --variables "PORT=${REST_PORT}" \
    --variables "GOODMEM_REST_TLS_ENABLED=false" \
    --variables "GOODMEM_GRPC_TLS_ENABLED=true" \
    --variables "GOODMEM_GRPC_PORT=${GRPC_PORT}" \
    --variables "DB_USER=${ref_user}" \
    --variables "DB_PASSWORD=${ref_password}" \
    --variables "DB_URL=${ref_url}"
}

extract_domain() {
  local text="$1"
  local domain=""

  domain="$(printf '%s\n' "$text" | grep -Eo 'https?://[^[:space:]]+' | head -n1 || true)"
  if [ -n "$domain" ]; then
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%/}"
    printf '%s' "$domain"
    return
  fi

  domain="$(printf '%s\n' "$text" | grep -Eo '([a-zA-Z0-9-]+\\.)+up\\.railway\\.app' | head -n1 || true)"
  if [ -n "$domain" ]; then
    printf '%s' "$domain"
    return
  fi

  domain="$(printf '%s\n' "$text" | grep -Eo '([a-zA-Z0-9-]+\\.)+[a-zA-Z]{2,}' | head -n1 || true)"
  printf '%s' "$domain"
}

wait_for_ready() {
  if [ "$WAIT_FOR_READY" = false ]; then
    return
  fi
  if [ -z "$rest_domain" ]; then
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found; skipping readiness wait."
    return
  fi

  local url="https://${rest_domain}/startupz"
  local deadline=$((SECONDS + READY_WAIT_TIMEOUT))

  echo "Waiting for GoodMem readiness (this can take a minute on first boot)..."
  while (( SECONDS < deadline )); do
    local body=""
    body="$(curl -fsSL --max-time 5 "$url" 2>/dev/null || true)"
    if printf '%s' "$body" | grep -q '"state":"READY"'; then
      echo "GoodMem reported READY via /startupz."
      return
    fi
    if printf '%s' "$body" | grep -q '"started":true'; then
      echo "GoodMem reported started via /startupz."
      return
    fi
    sleep "$READY_WAIT_INTERVAL"
  done

  echo "Warning: readiness did not respond within ${READY_WAIT_TIMEOUT}s. It may still be starting."
}

init_system_rest() {
  if [ -z "$rest_domain" ]; then
    echo "REST domain not available; skipping system initialization." >&2
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found; skipping system initialization." >&2
    return
  fi

  local url="https://${rest_domain}/v1/system/init"
  echo "Initializing GoodMem via REST..."

  local response=""
  if ! response="$(curl -sS -X POST "$url" 2>/dev/null)"; then
    echo "Warning: system init request failed. Retry with: curl -sS -X POST ${url}" >&2
    return
  fi
  if [ -z "$response" ]; then
    echo "Warning: system init returned an empty response." >&2
    return
  fi

  INIT_ALREADY="$(printf '%s' "$response" | json_value alreadyInitialized 2>/dev/null || true)"
  INIT_MESSAGE="$(printf '%s' "$response" | json_value message 2>/dev/null || true)"
  ROOT_API_KEY="$(printf '%s' "$response" | json_value rootApiKey 2>/dev/null || true)"
  ROOT_USER_ID="$(printf '%s' "$response" | json_value userId 2>/dev/null || true)"

  if [ -n "$INIT_MESSAGE" ]; then
    echo "$INIT_MESSAGE"
  fi
  if [ -n "$ROOT_API_KEY" ]; then
    echo "Root API key: ${COLOR_KEY}${ROOT_API_KEY}${COLOR_RESET}"
    echo "Save this key now; it will not be shown again."
  elif [ "$INIT_ALREADY" = "true" ]; then
    echo "Root API key not returned because the system was already initialized."
  fi
  if [ -n "$ROOT_USER_ID" ]; then
    echo "Root user ID: ${COLOR_ID}${ROOT_USER_ID}${COLOR_RESET}"
  fi
  if [ -z "$INIT_MESSAGE" ] && [ -z "$ROOT_API_KEY" ] && [ -z "$ROOT_USER_ID" ]; then
    echo "Init response: ${response}"
  fi
}

if [ "$SKIP_INIT" = false ]; then
  init_args=()
  if [ -n "$PROJECT_NAME" ]; then
    init_args+=(--name "$PROJECT_NAME")
  fi
  if [ -n "$WORKSPACE" ]; then
    init_args+=(--workspace "$WORKSPACE")
  fi
  run_with_tty railway init "${init_args[@]}"
fi

ensure_postgres_service
ref_user="\${{${POSTGRES_SERVICE}.POSTGRES_USER}}"
ref_password="\${{${POSTGRES_SERVICE}.POSTGRES_PASSWORD}}"
ref_url="jdbc:postgresql://\${{${POSTGRES_SERVICE}.RAILWAY_PRIVATE_DOMAIN}}:5432/\${{${POSTGRES_SERVICE}.POSTGRES_DB}}?sslmode=disable"
ensure_goodmem_service
railway variables --service "$GOODMEM_SERVICE" \
  --set "PORT=${REST_PORT}" \
  --set "GOODMEM_REST_TLS_ENABLED=false" \
  --set "GOODMEM_GRPC_TLS_ENABLED=true" \
  --set "GOODMEM_GRPC_PORT=${GRPC_PORT}" \
  --set "DB_USER=${ref_user}" \
  --set "DB_PASSWORD=${ref_password}" \
  --set "DB_URL=${ref_url}"

rest_domain=""
if [ "$SKIP_DOMAIN" = false ]; then
  rest_domain_output=""
  if rest_domain_output="$(railway domain --service "$GOODMEM_SERVICE" --port "$REST_PORT" 2>&1)"; then
    printf '%s\n' "$rest_domain_output"
    rest_domain="$(extract_domain "$rest_domain_output")"
  else
    printf '%s\n' "$rest_domain_output" >&2
    exit 1
  fi
fi

rest_line="not created (run: railway domain --service \"$GOODMEM_SERVICE\" --port $REST_PORT)"
if [ -n "$rest_domain" ]; then
  rest_line="https://$rest_domain (public 443 -> internal $REST_PORT)"
fi

grpc_line="TCP proxy required (see steps below)"
health_line="not available (requires a domain)"
if [ -n "$rest_domain" ]; then
  health_line="https://${rest_domain}/startupz"
fi

wait_for_ready

init_system_rest

cat <<EOF_MSG
Bootstrap complete.

Endpoints:
- REST: $rest_line
- gRPC (HTTP/2): $grpc_line
- Health: $health_line
- Public IP: Railway does not provide a fixed public IP for services; use the domain(s).

Next steps:
- Resource limits: Railway defaults to your plan's per-service caps (Free 0.5 GB RAM, Trial 1 GB, etc.).
  To match Fly defaults, set memory limits for ${GOODMEM_SERVICE} and ${POSTGRES_SERVICE} to
  ${GOODMEM_MEMORY_MB} MB and ${POSTGRES_MEMORY_MB} MB in the Railway UI (Service -> Settings -> Deploy -> Resource Limits).
- pgvector is bundled in the Postgres image and GoodMem will create the extension.
  If you want to verify manually, connect via the Postgres TCP proxy and run:
  CREATE EXTENSION IF NOT EXISTS vector;
- If the GoodMem service did not auto-deploy, trigger a deploy in the Railway UI.
EOF_MSG
cat <<EOF_MSG

Manual gRPC (TCP proxy) steps:
1) Open Railway dashboard -> Project -> Service "$GOODMEM_SERVICE".
2) Settings -> Public Networking -> Add TCP Proxy.
3) Set internal port ${GRPC_PORT} and save.
4) Use the assigned proxy domain:port for gRPC clients.
   Railway will also expose RAILWAY_TCP_PROXY_DOMAIN and RAILWAY_TCP_PROXY_PORT
   as runtime environment variables once the proxy exists.
EOF_MSG

if goodmem_cli_available; then
  cat <<'EOF_MSG'

GoodMem CLI (after TCP proxy exists):
1) Export the API key from the REST init step:
   export GOODMEM_API_KEY="<ROOT_API_KEY>"
2) Example command:
   goodmem --server https://<TCP_PROXY_DOMAIN>:<TCP_PROXY_PORT> user list

Notes:
- REST TLS is terminated by Railway; GoodMem REST runs plaintext behind it. gRPC TLS stays enabled by default.
- Use https:// (or no scheme) for gRPC unless you explicitly disable it.
- To force plaintext gRPC, set GOODMEM_GRPC_TLS_ENABLED=false or GOODMEM_TLS_DISABLED=true and use http://.
EOF_MSG
else
  cat <<'EOF_MSG'

GoodMem CLI (optional):
- goodmem CLI not found in PATH. Install it if you want to use CLI commands.
- Use the root API key from the REST init step with any client.
EOF_MSG
fi
