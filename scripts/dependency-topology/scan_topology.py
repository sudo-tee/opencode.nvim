#!/usr/bin/env python3
"""
Dependency topology scanner for Lua codebases.

Detects policy violations (e.g. entry layer depending on infra) and
generates interactive HTML visualizations with SCC highlighting.

Usage:
  python scan_topology.py scan          # Generate HTML graph, auto-open on macOS
  python scan_topology.py diff          # Compare HEAD vs uncommitted changes
  python scan_topology.py --help        # This message

Policy:
  Modules are grouped into layers (defined in topology.jsonc):
    - entry_layer:              plugin entry, api, keymap, handler shells, picker-type UIs
    - dispatch_layer:           command registry, execute gate, parse, slash, complete
    - capabilities_layer:       CLI mirrors, Nvim-native, UI rendering pipeline
    - cli_infrastructure_layer: Connection, protocol operations/Observation, transport, server lifecycle

  Policy rules forbid certain cross-layer dependencies (see topology.jsonc for the full
  7-rule matrix). Violations appear as red edges in the HTML graph.
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
import textwrap
from pathlib import Path

from graph_utils import load_snapshot_graph
from html_renderer import render_html
from scan_analysis import (
    init_policy,
    load_strategy,
    build_scan_payload,
    build_diff_payload,
)


DEFAULT_STRATEGY = Path(__file__).parent / "topology.jsonc"


def cmd_scan(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    snapshot = args.snapshot or "HEAD"
    strategy = load_strategy(args.strategy, DEFAULT_STRATEGY)
    init_policy(strategy.get("policy", {}).get("rules", []))

    payload = build_scan_payload(repo, snapshot, strategy, top_n=8)

    # Pop internal fields — not part of public JSON output
    graph = payload.pop("_graph")
    sccs = payload.pop("_sccs")

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    # Generate HTML visualization — reuse already-computed graph and sccs
    html_payload = {
        "node_list": sorted(graph.nodes.keys()),
        "edge_list": list(graph.edges),
        "sccs": sccs,
    }
    groups = strategy.get("groups", {})
    html_content = render_html(html_payload, groups)
    output = Path(args.output) if args.output else repo / "dependency-graph.html"
    output.write_text(html_content, encoding="utf-8")

    # Auto-open on macOS
    if platform.system() == "Darwin":
        subprocess.run(["open", str(output)], check=False)

    # Summary line
    violations = payload["health"]["violations"]["count"]
    status = f"violations={violations}" if violations else "clean"
    print(f"{payload['health']['cycles']['count']} cycles, {violations} violations, {status} → {output}")
    return 0

def _diff_default_snapshots(repo: Path) -> tuple[str, str]:
    """Smart default for diff with no args:
    - If worktree has uncommitted changes: HEAD vs worktree
    - If worktree is clean: HEAD~1 vs HEAD (last commit)
    """
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=repo, capture_output=True, text=True
    )
    if result.stdout.strip():
        return "HEAD", "worktree"
    return "HEAD~1", "HEAD"


def diff_regressions(payload: dict) -> list[str]:
    """Changes that fail `diff --check`: new violations, unmapped modules, new or grown cycles."""
    problems = []
    for v in payload["violations_new"]:
        problems.append(f"`{v['src']}` imports `{v['dst']}`, which breaks rule `{v['rule']}`")
    for m in payload["ungrouped_modules"]:
        problems.append(f"`{m}` has no layer in topology.jsonc, so its imports are not checked")
    for ch in payload.get("scc_changes", []):
        if "new_cycle" in ch:
            problems.append("new import loop between: " + ", ".join(f"`{m}`" for m in ch["new_cycle"]))
        elif ch.get("gained_members"):
            problems.append("import loop now also includes: " + ", ".join(f"`{m}`" for m in ch["gained_members"]))
    return problems


REPORT_MARKER = "<!-- architecture-check-report -->"


def render_markdown(payload: dict, problems: list[str]) -> str:
    hc = payload["health_comparison"]

    def row(label: str, before: int, after: int) -> str:
        delta = after - before
        return f"| {label} | {before} | {after} | {delta:+d} |"

    lines = [
        REPORT_MARKER,
        "## 🏗️ Architecture check",
        "",
        "Checks that `require()` calls between modules follow the layer rules in "
        "`scripts/dependency-topology/topology.jsonc` "
        "(entry → dispatch → services/UI → server/protocols; shared helpers usable everywhere).",
        "",
        f"Compared `{payload['from_snapshot']}` → `{payload['to_snapshot']}`.",
        "",
        "| | Before | After | Δ |",
        "|---|---|---|---|",
        row("Imports breaking layer rules", hc["violations"]["from"], hc["violations"]["to"]),
        row("Import loops", hc["cycles"]["count"]["from"], hc["cycles"]["count"]["to"]),
        row("Modules in largest loop", hc["cycles"]["largest"]["from"], hc["cycles"]["largest"]["to"]),
        row("Modules without a layer", hc["ungrouped"]["from"], hc["ungrouped"]["to"]),
        "",
        f"Imports between modules: +{payload['edge_changes']['added']} / -{payload['edge_changes']['removed']}",
        "",
    ]
    if problems:
        lines.append(f"### ❌ {len(problems)} problem(s) to fix")
        lines.append("")
        lines.extend(f"- {p}" for p in problems)
        lines.append("")
        lines.append(
            "To fix: give new modules a layer in `topology.jsonc`, move the import so it points "
            "down the layers, or list it as an `allowed` exception with a reason."
        )
    else:
        lines.append("### ✅ No new problems")
    fixed = payload["violations_fixed"]
    if fixed:
        lines.append("")
        lines.append(f"### Fixed layer-rule breaks ({len(fixed)})")
        lines.append("")
        lines.extend(f"- [{v['rule']}] `{v['src']}` → `{v['dst']}`" for v in fixed)
    lines.append("")
    lines.append("<sub>Run locally: `make topology-check`</sub>")
    return "\n".join(lines) + "\n"


def cmd_diff(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    if args.from_snapshot or args.to_snapshot:
        from_snap = args.from_snapshot or "HEAD"
        to_snap = args.to_snapshot or "worktree"
    else:
        from_snap, to_snap = _diff_default_snapshots(repo)
    strategy = load_strategy(args.strategy, DEFAULT_STRATEGY)
    init_policy(strategy.get("policy", {}).get("rules", []))

    payload = build_diff_payload(repo, from_snap, to_snap, strategy)
    problems = diff_regressions(payload)
    status = 1 if args.check and problems else 0

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return status
    if args.markdown:
        print(render_markdown(payload, problems), end="")
        return status

    # Human-readable — show meaningful detail, not just counts
    hc = payload["health_comparison"]
    cyc = hc["cycles"]
    vio = hc["violations"]

    print(f"{from_snap} → {to_snap}")
    print()

    # Health overview
    cyc_delta = cyc["largest"]["delta"]
    vio_delta = vio["delta"]
    print(f"  cycles:     {cyc['count']['from']}→{cyc['count']['to']}  "
          f"largest {cyc['largest']['from']}→{cyc['largest']['to']} ({cyc_delta:+d})")
    print(f"  violations: {vio['from']}→{vio['to']} ({vio_delta:+d})")
    ec = payload["edge_changes"]
    print(f"  edges:      +{ec['added']}/-{ec['removed']} (net {ec['net']:+d})")
    print()

    # SCC changes
    scc_changes = payload.get("scc_changes", [])
    if scc_changes:
        print("  SCC changes:")
        for ch in scc_changes:
            if "resolved" in ch:
                print(f"    ✓ resolved  size={ch['from_size']} → gone")
            elif "new_cycle" in ch:
                members = ", ".join(ch["new_cycle"][:4])
                ellipsis = f" +{len(ch['new_cycle'])-4} more" if len(ch["new_cycle"]) > 4 else ""
                print(f"    ✗ new cycle size={ch['to_size']}: {members}{ellipsis}")
            else:
                delta = ch["delta"]
                if ch["gained_members"]:
                    print(f"    ~ grew      {ch['from_size']}→{ch['to_size']} ({delta:+d})")
                    for m in ch["gained_members"]:
                        print(f"        + {m}")
                if ch["lost_members"]:
                    print(f"    ~ shrank    {ch['from_size']}→{ch['to_size']} ({delta:+d})")
                    for m in ch["lost_members"]:
                        print(f"        - {m}")
        print()

    # Violations fixed / introduced
    fixed = payload["violations_fixed"]
    new_v = payload["violations_new"]
    if fixed:
        print(f"  Fixed violations ({len(fixed)}):")
        for v in fixed:
            print(f"    ✓ [{v['rule']}]  {v['src']} → {v['dst']}")
        print()
    if new_v:
        print(f"  New violations ({len(new_v)}):")
        for v in new_v:
            print(f"    ✗ [{v['rule']}]  {v['src']} → {v['dst']}")
        print()
    if not fixed and not new_v:
        print("  No violation changes.")
        print()

    ungrouped = payload["ungrouped_modules"]
    if ungrouped:
        print(f"  Unmapped modules ({len(ungrouped)}) — add them to topology.jsonc:")
        for m in ungrouped:
            print(f"    ? {m}")
        print()

    if args.check:
        print(f"  check: {'FAILED, ' + str(len(problems)) + ' regression(s)' if problems else 'passed'}")

    return status

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Dependency topology scanner — detect layering violations and visualize module dependencies.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Examples:
              %(prog)s scan                    Generate HTML graph (auto-opens on macOS)
              %(prog)s scan -o /tmp/deps.html  Output to specific path
              %(prog)s scan --json             Output analysis as JSON (no HTML)
              %(prog)s diff                           Compare HEAD vs uncommitted changes
              %(prog)s diff --from HEAD~5             Compare 5 commits ago vs uncommitted
              %(prog)s diff --from v1.0 --to HEAD     Compare two commits
              %(prog)s diff --from origin/main --check --markdown   CI gate + PR report

            Policy rules are defined in topology.jsonc. Edit that file to customize
            layer definitions and forbidden dependency directions.
        """),
    )
    parser.add_argument("--repo", default=".", help="Repository path (default: current directory)")
    subparsers = parser.add_subparsers(dest="command")

    # scan
    p_scan = subparsers.add_parser(
        "scan",
        help="Scan topology and generate interactive HTML visualization",
        description="Analyze module dependencies, detect SCC cycles and policy violations, generate HTML.",
    )
    p_scan.add_argument("--snapshot", help="Git ref to analyze (default: HEAD)")
    p_scan.add_argument("--output", "-o", help="HTML output path (default: <repo>/dependency-graph.html)")
    p_scan.add_argument("--json", action="store_true", help="Output JSON analysis instead of HTML")
    p_scan.add_argument("--strategy", help="Path to strategy JSONC (default: topology.jsonc)")

    # diff
    p_diff = subparsers.add_parser(
        "diff",
        help="Compare two snapshots and report edge changes",
        description="Show added/removed edges and whether changes improved or regressed policy compliance.",
    )
    p_diff.add_argument("--from", dest="from_snapshot", help="Base ref (default: HEAD)")
    p_diff.add_argument("--to", dest="to_snapshot", help="Target ref (default: worktree = uncommitted changes)")
    p_diff.add_argument("--json", action="store_true", help="Output JSON instead of summary")
    p_diff.add_argument("--markdown", action="store_true", help="Output a Markdown report (for PR comments)")
    p_diff.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 on new violations, unmapped modules, or new/grown cycles",
    )
    p_diff.add_argument("--strategy", help="Path to strategy JSONC (default: topology.jsonc)")

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        return 0

    if args.command == "scan":
        return cmd_scan(args)
    elif args.command == "diff":
        return cmd_diff(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
