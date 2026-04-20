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
    - cli_infrastructure_layer: api_client, server_job, event_manager, opencode_server

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

from graph_utils import load_snapshot_graph, tarjan_scc
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

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    # Generate HTML visualization
    graph = load_snapshot_graph(repo, snapshot)
    sccs = tarjan_scc(list(graph.nodes.keys()), list(graph.edges))
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


def cmd_diff(args: argparse.Namespace) -> int:
    repo = Path(args.repo).resolve()
    from_snap = args.from_snapshot or "HEAD"
    to_snap = args.to_snapshot or "worktree"
    strategy = load_strategy(args.strategy, DEFAULT_STRATEGY)
    init_policy(strategy.get("policy", {}).get("rules", []))

    payload = build_diff_payload(repo, from_snap, to_snap, strategy)

    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    # Human-readable summary
    hc = payload["health_comparison"]
    cyc = hc["cycles"]
    vio = hc["violations"]

    parts = [f"{from_snap} → {to_snap}:"]
    parts.append(f"edges {payload['edge_changes']['added']:+d}/{-payload['edge_changes']['removed']}")

    cyc_delta = cyc["largest"]["delta"]
    if cyc_delta:
        parts.append(f"largest_cycle {cyc['largest']['from']}→{cyc['largest']['to']} ({cyc_delta:+d})")

    vio_delta = vio["delta"]
    parts.append(f"violations {vio['from']}→{vio['to']} ({vio_delta:+d})")

    fixed = payload["violations_fixed"]
    new = payload["violations_new"]
    if fixed:
        parts.append(f"fixed={len(fixed)}")
    if new:
        parts.append(f"new={len(new)}")

    print("  ".join(parts))
    return 0


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
