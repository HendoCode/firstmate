#!/usr/bin/env bash
# Primary marathon session reminder process-event adapter.
#
# Registers a recurring reminder that fires when the live primary session
# exceeds a turn or age threshold, and keeps firing at a configured cadence
# while the session remains over threshold. The reminder is only a durable
# wake to firstmate; this adapter never restarts, terminates, or otherwise
# controls the primary session.
#
# Usage:
#   fm-procevent-primary-marathon.sh arm [options]
#   fm-procevent-primary-marathon.sh poll [options]
#   fm-procevent-primary-marathon.sh classify <result-file>
#   fm-procevent-primary-marathon.sh terminal <result-file>
#   fm-procevent-primary-marathon.sh relisten
#   fm-procevent-primary-marathon.sh source-id
#
# arm       Register the source with fm-procevent.sh. The registered command
#           carries all options, so re-arming after a restart or a self-update
#           is a normal reconcile, not a manual step.
# poll      One evaluation. Prints a result document and exits 0 when the
#           session is over threshold and the reminder cooldown has elapsed.
#           Exits 75 when nothing is due, signalling fm-procevent.sh to
#           relisten and poll again. Sleeps for --poll-interval before exit 75
#           so the runner does not spin on a still-healthy source.
# classify  Print the captured outcome class: marathon or unknown.
# terminal  Return 1: this source is never terminal; it relistens indefinitely.
# relisten  Return 0 so fm-procevent.sh keeps the same runner claim.
# source-id Print the canonical source id.
#
# Options (arm and poll):
#   --session-dir <dir>     Directory containing session jsonl files.
#                           Default: $FM_PRIMARY_SESSION_DIR, or
#                           $HOME/.pi/agent/sessions if it exists.
#   --state-dir <dir>       Directory for last-reminder and eval-count state.
#                           Default: $FM_HOME/state/primary-marathon.
#   --turn-threshold <n>    Assistant-turn count that triggers a reminder.
#                           Default: 150. The existing comparison uses >, so
#                           150 itself is below threshold and 151 is over.
#   --age-hours <h>         Session-file age in hours that triggers a reminder.
#                           Default: 24. The existing comparison uses >, so
#                           24 itself is below threshold and 25 is over.
#   --poll-interval <secs>  Seconds to sleep between evaluations.
#                           Default: 1800.
#   --cooldown <secs>       Minimum seconds between reminders.
#                           Default: 1800.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SOURCE_ID=primary-marathon
DEFAULT_TURN_THRESHOLD=150
DEFAULT_AGE_HOURS=24
DEFAULT_POLL_INTERVAL=1800
DEFAULT_COOLDOWN=1800

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# Portable file mtime in seconds since epoch.
file_mtime() {
  local path=$1
  if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/stat -f %m "$path" 2>/dev/null
  else
    stat -c %Y "$path" 2>/dev/null
  fi
}

# Current epoch seconds.
now_seconds() { date +%s; }

# Find the newest jsonl session file in the directory.
newest_session_file() {
  local dir=$1 newest='' newest_epoch=0 f m
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    m=$(file_mtime "$f") || continue
    [ -n "$m" ] || continue
    [ "$m" -gt "${newest_epoch:-0}" ] || continue
    newest_epoch=$m
    newest=$f
  done
  printf '%s\n' "$newest"
}

# Count assistant turns in a Pi-style jsonl session file.
count_assistant_turns() {
  local file=$1
  [ -f "$file" ] || { printf '0\n'; return; }
  grep -c '"role":"assistant"' "$file" 2>/dev/null || printf '0\n'
}

parse_options() {
  SESSION_DIR=${FM_PRIMARY_SESSION_DIR:-}
  STATE_DIR=${FM_PRIMARY_MARATHON_STATE_DIR:-${STATE}/primary-marathon}
  TURN_THRESHOLD=$DEFAULT_TURN_THRESHOLD
  AGE_HOURS=$DEFAULT_AGE_HOURS
  POLL_INTERVAL=$DEFAULT_POLL_INTERVAL
  COOLDOWN=$DEFAULT_COOLDOWN

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-dir)   [ -n "${2:-}" ] || die "--session-dir needs a value"; SESSION_DIR=$2; shift 2 ;;
      --state-dir)     [ -n "${2:-}" ] || die "--state-dir needs a value"; STATE_DIR=$2; shift 2 ;;
      --turn-threshold)
        case "${2:-}" in ''|*[!0-9]*) die "--turn-threshold needs a non-negative integer" ;; esac
        TURN_THRESHOLD=$2; shift 2 ;;
      --age-hours)
        case "${2:-}" in ''|*[!0-9]*) die "--age-hours needs a non-negative integer" ;; esac
        AGE_HOURS=$2; shift 2 ;;
      --poll-interval)
        case "${2:-}" in ''|*[!0-9]*) die "--poll-interval needs a non-negative integer" ;; esac
        POLL_INTERVAL=$2; shift 2 ;;
      --cooldown)
        case "${2:-}" in ''|*[!0-9]*) die "--cooldown needs a non-negative integer" ;; esac
        COOLDOWN=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

ensure_session_dir() {
  if [ -z "$SESSION_DIR" ]; then
    if [ -d "${HOME:-}/.pi/agent/sessions" ]; then
      SESSION_DIR="${HOME:-}/.pi/agent/sessions"
    else
      die "no session directory; pass --session-dir or set FM_PRIMARY_SESSION_DIR"
    fi
  fi
  [ -d "$SESSION_DIR" ] || die "session directory does not exist: $SESSION_DIR"
}

state_init() {
  (umask 077; mkdir -p "$STATE_DIR") || die "cannot create state directory: $STATE_DIR"
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || die "state directory is unavailable: $STATE_DIR"
}

last_reminder_epoch() {
  local file="$STATE_DIR/last-reminder"
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    cat "$file" 2>/dev/null || printf '0\n'
  else
    printf '0\n'
  fi
}

record_reminder() {
  local file="$STATE_DIR/last-reminder"
  (umask 077; printf '%s\n' "$(now_seconds)" > "$file") || die "cannot record reminder timestamp"
}

bump_eval_count() {
  local file="$STATE_DIR/eval-count" count=0
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    count=$(cat "$file" 2>/dev/null || printf '0\n')
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
  fi
  count=$((count + 1))
  (umask 077; printf '%s\n' "$count" > "$file") || true
  printf '%s\n' "$count"
}

cmd_source_id() {
  printf '%s\n' "$SOURCE_ID"
}

cmd_relisten() {
  exit 0
}

cmd_terminal() {
  return 1
}

cmd_autohandle() {  # <id> <seq> <result-file>
  local id=${1-} seq=${2-}
  [ -n "$id" ] || die "autohandle needs a source id"
  [ -n "$seq" ] || die "autohandle needs a sequence"
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh" || die "cannot load fm-pr-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" || die "cannot load fm-wake-lib.sh"
  # shellcheck source=bin/fm-procevent-lib.sh
  . "$SCRIPT_DIR/fm-procevent-lib.sh" || die "cannot load fm-procevent-lib.sh"
  fm_procevent_mark_handled "$STATE" "$id" "$seq" >/dev/null 2>&1 || true
  exit 0
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(awk '
    $0 == "output:" { exit }
    /^status: / { sub(/^status: /, ""); print; exit }
  ' "$file")
  case "$status" in
    marathon) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_poll() {
  parse_options "$@"
  ensure_session_dir
  state_init

  local session_file turns age_hours now last_reminder cooldown_remaining sleep_for
  session_file=$(newest_session_file "$SESSION_DIR")
  if [ -z "$session_file" ]; then
    # No session file yet; wait and relisten.
    sleep "$POLL_INTERVAL"
    exit 75
  fi

  turns=$(count_assistant_turns "$session_file")
  now=$(now_seconds)
  age_hours=$(( (now - $(file_mtime "$session_file")) / 3600 ))

  if [ "$turns" -le "$TURN_THRESHOLD" ] && [ "$age_hours" -le "$AGE_HOURS" ]; then
    # Below threshold: sleep and relisten.
    sleep "$POLL_INTERVAL"
    exit 75
  fi

  # Over threshold. Enforce the reminder cooldown.
  last_reminder=$(last_reminder_epoch)
  cooldown_remaining=$((last_reminder + COOLDOWN - now))
  if [ "$cooldown_remaining" -gt 0 ]; then
    sleep_for=$cooldown_remaining
    [ "$sleep_for" -le "$POLL_INTERVAL" ] || sleep_for=$POLL_INTERVAL
    sleep "$sleep_for"
    exit 75
  fi

  # Reminder is due.
  record_reminder
  printf 'primary-marathon: %s\n' "$SOURCE_ID"
  printf 'status: marathon\n'
  printf 'detail: %s assistant turns, %s hours since session write\n' "$turns" "$age_hours"
  printf 'condition_polls: %s\n' "$(bump_eval_count)"
  printf 'output:\n'
  printf 'check: primary session is marathon-aged (%s+ turns or %sh+) - type /new in the firstmate window to shed the context; durable state makes it a non-event\n' \
    "$TURN_THRESHOLD" "$AGE_HOURS"
  exit 0
}

cmd_arm() {
  parse_options "$@"
  state_init

  local -a argv=()
  [ -n "$SESSION_DIR" ] && argv+=(--session-dir "$SESSION_DIR")
  argv+=(--state-dir "$STATE_DIR")
  argv+=(--turn-threshold "$TURN_THRESHOLD")
  argv+=(--age-hours "$AGE_HOURS")
  argv+=(--poll-interval "$POLL_INTERVAL")
  argv+=(--cooldown "$COOLDOWN")

  FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 \
    "$SCRIPT_DIR/fm-procevent.sh" register primary-marathon "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-primary-marathon.sh" poll "${argv[@]}" || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
  printf 'session-dir: %s\n' "$SESSION_DIR"
  printf 'turn-threshold: %s\n' "$TURN_THRESHOLD"
  printf 'age-hours: %s\n' "$AGE_HOURS"
  printf 'poll-interval: %ss\n' "$POLL_INTERVAL"
  printf 'cooldown: %ss\n' "$COOLDOWN"
}

case "${1:-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal ;;
  relisten)  shift; cmd_relisten ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  source-id) shift; cmd_source_id ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
