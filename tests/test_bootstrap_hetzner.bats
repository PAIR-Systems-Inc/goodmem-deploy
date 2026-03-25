#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_test_env
}

@test "bootstrap_hetzner.sh prompt_tier defaults to large without /dev/tty errors" {
  local market_for_location_fn
  local tier_summary_fn
  local apply_tier_defaults_fn
  local tty_available_fn
  local prompt_tier_fn

  market_for_location_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" market_for_location)"
  tier_summary_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" tier_summary)"
  apply_tier_defaults_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" apply_tier_defaults)"
  tty_available_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" tty_available)"
  prompt_tier_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" prompt_tier)"

  run env -i HOME="$TEST_HOME" PATH="$PATH" bash -c '
    set -euo pipefail
    LOCATION="hil"
    SIZE_TIER=""
    TIER_SET=false
    SERVER_TYPE=""
    SERVER_TYPE_SET=false
    log() { printf "[INFO] %s\n" "$*"; }
    '"$market_for_location_fn"'
    '"$tier_summary_fn"'
    '"$apply_tier_defaults_fn"'
    '"$tty_available_fn"'
    '"$prompt_tier_fn"'
    prompt_tier
    printf "SIZE_TIER=%s\nSERVER_TYPE=%s\n" "$SIZE_TIER" "$SERVER_TYPE"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"defaulting Hetzner tier to large"* ]]
  [[ "$output" == *"SIZE_TIER=large"* ]]
  [[ "$output" == *"SERVER_TYPE=cpx41"* ]]
  [[ "$output" != *"/dev/tty: No such device"* ]]
}

@test "bootstrap_hetzner.sh finalizes sslip domain when no domain is provided" {
  local sslip_domain_for_ip_fn
  local finalize_public_domain_fn

  sslip_domain_for_ip_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" sslip_domain_for_ip)"
  finalize_public_domain_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" finalize_public_domain)"

  run env -i HOME="$TEST_HOME" PATH="$PATH" bash -c '
    set -euo pipefail
    DOMAIN=""
    AUTO_SSLIP_DOMAIN=false
    DNS_MODE_USED="none"
    INSTANCE_IP="5.78.115.128"
    '"$sslip_domain_for_ip_fn"'
    '"$finalize_public_domain_fn"'
    finalize_public_domain
    printf "DOMAIN=%s\nAUTO_SSLIP_DOMAIN=%s\nDNS_MODE_USED=%s\n" "$DOMAIN" "$AUTO_SSLIP_DOMAIN" "$DNS_MODE_USED"
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"DOMAIN=5-78-115-128.sslip.io"* ]]
  [[ "$output" == *"AUTO_SSLIP_DOMAIN=true"* ]]
  [[ "$output" == *"DNS_MODE_USED=sslip"* ]]
}

@test "bootstrap_hetzner.sh ensure_firewall suppresses noisy hcloud wait output" {
  local run_hcloud_quiet_fn
  local ensure_firewall_fn

  write_test_bin hcloud <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Waiting for set_firewall_rules..." >&2
echo "done" >&2
exit 0
EOF

  run_hcloud_quiet_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" run_hcloud_quiet)"
  ensure_firewall_fn="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" ensure_firewall)"

  run env -i HOME="$TEST_HOME" PATH="$PATH" bash -c '
    set -euo pipefail
    HCLOUD_BIN="hcloud"
    FIREWALL_NAME="gm-hetzner-test-fw"
    ACCESS_CIDR="203.0.113.10/32"
    PUBLIC_GRPC_PORT=50051
    firewall_exists() { return 1; }
    log() { printf "[INFO] %s\n" "$*"; }
    '"$run_hcloud_quiet_fn"'
    '"$ensure_firewall_fn"'
    ensure_firewall
  '

  [ "$status" -eq 0 ]
  [[ "$output" == *"Creating firewall gm-hetzner-test-fw"* ]]
  [[ "$output" == *"Firewall gm-hetzner-test-fw configured."* ]]
  [[ "$output" != *"Waiting for set_firewall_rules"* ]]
}

@test "bootstrap_hetzner.sh list output includes tier and management commands" {
  mkdir -p "$TEST_HOME/.goodmem/hetzner-state"
  cat >"$TEST_HOME/.goodmem/hetzner-state/gm-hetzner-demo.json" <<'EOF'
{
  "deployment_name": "gm-hetzner-demo",
  "location": "hil",
  "size_tier": "large",
  "server_type": "cpx41",
  "server_name": "gm-hetzner-demo",
  "server_ip": "5.78.115.128",
  "volume_name": "gm-hetzner-demo-pgdata",
  "domain": "5-78-115-128.sslip.io"
}
EOF

  run env -i HOME="$TEST_HOME" PATH="$PATH" bash "$BATS_TEST_DIRNAME/../scripts/bootstrap_hetzner.sh" --list

  [ "$status" -eq 0 ]
  [[ "$output" == *"Tier:       large ("* ]]
  [[ "$output" == *"Domain:     5-78-115-128.sslip.io"* ]]
  [[ "$output" == *"Re-run:     ./scripts/bootstrap_hetzner.sh --name gm-hetzner-demo"* ]]
  [[ "$output" == *"Destroy:    ./scripts/bootstrap_hetzner.sh --destroy --name gm-hetzner-demo --delete-volume --yes"* ]]
}
