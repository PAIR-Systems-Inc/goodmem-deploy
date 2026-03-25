#!/usr/bin/env bash

setup_test_env() {
  export TEST_ROOT="$BATS_TEST_TMPDIR/test-root"
  export TEST_HOME="$TEST_ROOT/home"
  export TEST_BIN="$TEST_ROOT/bin"
  mkdir -p "$TEST_HOME" "$TEST_BIN"

  # Keep a minimal PATH so local developer tools do not accidentally satisfy
  # missing-dependency checks in the bootstrap scripts.
  export PATH="$TEST_BIN:/usr/bin:/bin"
}

write_test_bin() {
  local name="$1"
  local path="$TEST_BIN/$name"
  cat >"$path"
  chmod +x "$path"
}

extract_shell_function() {
  local script_path="$1"
  local function_name="$2"

  python3 - "$script_path" "$function_name" <<'PY'
import sys

script_path, function_name = sys.argv[1], sys.argv[2]
needle = f"{function_name}() {{"

with open(script_path, "r", encoding="utf-8") as fh:
    lines = fh.readlines()

start = None
for idx, line in enumerate(lines):
    if line.startswith(needle):
        start = idx
        break

if start is None:
    raise SystemExit(f"function not found: {function_name}")

depth = 0
captured = []
for line in lines[start:]:
    captured.append(line)
    depth += line.count("{")
    depth -= line.count("}")
    if depth == 0:
        break

sys.stdout.write("".join(captured))
PY
}
