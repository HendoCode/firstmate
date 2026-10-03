#!/usr/bin/env bash
# Behavior tests for the primary marathon session reminder process-event
# adapter (bin/fm-procevent-primary-marathon.sh).
#
# The adapter watches the primary session and emits a durable reminder wake
# when it exceeds a turn or age threshold. It must keep emitting reminders
# while the session remains over threshold; it must never fire below threshold;
# and it must never restart or terminate the session itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-primary-marathon-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

MARATHON() { FM_HOME="$1" "$ROOT/bin/fm-procevent-primary-marathon.sh" "${@:2}"; }
PE() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

new_home() {
  local home=$1
  mkdir -p "$home/state"
  fm_test_track_procevent_home "$home"
}

# Create a fake session file with the given assistant-turn count and mtime age.
make_session() {  # <home> <file> <assistant-turns> <age-seconds>
  local home=$1 file=$2 turns=$3 age=$4 dir session_path target_epoch now
  dir="$home/sessions"
  session_path="$dir/$file"
  mkdir -p "$dir"
  rm -f -- "$session_path"
  : > "$session_path"
  while [ "$turns" -gt 0 ]; do
    printf '{"role":"assistant","content":"turn %d"}\n' "$turns" >> "$session_path"
    turns=$((turns - 1))
  done
  now=$(date +%s)
  target_epoch=$((now - age))
  if touch -d "@$target_epoch" "$session_path" 2>/dev/null; then
    :
  elif touch -t "$(date -r "$target_epoch" +%Y%m%d%H%M.%S 2>/dev/null)" "$session_path" 2>/dev/null; then
    :
  else
    # Final fallback: perl portable touch.
    perl -e '
      use strict;
      use warnings;
      my ($path, $epoch) = @ARGV;
      utime $epoch, $epoch, $path or die "utime failed: $!";
    ' "$session_path" "$target_epoch"
  fi
}

# Result file helpers.
first_result() {  # <home>
  for g in "$home/state/procevent-inbox/primary-marathon".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

wait_for_result() {  # <home> [tries]
  local n=${2:-150}
  for _ in $(seq 1 "$n"); do
    first_result "$1" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_for_n_results() {  # <home> <n> [tries]
  local home=$1 want=$2 n=${3:-150} count
  for _ in $(seq 1 "$n"); do
    count=$(find "$home/state/procevent-inbox" -name 'primary-marathon.*.result' -type f 2>/dev/null | grep -c . || true)
    [ "$count" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

# --- adapter contract helpers ----------------------------------------------

test_source_id_and_relisten() {
  local home
  home="$TMP_ROOT/h-contract"
  new_home "$home"
  out=$(MARATHON "$home" source-id)
  [ "$out" = primary-marathon ] || fail "source-id should be primary-marathon, got: $out"
  MARATHON "$home" relisten || fail "relisten should exit 0"
  MARATHON "$home" terminal >/dev/null && fail "terminal should return 1"
  pass "source-id, relisten, and terminal behave as expected"
}

test_classify() {
  local home result
  home="$TMP_ROOT/h-classify"
  new_home "$home"
  result="$TMP_ROOT/classify.result"
  cat > "$result" <<'EOF'
primary-marathon: primary-marathon
status: marathon
detail: 151 assistant turns, 26 hours since session write
condition_polls: 1
output:
check: primary session is marathon-aged ...
EOF
  out=$(MARATHON "$home" classify "$result")
  [ "$out" = marathon ] || fail "classify should return marathon, got: $out"
  cat > "$result" <<'EOF'
primary-marathon: primary-marathon
status: unknown
EOF
  out=$(MARATHON "$home" classify "$result")
  [ "$out" = unknown ] || fail "classify should return unknown for unfamiliar status, got: $out"
  pass "classify recognizes marathon and unknown statuses"
}

# --- below-threshold behavior ----------------------------------------------

test_below_threshold_turns() {
  local home
  home="$TMP_ROOT/h-below-turns"
  new_home "$home"
  # 150 turns is not > 150, so it is below threshold.
  make_session "$home" session.jsonl 150 0
  rc=0
  MARATHON "$home" poll --session-dir "$home/sessions" --state-dir "$home/state" --poll-interval 1 --cooldown 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 75 ] || fail "150 turns should be below threshold (exit 75), got rc=$rc"
  pass "150 assistant turns does not trigger a reminder"
}

test_below_threshold_age() {
  local home
  home="$TMP_ROOT/h-below-age"
  new_home "$home"
  # 24 hours is not > 24, so it is below threshold.
  make_session "$home" session.jsonl 1 $((24 * 3600))
  rc=0
  MARATHON "$home" poll --session-dir "$home/sessions" --state-dir "$home/state" --poll-interval 1 --cooldown 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 75 ] || fail "24h age should be below threshold (exit 75), got rc=$rc"
  pass "24-hour session age does not trigger a reminder"
}

# --- over-threshold behavior and re-arm/repeat -------------------------------

test_over_threshold_turns() {
  local home result
  home="$TMP_ROOT/h-over-turns"
  new_home "$home"
  make_session "$home" session.jsonl 151 0
  result=$(MARATHON "$home" poll --session-dir "$home/sessions" --state-dir "$home/state" --poll-interval 1 --cooldown 1)
  assert_contains "$result" "status: marathon" "poll should emit a marathon result for 151 turns"
  assert_contains "$result" "151 assistant turns" "result detail should report the turn count"
  assert_contains "$result" "check: primary session is marathon-aged" "result should carry the reminder text"
  [ -f "$home/state/last-reminder" ] || fail "poll should record the reminder timestamp"
  pass "151 assistant turns triggers a reminder and records the reminder time"
}

test_cooldown_suppresses_repeat() {
  local home rc=0
  home="$TMP_ROOT/h-cooldown"
  new_home "$home"
  make_session "$home" session.jsonl 151 0
  # First poll fires and records last-reminder at the current epoch.
  MARATHON "$home" poll --session-dir "$home/sessions" --state-dir "$home/state" --poll-interval 1 --cooldown 3600 >/dev/null || fail "first poll should fire"
  # Immediately poll again: cooldown has not elapsed.
  MARATHON "$home" poll --session-dir "$home/sessions" --state-dir "$home/state" --poll-interval 1 --cooldown 3600 >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 75 ] || fail "immediate re-poll should be suppressed by cooldown (exit 75), got rc=$rc"
  pass "cooldown suppresses a second reminder while still over threshold"
}

test_cooldown_expires_and_repeats() {
  local home
  home="$TMP_ROOT/h-repeat"
  new_home "$home"
  make_session "$home" session.jsonl 151 0
  # First poll fires.
  MARATHON "$home" poll --session-dir "$home/sessions" --state-dir "$home/state" --poll-interval 1 --cooldown 1 >/dev/null || fail "first poll should fire"
  # Wait for the cooldown to expire.
  sleep 2
  # Poll again; the session is still over threshold, so it should re-fire.
  out=$(MARATHON "$home" poll --session-dir "$home/sessions" --state-dir "$home/state" --poll-interval 1 --cooldown 1)
  assert_contains "$out" "status: marathon" "poll should re-fire after cooldown expires"
  pass "reminder repeats once the cooldown elapses while the session stays over threshold"
}

# --- runner integration: recurring reminders ---------------------------------

test_runner_emits_recurring_reminders() {
  local home
  home="$TMP_ROOT/h-runner"
  new_home "$home"
  make_session "$home" session.jsonl 151 0

  MARATHON "$home" arm \
    --session-dir "$home/sessions" \
    --state-dir "$home/state" \
    --poll-interval 1 \
    --cooldown 1 \
    >/dev/null || fail "arm should register the source"

  PE "$home" reconcile >/dev/null 2>&1 || fail "reconcile failed"
  wait_for_n_results "$home" 2 150 || fail "runner did not emit at least two recurring reminders"
  pass "runner emits recurring reminders while the session stays over threshold"
}

# --- main -------------------------------------------------------------------

test_source_id_and_relisten
test_classify
test_below_threshold_turns
test_below_threshold_age
test_over_threshold_turns
test_cooldown_suppresses_repeat
test_cooldown_expires_and_repeats
test_runner_emits_recurring_reminders

pass "all primary-marathon reminder tests"
