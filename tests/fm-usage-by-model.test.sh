#!/usr/bin/env bash
# fm-usage-by-model.test.sh
# Exercises the multi-source usage aggregator end-to-end against synthetic
# opencode SQLite + Claude Code JSONL fixtures, wired in via
# FM_USAGE_OPENCODE_DB / FM_USAGE_CLAUDE_GLOB, and asserts computed
# aggregation values (turns, tokens, cost, filtering) -- not just output shape.
# Never touches real user dirs.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/../bin" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

TODAY="$(date -u +%Y-%m-%d)"
# Epoch ms (UTC, offset off midnight) via python3 for cross-platform date
# arithmetic -- BSD date on macOS lacks GNU date's -d flag.
TODAY_MS="$(python3 -c "
import datetime
d = datetime.datetime.strptime('$TODAY', '%Y-%m-%d').replace(tzinfo=datetime.timezone.utc)
print(int((d + datetime.timedelta(hours=12)).timestamp() * 1000))
")"
OLD_DATE="$(python3 -c "
import datetime
d = datetime.datetime.strptime('$TODAY', '%Y-%m-%d') - datetime.timedelta(days=5)
print(d.date().isoformat())
")"
OLD_MS="$(python3 -c "
import datetime
d = datetime.datetime.strptime('$OLD_DATE', '%Y-%m-%d').replace(tzinfo=datetime.timezone.utc)
print(int((d + datetime.timedelta(hours=12)).timestamp() * 1000))
")"

# Synthetic opencode.db using the real opencode message schema: role lives at
# the top level, tokens.cache is a nested {read,write} object (not dotted
# keys), and a plain user message (no tokens) must not inflate turn counts.
OC_DB="$TEST_DIR/opencode.db"
sqlite3 "$OC_DB" <<SQL
CREATE TABLE message (time_created INTEGER, data TEXT);
INSERT INTO message VALUES ($TODAY_MS, '{"role":"assistant","providerID":"anthropic","modelID":"claude-3-5-sonnet","tokens":{"input":100,"output":50,"cache":{"read":10,"write":5}}}');
INSERT INTO message VALUES ($TODAY_MS, '{"role":"assistant","providerID":"anthropic","modelID":"claude-3-5-sonnet","tokens":{"input":100,"output":50}}');
INSERT INTO message VALUES ($TODAY_MS, '{"role":"user","model":{"providerID":"anthropic","modelID":"claude-3-5-sonnet"}}');
INSERT INTO message VALUES ($OLD_MS, '{"role":"assistant","providerID":"anthropic","modelID":"claude-3-5-sonnet","tokens":{"input":999,"output":999}}');
SQL

# Synthetic Claude Code JSONL using real usage field names, plus a
# <synthetic>-model row that must be excluded and an old-day row to prove
# --since/--today filtering.
CC_DIR="$TEST_DIR/claude-projects/p1"
mkdir -p "$CC_DIR"
cat > "$CC_DIR/session.jsonl" <<JSONL
{"timestamp":"${TODAY}T12:00:00Z","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":300,"output_tokens":120,"cache_read_input_tokens":20,"cache_creation_input_tokens":0}}}
{"timestamp":"${TODAY}T12:01:00Z","message":{"role":"assistant","model":"<synthetic>","usage":{"input_tokens":10,"output_tokens":10}}}
{"timestamp":"${OLD_DATE}T12:00:00Z","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":999,"output_tokens":999}}}
JSONL

export FM_USAGE_OPENCODE_DB="$OC_DB"
export FM_USAGE_CLAUDE_GLOB="$TEST_DIR/claude-projects/**/*.jsonl"

OUT_JSON="$("$BIN_DIR/fm-usage-by-model.sh" --json --since "$TODAY" 2>"$TEST_DIR/stderr.log")" || fail "json run exited non-zero"
[ ! -s "$TEST_DIR/stderr.log" ] || fail "unexpected stderr for valid fixtures: $(cat "$TEST_DIR/stderr.log")"
echo "$OUT_JSON" | jq -e '.total and .models and .pi_note and (.warnings == [])' >/dev/null || fail "legacy json shape / empty-warnings failed"

# opencode: 2 assistant turns aggregated (the user message must not count),
# 200 input / 100 output tokens, cache 10 read / 5 write (from the nested
# tokens.cache object), cost = (200*3 + 100*15)/1e6 = 0.0021.
sonnet_turns="$(echo "$OUT_JSON" | jq '[.models[] | select(.model=="claude-3-5-sonnet")][0].turns')"
[ "$sonnet_turns" = "2" ] || fail "expected 2 opencode turns (user message must be excluded), got $sonnet_turns"
sonnet_input="$(echo "$OUT_JSON" | jq '[.models[] | select(.model=="claude-3-5-sonnet")][0].input_tokens')"
[ "$sonnet_input" = "200" ] || fail "expected 200 input tokens, got $sonnet_input"
sonnet_cache_read="$(echo "$OUT_JSON" | jq '[.models[] | select(.model=="claude-3-5-sonnet")][0].cache_read_tokens')"
[ "$sonnet_cache_read" = "10" ] || fail "expected nested tokens.cache.read=10 to be picked up, got $sonnet_cache_read"
sonnet_cost="$(echo "$OUT_JSON" | jq '[.models[] | select(.model=="claude-3-5-sonnet")][0].est_cost_usd')"
[ "$sonnet_cost" = "0.0021" ] || fail "expected sonnet cost 0.0021, got $sonnet_cost"

# claude-code: 1 turn (the <synthetic> row must be excluded), list-price note.
opus_turns="$(echo "$OUT_JSON" | jq '[.models[] | select(.model=="claude-opus-4-8")][0].turns')"
[ "$opus_turns" = "1" ] || fail "expected 1 claude-code turn (<synthetic> excluded), got $opus_turns"
opus_note="$(echo "$OUT_JSON" | jq -r '[.models[] | select(.model=="claude-opus-4-8")][0].note')"
[ "$opus_note" = "list-price estimate" ] || fail "expected list-price estimate note, got $opus_note"
opus_cost="$(echo "$OUT_JSON" | jq '[.models[] | select(.model=="claude-opus-4-8")][0].est_cost_usd')"
[ "$opus_cost" = "0.0135" ] || fail "expected opus cost 0.0135, got $opus_cost"

total_turns="$(echo "$OUT_JSON" | jq '.total.turns')"
[ "$total_turns" = "3" ] || fail "expected total turns 3 (old-day rows excluded by --since), got $total_turns"
total_cost="$(echo "$OUT_JSON" | jq '.total.est_cost_usd')"
[ "$total_cost" = "0.0156" ] || fail "expected total cost 0.0156, got $total_cost"

# --today must match --since <today> for these fixtures.
OUT_TODAY="$("$BIN_DIR/fm-usage-by-model.sh" --json --today 2>/dev/null)"
[ "$(echo "$OUT_TODAY" | jq '.total.turns')" = "3" ] || fail "--today did not match --since <today>"

# CSV output: header plus one data row per (date,source,provider,model),
# matching the totals verified above.
OUT_CSV="$("$BIN_DIR/fm-usage-by-model.sh" --csv --since "$TODAY" 2>/dev/null)"
echo "$OUT_CSV" | head -1 | grep -q '^date,source,provider,model,turns' || fail "csv header failed"
csv_rows="$(echo "$OUT_CSV" | tail -n +2 | grep -c '^' || true)"
[ "$csv_rows" = "2" ] || fail "expected 2 csv data rows, got $csv_rows"
echo "$OUT_CSV" | grep -q "^${TODAY},opencode,anthropic,claude-3-5-sonnet,2,200,100,10,5,0.0021," || fail "csv opencode row mismatch"
echo "$OUT_CSV" | grep -q "^${TODAY},claude-code,anthropic,claude-opus-4-8,1,300,120,20,0,0.0135,list-price estimate" || fail "csv claude-code row mismatch"

# Both sources absent: report zero, no warnings, exit 0 -- never fail just
# because a harness was never used locally.
OUT_ABSENT="$(FM_USAGE_OPENCODE_DB="$TEST_DIR/no-such.db" FM_USAGE_CLAUDE_GLOB="$TEST_DIR/no-such/**/*.jsonl" "$BIN_DIR/fm-usage-by-model.sh" --json 2>"$TEST_DIR/absent-stderr.log")" || fail "absent-source run exited non-zero"
[ ! -s "$TEST_DIR/absent-stderr.log" ] || fail "absent source produced unexpected warning: $(cat "$TEST_DIR/absent-stderr.log")"
echo "$OUT_ABSENT" | jq -e '.total.turns == 0 and .warnings == []' >/dev/null || fail "absent source did not report zero cleanly"

# A source that exists but fails to parse (corrupt db) must surface a warning
# instead of silently looking absent -- and still exit 0.
BAD_DB="$TEST_DIR/corrupt.db"
printf 'not a real sqlite db' > "$BAD_DB"
OUT_WARN="$(FM_USAGE_OPENCODE_DB="$BAD_DB" FM_USAGE_CLAUDE_GLOB="$TEST_DIR/no-such/**/*.jsonl" "$BIN_DIR/fm-usage-by-model.sh" --json 2>"$TEST_DIR/warn-stderr.log")" || fail "corrupt source run should still exit 0"
grep -q 'warning:.*opencode' "$TEST_DIR/warn-stderr.log" || fail "corrupt opencode db did not produce a stderr warning"
echo "$OUT_WARN" | jq -e '(.warnings | length) == 1 and (.warnings[0] | test("opencode"))' >/dev/null || fail "corrupt source not reported in JSON warnings"

echo "PASS: fm-usage-by-model.test.sh"
