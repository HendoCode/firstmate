#!/usr/bin/env bash
# Report the OpenRouter account credit balance, preferring the remaining limit from GET /api/v1/auth/key and falling back to total_credits minus total_usage from GET /api/v1/credits when no cap is set.
# The key is read from ~/.pi/agent/auth.json (`.openrouter.key`), falling back to $OPENROUTER_API_KEY, and is never printed.
# Exit codes: 0 healthy, 1 remaining credit at or below the threshold, 2 key or API error.
# With --watch it prints one wake line only when the balance is low or the probe failed, and nothing when healthy, so it can serve as a watcher check.
# Threshold is $5.00 remaining by default; override with FM_OPENROUTER_CREDIT_THRESHOLD or --threshold <dollars>.
# Usage: fm-openrouter-credit.sh [--threshold <dollars>] [--watch]
set -u

API_BASE="${FM_OPENROUTER_API_BASE:-https://openrouter.ai}"
AUTH_FILE="${FM_OPENROUTER_AUTH_FILE:-$HOME/.pi/agent/auth.json}"
THRESHOLD="${FM_OPENROUTER_CREDIT_THRESHOLD:-5}"
WATCH=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --threshold)
      [ "$#" -ge 2 ] || { echo "error: --threshold needs a dollar value" >&2; exit 2; }
      THRESHOLD=$2
      shift 2
      ;;
    --watch) WATCH=1; shift ;;
    -h | --help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$THRESHOLD" in
  '' | *[!0-9.]* | *.*.*) echo "error: threshold must be a dollar amount" >&2; exit 2 ;;
esac
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "error: jq and curl are required" >&2
  exit 2
fi

fail() {
  # Report an unusable probe: a wake line in watch mode, a stderr error otherwise.
  if [ "$WATCH" -eq 1 ]; then
    printf 'openrouter credit check failed: %s\n' "$1"
    exit 0
  fi
  printf 'error: %s\n' "$1" >&2
  exit 2
}

KEY=
[ -f "$AUTH_FILE" ] && KEY=$(jq -r '.openrouter.key // empty' "$AUTH_FILE" 2>/dev/null)
[ -n "$KEY" ] || KEY="${OPENROUTER_API_KEY:-}"
[ -n "$KEY" ] || fail "no OpenRouter API key in $AUTH_FILE or OPENROUTER_API_KEY"

RESPONSE=$(curl -fsS --max-time 15 -H "Authorization: Bearer $KEY" "$API_BASE/api/v1/auth/key" 2>/dev/null) || RESPONSE=
[ -n "$RESPONSE" ] || fail "OpenRouter auth/key probe failed"

REMAINING=$(printf '%s' "$RESPONSE" | jq -r '
  (.data // .) as $d |
  if ($d.limit_remaining | type) == "number" then $d.limit_remaining
  elif (($d.limit | type) == "number") and (($d.usage | type) == "number") then ($d.limit - $d.usage)
  else empty end' 2>/dev/null)
LIMIT=$(printf '%s' "$RESPONSE" | jq -r '((.data // .).limit) as $l | if ($l | type) == "number" then $l else empty end')
LIMIT_LABEL="limit"

# Accounts without a credit cap report null limits, so fall back to the account credit pool.
if [ -z "$REMAINING" ]; then
  CREDITS=$(curl -fsS --max-time 15 -H "Authorization: Bearer $KEY" "$API_BASE/api/v1/credits" 2>/dev/null) || CREDITS=
  [ -n "$CREDITS" ] || fail "no credit balance in OpenRouter auth/key response and credits probe failed"
  REMAINING=$(printf '%s' "$CREDITS" | jq -r '
    (.data // .) as $d |
    if (($d.total_credits | type) == "number") and (($d.total_usage | type) == "number") then ($d.total_credits - $d.total_usage)
    else empty end' 2>/dev/null)
  LIMIT=$(printf '%s' "$CREDITS" | jq -r '((.data // .).total_credits) as $c | if ($c | type) == "number" then $c else empty end')
  LIMIT_LABEL="credit pool"
fi
[ -n "$REMAINING" ] || fail "no credit balance in OpenRouter auth/key or credits response"
LOW=$(jq -n --argjson r "$REMAINING" --argjson t "$THRESHOLD" '$r <= $t')
AMOUNT=$(awk -v v="$REMAINING" 'BEGIN { printf "%.2f", v }')
FLOOR=$(awk -v v="$THRESHOLD" 'BEGIN { printf "%.2f", v }')

if [ "$LOW" = true ]; then
  LINE="openrouter credit LOW: \$$AMOUNT remaining, at or below \$$FLOOR threshold"
  [ "$WATCH" -eq 1 ] && { printf '%s\n' "$LINE"; exit 0; }
  printf '%s\n' "$LINE"
  exit 1
fi
[ "$WATCH" -eq 1 ] && exit 0
LINE="openrouter credit ok: \$$AMOUNT remaining (warn at or below \$$FLOOR)"
[ -n "$LIMIT" ] && LINE="$LINE, $LIMIT_LABEL \$$(awk -v v="$LIMIT" 'BEGIN { printf "%.2f", v }')"
printf '%s\n' "$LINE"
