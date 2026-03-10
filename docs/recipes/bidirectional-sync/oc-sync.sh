#!/bin/bash
# oc-sync.sh: low-complexity opencode sync wrapper
# - default/path argument: ensure shared server, then attach
# - other commands: pass through to opencode found in PATH
# - fail fast when no executable opencode can be resolved

set -euo pipefail

DEFAULT_PORT="${OPENCODE_SYNC_PORT:-4096}"
DEFAULT_HOST="${OPENCODE_SYNC_HOST:-127.0.0.1}"
SERVER_READY_TIMEOUT_SEC="${OPENCODE_SYNC_WAIT_TIMEOUT_SEC:-20}"

log_info() { echo "[oc-sync] $*" >&2; }
log_error() { echo "[oc-sync] ERROR: $*" >&2; }

build_endpoint() { echo "http://${1}:${2}"; }

check_health() {
  curl -sf "${1}/global/health" >/dev/null 2>&1
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
  opencode_bin="$(get_opencode_bin)" || exit 1
  work_dir="${PWD}"
  if [ "$#" -gt 0 ] && [ -d "$1" ]; then
    work_dir="$1"
    shift
  fi
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
  route_command "$@"
}

main "$@"
