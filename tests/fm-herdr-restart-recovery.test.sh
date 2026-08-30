#!/usr/bin/env bash
# Regression tests for Herdr server restart recovery: stale busy records that
# survive a restart, and endpoint identity verification against live agent
# state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the Herdr adapter)"; exit 0; }

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-restart-recovery)

# --- helpers ---------------------------------------------------------------

# make_herdr_restart_fakebin: a fake herdr that can model both a live agent and
# an agentless restart husk. Controlled via env vars:
#   FM_FAKE_HERDR_AGENT_STATE   live | no-agent | dead (default: live)
#                               live: agent get returns working; pane get succeeds
#                               no-agent: pane get succeeds but agent get returns
#                                         agent_not_found (restart husk)
#                               dead: pane get returns pane_not_found
#   FM_FAKE_HERDR_SESSION_PANE  the pane_id the fake expects, for pane get
#                               round-trip verification (default: w1:p2)
make_herdr_restart_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
AGENT_STATE="${FM_FAKE_HERDR_AGENT_STATE:-live}"
SESSION_PANE="${FM_FAKE_HERDR_SESSION_PANE:-w1:p2}"
case "${1:-}" in
  status)
    printf '{"client":{"version":"0.7.1","protocol":19},"server":{"running":true}}\n'
    exit 0 ;;
  pane)
    case "${2:-}" in
      get)
        if [ "$AGENT_STATE" = dead ]; then
          printf '{"error":{"code":"pane_not_found"}}\n'
        else
          printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$SESSION_PANE"
        fi
        exit 0 ;;
      read)
        printf 'ready\n> \n'
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        case "$AGENT_STATE" in
          live)
            printf '{"result":{"agent":{"agent_status":"working"}}}\n' ;;
          no-agent)
            printf '{"error":{"code":"agent_not_found"}}\n' ;;
          dead)
            printf '{"error":{"code":"pane_not_found"}}\n' ;;
          *)
            printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$AGENT_STATE" ;;
        esac
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

arm_busy_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

# --- crew-state: stale busy record after Herdr restart ---------------------

test_crew_state_herdr_restart_husk_reports_unknown() {
  local d out
  d="$TMP_ROOT/cs-restart-husk"
  mkdir -p "$d/state" "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  make_herdr_restart_fakebin "$d" >/dev/null

  # A task with a valid busy record from before the restart.
  fm_write_meta "$d/state/t1.meta" \
    "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  arm_busy_record "$d/state" t1

  # Simulate a Herdr restart: the pane exists but has no agent.
  out=$(FM_FAKE_HERDR_AGENT_STATE=no-agent \
    FM_FAKE_HERDR_SESSION_PANE=w1:p2 \
    PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$d" "$CREW_STATE" t1 2>/dev/null)

  assert_not_contains "$out" "state: working" \
    "stale busy record must not read as working after Herdr restart"
  assert_not_contains "$out" "harness busy" \
    "stale busy record must not read as harness busy after Herdr restart"
  assert_contains "$out" "herdr-agent-gone" \
    "stale busy record + no agent -> herdr-agent-gone source"
  pass "crew-state: Herdr restart husk + stale busy record -> unknown (not working)"
}

test_crew_state_herdr_live_agent_with_busy_record_stays_working() {
  local d out
  d="$TMP_ROOT/cs-live-agent"
  mkdir -p "$d/state" "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  make_herdr_restart_fakebin "$d" >/dev/null

  fm_write_meta "$d/state/t2.meta" \
    "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  arm_busy_record "$d/state" t2

  # Live agent: busy record is still valid.
  out=$(FM_FAKE_HERDR_AGENT_STATE=live \
    FM_FAKE_HERDR_SESSION_PANE=w1:p3 \
    PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$d" "$CREW_STATE" t2 2>/dev/null)

  assert_contains "$out" "state: working" \
    "busy record + live agent -> working"
  assert_contains "$out" "claude-hook" \
    "busy record source preserved for live agent"
  pass "crew-state: live Herdr agent + busy record -> working (no regression)"
}

test_crew_state_herdr_dead_pane_with_busy_record_reports_unknown() {
  local d out
  d="$TMP_ROOT/cs-dead-pane"
  mkdir -p "$d/state" "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  make_herdr_restart_fakebin "$d" >/dev/null

  fm_write_meta "$d/state/t3.meta" \
    "window=default:w1:p9" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  arm_busy_record "$d/state" t3

  # Pane is gone entirely.
  out=$(FM_FAKE_HERDR_AGENT_STATE=dead \
    FM_FAKE_HERDR_SESSION_PANE=w1:p9 \
    PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$d" "$CREW_STATE" t3 2>/dev/null)

  assert_not_contains "$out" "state: working" \
    "stale busy record must not read as working when pane is gone"
  assert_not_contains "$out" "harness busy" \
    "stale busy record must not read as harness busy when pane is gone"
  pass "crew-state: Herdr dead pane + stale busy record -> unknown (not working)"
}

# --- run -------------------------------------------------------------------

test_crew_state_herdr_restart_husk_reports_unknown
test_crew_state_herdr_live_agent_with_busy_record_stays_working
test_crew_state_herdr_dead_pane_with_busy_record_reports_unknown