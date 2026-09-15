#!/bin/bash
# oc-sync.sh: legacy V1 attach helper
# - default/path argument: ensure shared V1 server, then attach
# - other commands: pass through to opencode found in PATH
# - fail fast when no executable opencode can be resolved

set -euo pipefail

DEFAULT_PORT="${OPENCODE_SYNC_PORT:-4096}"
DEFAULT_HOST="${OPENCODE_SYNC_HOST:-127.0.0.1}"
SERVER_READY_TIMEOUT_SEC="${OPENCODE_SYNC_WAIT_TIMEOUT_SEC:-20}"
PASSWORD_FILE="${OPENCODE_SYNC_PASSWORD_FILE:-${XDG_STATE_HOME:-${HOME}/.local/state}/nvim/opencode/server-password}"

log_info() { echo "[oc-sync] $*" >&2; }
log_error() { echo "[oc-sync] ERROR: $*" >&2; }

build_endpoint() { echo "http://${1}:${2}"; }

password_file_mode() {
  stat -f '%Lp' "${PASSWORD_FILE}" 2>/dev/null || stat -c '%a' "${PASSWORD_FILE}" 2>/dev/null
}

load_password_file() {
  if [ -L "${PASSWORD_FILE}" ] || [ ! -f "${PASSWORD_FILE}" ] || [ ! -r "${PASSWORD_FILE}" ]; then
    log_error "shared credential is not a readable regular file: ${PASSWORD_FILE}"
    return 1
  fi
  if [ "$(password_file_mode)" != 600 ]; then
    log_error "shared credential must have mode 0600: ${PASSWORD_FILE}"
    return 1
  fi
  IFS= read -r RESOLVED_PASSWORD <"${PASSWORD_FILE}" || true
  if [ -z "${RESOLVED_PASSWORD:-}" ]; then
    log_error "shared credential is empty: ${PASSWORD_FILE}"
    return 1
  fi
}

ensure_credential() {
  RESOLVED_PASSWORD=""
  if [ -e "${PASSWORD_FILE}" ] || [ -L "${PASSWORD_FILE}" ]; then
    load_password_file || return 1
  else
    local password_dir
    local generated
    generated="${OPENCODE_PASSWORD:-${OPENCODE_SERVER_PASSWORD:-}}"
    if [ -z "${generated}" ]; then
      generated="$(openssl rand -hex 16)"
    fi
    password_dir="$(dirname "${PASSWORD_FILE}")"
    mkdir -p "${password_dir}" || return 1
    if ! (
      umask 077
      set -o noclobber
      printf '%s\n' "${generated}" >"${PASSWORD_FILE}"
    ) 2>/dev/null && [ ! -f "${PASSWORD_FILE}" ]; then
      log_error "failed to create shared credential: ${PASSWORD_FILE}"
      return 1
    fi
    load_password_file || return 1
  fi

  export OPENCODE_PASSWORD="${RESOLVED_PASSWORD}"
  export OPENCODE_SERVER_PASSWORD="${RESOLVED_PASSWORD}"
  export OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"
}

request_health() {
  local url="$1"
  local password="${OPENCODE_PASSWORD:-${OPENCODE_SERVER_PASSWORD:-}}"
  local username="${OPENCODE_SERVER_USERNAME:-opencode}"
  local authorization

  if [ -n "${password}" ]; then
    authorization="$(printf '%s' "${username}:${password}" | base64 | tr -d '\n')"
    printf 'header = "Authorization: Basic %s"\n' "${authorization}" \
      | curl --config - -sS -w '\n%{http_code}' "${url}" 2>/dev/null || true
    return
  fi

  curl -sS -w '\n%{http_code}' "${url}" 2>/dev/null || true
}

check_health() {
  local endpoint="$1"
  local body status
  body="$(request_health "${endpoint}/global/health")"
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"
  [ "$status" -ge 200 ] 2>/dev/null && [ "$status" -lt 300 ] 2>/dev/null || return 1
  if printf '%s' "$body" | jq -e '
    type == "object" and .healthy == true and (.healthy | type == "boolean")
    and (.version | type == "string") and (.version | test("^1\\.18\\.[0-9]+"))
  ' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

port_in_use() {
  lsof -i ":${1}" -sTCP:LISTEN >/dev/null 2>&1
}

port_owner_pid() {
  lsof -i ":${1}" -sTCP:LISTEN -t 2>/dev/null | head -1
}

_norm_path() {
  local p="$1"
  local d
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
  printf "%s/%s" "$d" "$(basename "$p")"
}

get_opencode_bin() {
  local script_path
  local candidate
  local norm_script
  local norm_candidate

  script_path="$(_norm_path "${BASH_SOURCE[0]}" 2>/dev/null || printf "%s" "${BASH_SOURCE[0]}")"
  norm_script="${script_path}"

  candidate="$(command -v opencode 2>/dev/null || true)"
  if [ -z "${candidate}" ] || [ ! -x "${candidate}" ]; then
    log_error "opencode not found in PATH"
    return 1
  fi

  norm_candidate="$(_norm_path "${candidate}" 2>/dev/null || printf "%s" "${candidate}")"
  if [ "${norm_candidate}" = "${norm_script}" ]; then
    log_error "resolved opencode points to wrapper itself: ${candidate}"
    log_error "fix PATH to point to the real opencode binary"
    return 1
  fi

  echo "${candidate}"
}

wait_for_server() {
  local endpoint="$1"
  local start_ts
  local now_ts
  start_ts="$(date +%s)"
  while true; do
    if check_health "${endpoint}"; then
      return 0
    fi
    now_ts="$(date +%s)"
    if [ $((now_ts - start_ts)) -ge "${SERVER_READY_TIMEOUT_SEC}" ]; then
      return 1
    fi
    sleep 0.5
  done
}

start_server() {
  local host="$1"
  local port="$2"
  local endpoint
  local opencode_bin
  endpoint="$(build_endpoint "${host}" "${port}")"

  if port_in_use "${port}"; then
    local pid
    pid="$(port_owner_pid "${port}")"
    log_error "Port ${port} is in use (PID: ${pid:-unknown})"
    return 1
  fi

  opencode_bin="$(get_opencode_bin)" || return 1

  log_info "Starting server on ${host}:${port}..."
  nohup "${opencode_bin}" serve --port "${port}" --hostname "${host}" \
    </dev/null >/dev/null 2>&1 &

  if wait_for_server "${endpoint}"; then
    log_info "Server started"
    return 0
  fi

  log_error "Server failed to start within timeout"
  return 1
}

# Ensure the server is running and print endpoint to stdout.
ensure_server() {
  local port="${1:-$DEFAULT_PORT}"
  local host="${2:-$DEFAULT_HOST}"
  local endpoint
  ensure_credential
  endpoint="$(build_endpoint "${host}" "${port}")"

  if check_health "${endpoint}"; then
    echo "${endpoint}"
    return 0
  fi

  if port_in_use "${port}"; then
    local pid
    pid="$(port_owner_pid "${port}")"
    log_error "Port ${port} occupied by PID ${pid:-unknown} but not healthy"
    return 1
  fi

  start_server "${host}" "${port}" || return 1
  echo "${endpoint}"
}

handler_passthrough() {
  local opencode_bin
  opencode_bin="$(get_opencode_bin)" || exit 1
  exec "${opencode_bin}" "$@"
}

handler_wrap_tui() {
  local endpoint
  local opencode_bin
  local work_dir
  endpoint="$(ensure_server)" || {
    log_error "Failed to ensure shared server"
    exit 1
  }
  ensure_credential
  if ! check_health "${endpoint}"; then
    log_error "Shared server failed authenticated protocol probe"
    exit 1
  fi
  opencode_bin="$(get_opencode_bin)" || exit 1
  work_dir="${PWD}"
  if [ "$#" -gt 0 ] && [ -d "$1" ]; then
    work_dir="$1"
    shift
  fi
  cd "${work_dir}"
  exec "${opencode_bin}" attach "${endpoint}" --dir "${work_dir}" "$@"
}

route_command() {
  local cmd="${1:-}"

  if [ "${cmd}" = "--sync-ensure" ]; then
    shift
    ensure_server "$@"
    return
  fi

  if [ -z "${cmd}" ] || [ -d "${cmd}" ]; then
    handler_wrap_tui "$@"
    return
  fi

  handler_passthrough "$@"
}

main() {
  local opencode_bin help
  opencode_bin="$(get_opencode_bin)" || return 1
  help="$("${opencode_bin}" --help)" || return 1
  if printf '%s\n' "$help" | grep -Eq '^[[:space:]]*service[[:space:]]'; then
    log_error "V2 uses its native background service; run opencode directly."
    return 1
  fi
  route_command "$@"
}

main "$@"
