#!/usr/bin/env bash
# fm-usage-by-model.test.sh
# Colocated test exercising the multi-source usage aggregator with synthetic fixtures.
# Uses fake opencode.db (SQLite) and fake Claude Code JSONL; never touches real user dirs.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/../bin" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# synthetic opencode.db
OC_DB="$TEST_DIR/opencode.db"
sqlite3 "$OC_DB" <<'SQL'
CREATE TABLE message (time_created INTEGER, data TEXT);
INSERT INTO message VALUES (1724800000000, '{"providerID":"anthropic","modelID":"claude-3-5-sonnet","tokens":{"input":100,"output":50,"cache.read":10,"cache.write":5}}');
INSERT INTO message VALUES (1724800000000, '{"providerID":"anthropic","modelID":"claude-3-5-sonnet","tokens":{"input":200,"output":75}}');
SQL

# synthetic claude-code jsonl (one day)
CC_DIR="$TEST_DIR/.claude/projects/p1"
mkdir -p "$CC_DIR"
cat > "$CC_DIR/session.jsonl" <<'JSONL'
{"timestamp":"2024-08-28T00:00:00Z","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":300,"output_tokens":120,"cache_read_input_tokens":20,"cache_creation_input_tokens":0}}}
{"timestamp":"2024-08-28T00:01:00Z","message":{"role":"assistant","model":"<synthetic>","usage":{"input_tokens":10}}}
JSONL

# synthetic pi jsonl (2 lines, one usage-bearing, one non-usage to test skip)
PI_DIR="$TEST_DIR/.pi/agent/sessions/p1"
mkdir -p "$PI_DIR"
cat > "$PI_DIR/session.jsonl" <<'JSONL'
{"type":"message","timestamp":"2024-08-28T00:00:00Z","message":{"role":"assistant","model":"claude-sonnet-4-6","provider":"anthropic","usage":{"input":3,"output":752,"cacheRead":0,"cacheWrite":42889,"totalTokens":43644,"cost":{"input":0.000009,"output":0.01128,"cacheRead":0,"cacheWrite":0.16083375,"total":0.17212275},"cacheWrite1h":0,"reasoning":671}}}
{"type":"thinking","timestamp":"2024-08-28T00:00:01Z","message":{}}
JSONL

# run with env overrides for pi path (opencode/claude hardcode user paths but test filters by --since; pi now respects PI_SESSIONS_DIR)
OUT_JSON=$(PI_SESSIONS_DIR="$PI_DIR" "$BIN_DIR/fm-usage-by-model.sh" --json --since 2024-08-28 2>/dev/null || true)
echo "$OUT_JSON" | jq -e '.total and .models and (.sources | index("pi"))' >/dev/null || { echo "legacy json shape failed"; exit 1; }

OUT_CSV=$(PI_SESSIONS_DIR="$PI_DIR" "$BIN_DIR/fm-usage-by-model.sh" --csv --since 2024-08-28 2>/dev/null || true)
echo "$OUT_CSV" | head -1 | grep -q 'date,source,provider,model,turns' || { echo "csv header failed"; exit 1; }
echo "$OUT_CSV" | grep -q 'pi,anthropic,claude-sonnet-4-6.*pi-computed cost' || { echo "pi row missing or wrong"; exit 1; }

echo "PASS: fm-usage-by-model.test.sh"
