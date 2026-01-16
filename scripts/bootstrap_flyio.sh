#!/usr/bin/env bash
set -euo pipefail
trap 'echo "Error: command failed at line $LINENO: $BASH_COMMAND" >&2' ERR

GOODMEM_APP=""
POSTGRES_APP=""
GOODMEM_APP_SET=false
POSTGRES_APP_SET=false
ORG=""
REGION="sjc"
POSTGRES_USER="postgres"
POSTGRES_DB="goodmem"
POSTGRES_PASSWORD=""
POSTGRES_VOLUME="pg_data"
POSTGRES_VOLUME_SIZE=10
POSTGRES_DATA_DIR="/var/lib/postgresql/data/pgdata"
GOODMEM_MEMORY_MB=1024
GOODMEM_GRPC_TLS_ENABLED=false
WAIT_FOR_GRPC=true
GRPC_WAIT_TIMEOUT=120
GRPC_WAIT_INTERVAL=5
IMAGE="ghcr.io/pair-systems-inc/goodmem/server:latest"
POSTGRES_IMAGE="pgvector/pgvector:pg17"
REST_PORT=8080
GRPC_PORT=50051
INSTALL_CLI=false

usage() {
  cat <<'USAGE'
Usage: ./scripts/bootstrap_flyio.sh [options]

Options:
  --app-name NAME           GoodMem app name (default: random <adj>-<noun>-goodmem)
  --postgres-app NAME       Postgres app name (default: <app-name>-postgres)
  --org NAME|ID             Fly organization slug
  --region CODE             Fly region (default: sjc)
  --postgres-user NAME      Postgres user (default: postgres)
  --postgres-db NAME        Postgres database (default: goodmem)
  --postgres-password PASS  Postgres password (generated if not set)
  --postgres-volume NAME    Postgres volume name (default: pg_data)
  --postgres-volume-size GB Postgres volume size in GB (default: 10)
  --goodmem-memory MB       GoodMem VM memory in MB (default: 1024)
  --no-wait                 Skip waiting for readiness (/startupz or gRPC)
  --wait-timeout SECONDS    Readiness wait timeout (default: 120)
  --image IMAGE             GoodMem image (default: ghcr.io/pair-systems-inc/goodmem/server:latest)
  --postgres-image IMAGE    Postgres image (default: pgvector/pgvector:pg17)
  --install-cli             Install Fly CLI if missing
  -h, --help                Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      GOODMEM_APP="$2"
      GOODMEM_APP_SET=true
      shift 2
      ;;
    --postgres-app)
      POSTGRES_APP="$2"
      POSTGRES_APP_SET=true
      shift 2
      ;;
    --org)
      ORG="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
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
    --postgres-password)
      POSTGRES_PASSWORD="$2"
      shift 2
      ;;
    --postgres-volume)
      POSTGRES_VOLUME="$2"
      shift 2
      ;;
    --postgres-volume-size)
      POSTGRES_VOLUME_SIZE="$2"
      shift 2
      ;;
    --goodmem-memory)
      GOODMEM_MEMORY_MB="$2"
      shift 2
      ;;
    --no-wait)
      WAIT_FOR_GRPC=false
      shift
      ;;
    --wait-timeout)
      GRPC_WAIT_TIMEOUT="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --postgres-image)
      POSTGRES_IMAGE="$2"
      shift 2
      ;;
    --install-cli)
      INSTALL_CLI=true
      shift
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

FLYCTL_BIN="${FLYCTL_BIN:-flyctl}"
JQ_BIN="${JQ_BIN:-jq}"

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

ensure_app_names() {
  if [ "$GOODMEM_APP_SET" = false ] && [ "$POSTGRES_APP_SET" = false ]; then
    local prefix
    prefix="$(random_name_prefix)"
    GOODMEM_APP="${prefix}-goodmem"
    POSTGRES_APP="${GOODMEM_APP}-postgres"
    echo "Using generated app names: GoodMem \"$GOODMEM_APP\", Postgres \"$POSTGRES_APP\"."
    return
  fi

  if [ "$GOODMEM_APP_SET" = true ] && [ "$POSTGRES_APP_SET" = false ]; then
    POSTGRES_APP="${GOODMEM_APP}-postgres"
    echo "Using Postgres app name \"$POSTGRES_APP\" derived from GoodMem app."
    return
  fi

  if [ "$GOODMEM_APP_SET" = false ] && [ "$POSTGRES_APP_SET" = true ]; then
    local prefix
    prefix="$(random_name_prefix)"
    GOODMEM_APP="${prefix}-goodmem"
    echo "Using generated GoodMem app name \"$GOODMEM_APP\"."
  fi
}

resolve_flyctl() {
  if command -v "$FLYCTL_BIN" >/dev/null 2>&1; then
    return
  fi
  if [ -x "$HOME/.fly/bin/flyctl" ]; then
    FLYCTL_BIN="$HOME/.fly/bin/flyctl"
    return
  fi
}

ensure_jq() {
  if command -v "$JQ_BIN" >/dev/null 2>&1; then
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "jq not found and curl is unavailable to download it." >&2
    exit 1
  fi

  local os
  local arch
  os="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m 2>/dev/null)"

  case "$os" in
    linux) ;;
    darwin) os="osx" ;;
    *) echo "Unsupported OS for jq install: ${os:-unknown}" >&2; exit 1 ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Unsupported architecture for jq install: ${arch:-unknown}" >&2; exit 1 ;;
  esac

  local jq_url="https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-${os}-${arch}"
  JQ_BIN="$(mktemp -t goodmem-jq-XXXXXX)"
  echo "Downloading jq (${os}/${arch})..."
  curl -fsSL "$jq_url" -o "$JQ_BIN"
  chmod +x "$JQ_BIN"
}

ensure_cli() {
  resolve_flyctl
  if command -v "$FLYCTL_BIN" >/dev/null 2>&1; then
    return
  fi

  if [ "$INSTALL_CLI" = true ]; then
    if command -v curl >/dev/null 2>&1; then
      echo "Installing Fly CLI..."
      curl -fsSL https://fly.io/install.sh | sh
      resolve_flyctl
    else
      echo "curl is required to install the Fly CLI automatically." >&2
      exit 1
    fi
  else
    echo "flyctl not found. Install it first: https://fly.io/docs/flyctl/install/" >&2
    echo "Tip: re-run with --install-cli to auto-install." >&2
    exit 1
  fi

  if ! command -v "$FLYCTL_BIN" >/dev/null 2>&1; then
    echo "Fly CLI install did not complete successfully." >&2
    exit 1
  fi
}

ensure_login() {
  if [ -n "${FLY_API_TOKEN:-}" ] || [ -n "${FLY_ACCESS_TOKEN:-}" ]; then
    return
  fi

  if "$FLYCTL_BIN" auth whoami >/dev/null 2>&1; then
    return
  fi

  if [ -t 0 ]; then
    "$FLYCTL_BIN" auth login
  else
    echo "Not logged in to Fly and no TTY available." >&2
    echo "Run 'flyctl auth login' interactively or set FLY_API_TOKEN." >&2
    exit 1
  fi

  if ! "$FLYCTL_BIN" auth whoami >/dev/null 2>&1; then
    echo "Fly login did not complete successfully." >&2
    exit 1
  fi
}

prompt_org_slug() {
  local choice=""
  local prompt="Enter Fly org slug to use for app creation: "
  if [ -t 0 ]; then
    while [ -z "$choice" ]; do
      read -r -p "$prompt" choice
    done
  elif [ -r /dev/tty ]; then
    while [ -z "$choice" ]; do
      read -r -p "$prompt" choice </dev/tty
    done
  else
    echo "Fly org must be specified when not running interactively." >&2
    echo "Re-run with --org <slug> or set FLY_ORG." >&2
    exit 1
  fi
  ORG="$choice"
  echo "Using Fly org \"$ORG\"."
}

ensure_org() {
  if [ -n "$ORG" ]; then
    return
  fi
  if [ -n "${FLY_ORG:-}" ]; then
    ORG="$FLY_ORG"
    echo "Using Fly org from FLY_ORG: \"$ORG\"."
    return
  fi
  if [ -n "${FLY_ORG_SLUG:-}" ]; then
    ORG="$FLY_ORG_SLUG"
    echo "Using Fly org from FLY_ORG_SLUG: \"$ORG\"."
    return
  fi

  local -a org_lines=()
  local orgs_parsed=""
  if ! orgs_parsed="$("$FLYCTL_BIN" orgs list --json 2>/dev/null | "$JQ_BIN" -r 'def emit(s;n;t): if s==null then empty else "\(s)\t\((n//"")|tostring)\t\((t//"")|tostring)" end; if type=="array" then .[]|select(type=="object")|emit(.slug;.name;.type) elif type=="object" then if (to_entries|all(.value|type=="string" or type=="null")) then to_entries[]|emit(.key;.value;null) elif has("slug") then emit(.slug;.name;.type) else empty end else empty end' 2>/dev/null)"; then
    prompt_org_slug
    return
  fi
  if [ -z "$orgs_parsed" ]; then
    prompt_org_slug
    return
  fi
  mapfile -t org_lines <<< "$orgs_parsed"

  if [ "${#org_lines[@]}" -eq 0 ]; then
    prompt_org_slug
    return
  fi

  local -a org_slugs=()
  local -a org_labels=()
  local line=""
  local slug=""
  local name=""
  local org_type=""
  local label=""

  for line in "${org_lines[@]}"; do
    slug=""
    name=""
    org_type=""
    label=""
    IFS=$'\t' read -r slug name org_type <<< "$line"
    if [ -z "$slug" ]; then
      slug="$line"
    fi
    if [ -z "$slug" ]; then
      continue
    fi
    label="$slug"
    if [ -n "$name" ] && [ "$name" != "$slug" ]; then
      label="${label} (${name})"
    fi
    if [ -n "$org_type" ]; then
      label="${label} [${org_type}]"
    fi
    org_slugs+=("$slug")
    org_labels+=("$label")
  done

  if [ "${#org_slugs[@]}" -eq 1 ]; then
    ORG="${org_slugs[0]}"
    echo "Using only available Fly org \"$ORG\"."
    return
  fi

  local tty_input=""
  if [ -t 0 ]; then
    tty_input=""
  elif [ -r /dev/tty ]; then
    tty_input="/dev/tty"
  else
    echo "Multiple Fly orgs detected but no --org was provided." >&2
    echo "Re-run with --org <slug> or set FLY_ORG." >&2
    exit 1
  fi

  echo "Multiple Fly orgs detected. Select one for app creation:"
  local i=0
  for label in "${org_labels[@]}"; do
    i=$((i + 1))
    echo "  ${i}) ${label}"
  done

  local choice=""
  while true; do
    if [ -n "$tty_input" ]; then
      read -r -p "Enter selection (1-${#org_slugs[@]}) or slug: " choice <"$tty_input"
    else
      read -r -p "Enter selection (1-${#org_slugs[@]}) or slug: " choice
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if (( choice >= 1 && choice <= ${#org_slugs[@]} )); then
        ORG="${org_slugs[choice - 1]}"
        break
      fi
    else
      local matched="0"
      for slug in "${org_slugs[@]}"; do
        if [ "$choice" = "$slug" ]; then
          ORG="$slug"
          matched="1"
          break
        fi
      done
      if [ "$matched" = "1" ]; then
        break
      fi
    fi
    echo "Invalid selection."
  done

  echo "Using Fly org \"$ORG\"."
  return
}

app_exists() {
  local app="$1"
  "$FLYCTL_BIN" status --app "$app" >/dev/null 2>&1
}

ensure_public_ips() {
  local app="$1"
  local has_ips="0"
  local ips_json=""
  local attempt=""

  for attempt in 1 2 3 4 5 6; do
    if ips_json="$("$FLYCTL_BIN" ips list --app "$app" --json 2>/dev/null)"; then
      break
    fi
    sleep 2
  done

  if [ -n "$ips_json" ]; then
    if command -v python3 >/dev/null 2>&1; then
      has_ips="$(printf '%s' "$ips_json" | python3 - <<'PY'
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("0")
    sys.exit(0)

print("1" if data else "0")
PY
)"
    else
      if printf '%s' "$ips_json" | grep -q '"address"'; then
        has_ips="1"
      fi
    fi
  fi

  if [ "$has_ips" = "1" ]; then
    return
  fi

  echo "Allocating shared IPv4 and IPv6 for \"$app\"..."
  local v4_ok="0"
  local v6_ok="0"

  for attempt in 1 2 3; do
    if "$FLYCTL_BIN" ips allocate-v4 --app "$app" --shared --yes; then
      v4_ok="1"
      break
    fi
    sleep 2
  done

  for attempt in 1 2 3; do
    if "$FLYCTL_BIN" ips allocate-v6 --app "$app"; then
      v6_ok="1"
      break
    fi
    sleep 2
  done

  if [ "$v4_ok" = "0" ] && [ "$v6_ok" = "0" ]; then
    echo "Error: failed to allocate public IPs for \"$app\"; aborting to avoid dedicated IP prompts." >&2
    exit 1
  fi
  if [ "$v4_ok" = "0" ] || [ "$v6_ok" = "0" ]; then
    echo "Warning: allocated only one public IP for \"$app\" (v4=${v4_ok}, v6=${v6_ok})." >&2
  fi
}

volume_exists() {
  local app="$1"
  local volume="$2"
  "$FLYCTL_BIN" volumes list --app "$app" --json 2>/dev/null | grep -q "\"name\":\"${volume}\""
}

goodmem_cli_available() {
  command -v goodmem >/dev/null 2>&1
}

wait_for_grpc() {
  if [ "$WAIT_FOR_GRPC" = false ]; then
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not found; skipping readiness wait."
    return
  fi
  local health_url="https://${GOODMEM_APP}.fly.dev/startupz"
  local grpc_url="https://${GOODMEM_APP}.fly.dev:${GRPC_PORT}/"
  local deadline=$((SECONDS + GRPC_WAIT_TIMEOUT))
  local can_http2="0"

  if curl --version 2>/dev/null | grep -qi "HTTP2"; then
    can_http2="1"
  fi

  echo "Waiting for GoodMem readiness (this can take a minute on first boot)..."
  while (( SECONDS < deadline )); do
    local health=""
    health="$(curl -sk --max-time 5 "$health_url" 2>/dev/null || true)"
    if printf '%s' "$health" | grep -q '"state":"READY"'; then
      echo "GoodMem reported READY via /startupz."
      return
    fi
    if printf '%s' "$health" | grep -q '"started":true'; then
      echo "GoodMem reported started via /startupz."
      return
    fi
    if [ "$can_http2" = "1" ]; then
      local code=""
      code="$(curl -sk --http2 --max-time 5 -o /dev/null -w '%{http_code}' "$grpc_url" || true)"
      if [ "$code" = "415" ]; then
        echo "gRPC endpoint is responding."
        return
      fi
    fi
    sleep "$GRPC_WAIT_INTERVAL"
  done

  echo "Warning: readiness did not respond within ${GRPC_WAIT_TIMEOUT}s. It may still be starting."
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

ensure_postgres_app() {
  if app_exists "$POSTGRES_APP"; then
    return
  fi

  echo "Creating Postgres app \"$POSTGRES_APP\"..."
  local -a org_args=()
  if [ -n "$ORG" ]; then
    org_args+=(--org "$ORG")
  fi
  "$FLYCTL_BIN" apps create "$POSTGRES_APP" "${org_args[@]}" --yes

  if [ -z "$POSTGRES_PASSWORD" ]; then
    POSTGRES_PASSWORD="$(generate_password)"
  fi

  if ! volume_exists "$POSTGRES_APP" "$POSTGRES_VOLUME"; then
    "$FLYCTL_BIN" volumes create "$POSTGRES_VOLUME" \
      --app "$POSTGRES_APP" \
      --size "$POSTGRES_VOLUME_SIZE" \
      --region "$REGION" \
      --yes
  fi

  "$FLYCTL_BIN" secrets set --app "$POSTGRES_APP" \
    "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}"

  postgres_config="$(mktemp -t goodmem-postgres-XXXX.toml)"
  cat >"$postgres_config" <<EOF
app = "$POSTGRES_APP"
primary_region = "$REGION"

[build]
  image = "$POSTGRES_IMAGE"

[env]
  POSTGRES_USER = "$POSTGRES_USER"
  POSTGRES_DB = "$POSTGRES_DB"
  PGDATA = "$POSTGRES_DATA_DIR"

[[mounts]]
  source = "$POSTGRES_VOLUME"
  destination = "/var/lib/postgresql/data"

[[services]]
  internal_port = 5432
  protocol = "tcp"
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 1
  processes = ["app"]

  [services.concurrency]
    type = "connections"
    hard_limit = 50
    soft_limit = 40
EOF

  "$FLYCTL_BIN" deploy --app "$POSTGRES_APP" --config "$postgres_config" --now
}

ensure_goodmem_app() {
  if [ -z "$POSTGRES_PASSWORD" ]; then
    echo "Postgres password is required to configure GoodMem." >&2
    echo "Provide --postgres-password if you are reusing an existing Postgres app." >&2
    exit 1
  fi

  if ! app_exists "$GOODMEM_APP"; then
    echo "Creating GoodMem app \"$GOODMEM_APP\"..."
    local -a org_args=()
    if [ -n "$ORG" ]; then
      org_args+=(--org "$ORG")
    fi
    "$FLYCTL_BIN" apps create "$GOODMEM_APP" "${org_args[@]}" --yes
  fi

  ensure_public_ips "$GOODMEM_APP"

  goodmem_config="$(mktemp -t goodmem-app-XXXX.toml)"
  local primary_region_line=""
  if [ -n "$REGION" ]; then
    primary_region_line="primary_region = \"${REGION}\""
  fi

  db_url="jdbc:postgresql://${POSTGRES_APP}.internal:5432/${POSTGRES_DB}?sslmode=disable"

  cat >"$goodmem_config" <<EOF
app = "$GOODMEM_APP"
${primary_region_line}

[build]
  image = "$IMAGE"

[env]
  PORT = "${REST_PORT}"
  GOODMEM_REST_TLS_ENABLED = "false"
  GOODMEM_GRPC_TLS_ENABLED = "${GOODMEM_GRPC_TLS_ENABLED}"
  GOODMEM_GRPC_PORT = "${GRPC_PORT}"
  DB_URL = "${db_url}"

[[services]]
  internal_port = ${REST_PORT}
  protocol = "tcp"
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0
  processes = ["app"]

  [[services.ports]]
    port = 80
    handlers = ["http"]

  [[services.ports]]
    port = 443
    handlers = ["tls", "http"]

[[services]]
  internal_port = ${GRPC_PORT}
  protocol = "tcp"
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0
  processes = ["app"]

  [[services.ports]]
    port = ${GRPC_PORT}
    handlers = ["tls"]
    tls_options = { "alpn" = ["h2"] }
EOF

  "$FLYCTL_BIN" secrets set --app "$GOODMEM_APP" \
    "DB_USER=${POSTGRES_USER}" \
    "DB_PASSWORD=${POSTGRES_PASSWORD}"

  "$FLYCTL_BIN" deploy --app "$GOODMEM_APP" --config "$goodmem_config" --now --yes \
    --vm-memory "$GOODMEM_MEMORY_MB"
}

cleanup() {
  if [ -n "${postgres_config:-}" ]; then
    rm -f "$postgres_config"
  fi
  if [ -n "${goodmem_config:-}" ]; then
    rm -f "$goodmem_config"
  fi
}

trap cleanup EXIT

ensure_cli
ensure_login
ensure_jq
ensure_org
ensure_app_names
ensure_postgres_app
ensure_goodmem_app
wait_for_grpc

rest_domain="https://${GOODMEM_APP}.fly.dev"
grpc_domain="${GOODMEM_APP}.fly.dev:${GRPC_PORT}"
postgres_internal="${POSTGRES_APP}.internal:5432"
health_endpoint="${rest_domain}/startupz"

cat <<EOF_MSG
Bootstrap complete.

Endpoints:
- REST: ${rest_domain} (public 443 -> internal ${REST_PORT})
- gRPC (HTTP/2): ${grpc_domain} (TLS terminated by Fly, h2c to app)
- Postgres (internal): ${postgres_internal}
- Health: ${health_endpoint}
EOF_MSG

if goodmem_cli_available; then
  cat <<EOF_MSG

GoodMem CLI (after gRPC is reachable):
1) Initialize GoodMem (creates root user + master API key):
   goodmem init --server https://${GOODMEM_APP}.fly.dev:${GRPC_PORT} --save-config=false
2) Export the API key for future calls:
   export GOODMEM_API_KEY="<API_KEY_FROM_INIT>"
3) Example command:
   goodmem --server https://${GOODMEM_APP}.fly.dev:${GRPC_PORT} user list

Notes:
- Use https:// for gRPC when connecting via the Fly domain.
- goodmem init saves config to ~/.goodmem/config.json by default; --save-config=false avoids overwriting existing config.
EOF_MSG
else
  cat <<EOF_MSG

GoodMem CLI (after gRPC is reachable):
- goodmem CLI not found in PATH. Install it, then run:
  goodmem init --server https://${GOODMEM_APP}.fly.dev:${GRPC_PORT} --save-config=false
- This first call creates the root user and master API key.
EOF_MSG
fi
