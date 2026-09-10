#!/usr/bin/env bash
# fm-usage-extract.test.sh
# Colocated test exercising fm-usage-extract.sh --summary.
# Pins the zero-contribution contract for an absent opencode database and the
# non-zero path against a synthetic one, without touching real user dirs.
# shellcheck shell=bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/../bin" && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# absent database -> zero summary, exit 0, never error
OUT_ABSENT=$(OPENCODE_DB_PATH="$TEST_DIR/absent.db" "$BIN_DIR/fm-usage-extract.sh" --summary)
echo "$OUT_ABSENT" | jq -e '.turns == 0 and .estimated_cost_usd == 0 and .tokens.input == 0' >/dev/null || { echo "absent db did not report zero"; exit 1; }

# present database -> totals reflect the synthetic rows
OC_DB="$TEST_DIR/opencode.db"
python3 - "$OC_DB" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE message (time_created INTEGER, data TEXT)")
con.execute("INSERT INTO message VALUES (1724800000000, ?)", ('{"role":"assistant","providerID":"anthropic","modelID":"claude-3-5-sonnet","tokens":{"input":100,"output":50,"cache.read":10,"cache.write":5}}',))
con.execute("INSERT INTO message VALUES (1724800000000, ?)", ('{"role":"assistant","providerID":"anthropic","modelID":"claude-3-5-sonnet","tokens":{"input":200,"output":75}}',))
con.commit()
PYEOF

OUT_PRESENT=$(OPENCODE_DB_PATH="$OC_DB" "$BIN_DIR/fm-usage-extract.sh" --summary)
echo "$OUT_PRESENT" | jq -e '.turns == 2 and .tokens.input == 300 and .tokens.output == 125' >/dev/null || { echo "present db summary wrong"; exit 1; }

echo "PASS: fm-usage-extract.test.sh"
