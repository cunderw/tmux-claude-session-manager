# tests/helper.bash
# shellcheck shell=bash

# Common bats setup. Source from each test's setup().
common_setup() {
  PLUGIN_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  STUBS="$PLUGIN_DIR/tests/stubs"
  FIXTURES="$PLUGIN_DIR/tests/fixtures"
  TMUX_TMPDIR="$BATS_TEST_TMPDIR"
  STUB_OUT="$BATS_TEST_TMPDIR/stub-calls.txt"
  : > "$STUB_OUT"
  export PLUGIN_DIR STUBS FIXTURES TMUX_TMPDIR STUB_OUT
  PATH="$STUBS:$PATH"
  export PATH
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/scripts/variables.sh"
  # shellcheck disable=SC1091
  source "$PLUGIN_DIR/scripts/helpers.sh"
}
