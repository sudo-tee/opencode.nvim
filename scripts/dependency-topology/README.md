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

## What it checks

Every Lua module belongs to a layer (`topology.jsonc`). Imports (`require()`)
may only point down the layers: Entry → Dispatch → Capabilities → Infrastructure,
with Foundation helpers usable from anywhere. The scanner reports:

- **layer-rule breaks** — an import pointing the wrong way;
- **import loops** — modules that depend on each other in a circle;
- **modules without a layer** — not matched by any pattern, so their imports are not checked.

Most new files are covered by wildcards (`opencode.services.*`, `opencode.ui.renderer.*`).
Only files outside them need a new entry in `topology.jsonc`.

## CI and `make topology-check`

The `architecture check` job runs on every pull request:

```bash
make topology-check                          # vs origin/main, worktree included
make topology-check TOPOLOGY_BASE=upstream/main
```

It fails on **new** layer-rule breaks, **new or grown** import loops, and **any**
module without a layer. Existing debt is reported but does not fail the build.
The job posts (and updates) a Markdown report comment on the PR and in the job
summary (`diff --check --markdown`).

Python dependencies are in `requirements.txt`. With [uv](https://docs.astral.sh/uv/)
installed, the `make` targets fetch them automatically; otherwise run
`pip install -r scripts/dependency-topology/requirements.txt`.

The current `topology.jsonc` is applied to both sides of a diff, so a mapping
change shows up on both snapshots rather than as a regression.

## Quick Start

```bash
# Scan current HEAD → generate interactive HTML
python3 scripts/dependency-topology/scan_topology.py scan

# Output to specific path
python3 scripts/dependency-topology/scan_topology.py scan -o /tmp/deps.html

# JSON output (for scripts/agents)
python3 scripts/dependency-topology/scan_topology.py scan --json

# Diff — smart default:
#   worktree has uncommitted Lua changes → HEAD vs worktree
#   worktree is clean                   → HEAD~1 vs HEAD (last commit)
python3 scripts/dependency-topology/scan_topology.py diff

# Compare specific refs (branch names, commit SHAs, remote refs)
python3 scripts/dependency-topology/scan_topology.py diff --from upstream/main --to clean-code-remove-core
python3 scripts/dependency-topology/scan_topology.py diff --from HEAD~5 --to HEAD
```

## Snapshot References

- `worktree` — current working tree (uncommitted changes)
- `HEAD` — latest commit
- Any git ref — branch name (e.g. `upstream/main`), tag, short or full commit SHA
- Relative refs — `HEAD~1`, `HEAD^`

**diff defaults (no args):**
- Worktree has uncommitted Lua changes → `HEAD` vs `worktree`
- Worktree is clean → `HEAD~1` vs `HEAD`

Note: ambiguous short names (e.g. `upstream` when both a local branch and remote exist)
produce a git warning. Prefer fully-qualified refs: `upstream/main`, `refs/heads/mybranch`.

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
