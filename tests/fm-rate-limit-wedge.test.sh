#!/usr/bin/env bash
# tests/fm-rate-limit-wedge.test.sh - rate-limit wedge auto-recovery contract.
#
# Exercises the detection signature, model-rotation selection, and the recovery
# action from bin/fm-rate-limit-wedge-lib.sh. The recovery action drives the
# real library against a fake control plane so no actual worker is relaunched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-rate-limit-wedge-lib.sh
. "$ROOT/bin/fm-rate-limit-wedge-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rate-limit-wedge-tests)

# A pane tail matching the OpenRouter new-account-rpm retry-exhaustion signature.
WEDGE_TAIL='Error: Retry failed after 3 attempts: 429: {"message":"Rate limit exceeded: new-account-rpm/..."}'
# A transient 429 without exhausted retries must not match.
TRANSIENT_TAIL='warning: 429 rate limit exceeded, will retry'
# A context-overflow error must not match.
OVERFLOW_TAIL='Error: context length exceeded'

make_state() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s\n' "$d"
}

make_control_fake() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -u
# Capture the invocation for assertions and fake a successful relaunch by
# updating the task meta model to the requested one.
log="${FM_RATE_LIMIT_WEDGE_CONTROL_LOG:?}"
{
  printf 'args='
  for a in "$@"; do printf ' <%s>' "$a"; done
  printf '\n'
} >> "$log"
if [ "$2" != relaunch ]; then
  exit 1
fi
meta="$FM_HOME/state/$1.meta"
shift 2
model=
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model=$2; shift 2 ;;
    --note) shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$model" ] || exit 1
# Update model in place so the library can see the swap succeeded.
tmp=$(mktemp "${meta}.tmp.XXXXXX") || exit 1
awk -v m="$model" 'BEGIN{done=0} /^model=/{print "model="m; done=1; next} {print} END{if(!done) print "model="m}' "$meta" > "$tmp" || { rm -f "$tmp"; exit 1; }
mv -f "$tmp" "$meta" || exit 1
exit 0
SH
  chmod +x "$fakebin/fm-control.sh"
}

write_task() {  # <state> <task> <model> <candidates>
  local state=$1 task=$2 model=$3 candidates=$4
  mkdir -p "$state"
  fm_write_meta "$state/$task.meta" \
    "window=tmux:fm-$task" \
    "endpoint_task_id=$task" \
    "worktree=/tmp/fake-$task" \
    "project=/tmp/fake-$task" \
    "harness=claude" \
    "kind=ship" \
    "model=$model" \
    "model_candidates=$candidates"
}

test_detects_exhausted_rate_limit_signature() {
  fm_rate_limit_wedge_detect "$WEDGE_TAIL" || fail "did not detect the known wedge signature"
  ! fm_rate_limit_wedge_detect "$TRANSIENT_TAIL" || fail "transient 429 must not trigger wedge detection"
  ! fm_rate_limit_wedge_detect "$OVERFLOW_TAIL" || fail "context overflow must not trigger wedge detection"
  pass "detects exhausted-retry 429 and rejects unrelated errors"
}

test_status_working_gate() {
  local dir statusf
  dir=$(make_state status-gate)
  statusf="$dir/t.status"
  printf 'working: investigating\n' > "$statusf"
  fm_rate_limit_wedge_status_is_working "$statusf" || fail "working: line not recognized as working"
  printf 'blocked: something broke\n' >> "$statusf"
  ! fm_rate_limit_wedge_status_is_working "$statusf" || fail "blocked: line recognized as working"
  printf 'paused: waiting on upstream\n' > "$statusf"
  ! fm_rate_limit_wedge_status_is_working "$statusf" || fail "paused: line recognized as working"
  printf 'done: finished\n' > "$statusf"
  ! fm_rate_limit_wedge_status_is_working "$statusf" || fail "done: line recognized as working"
  pass "only working status admits auto-rotation"
}

test_rotates_through_candidates() {
  local next
  next=$(fm_rate_limit_wedge_next_model "a" "a,b,c") || fail "rotation from a failed"
  [ "$next" = b ] || fail "expected b after a, got $next"
  next=$(fm_rate_limit_wedge_next_model "c" "a,b,c") || fail "rotation from c failed"
  [ "$next" = a ] || fail "expected wrap to a after c, got $next"
  next=$(fm_rate_limit_wedge_next_model "x" "a,b,c") || fail "rotation from unknown failed"
  [ "$next" = a ] || fail "expected first candidate when current not in list, got $next"
  ! fm_rate_limit_wedge_next_model "a" "a" >/dev/null 2>&1 || fail "single-candidate list must fail"
  next=$(fm_rate_limit_wedge_next_model "a" " a , b , c ") || fail "rotation from spaced list failed"
  [ "$next" = b ] || fail "expected trimmed b, got $next"
  pass "rotates to next model, wraps, and refuses when no alternative exists"
}

test_recovery_runs_relaunch_and_logs_rotation() {
  local dir fakebin task state statusf marker
  dir=$(make_state recovery-ok)
  fakebin=$(fm_fakebin "$dir")
  make_control_fake "$fakebin"
  state="$dir/state"
  task=wedge-ok
  write_task "$state" "$task" "openrouter/gemini-flash" "openrouter/gemini-flash,openrouter/claude-sonnet"
  statusf="$state/$task.status"
  printf 'working: still going\n' > "$statusf"
  marker=$(fm_rate_limit_wedge_marker "$state" "$task")

  FM_HOME="$dir" FM_RATE_LIMIT_WEDGE_CONTROL_BIN="$fakebin/fm-control.sh" \
    FM_RATE_LIMIT_WEDGE_CONTROL_LOG="$dir/control.log" \
    fm_rate_limit_wedge_try_recover "$state" "$task" "$WEDGE_TAIL" || fail "recovery should have initiated"

  assert_grep "relaunch" "$dir/control.log" "control script not called with relaunch"
  assert_grep "openrouter/claude-sonnet" "$dir/control.log" "control script not called with next model"
  assert_grep "auto-rotated from openrouter/gemini-flash to openrouter/claude-sonnet" "$statusf" "rotation not logged to status"
  assert_present "$marker" "rotation marker not written"
  pass "recovery relaunches on next model and logs a visible status line"
}

test_recovery_refuses_blocked_status() {
  local dir state task
  dir=$(make_state recovery-blocked)
  state="$dir/state"
  task=wedge-blocked
  write_task "$state" "$task" "a" "a,b"
  printf 'blocked: need help\n' > "$state/$task.status"
  ! FM_HOME="$dir" fm_rate_limit_wedge_try_recover "$state" "$task" "$WEDGE_TAIL" || fail "should not rotate a blocked worker"
  pass "refuses to rotate when the worker is blocked"
}

test_recovery_refuses_missing_candidates() {
  local dir state task
  dir=$(make_state recovery-no-candidates)
  state="$dir/state"
  task=wedge-no-cand
  write_task "$state" "$task" "a" ""
  printf 'model=a\n' >> "$state/$task.meta"  # overwrite empty candidates with no key
  printf 'working: still going\n' > "$state/$task.status"
  ! FM_HOME="$dir" fm_rate_limit_wedge_try_recover "$state" "$task" "$WEDGE_TAIL" || fail "should not rotate without candidates"
  pass "refuses to rotate when no candidate list is recorded"
}

test_recovery_refuses_active_control_lock() {
  local dir fakebin state task lock
  dir=$(make_state recovery-control-lock)
  fakebin=$(fm_fakebin "$dir")
  make_control_fake "$fakebin"
  state="$dir/state"
  task=wedge-lock
  write_task "$state" "$task" "a" "a,b"
  printf 'working: still going\n' > "$state/$task.status"
  lock="$state/.control-$task.lock"
  mkdir -p "$lock"
  ! FM_HOME="$dir" FM_RATE_LIMIT_WEDGE_CONTROL_BIN="$fakebin/fm-control.sh" \
    fm_rate_limit_wedge_try_recover "$state" "$task" "$WEDGE_TAIL" || fail "should not race a live control lock"
  assert_absent "$dir/control.log" "control script ran despite active lock"
  pass "refuses to rotate while a control lock is held"
}

test_recovery_refuses_cooldown() {
  local dir fakebin state task marker
  dir=$(make_state recovery-cooldown)
  fakebin=$(fm_fakebin "$dir")
  make_control_fake "$fakebin"
  state="$dir/state"
  task=wedge-cool
  write_task "$state" "$task" "a" "a,b"
  printf 'working: still going\n' > "$state/$task.status"
  marker=$(fm_rate_limit_wedge_marker "$state" "$task")
  printf '1\ta\tb\n' > "$marker"
  ! FM_HOME="$dir" FM_RATE_LIMIT_WEDGE_CONTROL_BIN="$fakebin/fm-control.sh" \
    fm_rate_limit_wedge_try_recover "$state" "$task" "$WEDGE_TAIL" || fail "should not rotate inside cooldown"
  pass "refuses to rotate inside the post-rotation cooldown"
}

test_recovery_refuses_non_wedge_signature() {
  local dir fakebin state task
  dir=$(make_state recovery-no-wedge)
  fakebin=$(fm_fakebin "$dir")
  make_control_fake "$fakebin"
  state="$dir/state"
  task=wedge-nowedge
  write_task "$state" "$task" "a" "a,b"
  printf 'working: still going\n' > "$state/$task.status"
  ! FM_HOME="$dir" FM_RATE_LIMIT_WEDGE_CONTROL_BIN="$fakebin/fm-control.sh" \
    fm_rate_limit_wedge_try_recover "$state" "$task" "$TRANSIENT_TAIL" || fail "should not rotate without exhausted-retry signature"
  pass "refuses to rotate when the pane lacks the exhausted-retry signature"
}

# Run all test_* functions.
for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  "$t"
done
printf 'ok - all rate-limit wedge tests passed\n'
