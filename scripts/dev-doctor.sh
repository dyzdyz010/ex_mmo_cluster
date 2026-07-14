#!/usr/bin/env bash
# =============================================================================
# Local client/server bootstrap doctor.
#
# Writes a structured, CLI-readable report to .demo/observe/dev-doctor.log by
# default. It intentionally checks the same HTTP/proxy endpoints that the
# browser client needs before WebSocket auth and voxel subscription can start.
# =============================================================================

set -u

cat >&2 <<'EOF'
archived_client_default_disabled: this generic doctor targets the archived browser client and is disabled by default.
Active Voxia entry: node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."
Explicit archived-client work must use its own README.
EOF
exit 64

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./dev-env.sh
. "${SCRIPT_DIR}/dev-env.sh" >/dev/null

OBSERVE_DIR="${DEV_DOCTOR_OBSERVE_DIR:-${REPO_ROOT}/.demo/observe}"
OBSERVE_LOG="${DEV_DOCTOR_LOG:-${OBSERVE_DIR}/dev-doctor.log}"
CLIENT_PORT="${CLIENT_PORT:-${PORT:-5173}}"
CLIENT_BASE_URL="${CLIENT_BASE_URL:-http://127.0.0.1:${CLIENT_PORT}}"
TIMEOUT_SECS="${DEV_DOCTOR_TIMEOUT_SECS:-8}"

mkdir -p "${OBSERVE_DIR}"
: >"${OBSERVE_LOG}"

failures=0
warnings=0

kv() {
  local key="$1"
  local value="${2//$'\n'/ }"
  value="${value//\"/\\\"}"
  printf '%s="%s"' "${key}" "${value}"
}

emit() {
  local level="$1"
  local event="$2"
  shift 2

  local ts line
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  line="dev_doctor ts=\"${ts}\" level=\"${level}\" event=\"${event}\""

  for field in "$@"; do
    line="${line} ${field}"
  done

  echo "${line}" | tee -a "${OBSERVE_LOG}"
}

record_fail() {
  failures=$((failures + 1))
  emit "fail" "$@"
}

record_warn() {
  warnings=$((warnings + 1))
  emit "warn" "$@"
}

port_owner() {
  local port="$1"

  if ! command -v lsof >/dev/null 2>&1; then
    echo "lsof_unavailable"
    return
  fi

  local owner
  owner="$(
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null |
      awk 'NR == 2 {print $1 "/" $2 " " $9}'
  )"

  if [ -z "${owner}" ]; then
    echo "none"
  else
    echo "${owner}"
  fi
}

http_post_json() {
  local name="$1"
  local url="$2"
  local data="$3"
  local expected_status="$4"
  local body_file="${OBSERVE_DIR}/dev-doctor-${name}.body"
  local err_file="${OBSERVE_DIR}/dev-doctor-${name}.err"
  local curl_status=0
  local status

  status="$(
    curl -sS -m "${TIMEOUT_SECS}" \
      -o "${body_file}" \
      -w "%{http_code}" \
      -X POST "${url}" \
      -H "content-type: application/json" \
      --data "${data}" \
      2>"${err_file}"
  )" || curl_status=$?

  local body err
  body="$(head -c 320 "${body_file}" 2>/dev/null | tr '\n' ' ')"
  err="$(head -c 320 "${err_file}" 2>/dev/null | tr '\n' ' ')"

  if [ "${curl_status}" -ne 0 ]; then
    record_fail \
      "http_${name}" \
      "$(kv url "${url}")" \
      "$(kv curl_status "${curl_status}")" \
      "$(kv error "${err}")"
    return
  fi

  if [ "${status}" = "${expected_status}" ]; then
    emit \
      "ok" \
      "http_${name}" \
      "$(kv url "${url}")" \
      "$(kv status "${status}")" \
      "$(kv body "${body}")"
  else
    record_fail \
      "http_${name}" \
      "$(kv url "${url}")" \
      "$(kv expected_status "${expected_status}")" \
      "$(kv status "${status}")" \
      "$(kv body "${body}")"
  fi
}

http_get_optional() {
  local name="$1"
  local url="$2"
  local body_file="${OBSERVE_DIR}/dev-doctor-${name}.body"
  local err_file="${OBSERVE_DIR}/dev-doctor-${name}.err"
  local curl_status=0
  local status

  status="$(
    curl -sS -m "${TIMEOUT_SECS}" \
      -o "${body_file}" \
      -w "%{http_code}" \
      "${url}" \
      2>"${err_file}"
  )" || curl_status=$?

  local err
  err="$(head -c 320 "${err_file}" 2>/dev/null | tr '\n' ' ')"

  if [ "${curl_status}" -ne 0 ]; then
    record_warn \
      "http_${name}" \
      "$(kv url "${url}")" \
      "$(kv curl_status "${curl_status}")" \
      "$(kv error "${err}")"
    return 1
  fi

  emit "ok" "http_${name}" "$(kv url "${url}")" "$(kv status "${status}")"
  return 0
}

emit \
  "ok" \
  "config" \
  "$(kv auth_port "${AUTH_PORT}")" \
  "$(kv visualize_port "${VISUALIZE_PORT}")" \
  "$(kv gate_tcp_port "${GATE_TCP_PORT}")" \
  "$(kv gate_udp_port "${GATE_UDP_PORT}")" \
  "$(kv game_auth_base_url "${GAME_AUTH_BASE_URL}")" \
  "$(kv game_ws_url "${GAME_WS_URL}")" \
  "$(kv vite_ingame_proxy_target "${VITE_INGAME_PROXY_TARGET}")" \
  "$(kv client_base_url "${CLIENT_BASE_URL}")" \
  "$(kv username "${GAME_CLIENT_USERNAME}")"

emit "ok" "port_owner" "$(kv port "${AUTH_PORT}")" "$(kv owner "$(port_owner "${AUTH_PORT}")")"
emit "ok" "port_owner" "$(kv port "${VISUALIZE_PORT}")" "$(kv owner "$(port_owner "${VISUALIZE_PORT}")")"
emit "ok" "port_owner" "$(kv port "${GATE_TCP_PORT}")" "$(kv owner "$(port_owner "${GATE_TCP_PORT}")")"
emit "ok" "port_owner" "$(kv port "${CLIENT_PORT}")" "$(kv owner "$(port_owner "${CLIENT_PORT}")")"

http_post_json \
  "auth_auto_login" \
  "${GAME_AUTH_BASE_URL}/ingame/auto_login" \
  "{\"username\":\"dev_doctor\"}" \
  "200"

if [ "${DEV_DOCTOR_SKIP_DEV_SEED:-0}" != "1" ]; then
  http_post_json \
    "voxel_dev_seed" \
    "${GAME_AUTH_BASE_URL}/ingame/voxel/dev_seed" \
    "{\"logical_scene_id\":${VITE_VOXEL_LOGICAL_SCENE_ID}}" \
    "200"
fi

if http_get_optional "client_index" "${CLIENT_BASE_URL}/"; then
  http_post_json \
    "client_proxy_auto_login" \
    "${CLIENT_BASE_URL}/ingame/auto_login" \
    "{\"username\":\"dev_doctor_proxy\"}" \
    "200"
fi

if [ "${failures}" -eq 0 ]; then
  emit \
    "ok" \
    "summary" \
    "$(kv failures "${failures}")" \
    "$(kv warnings "${warnings}")" \
    "$(kv observe_log "${OBSERVE_LOG}")"
  exit 0
fi

emit \
  "fail" \
  "summary" \
  "$(kv failures "${failures}")" \
  "$(kv warnings "${warnings}")" \
  "$(kv observe_log "${OBSERVE_LOG}")"
exit 1
