#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v nvim >/dev/null 2>&1; then
  echo 'error: nvim is required to resolve VIMRUNTIME' >&2
  exit 127
fi

if ! command -v emmylua_check >/dev/null 2>&1; then
  echo 'error: emmylua_check is required' >&2
  exit 127
fi

if [[ ! -d "${VIMRUNTIME:-}" ]]; then
  VIMRUNTIME="$(nvim --headless -u NONE -i NONE --noplugin \
    --cmd 'lua io.write(vim.env.VIMRUNTIME or "")' \
    --cmd 'qa!' 2>/dev/null)"
fi

if [[ ! -d "${VIMRUNTIME:-}" ]]; then
  echo 'error: unable to resolve a valid VIMRUNTIME' >&2
  exit 1
fi

export VIMRUNTIME
exec emmylua_check . "$@"
