"""HTML visualization renderer v2 for dependency topology.

Features:
- Full node names (no truncation)
- Compact TB layout
- Cluster collapse/expand on click
- Violation coloring (red edges for policy violations)
"""

from dataclasses import dataclass, field
from typing import List, Dict, Set, Tuple, Any
import json
import fnmatch

from scan_analysis import edge_rule as _edge_rule_impl


@dataclass
class ClusterNode:
    id: str
    is_cluster: bool
    children: List[str] = field(default_factory=list)
    in_degree: int = 0
    out_degree: int = 0
    in_scc: bool = False


@dataclass
class ClusterEdge:
    src: str
    dst: str
    weight: int = 1
    is_violation: bool = False
    rule: str = ""


def match_group(module: str, groups: Dict[str, Any]) -> str:
    """Match module to group using fnmatch patterns."""
    for group_name, group_data in groups.items():
        patterns = group_data.get("modules", [])
        for pattern in patterns:
            if fnmatch.fnmatch(module, pattern):
                return group_name
    return "ungrouped"


def _edge_rule(src_group: str, dst_group: str) -> str:
    """Thin wrapper: normalise scan_analysis.edge_rule None -> empty string."""
    return _edge_rule_impl(src_group, dst_group) or ""


def auto_cluster_graph(
    nodes: List[str],
    edges: List[Tuple[str, str]],
    scc_nodes: Set[str],
    groups: Dict[str, Any],
    depth: int = 2
) -> Tuple[List[ClusterNode], List[ClusterEdge]]:
    """Cluster nodes by namespace prefix at given depth."""
    # Build prefix → children mapping
    prefix_children: Dict[str, List[str]] = {}
    node_to_cluster: Dict[str, str] = {}
    
    for node in nodes:
        parts = node.split('.')
        if len(parts) > depth:
            prefix = '.'.join(parts[:depth]) + '.*'
        else:
            prefix = node
        
        if prefix not in prefix_children:
            prefix_children[prefix] = []
        prefix_children[prefix].append(node)
        node_to_cluster[node] = prefix
    
    # Build cluster nodes
    cluster_nodes: Dict[str, ClusterNode] = {}
    for prefix, children in prefix_children.items():
        is_cluster = prefix.endswith('.*')
        in_scc = any(c in scc_nodes for c in children)
        cluster_nodes[prefix] = ClusterNode(
            id=prefix,
            is_cluster=is_cluster,
            children=sorted(children) if is_cluster else [],
            in_scc=in_scc
        )
    
    # Build cluster edges with violation detection
    edge_counts: Dict[Tuple[str, str], Tuple[int, bool, str]] = {}
    for src, dst in edges:
        csrc = node_to_cluster.get(src, src)
        cdst = node_to_cluster.get(dst, dst)
        if csrc != cdst:
            key = (csrc, cdst)
            # Check violation on original edge
            src_grp = match_group(src, groups)
            dst_grp = match_group(dst, groups)
            rule = _edge_rule(src_grp, dst_grp)
            
            if key not in edge_counts:
                edge_counts[key] = (0, False, "")
            cnt, is_vio, existing_rule = edge_counts[key]
            edge_counts[key] = (cnt + 1, is_vio or bool(rule), existing_rule or rule)
    
    cluster_edges = [
        ClusterEdge(k[0], k[1], v[0], v[1], v[2]) 
        for k, v in edge_counts.items()
    ]
    
    # Compute degrees
    for e in cluster_edges:
        if e.src in cluster_nodes:
            cluster_nodes[e.src].out_degree += 1
        if e.dst in cluster_nodes:
            cluster_nodes[e.dst].in_degree += 1
    
    return list(cluster_nodes.values()), cluster_edges


def render_html(payload: dict, groups: Dict[str, Any], cluster_depth: int = 2) -> str:
    """Render interactive HTML visualization."""
    node_list = payload.get('node_list', [])
    edge_list = payload.get('edge_list', [])
    sccs = payload.get('sccs', [])
    
    # Flatten SCC nodes
    scc_nodes: Set[str] = set()
    for scc in sccs:
        if len(scc) > 1:
            scc_nodes.update(scc)
    
    # Auto-cluster with violation detection
    cluster_nodes, cluster_edges = auto_cluster_graph(
        node_list, edge_list, scc_nodes, groups, depth=cluster_depth
    )
    
    # Build GRAPH data
    graph_data = {
        'nodes': [
            {
                'id': n.id,
                'isCluster': n.is_cluster,
                'children': n.children,
                'inDegree': n.in_degree,
                'outDegree': n.out_degree,
                'inScc': n.in_scc
            }
            for n in cluster_nodes
        ],
        'edges': [
            {
                'src': e.src, 
                'dst': e.dst, 
                'weight': e.weight,
                'isViolation': e.is_violation,
                'rule': e.rule
            }
            for e in cluster_edges
        ]
    }
    
    # Build METRICS
    violation_count = sum(1 for e in cluster_edges if e.is_violation)
    
    # Compute degree stats from original edges
    in_deg: Dict[str, int] = {}
    out_deg: Dict[str, int] = {}
    for src, dst in edge_list:
        out_deg[src] = out_deg.get(src, 0) + 1
        in_deg[dst] = in_deg.get(dst, 0) + 1
    
    # Top hubs/spreaders
    top_in = sorted([(k, v) for k, v in in_deg.items()], key=lambda x: -x[1])[:5]
    top_out = sorted([(k, v) for k, v in out_deg.items()], key=lambda x: -x[1])[:5]
    
    avg_degree = len(edge_list) * 2 / len(node_list) if node_list else 0
    max_in = top_in[0][1] if top_in else 0
    max_out = top_out[0][1] if top_out else 0
    
    metrics = {
        'total_modules': len(node_list),
        'total_edges': len(edge_list),
        'clusters': sum(1 for n in cluster_nodes if n.is_cluster),
        'leaves': sum(1 for n in cluster_nodes if not n.is_cluster),
        'scc_count': len([s for s in sccs if len(s) > 1]),
        'largest_scc': max((len(s) for s in sccs), default=0),
        'violations': violation_count,
        'avg_degree': round(avg_degree, 2),
        'max_in_degree': max_in,
        'max_out_degree': max_out,
        'top_in_degree': [{'id': k, 'degree': v} for k, v in top_in],
        'top_out_degree': [{'id': k, 'degree': v} for k, v in top_out]
    }
    
    # Generate HTML
    html = HTML_TEMPLATE.replace('__GRAPH_DATA__', json.dumps(graph_data, indent=2))
    html = html.replace('__METRICS_DATA__', json.dumps(metrics, indent=2))
    
    return html


HTML_TEMPLATE = '''<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>Dependency Topology</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/d3/5.16.0/d3.min.js"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/dagre-d3/0.6.4/dagre-d3.min.js"></script>
  <style>
    :root {
      --bg: #0d1117; --bg2: #161b22; --bg3: #21262d; --border: #30363d;
      --text: #c9d1d9; --text2: #8b949e; --accent: #58a6ff; --warn: #f0883e; --danger: #f85149; --success: #3fb950;
    }
    body.light {
      --bg: #ffffff; --bg2: #f6f8fa; --bg3: #eaeef2; --border: #d0d7de;
      --text: #1f2328; --text2: #656d76; --accent: #0969da; --warn: #bf8700; --danger: #cf222e; --success: #1a7f37;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body { height: 100%; overflow: hidden; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: var(--bg); color: var(--text); display: flex; }
    
    .sidebar { width: 280px; background: var(--bg2); padding: 16px; overflow-y: auto; border-right: 1px solid var(--border); }
    .sidebar h1 { font-size: 16px; margin-bottom: 12px; color: var(--accent); display: flex; align-items: center; gap: 8px; }
    
    .header-row { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
    .theme-toggle { background: var(--bg3); border: 1px solid var(--border); padding: 4px 8px; border-radius: 4px; cursor: pointer; font-size: 12px; color: var(--text); }
    
    .metric-row { display: flex; gap: 6px; margin-bottom: 6px; }
    .metric-card { flex: 1; background: var(--bg3); border-radius: 6px; padding: 10px 8px; text-align: center; }
    .metric-card .value { font-size: 20px; font-weight: 600; color: var(--accent); }
    .metric-card .label { font-size: 10px; color: var(--text2); text-transform: uppercase; margin-top: 2px; }
    .metric-card.warn .value { color: var(--warn); }
    .metric-card.danger .value { color: var(--danger); }
    
    .section { margin-top: 16px; border-top: 1px solid var(--border); padding-top: 12px; }
    .section-title { font-size: 11px; font-weight: 600; color: var(--text2); text-transform: uppercase; margin-bottom: 8px; }
    .stat-row { display: flex; justify-content: space-between; font-size: 12px; padding: 4px 0; border-bottom: 1px solid var(--border); }
    .stat-row:last-child { border-bottom: none; }
    .stat-label { color: var(--text2); }
    .stat-value { color: var(--text); font-weight: 500; }
    .stat-value.accent { color: var(--accent); }
    .stat-value.warn { color: var(--warn); }
    .stat-value.danger { color: var(--danger); }
    
    .search-box { margin: 12px 0; }
    .search-box input { width: 100%; padding: 8px 10px; background: var(--bg3); border: 1px solid var(--border); border-radius: 6px; color: var(--text); font-size: 13px; }
    .search-box input:focus { outline: none; border-color: var(--accent); }
    
    .legend { margin-top: 12px; font-size: 11px; }
    .legend-item { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
    .legend-color { width: 16px; height: 16px; border-radius: 3px; }
    .legend-color.cluster { background: var(--bg3); border: 2px solid var(--accent); }
    .legend-color.leaf { background: var(--bg3); border: 2px solid var(--border); }
    .legend-color.scc { background: var(--bg3); border: 2px solid var(--danger); }
    .legend-color.violation { background: var(--danger); width: 20px; height: 3px; border-radius: 1px; }
    
    .graph-container { flex: 1; position: relative; overflow: hidden; background: var(--bg); }
    svg { width: 100%; height: 100%; }
    
    .node rect { fill: var(--bg3); stroke: var(--border); stroke-width: 1.5px; }
    .node.cluster rect { fill: var(--bg2); stroke: var(--accent); stroke-width: 2px; cursor: pointer; }
    .node.scc rect { stroke: var(--danger); stroke-width: 2.5px; }
    .node.highlighted rect { stroke: var(--success); stroke-width: 2.5px; }
    .node.dimmed { opacity: 0.25; }
    .node.search-match rect { fill: #238636; }
    .node.expanded rect { fill: #1a2233; stroke: #79c0ff; }
    body.light .node.expanded rect { fill: #ddf4ff; stroke: #0969da; }
    .node text { fill: var(--text); font-size: 11px; font-weight: 500; }
    
    .edgePath path { stroke: var(--border); stroke-width: 1.2px; fill: none; }
    .edgePath.violation path { stroke: var(--danger); stroke-width: 2px; }
    .edgePath.highlighted path { stroke: var(--warn); stroke-width: 2px; }
    .edgePath.dimmed { opacity: 0.1; }
    
    .controls { position: absolute; top: 10px; right: 10px; display: flex; gap: 6px; }
    .controls button { padding: 5px 10px; background: var(--bg3); border: 1px solid var(--border); color: var(--text); border-radius: 6px; cursor: pointer; font-size: 12px; }
    .controls button:hover { background: var(--border); }
    
    #tooltip { position: absolute; background: var(--bg2); border: 1px solid var(--border); padding: 10px; border-radius: 6px; pointer-events: none; opacity: 0; max-width: 320px; font-size: 11px; z-index: 100; line-height: 1.5; }
    #tooltip strong { color: var(--accent); }
    #tooltip .children { color: var(--text2); margin-top: 6px; max-height: 120px; overflow-y: auto; }
  </style>
</head>
<body>
  <div class="sidebar">
    <div class="header-row">
      <h1>📊 Topology</h1>
      <button class="theme-toggle" id="theme-toggle">☀️ Light</button>
    </div>
    <div class="metric-row">
      <div class="metric-card"><div class="value" id="m-modules">-</div><div class="label">Modules</div></div>
      <div class="metric-card"><div class="value" id="m-edges">-</div><div class="label">Edges</div></div>
    </div>
    <div class="metric-row">
      <div class="metric-card"><div class="value" id="m-clusters">-</div><div class="label">Clusters</div></div>
      <div class="metric-card"><div class="value" id="m-leaves">-</div><div class="label">Leaves</div></div>
    </div>
    <div class="metric-row">
      <div class="metric-card warn"><div class="value" id="m-scc">-</div><div class="label">SCCs</div></div>
      <div class="metric-card danger"><div class="value" id="m-violations">-</div><div class="label">Violations</div></div>
    </div>
    
    <div class="section">
      <div class="section-title">Graph Structure</div>
      <div class="stat-row"><span class="stat-label">Largest SCC</span><span class="stat-value warn" id="s-largest">-</span></div>
      <div class="stat-row"><span class="stat-label">Avg Degree</span><span class="stat-value" id="s-avgdeg">-</span></div>
      <div class="stat-row"><span class="stat-label">Max In-Degree</span><span class="stat-value accent" id="s-maxin">-</span></div>
      <div class="stat-row"><span class="stat-label">Max Out-Degree</span><span class="stat-value accent" id="s-maxout">-</span></div>
    </div>
    
    <div class="section">
      <div class="section-title">Top Hubs (In-Degree)</div>
      <div id="top-hubs"></div>
    </div>
    
    <div class="section">
      <div class="section-title">Top Spreaders (Out-Degree)</div>
      <div id="top-spreaders"></div>
    </div>
    
    <div class="search-box">
      <input type="text" id="search" placeholder="Search modules...">
    </div>
    <div class="legend">
      <div class="legend-item"><div class="legend-color cluster"></div>Cluster (click to expand)</div>
      <div class="legend-item"><div class="legend-color leaf"></div>Leaf module (click to highlight)</div>
      <div class="legend-item" style="font-size:10px;color:var(--text2);padding-left:24px;">Click any expanded child to collapse</div>
      <div class="legend-item"><div class="legend-color scc"></div>In SCC (cycle)</div>
      <div class="legend-item"><div class="legend-color violation"></div>Policy violation</div>
    </div>
  </div>
  <div class="graph-container">
    <svg id="graph"><g></g></svg>
    <div class="controls">
      <button id="btn-fit">Fit</button>
      <button id="btn-reset">Reset</button>
      <button id="btn-collapse">Collapse All</button>
    </div>
    <div id="tooltip"></div>
  </div>
<script>
const GRAPH = __GRAPH_DATA__;
const METRICS = __METRICS_DATA__;

// State
let expandedClusters = new Set();
let currentNodes = [];
let currentEdges = [];

// Populate metrics
document.getElementById('m-modules').textContent = METRICS.total_modules;
document.getElementById('m-edges').textContent = METRICS.total_edges;
document.getElementById('m-clusters').textContent = METRICS.clusters;
document.getElementById('m-leaves').textContent = METRICS.leaves;
document.getElementById('m-scc').textContent = METRICS.scc_count;
document.getElementById('m-violations').textContent = METRICS.violations;
document.getElementById('s-largest').textContent = METRICS.largest_scc;
document.getElementById('s-avgdeg').textContent = METRICS.avg_degree ? METRICS.avg_degree.toFixed(1) : '-';
document.getElementById('s-maxin').textContent = METRICS.max_in_degree || '-';
document.getElementById('s-maxout').textContent = METRICS.max_out_degree || '-';

// Top hubs/spreaders
function renderTopList(containerId, items) {
  const el = document.getElementById(containerId);
  if (!items || items.length === 0) { el.innerHTML = '<div class="stat-row"><span class="stat-label">-</span></div>'; return; }
  el.innerHTML = items.slice(0, 5).map(x => 
    '<div class="stat-row"><span class="stat-label">' + x.id.split('.').slice(-2).join('.') + '</span><span class="stat-value">' + x.degree + '</span></div>'
  ).join('');
}
renderTopList('top-hubs', METRICS.top_in_degree);
renderTopList('top-spreaders', METRICS.top_out_degree);

// Theme toggle
document.getElementById('theme-toggle').onclick = function() {
  document.body.classList.toggle('light');
  this.textContent = document.body.classList.contains('light') ? '🌙 Dark' : '☀️ Light';
};

const svg = d3.select('#graph');
const inner = svg.select('g');
const zoom = d3.zoom().scaleExtent([0.1, 4]).on('zoom', function() {
  inner.attr('transform', d3.event.transform);
});
svg.call(zoom);

const nodeMap = {};
GRAPH.nodes.forEach(n => { nodeMap[n.id] = n; });

// Build edge lookup for violation check
const edgeViolations = {};
GRAPH.edges.forEach(e => {
  edgeViolations[e.src + '|' + e.dst] = { isViolation: e.isViolation, rule: e.rule };
});

function buildGraph() {
  currentNodes = [];
  currentEdges = [];
  
  // Determine visible nodes
  const visibleNodes = new Set();
  GRAPH.nodes.forEach(n => {
    if (n.isCluster && expandedClusters.has(n.id)) {
      // Show children instead
      n.children.forEach(c => visibleNodes.add(c));
    } else if (n.isCluster) {
      visibleNodes.add(n.id);
    } else {
      // Leaf: check if parent cluster is expanded
      let parentCluster = null;
      for (const [cid, cnode] of Object.entries(nodeMap)) {
        if (cnode.isCluster && cnode.children.includes(n.id)) {
          parentCluster = cid;
          break;
        }
      }
      if (!parentCluster || expandedClusters.has(parentCluster)) {
        visibleNodes.add(n.id);
      }
    }
  });
  
  // Add expanded children as nodes
  expandedClusters.forEach(cid => {
    const cn = nodeMap[cid];
    if (cn && cn.children) {
      cn.children.forEach(c => {
        currentNodes.push({
          id: c,
          isCluster: false,
          inScc: cn.inScc,
          inDegree: 0,
          outDegree: 0,
          parentCluster: cid
        });
      });
    }
  });
  
  // Add non-expanded clusters and leaves
  GRAPH.nodes.forEach(n => {
    if (visibleNodes.has(n.id) && !currentNodes.find(x => x.id === n.id)) {
      currentNodes.push({
        id: n.id,
        isCluster: n.isCluster,
        inScc: n.inScc,
        inDegree: n.inDegree,
        outDegree: n.outDegree,
        children: n.children,
        expanded: expandedClusters.has(n.id)
      });
    }
  });
  
  // Build edges between visible nodes
  const nodeIdSet = new Set(currentNodes.map(n => n.id));
  
  // Use original edges, map to visible nodes
  GRAPH.edges.forEach(e => {
    let src = e.src, dst = e.dst;
    // If src/dst is expanded cluster, need to find which child
    // For simplicity, show edge if both endpoints visible or map to cluster
    if (nodeIdSet.has(src) && nodeIdSet.has(dst)) {
      currentEdges.push({ src, dst, isViolation: e.isViolation, rule: e.rule });
    }
  });
  
  renderGraph();
}

function renderGraph() {
  inner.selectAll('*').remove();
  
  const g = new dagreD3.graphlib.Graph().setGraph({
    rankdir: 'TB', ranksep: 80, nodesep: 20, marginx: 20, marginy: 20
  });
  
  currentNodes.forEach(n => {
    const label = n.id;
    const cls = (n.isCluster ? 'cluster' : 'leaf') + 
                (n.inScc ? ' scc' : '') + 
                (n.expanded ? ' expanded' : '');
    g.setNode(n.id, {
      label: label,
      class: cls,
      rx: n.isCluster ? 8 : 4,
      ry: n.isCluster ? 8 : 4,
      width: Math.max(80, label.length * 7),
      height: 32
    });
  });
  
  currentEdges.forEach(e => {
    g.setEdge(e.src, e.dst, { 
      arrowhead: 'vee',
      class: e.isViolation ? 'violation' : ''
    });
  });
  
  const render = new dagreD3.render();
  render(inner, g);
  
  // Mark violation edges
  inner.selectAll('.edgePath').each(function(d) {
    const key = d.v + '|' + d.w;
    const info = edgeViolations[key];
    if (info && info.isViolation) {
      d3.select(this).classed('violation', true);
    }
  });
  
  setupInteractions();
  setTimeout(fitToScreen, 50);
}

function setupInteractions() {
  const tooltip = document.getElementById('tooltip');
  
  // Node click - expand/collapse or highlight
  inner.selectAll('.node').on('click', function(nodeId) {
    const n = nodeMap[nodeId] || currentNodes.find(x => x.id === nodeId);

    // If this is an expanded child, clicking it collapses its parent cluster
    if (n && n.parentCluster) {
      expandedClusters.delete(n.parentCluster);
      buildGraph();
      return;
    }

    // If cluster, toggle expand
    if (n && n.isCluster) {
      if (expandedClusters.has(nodeId)) {
        expandedClusters.delete(nodeId);
      } else {
        expandedClusters.add(nodeId);
      }
      buildGraph();
      return;
    }
    
    // Otherwise highlight
    const isSelected = d3.select(this).classed('highlighted');
    inner.selectAll('.node').classed('highlighted', false).classed('dimmed', false);
    inner.selectAll('.edgePath').classed('highlighted', false).classed('dimmed', false);
    
    if (isSelected) return;
    
    d3.select(this).classed('highlighted', true);
    const connected = new Set([nodeId]);
    
    currentEdges.forEach(e => {
      if (e.src === nodeId || e.dst === nodeId) {
        connected.add(e.src);
        connected.add(e.dst);
      }
    });
    
    inner.selectAll('.node').each(function(nid) {
      if (!connected.has(nid)) d3.select(this).classed('dimmed', true);
    });
    inner.selectAll('.edgePath').each(function(d) {
      if (connected.has(d.v) && connected.has(d.w) && (d.v === nodeId || d.w === nodeId)) {
        d3.select(this).classed('highlighted', true);
      } else {
        d3.select(this).classed('dimmed', true);
      }
    });
  });
  
  // Hover
  inner.selectAll('.node')
    .on('mouseenter', function(nodeId) {
      const n = nodeMap[nodeId] || currentNodes.find(x => x.id === nodeId);
      if (!n) return;
      let html = '<strong>' + nodeId + '</strong><br>In: ' + (n.inDegree||0) + ' | Out: ' + (n.outDegree||0);
      if (n.inScc) html += '<br><span style="color:#f85149">⚠ In SCC (cycle)</span>';
      if (n.isCluster && n.children && n.children.length > 0) {
        html += '<div class="children"><b>Children (' + n.children.length + '):</b><br>' + n.children.join('<br>') + '</div>';
      }
      tooltip.innerHTML = html;
      tooltip.style.opacity = 1;
    })
    .on('mousemove', function() {
      tooltip.style.left = (d3.event.pageX + 12) + 'px';
      tooltip.style.top = (d3.event.pageY + 12) + 'px';
    })
    .on('mouseleave', function() { tooltip.style.opacity = 0; });
}

function fitToScreen() {
  const bounds = inner.node().getBBox();
  const parent = svg.node().parentElement;
  const pw = parent.clientWidth, ph = parent.clientHeight;
  if (bounds.width === 0 || bounds.height === 0) return;
  const scale = Math.min(0.95 * pw / bounds.width, 0.95 * ph / bounds.height, 1.2);
  const tx = (pw - bounds.width * scale) / 2 - bounds.x * scale;
  const ty = (ph - bounds.height * scale) / 2 - bounds.y * scale;
  svg.transition().duration(400).call(zoom.transform, d3.zoomIdentity.translate(tx, ty).scale(scale));
}

document.getElementById('btn-fit').onclick = fitToScreen;
document.getElementById('btn-reset').onclick = function() {
  svg.transition().call(zoom.transform, d3.zoomIdentity);
};
document.getElementById('btn-collapse').onclick = function() {
  expandedClusters.clear();
  buildGraph();
};

// Search
document.getElementById('search').addEventListener('input', function(e) {
  const q = e.target.value.toLowerCase();
  inner.selectAll('.node').classed('search-match', false);
  if (q.length < 2) return;
  inner.selectAll('.node').each(function(nodeId) {
    if (nodeId.toLowerCase().includes(q)) {
      d3.select(this).classed('search-match', true);
    }
  });
});

// Initial render
buildGraph();
</script>
</body>
</html>
'''
