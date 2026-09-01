#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-openrouter-credit.sh, the OpenRouter account credit probe.
# The real API is replaced with a fake curl that returns a canned response and records its argv.
# Assertions cover the threshold verdict, the forced-threshold override, watch-mode output shape, and key hygiene.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-openrouter-credit.sh"
TMP=$(fm_test_tmproot fm-openrouter-credit)
FAKEBIN=$(fm_fakebin "$TMP")
AUTH="$TMP/auth.json"
ARGV_LOG="$TMP/curl-argv"
RESPONSE_FILE="$TMP/response.json"
SECRET='sk-or-test-0123456789abcdef'

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FM_TEST_ARGV_LOG:?}"
for a in "$@"; do
  case "$a" in
    */api/v1/credits) cat "${FM_TEST_CREDITS:-/dev/null}"; exit 0 ;;
    */api/v1/auth/key) cat "${FM_TEST_RESPONSE:?}"; exit 0 ;;
  esac
done
exit 22
SH
chmod +x "$FAKEBIN/curl"
printf '{"openrouter":{"type":"api_key","key":"%s"}}\n' "$SECRET" > "$AUTH"

export PATH="$FAKEBIN:$PATH"
export FM_OPENROUTER_AUTH_FILE="$AUTH"
export FM_TEST_ARGV_LOG="$ARGV_LOG"
export FM_TEST_RESPONSE="$RESPONSE_FILE"
unset OPENROUTER_API_KEY FM_OPENROUTER_CREDIT_THRESHOLD FM_OPENROUTER_API_BASE 2>/dev/null || true

printf '{"data":{"usage":40,"limit":50,"limit_remaining":10}}\n' > "$RESPONSE_FILE"
OUT=$("$CHECK") || fail "healthy balance exits 0 (got $?)"
printf '%s' "$OUT" | grep -q '\$10.00 remaining' || fail "healthy line shows the actual balance: $OUT"
pass "healthy balance prints the real remaining credit and exits 0"

OUT=$("$CHECK" --threshold 20; printf 'rc=%s' $?)
printf '%s' "$OUT" | grep -q 'rc=1' || fail "forced threshold exits 1: $OUT"
printf '%s' "$OUT" | grep -q 'LOW' || fail "forced threshold prints the warning state: $OUT"
pass "forced --threshold flips the same balance into the warning state"

printf '{"data":{"usage":47,"limit":50,"limit_remaining":3}}\n' > "$RESPONSE_FILE"
OUT=$("$CHECK" 2>&1; printf 'rc=%s' $?)
printf '%s' "$OUT" | grep -q 'rc=1' || fail "low balance exits 1: $OUT"
pass "balance at or below the default threshold warns"

printf '{"data":{"usage":40,"limit":null,"limit_remaining":null}}\n' > "$RESPONSE_FILE"
printf '{"data":{"total_credits":100,"total_usage":30}}\n' > "$TMP/credits.json"
OUT=$(FM_TEST_CREDITS="$TMP/credits.json" "$CHECK") \
  || fail "uncapped account falls back to the credits pool"
printf '%s' "$OUT" | grep -q '\$70.00 remaining' || fail "credits fallback computes the pool balance: $OUT"
OUT=$(FM_TEST_CREDITS="$TMP/credits.json" "$CHECK" --threshold 80; printf 'rc=%s' $?)
printf '%s' "$OUT" | grep -q 'rc=1' || fail "credits fallback honors the threshold: $OUT"
pass "an account with no credit cap is judged by total_credits minus total_usage"

printf '{"data":{"usage":40,"limit":50,"limit_remaining":10}}\n' > "$RESPONSE_FILE"
OUT=$("$CHECK" --watch)
[ -z "$OUT" ] || fail "watch mode is silent when healthy: $OUT"
OUT=$("$CHECK" --watch --threshold 20)
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "watch warning is exactly one line: $OUT"
printf '%s' "$OUT" | grep -q 'LOW' || fail "watch warning names the low state: $OUT"
pass "watch mode is silent when healthy and prints one wake line when low"

printf '{"data":{"usage":40,"limit":50,"limit_remaining":10}}\n' > "$RESPONSE_FILE"
OUT=$(FM_OPENROUTER_AUTH_FILE="$TMP/missing.json" OPENROUTER_API_KEY="$SECRET" "$CHECK") \
  || fail "env fallback key works"
printf '%s' "$OUT" | grep -q '\$10.00' || fail "env fallback reaches the same probe: $OUT"
OUT=$(FM_OPENROUTER_AUTH_FILE="$TMP/missing.json" "$CHECK" 2>&1; printf 'rc=%s' $?)
printf '%s' "$OUT" | grep -q 'rc=2' || fail "missing key exits 2: $OUT"
pass "key resolution falls back to the environment and fails closed without one"

"$CHECK" > "$TMP/run.out" 2>&1 || true
grep -q "$SECRET" "$TMP/run.out" && fail "output leaked the API key"
grep -q 'Authorization: Bearer' "$ARGV_LOG" || fail "key must travel in the Authorization header"
grep -v '^Authorization: Bearer' "$ARGV_LOG" | grep -q "$SECRET" && fail "curl argv leaked the API key outside the header"
pass "the API key never appears in output or command argv"
