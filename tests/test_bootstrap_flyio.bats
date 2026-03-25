#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_test_env
}

@test "bootstrap_flyio.sh shows correct retry syntax when flyctl is missing" {
  run env -i HOME="$TEST_HOME" PATH="$PATH" bash "$BATS_TEST_DIRNAME/../scripts/bootstrap_flyio.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"flyctl not found. Install it first:"* ]]
  [[ "$output" == *"curl -s https://get.goodmem.ai/flyio | bash -s -- --install-cli"* ]]
  [[ "$output" == *"scripts/bootstrap_flyio.sh --install-cli"* ]]
}

@test "bootstrap_flyio.sh defaults tier safely when /dev/tty cannot be read" {
  write_test_bin flyctl <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
  "auth whoami")
    exit 0
    ;;
  "orgs list")
    printf '%s\n' '[{"slug":"test-org","name":"Test Org","type":"personal"}]'
    exit 0
    ;;
  "status --app")
    exit 1
    ;;
  *)
    echo "stubbed flyctl: $*" >&2
    exit 1
    ;;
esac
EOF

  write_test_bin jq <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'test-org\tTest Org\tpersonal\n'
EOF

  run env -i HOME="$TEST_HOME" PATH="$PATH" bash "$BATS_TEST_DIRNAME/../scripts/bootstrap_flyio.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Using only available Fly org \"test-org\"."* ]]
  [[ "$output" == *"No TTY detected; defaulting instance tier to small."* ]]
  [[ "$output" != *"/dev/tty: No such device"* ]]
}
