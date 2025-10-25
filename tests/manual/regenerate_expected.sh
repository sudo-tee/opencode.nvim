#!/bin/bash
# regenerate_expected.sh - Regenerate all .expected.json files from test data

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../.."
cd "$PROJECT_ROOT"

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
echo "Done! Regenerated $(ls tests/data/*.expected.json | wc -l | tr -d ' ') expected files"
