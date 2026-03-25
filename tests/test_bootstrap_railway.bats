#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_test_env
}

@test "bootstrap_railway.sh shows correct retry syntax when railway CLI is missing" {
  run env -i HOME="$TEST_HOME" PATH="$PATH" bash "$BATS_TEST_DIRNAME/../scripts/bootstrap_railway.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"railway CLI not found. Install it first:"* ]]
  [[ "$output" == *"curl -s https://get.goodmem.ai/railway | bash -s -- --install-cli"* ]]
  [[ "$output" == *"scripts/bootstrap_railway.sh --install-cli"* ]]
}

@test "bootstrap_railway.sh reports no TTY cleanly when login is required" {
  write_test_bin railway <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  whoami)
    exit 1
    ;;
  login)
    echo "unexpected login attempt" >&2
    exit 0
    ;;
  *)
    echo "stubbed railway: $*" >&2
    exit 1
    ;;
esac
EOF

  run env -i HOME="$TEST_HOME" PATH="$PATH" bash "$BATS_TEST_DIRNAME/../scripts/bootstrap_railway.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Not logged in to Railway and no TTY available."* ]]
  [[ "$output" == *"Run 'railway login' interactively or set RAILWAY_API_TOKEN."* ]]
  [[ "$output" != *"/dev/tty: No such device"* ]]
  [[ "$output" != *"unexpected login attempt"* ]]
}
