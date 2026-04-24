#!/usr/bin/env python3
"""Repository-local static Lua dependency graph helpers.

Mechanism only:
- Parse `require('opencode.*')` edges from `lua/opencode/**/*.lua`
- Build snapshot graph from worktree or git ref
- Provide SCC / back-edge utilities
"""

from __future__ import annotations

from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple


REQUIRE_PATTERNS = [
    re.compile(r"require\s*\(\s*['\"](opencode(?:\.[^'\"]+)?)['\"]\s*\)"),
    re.compile(r"require\s+['\"](opencode(?:\.[^'\"]+)?)['\"]"),
]


@dataclass
class SnapshotGraph:
    snapshot: str
    files: int
    nodes: Dict[str, str]  # module -> relative file path
    edges: Set[Tuple[str, str]]


def module_from_relpath(relpath: str) -> Optional[str]:
    if not relpath.startswith("lua/opencode/") or not relpath.endswith(".lua"):
        return None
    mod = relpath[len("lua/") : -len(".lua")]
    if mod.endswith("/init"):
        mod = mod[: -len("/init")]
    return mod.replace("/", ".")


def _worktree_files(repo: Path) -> List[Tuple[str, str]]:
    out: List[Tuple[str, str]] = []
    base = repo / "lua" / "opencode"
    for fp in base.rglob("*.lua"):
        rel = fp.relative_to(repo).as_posix()
        text = fp.read_text(encoding="utf-8", errors="ignore")
        out.append((rel, text))
    return out


def _git_files(repo: Path, ref: str) -> List[Tuple[str, str]]:
    cmd = ["git", "ls-tree", "-r", "--name-only", ref, "lua/opencode"]
    try:
        ls = subprocess.check_output(cmd, cwd=repo, text=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.strip() if e.stderr else ""
        raise ValueError(
            f"Invalid snapshot ref '{ref}'. Valid values: HEAD, worktree, branch name, commit SHA.\n"
            f"git error: {stderr}"
        ) from None

    out: List[Tuple[str, str]] = []
    for rel in ls.splitlines():
        if not rel.endswith(".lua"):
            continue
        show_cmd = ["git", "show", f"{ref}:{rel}"]
        try:
            text = subprocess.check_output(show_cmd, cwd=repo, text=True, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            continue
        out.append((rel, text))
    return out


def load_snapshot_graph(repo: Path, snapshot: str) -> SnapshotGraph:
    files = _worktree_files(repo) if snapshot == "worktree" else _git_files(repo, snapshot)

    nodes: Dict[str, str] = {}
    for rel, _ in files:
        module = module_from_relpath(rel)
        if module:
            nodes[module] = rel

    edges: Set[Tuple[str, str]] = set()
    for rel, content in files:
        src = module_from_relpath(rel)
        if not src:
            continue

        deps: Set[str] = set()
        for pat in REQUIRE_PATTERNS:
            deps.update(m.group(1) for m in pat.finditer(content))

        for dep in deps:
            if dep in nodes:
                edges.add((src, dep))

    return SnapshotGraph(snapshot=snapshot, files=len(files), nodes=nodes, edges=edges)


def tarjan_scc(nodes: Iterable[str], edges: Iterable[Tuple[str, str]]) -> List[List[str]]:
    graph: Dict[str, List[str]] = defaultdict(list)
    for a, b in edges:
        graph[a].append(b)

    index = 0
    stack: List[str] = []
    on_stack: Set[str] = set()
    indices: Dict[str, int] = {}
    lowlink: Dict[str, int] = {}
    result: List[List[str]] = []

    def strongconnect(v: str) -> None:
        nonlocal index
        indices[v] = index
        lowlink[v] = index
        index += 1
        stack.append(v)
        on_stack.add(v)

        for w in graph[v]:
            if w not in indices:
                strongconnect(w)
                lowlink[v] = min(lowlink[v], lowlink[w])
            elif w in on_stack:
                lowlink[v] = min(lowlink[v], indices[w])

        if lowlink[v] == indices[v]:
            comp: List[str] = []
            while True:
                w = stack.pop()
                on_stack.remove(w)
                comp.append(w)
                if w == v:
                    break
            result.append(comp)

    for n in sorted(set(nodes)):
        if n not in indices:
            strongconnect(n)

    return result


def back_edges(nodes: Iterable[str], edges: Iterable[Tuple[str, str]]) -> Set[Tuple[str, str]]:
    graph: Dict[str, List[str]] = defaultdict(list)
    for a, b in edges:
        graph[a].append(b)
    for n in graph:
        graph[n] = sorted(set(graph[n]))

    white, gray, black = 0, 1, 2
    color: Dict[str, int] = {n: white for n in set(nodes)}
    backs: Set[Tuple[str, str]] = set()

    def dfs(v: str) -> None:
        color[v] = gray
        for w in graph[v]:
            c = color.get(w, white)
            if c == white:
                dfs(w)
            elif c == gray:
                backs.add((v, w))
        color[v] = black

    for n in sorted(color.keys()):
        if color[n] == white:
            dfs(n)

    return backs


def degree(edges: Iterable[Tuple[str, str]]) -> Tuple[Counter, Counter]:
    indeg: Counter = Counter()
    outdeg: Counter = Counter()
    for src, dst in edges:
        outdeg[src] += 1
        indeg[dst] += 1
    return indeg, outdeg


def find_cycle_in_scc(members: List[str], edges: Iterable[Tuple[str, str]]) -> List[str]:
    """Return one concrete cycle path within an SCC, e.g. [a, b, c, a].

    Uses DFS from the first member; backtracks until a back-edge is found.
    Returns [] if no cycle is found (shouldn't happen for a real SCC > 1).
    """
    member_set = set(members)
    graph: Dict[str, List[str]] = defaultdict(list)
    for a, b in edges:
        if a in member_set and b in member_set:
            graph[a].append(b)
    for n in graph:
        graph[n] = sorted(set(graph[n]))

    path: List[str] = []
    on_path: Dict[str, int] = {}  # node -> index in path
    visited: Set[str] = set()

    def dfs(v: str) -> List[str]:
        path.append(v)
        on_path[v] = len(path) - 1
        for w in graph[v]:
            if w in on_path:
                # Found cycle: extract from w's position to end, close it
                return path[on_path[w]:] + [w]
            if w not in visited:
                visited.add(w)
                result = dfs(w)
                if result:
                    return result
        path.pop()
        del on_path[v]
        return []

    start = sorted(members)[0]
    visited.add(start)
    return dfs(start)


def largest_scc_size(comps: Sequence[Sequence[str]]) -> int:
    nontrivial = [c for c in comps if len(c) > 1]
    return max((len(c) for c in nontrivial), default=0)
