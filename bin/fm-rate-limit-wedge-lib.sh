#!/usr/bin/env bash
# Rate-limit wedge auto-recovery.
# Detects a worker whose runtime has exhausted retries on a provider rate-limit
# error (e.g. OpenRouter 429 new-account-rpm) and rotates it to the next model
# drawn from the task's recorded crew-dispatch candidate list.
# This library is the single owner of the detection signature, the rotation
# selection rule, and the recovery action contract.
# It is sourced by the watcher (bin/fm-watch.sh); every other path that needs
# the same contract must use these functions rather than re-deriving the regex
# or the candidate list semantics.
set -u

_FM_RATE_LIMIT_WEDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# status_line_verb and last_status_line live in the shared classifier.
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_RATE_LIMIT_WEDGE_LIB_DIR/fm-classify-lib.sh"
# fm_meta_get lives with the backend helpers.
# shellcheck source=bin/fm-backend.sh
. "$_FM_RATE_LIMIT_WEDGE_LIB_DIR/fm-backend.sh"

# Minimum seconds between automatic rotations for one task.
# This stops a flapping series of wedges from launching a tight relaunch loop,
# while still allowing a genuine second wedge on a freshly rotated model after
# the cooldown.
FM_RATE_LIMIT_WEDGE_COOLDOWN=${FM_RATE_LIMIT_WEDGE_COOLDOWN:-60}

# A control lock less than this many seconds old is treated as an in-flight
# human-driven or firstmate-driven lifecycle action; back off rather than race.
FM_RATE_LIMIT_WEDGE_CONTROL_LOCK_GRACE=${FM_RATE_LIMIT_WEDGE_CONTROL_LOCK_GRACE:-120}

fm_rate_limit_wedge_marker() {  # <state> <task>
  printf '%s/.rate-limit-rotated-%s' "$1" "$2"
}

_fm_rate_limit_wedge_stat_mtime() {  # <file>
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

_fm_rate_limit_wedge_file_age() {  # <file> -> seconds since mtime
  local m now
  m=$(_fm_rate_limit_wedge_stat_mtime "$1") || { echo 999999; return; }
  now=$(date +%s)
  [ "$m" -le "$now" ] || { echo 999999; return; }
  echo $(( now - m ))
}

# 0 when <pane-tail> carries the exhausted-retry rate-limit signature.
# The detection is intentionally narrow: it requires a 429 status, an
# explicit rate-limit message, and wording that says retries have been spent.
# Auth failures, context overflows, and ordinary transient 429 retries do not
# match, so they continue to escalate through the normal stale path.
fm_rate_limit_wedge_detect() {  # <pane-tail>
  local tail=$1
  printf '%s' "$tail" | grep -qiE '429' || return 1
  printf '%s' "$tail" | grep -qiE 'rate limit exceeded' || return 1
  printf '%s' "$tail" | grep -qiE 'retry (failed|exhausted)|retries exhausted|retry failed after' || return 1
  return 0
}

# 0 when the task's last status line is a non-terminal `working:` event.
# A worker that has already declared itself blocked, paused, or finished must
# not be silently rotated; those states are captain-relevant and escalate as
# they do today.
fm_rate_limit_wedge_status_is_working() {  # <status-file>
  local line
  line=$(last_status_line "$1")
  [ -n "$line" ] || return 1
  [ "$(status_line_verb "$line")" = working ]
}

# Trim leading and trailing whitespace from a string.
_fm_rate_limit_wedge_trim() {  # <string>
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# Print the next model to try, rotating through the comma-separated candidate
# list and never returning the current model.
# If the current model is in the list, choose the next entry (wrapping).
# If it is not in the list, choose the first entry that differs from it.
# Print nothing and return 1 when the list is empty or every candidate equals
# the current model.
fm_rate_limit_wedge_next_model() {  # <current> <candidates-csv>
  local current=$1 csv=$2
  local -a models
  local i n idx found=-1 model
  IFS=',' read -r -a models <<< "$csv"
  # Normalize: strip whitespace around each candidate.
  for i in "${!models[@]}"; do
    models[i]=$(_fm_rate_limit_wedge_trim "${models[$i]}")
  done
  n=${#models[@]}
  [ "$n" -gt 0 ] || return 1
  current=$(_fm_rate_limit_wedge_trim "$current")
  for i in "${!models[@]}"; do
    [ "${models[$i]}" = "$current" ] && { found=$i; break; }
  done
  if [ "$found" -ge 0 ]; then
    for (( i = 1; i < n; i++ )); do
      idx=$(( (found + i) % n ))
      model=${models[$idx]}
      [ -n "$model" ] || continue
      [ "$model" != "$current" ] && { printf '%s' "$model"; return 0; }
    done
  else
    for i in "${!models[@]}"; do
      model=${models[$i]}
      [ -n "$model" ] || continue
      [ "$model" != "$current" ] && { printf '%s' "$model"; return 0; }
    done
  fi
  return 1
}

# Attempt automatic recovery for a rate-limit wedge.
# Arguments: <state-dir> <task-id> <pane-tail>
# Returns 0 if a relaunch was initiated, 1 otherwise.
# When it returns 0 it has already appended a `working:` status line naming
# the rotation so the event is durable and visible.
fm_rate_limit_wedge_try_recover() {  # <state> <task> <pane-tail>
  local state=$1 task=$2 tail=$3
  local meta statusf marker current candidates next note control_lock age
  local home

  meta="$state/$task.meta"
  statusf="$state/$task.status"
  marker=$(fm_rate_limit_wedge_marker "$state" "$task")
  [ -f "$meta" ] || return 1

  # Never race a human-driven or firstmate-driven lifecycle action.
  control_lock="$state/.control-$task.lock"
  if [ -e "$control_lock" ]; then
    age=$(_fm_rate_limit_wedge_file_age "$control_lock")
    [ "$age" -lt "$FM_RATE_LIMIT_WEDGE_CONTROL_LOCK_GRACE" ] && return 1
  fi

  # Cooldown so one recovery does not immediately trigger another while the
  # replacement agent is still starting.
  if [ -f "$marker" ]; then
    age=$(_fm_rate_limit_wedge_file_age "$marker")
    [ "$age" -lt "$FM_RATE_LIMIT_WEDGE_COOLDOWN" ] && return 1
  fi

  # The pane must show the exhausted-retry rate-limit signature.
  fm_rate_limit_wedge_detect "$tail" || return 1

  # The worker's own status log must still read `working:`, not blocked/paused/etc.
  fm_rate_limit_wedge_status_is_working "$statusf" || return 1

  current=$(fm_meta_get "$meta" model)
  [ -n "$current" ] || current=default
  candidates=$(fm_meta_get "$meta" model_candidates)
  [ -n "$candidates" ] || return 1

  next=$(fm_rate_limit_wedge_next_model "$current" "$candidates") || return 1

  note="auto-rotated from $current to $next after rate-limit wedge (429 retry-exhaustion)"

  home=${FM_HOME:-}
  if [ -z "$home" ]; then
    home=$(cd "$state/.." 2>/dev/null && pwd) || return 1
  fi

  control_bin=${FM_RATE_LIMIT_WEDGE_CONTROL_BIN:-"$_FM_RATE_LIMIT_WEDGE_LIB_DIR/fm-control.sh"}
  if ! FM_HOME="$home" "$control_bin" "$task" relaunch --model "$next" --note "$note" >/dev/null 2>&1; then
    return 1
  fi

  # Record the rotation where firstmate's routine status tail will show it.
  printf 'working: %s\n' "$note" >> "$statusf"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$current" "$next" > "$marker"
  return 0
}
