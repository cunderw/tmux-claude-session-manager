#!/usr/bin/env bats

load ../helper.bash

setup() { common_setup; }

run_mapper() {
  local pids="$1" panes="$2" pstree="$3"
  echo "$pids" | "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes" "$pstree"
}

@test "single-hop resolution" {
  output="$(run_mapper "36951" "$FIXTURES/list_panes.txt" "$FIXTURES/ps_simple.txt")"
  [ "$output" = $'36951\t@1\t%17\tmain:@1.%17' ]
}

@test "multi-hop resolution" {
  output="$(run_mapper "36951" "$FIXTURES/list_panes.txt" "$FIXTURES/ps_nested.txt")"
  [ "$output" = $'36951\t@1\t%17\tmain:@1.%17' ]
}

@test "missing ancestor returns no output" {
  output="$(run_mapper "99999" "$FIXTURES/list_panes.txt" "$FIXTURES/ps_simple.txt")"
  [ -z "$output" ]
}

@test "batch resolves multiple pids in one invocation" {
  panes="$BATS_TEST_TMPDIR/panes.txt"
  pstree="$BATS_TEST_TMPDIR/ps.txt"
  cat > "$panes" <<EOF
200 main:@1.%17 /a
300 main:@2.%18 /b
EOF
  cat > "$pstree" <<EOF
200 1
300 1
36951 200
36952 300
EOF
  output="$(printf '36951\n36952\n' | \
    "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes" "$pstree" | sort)"
  expected=$'36951\t@1\t%17\tmain:@1.%17\n36952\t@2\t%18\tmain:@2.%18'
  [ "$output" = "$expected" ]
}

@test "recursion is capped (synthetic cycle)" {
  pstree="$BATS_TEST_TMPDIR/cycle.txt"
  # PID 1000 -> 1001 -> 1000 cycle. Should terminate, print nothing.
  cat > "$pstree" <<EOF
1000 1001
1001 1000
EOF
  panes="$BATS_TEST_TMPDIR/panes.txt"
  echo "9999 main:@1.%17 /x" > "$panes"
  output="$(echo "1000" | "$PLUGIN_DIR/scripts/map_pid_to_pane.sh" "$panes" "$pstree")"
  [ -z "$output" ]
}
