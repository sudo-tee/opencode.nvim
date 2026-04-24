#!/usr/bin/env python3
"""Core analysis logic for scan and diff commands."""

from __future__ import annotations

import fnmatch
import json5
from collections import Counter
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple

from graph_utils import back_edges, load_snapshot_graph, tarjan_scc, find_cycle_in_scc


_POLICY_RULES: List[Dict[str, Any]] = []


def init_policy(rules: List[Dict[str, Any]]) -> None:
    """Initialize policy rules from topology.jsonc policy.rules list."""
    global _POLICY_RULES
    _POLICY_RULES = rules or []


def edge_rule(src_group: str, dst_group: str) -> str | None:
    for r in _POLICY_RULES:
        if r.get("from") == src_group and dst_group in r.get("to", []):
            return r["name"]
    return None


def load_strategy(path: str | None, default_path: Path) -> Dict[str, Any]:
    strategy_path = Path(path) if path else default_path
    if not strategy_path.exists():
        return {}
    data = json5.loads(strategy_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("strategy file must be an object")
    groups = data.get("groups", {})
    if groups is not None and not isinstance(groups, dict):
        raise ValueError("strategy.groups must be an object")
    return data


def build_group_rules(groups: Dict[str, Any] | None) -> List[Tuple[str, List[str]]]:
    rules: List[Tuple[str, List[str]]] = []
    for group_name, value in (groups or {}).items():
        if not isinstance(value, dict):
            continue
        raw_modules = value.get("modules", [])
        if not isinstance(raw_modules, list):
            continue
        patterns = [m for m in raw_modules if isinstance(m, str) and m.strip()]
        rules.append((group_name, patterns))
    return rules


def group_of(module: str, rules: List[Tuple[str, List[str]]], cache: Dict[str, str]) -> str:
    cached = cache.get(module)
    if cached:
        return cached

    for group_name, patterns in rules:
        for pattern in patterns:
            if fnmatch.fnmatch(module, pattern):
                cache[module] = group_name
                return group_name

    cache[module] = "ungrouped"
    return "ungrouped"


def classify_policy_violations(edge_rows: List[Dict[str, str]]) -> Tuple[Dict[str, int], List[Dict[str, str]]]:
    violations: List[Dict[str, str]] = []
    summary: Dict[str, int] = {"total_violations": 0}

    for row in edge_rows:
        rule = edge_rule(row["src_group"], row["dst_group"])
        if not rule:
            continue
        v = dict(row)
        v["rule"] = rule
        violations.append(v)
        summary[rule] = summary.get(rule, 0) + 1
        summary["total_violations"] += 1

    return summary, violations


def short_module_name(module: str) -> str:
    return module.split(".")[-1] if module else module


def build_scc_condensation_view(nodes: List[str], edges: Set[Tuple[str, str]]) -> Tuple[List[Dict[str, Any]], Set[Tuple[int, int]]]:
    comps = tarjan_scc(nodes, edges)
    comp_sorted = sorted(comps, key=lambda c: (-len(c), sorted(c)[0] if c else ""))

    comp_index: Dict[str, int] = {}
    comp_rows: List[Dict[str, Any]] = []
    for idx, comp in enumerate(comp_sorted):
        members = sorted(comp)
        for m in members:
            comp_index[m] = idx
        label = f"C{idx}"
        title = members[0] if members else label
        if len(members) > 1:
            title = f"{title} +{len(members)-1}"
        comp_rows.append(
            {
                "id": idx,
                "label": label,
                "size": len(members),
                "title": title,
                "members": members,
            }
        )

    condensed_edges: Set[Tuple[int, int]] = set()
    for a, b in edges:
        ia = comp_index.get(a)
        ib = comp_index.get(b)
        if ia is None or ib is None or ia == ib:
            continue
        condensed_edges.add((ia, ib))

    return comp_rows, condensed_edges


def build_reality_collapsed_view(
    components: List[Dict[str, Any]],
    edges: List[Dict[str, int]],
) -> Dict[str, Any]:
    major_ids = [c["id"] for c in components if c["size"] > 1]
    singleton_ids = [c["id"] for c in components if c["size"] == 1]

    singleton_bucket = -1 if singleton_ids else None

    def bucket_of(comp_id: int) -> int:
        if comp_id in major_ids:
            return comp_id
        return singleton_bucket if singleton_bucket is not None else comp_id

    edge_counter: Counter[Tuple[int, int]] = Counter()
    for e in edges:
        a = bucket_of(e["src"])
        b = bucket_of(e["dst"])
        if a is None or b is None:
            continue
        edge_counter[(a, b)] += 1

    comp_by_id = {c["id"]: c for c in components}

    nodes: Dict[int, str] = {}
    for c in components:
        if c["id"] in major_ids:
            head = c["members"][0] if c.get("members") else c["title"]
            nodes[c["id"]] = f"{c['label']}:{short_module_name(head)}({c['size']})"
    if singleton_bucket is not None:
        nodes[singleton_bucket] = f"S*({len(singleton_ids)})"

    flows = [
        {
            "src": k[0],
            "dst": k[1],
            "count": v,
            "src_label": nodes.get(k[0], str(k[0])),
            "dst_label": nodes.get(k[1], str(k[1])),
        }
        for k, v in edge_counter.items()
    ]
    flows.sort(key=lambda x: (-x["count"], x["src_label"], x["dst_label"]))

    return {
        "nodes": [{"id": k, "label": v} for k, v in sorted(nodes.items(), key=lambda x: x[1])],
        "flows": flows,
        "major_components": [c for c in components if c["id"] in major_ids],
        "major_component_legend": [
            {
                "id": c["id"],
                "label": c["label"],
                "size": c["size"],
                "head": c["members"][0] if c.get("members") else c["title"],
            }
            for c in components
            if c["id"] in major_ids
        ],
        "singleton_count": len(singleton_ids),
        "singleton_bucket_id": singleton_bucket,
        "singleton_sample_heads": [
            comp_by_id[i]["members"][0] if comp_by_id[i].get("members") else comp_by_id[i]["title"]
            for i in singleton_ids[:10]
        ],
    }


def build_scan_payload(repo: Path, snapshot: str, strategy: Dict[str, Any], top_n: int) -> Dict[str, Any]:
    graph = load_snapshot_graph(repo, snapshot)
    comps = tarjan_scc(graph.nodes.keys(), graph.edges)
    cycles = sorted([sorted(c) for c in comps if len(c) > 1], key=lambda c: (-len(c), c[0]))

    group_rules = build_group_rules(strategy.get("groups", {}))
    group_cache: Dict[str, str] = {}
    grouped_counts: Dict[str, int] = {}

    for m in graph.nodes.keys():
        g = group_of(m, group_rules, group_cache)
        grouped_counts[g] = grouped_counts.get(g, 0) + 1

    edge_rows = [
        {
            "src": a,
            "dst": b,
            "src_group": group_of(a, group_rules, group_cache),
            "dst_group": group_of(b, group_rules, group_cache),
        }
        for a, b in sorted(graph.edges)
    ]
    policy_summary, policy_violations = classify_policy_violations(edge_rows)

    # ── Cycles: business-logic view ──────────────────────────────────
    def scc_severity(size: int) -> str:
        if size >= 10:
            return "critical"
        if size >= 3:
            return "warning"
        return "minor"

    cycle_entries = []
    for members in cycles:
        member_set = set(members)
        # Back-edges that are internal to this SCC
        internal_backs = [
            {"src": a, "dst": b}
            for a, b in back_edges(members, {(a, b) for a, b in graph.edges if a in member_set and b in member_set})
        ]
        # Members grouped by layer
        by_layer: Dict[str, List[str]] = {}
        for m in members:
            layer = group_of(m, group_rules, group_cache)
            by_layer.setdefault(layer, []).append(m)

        cycle_entries.append({
            "size": len(members),
            "severity": scc_severity(len(members)),
            "members": members,
            "members_by_layer": by_layer,
            # One concrete cycle path so an agent can trace the actual loop
            "example_cycle": find_cycle_in_scc(members, graph.edges),
            # Back-edges within this SCC (the edges that close the loops)
            "back_edges_in_scc": sorted(internal_backs, key=lambda e: (e["src"], e["dst"])),
        })

    # ── Policy violations: grouped by rule ───────────────────────────
    violations_by_rule: Dict[str, List[Dict[str, str]]] = {}
    for v in policy_violations:
        rule = v["rule"]
        violations_by_rule.setdefault(rule, [])
        violations_by_rule[rule].append({"src": v["src"], "dst": v["dst"]})

    violation_groups = [
        {
            "rule": rule,
            "count": len(edges),
            "edges": sorted(edges, key=lambda e: (e["src"], e["dst"])),
        }
        for rule, edges in sorted(violations_by_rule.items())
    ]

    # ── Health summary ────────────────────────────────────────────────
    total_violations = policy_summary.get("total_violations", 0)
    ungrouped = grouped_counts.get("ungrouped", 0)
    cycle_verdict = "critical" if cycles and len(cycles[0]) >= 10 else "warning" if cycles else "ok"
    violation_verdict = "critical" if total_violations >= 20 else "warning" if total_violations > 0 else "ok"

    return {
        "snapshot": snapshot,

        # One-glance health — agent should start here
        "health": {
            "cycles": {
                "count": len(cycles),
                "largest": len(cycles[0]) if cycles else 0,
                "verdict": cycle_verdict,
                # Cycles are always bad — they prevent clean layering and make
                # incremental builds, testing, and refactoring harder.
            },
            "violations": {
                "count": total_violations,
                "verdict": violation_verdict,
                # Violations mean the layer rules in topology.jsonc are broken.
                # They indicate real architectural debt, not just style issues.
            },
            "ungrouped": {
                "count": ungrouped,
                # If > 0, some modules are not covered by topology.jsonc —
                # their dependencies are invisible to policy checking.
            },
        },

        # Full cycle details — the most actionable architectural problem
        "cycles": cycle_entries,

        # Policy violations grouped by rule
        "violations": violation_groups,

        # Layer coverage — confirms all modules are classified
        "group_coverage": grouped_counts,

        # Internal: raw graph for HTML rendering (not included in --json output)
        "_graph": graph,
        "_sccs": comps,
    }


def build_diff_payload(repo: Path, from_snapshot: str, to_snapshot: str, strategy: Dict[str, Any]) -> Dict[str, Any]:
    # Run full scan on both snapshots
    from_scan = build_scan_payload(repo, from_snapshot, strategy, top_n=0)
    to_scan = build_scan_payload(repo, to_snapshot, strategy, top_n=0)

    # ── Health delta ──────────────────────────────────────────────────
    fh = from_scan["health"]
    th = to_scan["health"]

    health_comparison = {
        "cycles": {
            "count": {"from": fh["cycles"]["count"], "to": th["cycles"]["count"],
                      "delta": th["cycles"]["count"] - fh["cycles"]["count"]},
            "largest": {"from": fh["cycles"]["largest"], "to": th["cycles"]["largest"],
                        "delta": th["cycles"]["largest"] - fh["cycles"]["largest"]},
        },
        "violations": {
            "from": fh["violations"]["count"], "to": th["violations"]["count"],
            "delta": th["violations"]["count"] - fh["violations"]["count"],
        },
        "ungrouped": {
            "from": fh["ungrouped"]["count"], "to": th["ungrouped"]["count"],
            "delta": th["ungrouped"]["count"] - fh["ungrouped"]["count"],
        },
    }

    # ── Violation diff (edge-level) ───────────────────────────────────
    from_v_edges = {(e["src"], e["dst"]): rg["rule"] for rg in from_scan["violations"] for e in rg["edges"]}
    to_v_edges = {(e["src"], e["dst"]): rg["rule"] for rg in to_scan["violations"] for e in rg["edges"]}

    fixed = [{"rule": r, "src": s, "dst": d} for (s, d), r in sorted(from_v_edges.items()) if (s, d) not in to_v_edges]
    new = [{"rule": r, "src": s, "dst": d} for (s, d), r in sorted(to_v_edges.items()) if (s, d) not in from_v_edges]

    # ── SCC diff ──────────────────────────────────────────────────────
    from_scc_sets = [frozenset(c["members"]) for c in from_scan["cycles"]]
    to_scc_sets = [frozenset(c["members"]) for c in to_scan["cycles"]]

    # Match SCCs by overlap (largest intersection)
    scc_changes = []
    matched_to = set()
    for f_scc in from_scc_sets:
        best_match = None
        best_overlap = 0
        for i, t_scc in enumerate(to_scc_sets):
            if i in matched_to:
                continue
            overlap = len(f_scc & t_scc)
            if overlap > best_overlap:
                best_overlap = overlap
                best_match = i
        if best_match is not None and best_overlap > 0:
            matched_to.add(best_match)
            t_scc = to_scc_sets[best_match]
            gained = sorted(t_scc - f_scc)
            lost = sorted(f_scc - t_scc)
            if gained or lost:
                scc_changes.append({
                    "from_size": len(f_scc),
                    "to_size": len(t_scc),
                    "delta": len(t_scc) - len(f_scc),
                    "gained_members": gained,
                    "lost_members": lost,
                })
        else:
            scc_changes.append({
                "from_size": len(f_scc),
                "to_size": 0,
                "delta": -len(f_scc),
                "resolved": sorted(f_scc),
            })

    for i, t_scc in enumerate(to_scc_sets):
        if i not in matched_to:
            scc_changes.append({
                "from_size": 0,
                "to_size": len(t_scc),
                "delta": len(t_scc),
                "new_cycle": sorted(t_scc),
            })

    # ── Edge-level changes ────────────────────────────────────────────
    from_graph = load_snapshot_graph(repo, from_snapshot)
    to_graph = load_snapshot_graph(repo, to_snapshot)
    added_edges = sorted(set(to_graph.edges) - set(from_graph.edges))
    removed_edges = sorted(set(from_graph.edges) - set(to_graph.edges))

    return {
        "from_snapshot": from_snapshot,
        "to_snapshot": to_snapshot,

        "health_comparison": health_comparison,

        "violations_fixed": fixed,
        "violations_new": new,

        "scc_changes": scc_changes,

        "edge_changes": {
            "added": len(added_edges),
            "removed": len(removed_edges),
            "net": len(added_edges) - len(removed_edges),
        },
    }
