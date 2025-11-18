#!/bin/bash
# regenerate_expected.sh - Regenerate .expected.json files from test data
# Usage: ./regenerate_expected.sh [filename]
#   filename: Optional. Just the filename (e.g., "simple-session.json"). If not provided, regenerates all files.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../.."
cd "$PROJECT_ROOT"

# Check if specific file was requested
TARGET_FILE="$1"

if [[ -n "$TARGET_FILE" ]]; then
  # Single file mode
  if [[ "$TARGET_FILE" != *.json ]]; then
    TARGET_FILE="$TARGET_FILE.json"
  fi

  data_file="tests/data/$TARGET_FILE"

  if [[ ! -f "$data_file" ]]; then
    echo "Error: File '$data_file' not found"
    echo "Available files:"
    for file in tests/data/*.json; do
      if [[ "$file" != *.expected.json ]]; then
        basename "$file"
      fi
    done
    exit 1
  fi

  if [[ "$data_file" == *.expected.json ]]; then
    echo "Error: Cannot regenerate an expected file. Please specify the source file (without .expected)"
    exit 1
  fi

  expected_file="${data_file%.json}.expected.json"
  echo "Regenerating: $data_file -> $expected_file"
  echo ""
  read -p "Are you sure you want to continue? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi

  echo "Processing: $data_file -> $expected_file"
  nvim --headless -u tests/manual/init_replay.lua \
    "+ReplayLoad $data_file" \
    "+ReplayAll 0" \
    "+lua vim.defer_fn(function() vim.cmd('ReplaySave $expected_file') vim.cmd('qall!') end, 200)" 2>&1 | grep -v "^$"

  echo "Done! Regenerated $expected_file"
else
  # All files mode (original behavior)
  echo "This will regenerate all .expected.json files in tests/data/"
  echo "This will overwrite existing expected files."
  echo ""
  read -p "Are you sure you want to continue? (y/N) " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi

  echo ""
  echo "Regenerating all .expected.json files..."
  echo "=========================================="

  for data_file in tests/data/*.json; do
    if [[ "$data_file" == *.expected.json ]]; then
      continue
    fi

    expected_file="${data_file%.json}.expected.json"
    echo "Processing: $data_file -> $expected_file"

    nvim --headless -u tests/manual/init_replay.lua \
      "+ReplayLoad $data_file" \
      "+ReplayAll 0" \
      "+lua vim.defer_fn(function() vim.cmd('ReplaySave $expected_file') vim.cmd('qall!') end, 200)" 2>&1 | grep -v "^$"
  done

  echo ""
  echo "=========================================="
  expected_count=0
  for file in tests/data/*.expected.json; do
    if [[ -f "$file" ]]; then
      ((expected_count++))
    fi
  done
  echo "Done! Regenerated $expected_count expected files"
fi
