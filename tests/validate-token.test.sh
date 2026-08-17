#!/usr/bin/env bash
#
# Tests for install.sh's validate_token HTTP->HTTPS redirect handling.
# Uses a mock `curl` on PATH - no network, no LZ install needed.
# Run: bash tests/validate-token.test.sh
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
      https://*) echo "curl: (7) Failed to connect to localhost port 443" >&2; exit 7 ;;
    esac ;;
  always-redirect)
    printf '\n301' ;;
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
assert() { # assert <desc> <command...> - counts pass AND fail
  local desc="$1"; shift
  if "$@"; then pass=$((pass+1)); echo "ok   - $desc";
  else fail=$((fail+1)); echo "FAIL - $desc"; fi
}
assert_not() { # assert_not <desc> <command...>
  local desc="$1"; shift
  if "$@"; then fail=$((fail+1)); echo "FAIL - $desc";
  else pass=$((pass+1)); echo "ok   - $desc"; fi
}
retry_used_k() { grep -- "-k" "$MOCK_LOG" | grep -q "$1"; }

# 1. Plain HTTP 200 + user object -> 0
export MOCK_LOG="${WORK}/log1"; : > "$MOCK_LOG"
export MOCK_MODE=ok LZ_HOST_URL="http://localhost:80"
validate_token tok; check "http 200 user-scoped -> 0" 0 $?

# 2. HTTP 301 -> https loopback retry succeeds -> 0, retry used -k
export MOCK_LOG="${WORK}/log2"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-ok LZ_HOST_URL="http://localhost:80"
validate_token tok; check "301 -> https retry user-scoped -> 0" 0 $?
assert "retried against https://localhost" grep -q "https://localhost/api/auth" "$MOCK_LOG"
assert "loopback retry skipped cert verification (-k)" retry_used_k "https://localhost/api/auth"

# 3. HTTP 301 -> https retry says ingest-only -> 1
export MOCK_LOG="${WORK}/log3"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-null LZ_HOST_URL="http://localhost:80"
validate_token tok; check "301 -> https retry ingest-only -> 1" 1 $?

# 4. HTTP 301 -> https unreachable -> 2, and curl's stderr reaches the warn
export MOCK_LOG="${WORK}/log4"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-unreachable LZ_HOST_URL="http://localhost:80"
validate_token tok; check "301 -> https unreachable -> 2" 2 $?
assert "unreachable warn includes curl's own error" grep -q "WARN: .*Failed to connect" "$MOCK_LOG"

# 5. Non-loopback host: https retry happens, WITHOUT -k
export MOCK_LOG="${WORK}/log5"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-ok LZ_HOST_URL="http://lz.example.com"
validate_token tok; check "non-loopback 301 -> https retry -> 0" 0 $?
assert "non-loopback https retry occurred" grep -q "https://lz.example.com/api/auth" "$MOCK_LOG"
assert_not "non-loopback retry must NOT use -k" retry_used_k "https://lz.example.com"

# 6. Trailing slash: :80 must still be stripped ('localhost:80/' would
#    otherwise retry https against the plaintext port and always fail TLS)
export MOCK_LOG="${WORK}/log6"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-ok LZ_HOST_URL="http://localhost:80/"
validate_token tok; check "trailing slash 301 -> https retry -> 0" 0 $?
assert "trailing-slash retry targets https://localhost (port stripped)" grep -q "https://localhost/api/auth" "$MOCK_LOG"
assert_not "trailing-slash retry did not target https://localhost:80" grep -q "https://localhost:80/api/auth" "$MOCK_LOG"

# 7. Userinfo trick: 'localhost:80@evil.com' is NOT loopback -> no -k
export MOCK_LOG="${WORK}/log7"; : > "$MOCK_LOG"
export MOCK_MODE=redirect-then-ok LZ_HOST_URL="http://localhost:80@evil.com/"
validate_token tok; check "userinfo-host 301 -> verified https retry -> 0" 0 $?
assert_not "userinfo host must NOT get the loopback cert-skip" retry_used_k "@evil.com"

# 8. Already-https base that redirects: NOT an http->https upgrade - refuse
#    to follow (rc 2) and never grant the loopback -k retry
export MOCK_LOG="${WORK}/log8"; : > "$MOCK_LOG"
export MOCK_MODE=always-redirect LZ_HOST_URL="https://localhost"
validate_token tok; check "https base 301 -> refused, rc 2" 2 $?
assert_not "https-base redirect must NOT trigger a -k retry" retry_used_k "https://localhost"
assert "https-base redirect warns instead of following" grep -q "WARN: .*refusing to follow" "$MOCK_LOG"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
