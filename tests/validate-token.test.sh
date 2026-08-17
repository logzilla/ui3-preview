#!/usr/bin/env bash
#
# Tests for install.sh's validate_token HTTP->HTTPS redirect handling
# (Story 34-23-adjacent QA bug #12). Uses a mock `curl` on PATH - no
# network, no LZ install needed. Run: bash tests/validate-token.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── mock curl ────────────────────────────────────────────────────────
cat > "${WORK}/curl" <<'MOCK'
#!/usr/bin/env bash
# Mock curl: behavior driven by MOCK_MODE; logs each invocation.
echo "$*" >> "${MOCK_LOG}"
url=""
for a in "$@"; do case "$a" in http://*|https://*) url="$a" ;; esac; done
case "${MOCK_MODE}" in
  ok)
    printf '{"user": {"id": 1}}\n200' ;;
  redirect-then-ok)
    case "$url" in
      http://*)  printf '\n301' ;;
      https://*) printf '{"user": {"id": 1}}\n200' ;;
    esac ;;
  redirect-then-null)
    case "$url" in
      http://*)  printf '\n301' ;;
      https://*) printf '{"user": null}\n200' ;;
    esac ;;
  redirect-then-unreachable)
    case "$url" in
      http://*)  printf '\n301' ;;
      https://*) exit 7 ;;
    esac ;;
esac
MOCK
chmod +x "${WORK}/curl"
export PATH="${WORK}:${PATH}"

# ── extract the functions under test from install.sh ────────────────
extract() { sed -n "/^$1()/,/^}/p" "$INSTALL_SH"; }
FUNCS="$(extract _auth_probe; extract validate_token)"
warn() { echo "WARN: $*" >> "${MOCK_LOG}"; }
eval "$FUNCS"

pass=0; fail=0
check() { # check <desc> <expected_rc> <actual_rc>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   - $1";
  else fail=$((fail+1)); echo "FAIL - $1 (expected rc=$2, got rc=$3)"; fi
}
has_log() { grep -q "$2" "$1"; }

# 1. Plain HTTP 200 + user object -> 0
export MOCK_LOG="${WORK}/log1"; : > "$MOCK_LOG"
export MOCK_MODE=ok LZ_HOST_URL="http://localhost:80"
validate_token tok; check "http 200 user-scoped -> 0" 0 $?

# 2. HTTP 301 -> https loopback retry succeeds -> 0, retry used -k
export MOCK_LOG="${WORK}/log2"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-ok LZ_HOST_URL="http://localhost:80"
validate_token tok; check "301 -> https retry user-scoped -> 0" 0 $?
has_log "$MOCK_LOG" "https://localhost/api/auth" && echo "ok   - retried against https://localhost" || { echo "FAIL - no https retry logged"; fail=$((fail+1)); }
grep -- "-k" "$MOCK_LOG" | grep -q "https://localhost" && echo "ok   - loopback retry skipped cert verification (-k)" || { echo "FAIL - loopback retry missing -k"; fail=$((fail+1)); }

# 3. HTTP 301 -> https retry says ingest-only -> 1
export MOCK_LOG="${WORK}/log3"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-null LZ_HOST_URL="http://localhost:80"
validate_token tok; check "301 -> https retry ingest-only -> 1" 1 $?

# 4. HTTP 301 -> https unreachable -> 2
export MOCK_LOG="${WORK}/log4"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-unreachable LZ_HOST_URL="http://localhost:80"
validate_token tok; check "301 -> https unreachable -> 2" 2 $?

# 5. Non-loopback host: https retry WITHOUT -k
export MOCK_LOG="${WORK}/log5"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-ok LZ_HOST_URL="http://lz.example.com"
validate_token tok; check "non-loopback 301 -> https retry -> 0" 0 $?
grep "https://lz.example.com" "$MOCK_LOG" | grep -q -- "-k" && { echo "FAIL - non-loopback retry must NOT use -k"; fail=$((fail+1)); } || echo "ok   - non-loopback retry kept cert verification"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
