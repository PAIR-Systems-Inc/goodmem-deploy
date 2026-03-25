#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_test_env
}

@test "bootstrap_lightsail.sh defaults tier safely when /dev/tty cannot be read" {
  write_test_bin aws <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stubbed aws: $*" >&2
exit 1
EOF

  run env -i HOME="$TEST_HOME" PATH="$PATH" bash "$BATS_TEST_DIRNAME/../scripts/bootstrap_lightsail.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"No TTY detected; defaulting Lightsail tier to small"* ]]
  [[ "$output" != *"/dev/tty: No such device"* ]]
}

@test "bootstrap_lightsail.sh run_ssh uses ssh -n so installer stdin is preserved" {
  write_test_bin ssh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

has_stdin_guard=0
for arg in "$@"; do
  if [ "$arg" = "-n" ]; then
    has_stdin_guard=1
    break
  fi
done

if [ "$has_stdin_guard" -eq 0 ]; then
  cat >/dev/null
fi

printf 'stubbed ssh args: %s\n' "$*" >&2
exit 0
EOF

  local function_body
  function_body="$(extract_shell_function "$BATS_TEST_DIRNAME/../scripts/bootstrap_lightsail.sh" run_ssh)"

  local piped_script="$BATS_TEST_TMPDIR/run-ssh-stdin.sh"
  cat >"$piped_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SSH_KEY_FILE="/tmp/test-key"
SSH_CERT_FILE=""
SSH_USERNAME="ubuntu"
INSTANCE_IP="127.0.0.1"
${function_body}
printf 'before\n'
run_ssh "echo ok"
printf 'after\n'
EOF

  run bash -c 'env -i PATH="$1" bash <"$2"' _ "$PATH" "$piped_script"

  [ "$status" -eq 0 ]
  [[ "$output" == *"before"* ]]
  [[ "$output" == *"after"* ]]
  [[ "$output" == *"stubbed ssh args:"* ]]
}
