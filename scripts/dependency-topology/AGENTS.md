# Dependency Topology Scanner

Static analysis tool for Lua codebase dependency architecture.

## File Structure

```
scripts/dependency-topology/
├── scan_topology.py   # CLI entry: scan / diff subcommands
├── scan_analysis.py   # Core analysis: groups, edge rules, payload builders
├── graph_utils.py     # Pure graph algorithms (Tarjan SCC, back edges, degree)
├── html_renderer.py   # Interactive dagre-d3 + d3v5 HTML visualization
└── topology.jsonc     # Group definitions + review comments (strategy file)
```

## Quick Start

```bash
# Scan current HEAD → generate interactive HTML
python3 scripts/dependency-topology/scan_topology.py scan

# Output to specific path
python3 scripts/dependency-topology/scan_topology.py scan -o /tmp/deps.html

# JSON output (for scripts/agents)
python3 scripts/dependency-topology/scan_topology.py scan --json

# Compare HEAD vs working tree (default)
python3 scripts/dependency-topology/scan_topology.py diff

# Compare specific refs
python3 scripts/dependency-topology/scan_topology.py diff --from main --to HEAD
```

## Snapshot References

- `worktree` — current working tree (uncommitted changes)
- `HEAD` — latest commit
- Any git ref — branch name, tag, commit SHA

**diff defaults:** `--from HEAD --to worktree`

## Output

**scan:** One-line summary + HTML file path
```
4 cycles, 20 violations, violations=20 → /path/to/dependency-graph.html
```

**diff:** Change direction summary
```
HEAD → worktree: +2/-1 edges, improved=1, regressed=0
```

## JSON Output Signals

When using `--json`:

- `health` — one-glance status for cycles / violations / ungrouped coverage
- `cycles` — SCC details with severity, members_by_layer, example_cycle, back_edges_in_scc
- `violations` — policy violations grouped by rule with full edge lists
- `group_coverage` — module counts per layer (including ungrouped)
