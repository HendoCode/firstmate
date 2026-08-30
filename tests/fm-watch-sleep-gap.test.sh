#!/usr/bin/env bash
# tests/fm-watch-sleep-gap.test.sh - watcher sleep/wake gap detection.
# The beacon is a wall-clock mtime, so a laptop sleep leaves it stale while the
# watcher process is still alive. These tests verify that a recorded sleep/wake
# suppresses the stale-beacon alarm, while a genuine crash or a hung watcher
# without such a record still reports down.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
GUARD="$ROOT/bin/fm-guard.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-sleep-gap-tests)

# Echo a fresh state directory under TMP_ROOT.
make_home() {
  local name=$1 dir state
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  mkdir -p "$state"
  printf '%s\n' "$state"
}

# Write a watcher lock that names <pid> with its identity and the test home.
write_lock() {
  local state=$1 home=$2 pid=$3 identity=$4
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
}

# Run fm_watcher_supervision_verdict in a clean subshell and echo <ok>:<reason>.
run_verdict() {
  local state=$1 home=$2
  FM_SUPERVISION_MODEL=persistent \
    FM_STATE_OVERRIDE="$state" \
    FM_HOME="$home" \
    bash -c '
      # shellcheck source=bin/fm-wake-lib.sh
      . "$1"
      fm_watcher_supervision_verdict "$2" "$3" 300 "$4" "$5"
      printf "%s:%s\n" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"
    ' _ "$LIB" "$state" "$WATCH" "$home" "$home"
}

# Run fm-guard.sh capturing stderr.
run_guard() {
  local state=$1 home=$2
  local err
  err="$home/guard.err"
  FM_SUPERVISION_MODEL=persistent \
    FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_HOME="$home" \
    FM_GUARD_GRACE=300 \
    "$GUARD" >/dev/null 2> "$err" || true
  printf '%s\n' "$err"
}

test_sleep_gap_suppresses_stale_beacon() {
  local state home pid identity err verdict
  state=$(make_home sleep-gap)
  home=${state%/state}
  sleep 1000 &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") || fail "could not compute watcher identity"
  write_lock "$state" "$home" "$pid" "$identity"
  touch -t 202001010000 "$state/.last-watcher-beat"
  touch "$state/.watcher-sleep-wake"
  printf 'project=x\n' > "$state/task.meta"

  verdict=$(run_verdict "$state" "$home")
  [ "$verdict" = "true:sleep-gap" ] || fail "expected true:sleep-gap, got $verdict"

  err=$(run_guard "$state" "$home")
  assert_not_contains "$(cat "$err")" "WATCHER DOWN - SUPERVISION IS OFF" \
    "guard raised a watcher-down alarm for a sleep gap"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "sleep gap with a live identity-matched watcher is suppressed"
}

test_killed_watcher_still_alarms() {
  local state home pid identity dead err verdict
  state=$(make_home killed-watcher)
  home=${state%/state}
  dead=$(dead_pid)
  write_lock "$state" "$home" "$dead" ""
  touch -t 202001010000 "$state/.last-watcher-beat"
  touch "$state/.watcher-sleep-wake"
  printf 'project=x\n' > "$state/task.meta"

  verdict=$(run_verdict "$state" "$home")
  [ "$verdict" = "false:stale-beacon" ] || fail "expected false:stale-beacon, got $verdict"

  err=$(run_guard "$state" "$home")
  assert_contains "$(cat "$err")" "WATCHER DOWN - SUPERVISION IS OFF" \
    "guard did not raise a watcher-down alarm for a killed watcher"
  pass "a killed watcher is still reported even with a recent sleep marker"
}

test_alive_watcher_without_marker_still_alarms() {
  local state home pid identity err verdict
  state=$(make_home alive-no-marker)
  home=${state%/state}
  sleep 1000 &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") || fail "could not compute watcher identity"
  write_lock "$state" "$home" "$pid" "$identity"
  touch -t 202001010000 "$state/.last-watcher-beat"
  rm -f "$state/.watcher-sleep-wake"
  printf 'project=x\n' > "$state/task.meta"

  verdict=$(run_verdict "$state" "$home")
  [ "$verdict" = "false:stale-beacon" ] || fail "expected false:stale-beacon, got $verdict"

  err=$(run_guard "$state" "$home")
  assert_contains "$(cat "$err")" "WATCHER DOWN - SUPERVISION IS OFF" \
    "guard did not raise a watcher-down alarm for a hung watcher without sleep marker"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "a live watcher with a stale beacon and no sleep marker still alarms"
}

test_sleep_tick_records_wake_after_suspension() {
  local state wall
  state=$(make_home tick-suspension)
  wall=$(date +%s)
  # Simulate a poll that went to sleep: wall time advanced by 100s but the
  # watcher's $SECONDS value did not (negative delta is clamped to 0).
  printf '%s %s\n' "$((wall - 100))" "999999" > "$state/.watcher-sleep-check"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_watcher_sleep_tick "$2"
  ' _ "$LIB" "$state"
  [ -f "$state/.watcher-sleep-wake" ] || fail "sleep tick did not record a wake"
  pass "sleep tick records a wake when wall time advances far beyond \$SECONDS"
}

test_sleep_tick_does_not_record_wake_on_normal_poll() {
  local state
  state=$(make_home tick-normal)
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_watcher_sleep_tick "$2"
    fm_watcher_sleep_tick "$2"
  ' _ "$LIB" "$state"
  [ ! -e "$state/.watcher-sleep-wake" ] || fail "sleep tick falsely recorded a wake on a normal poll"
  pass "sleep tick does not record a wake on a normal poll"
}

test_record_sleep_wake_writes_marker() {
  local state
  state=$(make_home record-wake)
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck source=bin/fm-wake-lib.sh
    . "$1"
    fm_watcher_record_sleep_wake "$2"
  ' _ "$LIB" "$state"
  [ -f "$state/.watcher-sleep-wake" ] || fail "record_sleep_wake did not create marker"
  pass "record_sleep_wake creates the sleep/wake marker"
}

test_sleep_gap_marker_must_be_newer_than_beacon() {
  local state home pid identity verdict
  state=$(make_home stale-marker)
  home=${state%/state}
  sleep 1000 &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") || fail "could not compute watcher identity"
  write_lock "$state" "$home" "$pid" "$identity"
  touch -t 202001010000 "$state/.last-watcher-beat"
  # Marker older than the beacon must not suppress the alarm.
  touch -t 199001010000 "$state/.watcher-sleep-wake"

  verdict=$(run_verdict "$state" "$home")
  [ "$verdict" = "false:stale-beacon" ] || fail "expected false:stale-beacon, got $verdict"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "an old sleep marker older than the beacon does not suppress the alarm"
}

test_sleep_gap_suppresses_stale_beacon
test_killed_watcher_still_alarms
test_alive_watcher_without_marker_still_alarms
test_sleep_tick_records_wake_after_suspension
test_sleep_tick_does_not_record_wake_on_normal_poll
test_record_sleep_wake_writes_marker
test_sleep_gap_marker_must_be_newer_than_beacon
