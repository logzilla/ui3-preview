#!/usr/bin/env bash
#
# UI3 Preview - sidecar bootstrap installer
#
# Run this on your LogZilla host (as root). It resolves everything a UI3
# sidecar needs against your already-running LogZilla, writes a ready `.env`,
# and brings the sidecar up with the image-based `compose.yml` shipped next to
# this script.
#
# You supply at most ONE value: a user-level LogZilla API token (or press
# Enter and this script creates one for you). Everything else is auto-resolved
# or defaulted for a standard LogZilla Docker install.
#
# Nothing is written and nothing is started unless every prerequisite check
# passes - this script fails loudly rather than leaving a half-configured host.
#
# Override any default by exporting it before running, e.g.
#   LZ_NETWORK_NAME=lz_custom UI3_PORT=9090 ./install.sh
set -euo pipefail

# ── Resolve paths ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/compose.yml"

# ── Standard-install defaults (override via environment) ─────────────
LZ_NETWORK_NAME="${LZ_NETWORK_NAME:-lz_main}"
LZ_ETC_PATH="${LZ_ETC_PATH:-/etc/logzilla}"
UI3_PORT="${UI3_PORT:-8080}"
LOGZILLA_API_URL="${LOGZILLA_API_URL:-http://gunicorn:80}"
LZ_MANAGER_CONTAINER="${LZ_MANAGER_CONTAINER:-lz_watcher}"
SEC_API_URL="${SEC_API_URL:-http://front:80}"
CACHE_REFRESH_INTERVAL="${CACHE_REFRESH_INTERVAL:-300}"
CACHE_TTL="${CACHE_TTL:-600}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
# Where to validate a token against the LZ API (LZ nginx published on the host).
# HTTPS-configured LZ installs answer this with a 301 to https:// - the token
# validator below follows that redirect explicitly (see validate_token).
LZ_HOST_URL="${LZ_HOST_URL:-http://localhost:80}"

# ── Output helpers ───────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi
info() { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[FATAL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# Read a key's value from an existing .env (last wins). Empty if absent.
env_get() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

# A value is "real" if non-empty and not one of the .env.example placeholders.
is_placeholder() {
  case "$1" in
    ""|your-api-token-here|your-internal-api-token-here|change-me-to-a-random-secret) return 0 ;;
    *) return 1 ;;
  esac
}

# ── 1. Preflight (fail loudly, write nothing) ────────────────────────
info "Preflight checks"

[ "$(id -u)" -eq 0 ] || die "must run as root (LogZilla's CLI and Docker operations require it). Try: sudo ./install.sh"

command -v docker >/dev/null 2>&1 || die "docker not found on PATH. Install Docker and re-run."
docker compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is not available ('docker compose'). Install it and re-run."
docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable. Is Docker running?"

[ -f "$COMPOSE_FILE" ] || die "compose.yml not found next to this script (expected $COMPOSE_FILE). Run install.sh from the ui3-preview checkout."

# LZ network: use the given/default name, else auto-detect a single lz* network.
if ! docker network inspect "$LZ_NETWORK_NAME" >/dev/null 2>&1; then
  mapfile -t _lz_nets < <(docker network ls --format '{{.Name}}' | grep -E '^lz' || true)
  if [ "${#_lz_nets[@]}" -eq 1 ]; then
    LZ_NETWORK_NAME="${_lz_nets[0]}"
    warn "network 'lz_main' not found; auto-detected LZ network '${LZ_NETWORK_NAME}'."
  elif [ "${#_lz_nets[@]}" -eq 0 ]; then
    die "no LogZilla Docker network found. Is LogZilla running on this host? (looked for '$LZ_NETWORK_NAME' and any 'lz*' network)"
  else
    die "multiple LZ networks found (${_lz_nets[*]}); set LZ_NETWORK_NAME explicitly and re-run."
  fi
fi
ok "LZ network: ${LZ_NETWORK_NAME}"

# At least one LZ container attached to that network.
_lz_containers="$(docker network inspect "$LZ_NETWORK_NAME" \
  --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)"
[ -n "${_lz_containers// /}" ] || die "no containers are attached to network '${LZ_NETWORK_NAME}'. Start LogZilla first."
ok "LZ containers present on ${LZ_NETWORK_NAME}"

SECRETS_FILE="${LZ_ETC_PATH}/settings/secrets.yaml"
[ -f "$SECRETS_FILE" ] || die "LogZilla secrets file not found: ${SECRETS_FILE}. Set LZ_ETC_PATH if your install differs."
ok "LZ secrets file: ${SECRETS_FILE}"

# ── 2. Resolve LOGZILLA_API_TOKEN (paste or auto-create; validate) ───
info "Resolving LogZilla API token"

# _auth_probe <token> <base_url> [curl-extra-arg...]
# Curls <base_url>/api/auth; sets _PROBE_HTTP/_PROBE_BODY. Non-zero only on
# transport failure (DNS/refused/timeout) - HTTP status is always captured.
_auth_probe() {
  local token="$1" url="$2" resp; shift 2
  resp="$(curl -sS -m 20 -w $'\n%{http_code}' "$@" \
    -H "Authorization: token ${token}" "${url}/api/auth" 2>/dev/null)" || return 1
  _PROBE_HTTP="$(printf '%s' "$resp" | tail -n1)"
  _PROBE_BODY="$(printf '%s' "$resp" | sed '$d')"
}

# validate_token <token>: 0 = user-scoped (good); 1 = ingest/invalid; 2 = could not validate
#
# HTTPS-configured LZ installs answer http://localhost:80 with a 301/308 to
# https:// - previously that redirect was treated as a hard validation
# failure and the installer died (QA bug #12). `curl -L` alone is not the
# fix: the redirect target's certificate rarely matches 'localhost', so the
# follow fails on verification anyway. Instead the redirect is followed
# EXPLICITLY to the same host over https, and only when that host is
# loopback is certificate verification skipped (loudly) - a non-loopback
# LZ_HOST_URL keeps full verification.
validate_token() {
  local token="$1" base="${LZ_HOST_URL}" https_base host_part
  if ! _auth_probe "$token" "$base"; then
    warn "could not reach the LZ API at ${base}/api/auth"
    return 2
  fi
  case "$_PROBE_HTTP" in
    301|302|307|308)
      host_part="$(printf '%s' "$base" | sed -E 's#^[a-zA-Z]+://##; s#:80$##; s#/+$##')"
      https_base="https://${host_part}"
      case "$host_part" in
        localhost|localhost:*|127.0.0.1|127.0.0.1:*|\[::1\]|\[::1\]:*)
          warn "the LZ API at ${base} redirects HTTP to HTTPS (HTTP ${_PROBE_HTTP}); retrying token validation against ${https_base} - certificate verification is skipped for this loopback-only probe"
          if ! _auth_probe "$token" "$https_base" -k; then
            warn "could not reach the LZ API at ${https_base}/api/auth after the HTTPS retry"
            return 2
          fi
          ;;
        *)
          warn "the LZ API at ${base} redirects HTTP to HTTPS (HTTP ${_PROBE_HTTP}); retrying token validation against ${https_base}"
          if ! _auth_probe "$token" "$https_base"; then
            warn "could not reach the LZ API at ${https_base}/api/auth after the HTTPS retry (if its certificate does not match '${host_part}', set LZ_HOST_URL to the certificate's hostname and re-run)"
            return 2
          fi
          ;;
      esac
      ;;
  esac
  [ "$_PROBE_HTTP" = "200" ] || { warn "LZ API returned HTTP ${_PROBE_HTTP} while validating the token"; return 2; }
  if printf '%s' "$_PROBE_BODY" | grep -Eq '"user"[[:space:]]*:[[:space:]]*null'; then return 1; fi
  if printf '%s' "$_PROBE_BODY" | grep -Eq '"user"[[:space:]]*:[[:space:]]*\{'; then return 0; fi
  warn "unexpected /api/auth response; cannot confirm the token is user-scoped"
  return 2
}

LOGZILLA_API_TOKEN=""
_existing_token="$(env_get LOGZILLA_API_TOKEN)"
if ! is_placeholder "$_existing_token"; then
  LOGZILLA_API_TOKEN="$_existing_token"
  ok "reusing existing LOGZILLA_API_TOKEN from ${ENV_FILE} (no duplicate token minted)"
else
  printf 'Paste an existing user-level LogZilla API token, or press Enter to create one now: '
  read -r _pasted || true
  if [ -n "${_pasted:-}" ]; then
    LOGZILLA_API_TOKEN="$_pasted"
  else
    command -v logzilla >/dev/null 2>&1 || die "the 'logzilla' CLI is not on PATH, so a token cannot be auto-created. Paste an existing user-level token and re-run."
    warn "creating a user token via 'logzilla authtoken create' - this takes ~10-15 seconds, please wait..."
    _create_out="$(logzilla authtoken create 2>&1)" || die "'logzilla authtoken create' failed:
${_create_out}"
    LOGZILLA_API_TOKEN="$(printf '%s\n' "$_create_out" | grep -oE 'user-[0-9A-Za-z]+' | head -n1 || true)"
    [ -n "$LOGZILLA_API_TOKEN" ] || die "could not parse a 'user-<...>' token from 'logzilla authtoken create' output:
${_create_out}"
    ok "created a user-scoped token (value kept out of the log)"
  fi
fi

info "Validating the token resolves to a user (no ingest-only tokens)"
set +e
validate_token "$LOGZILLA_API_TOKEN"; _v=$?
set -e
case "$_v" in
  0) ok "token is user-scoped" ;;
  1) die "that token is ingest-only / invalid - the UI needs a USER token (the ingest key is rejected with 401 by the backend). Create or paste a user-level token and re-run." ;;
  2) die "could not validate the token against the LZ API at ${LZ_HOST_URL}. If LZ's nginx is not on localhost:80, or serves HTTPS with a certificate for a specific hostname, set LZ_HOST_URL (e.g. LZ_HOST_URL=https://lz.example.com) and re-run. (Refusing to proceed unvalidated.)" ;;
esac

# ── 3. Resolve SEC_API_TOKEN + DJANGO_SECRET_KEY ─────────────────────
info "Resolving SEC API token from ${SECRETS_FILE}"
SEC_API_TOKEN="$(grep -E '^[[:space:]]*INTERNAL_API_TOKEN[[:space:]]*:' "$SECRETS_FILE" \
  | head -n1 | sed -E 's/^[^:]*:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//' || true)"
[ -n "$SEC_API_TOKEN" ] || die "INTERNAL_API_TOKEN not found in ${SECRETS_FILE}. Cannot wire the SEC engine."
ok "SEC_API_TOKEN resolved from INTERNAL_API_TOKEN"

info "Resolving DJANGO_SECRET_KEY"
_existing_secret="$(env_get DJANGO_SECRET_KEY)"
if ! is_placeholder "$_existing_secret"; then
  DJANGO_SECRET_KEY="$_existing_secret"
  ok "preserving existing DJANGO_SECRET_KEY (regenerating would orphan already-encrypted SSH keys)"
else
  command -v openssl >/dev/null 2>&1 || die "openssl not found; needed to generate DJANGO_SECRET_KEY. Install it or set DJANGO_SECRET_KEY and re-run."
  DJANGO_SECRET_KEY="$(openssl rand -hex 32)"
  ok "generated a new DJANGO_SECRET_KEY"
fi

# ── 4. Write .env (single atomic write) + bring up ───────────────────
info "Writing ${ENV_FILE}"
_tmp_env="$(mktemp "${SCRIPT_DIR}/.env.XXXXXX")"
trap 'rm -f "$_tmp_env"' EXIT
cat > "$_tmp_env" <<EOF
# UI3 Preview sidecar configuration - generated by install.sh
# Regenerate by re-running ./install.sh (existing secrets are preserved).

# ── Docker infrastructure ──
LZ_NETWORK_NAME=${LZ_NETWORK_NAME}
LZ_ETC_PATH=${LZ_ETC_PATH}
UI3_PORT=${UI3_PORT}

# ── LogZilla API ──
LOGZILLA_API_URL=${LOGZILLA_API_URL}
LOGZILLA_API_TOKEN=${LOGZILLA_API_TOKEN}

# ── Container deployment ──
LZ_MANAGER_CONTAINER=${LZ_MANAGER_CONTAINER}

# ── Orchestration / SEC ──
SEC_API_TOKEN=${SEC_API_TOKEN}
# MUST be front:80 - gunicorn:80 does NOT serve SEC routes (most common misconfig).
SEC_API_URL=${SEC_API_URL}
DJANGO_SECRET_KEY=${DJANGO_SECRET_KEY}

# ── Backend settings ──
CACHE_REFRESH_INTERVAL=${CACHE_REFRESH_INTERVAL}
CACHE_TTL=${CACHE_TTL}
LOG_LEVEL=${LOG_LEVEL}
EOF
chmod 600 "$_tmp_env"
mv "$_tmp_env" "$ENV_FILE"
trap - EXIT
ok "wrote ${ENV_FILE} (mode 600)"

info "Bringing up the UI3 sidecar (docker compose up -d)"
( cd "$SCRIPT_DIR" && docker compose -f "$COMPOSE_FILE" up -d )

printf '\n'
ok "UI3 sidecar is up."
info "Open the UI at: ${C_GRN}http://localhost:${UI3_PORT}/${C_OFF} (on this LZ host)"
info "Check status with: docker compose -f \"${COMPOSE_FILE}\" ps"
info "Stop it with:      docker compose -f \"${COMPOSE_FILE}\" down"
