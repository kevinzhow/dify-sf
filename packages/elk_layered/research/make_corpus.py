"""Construct Dify's flat root/child ELK inputs, preserving its port/DFS quirks."""
import argparse
from functools import cmp_to_key
import json
from pathlib import Path
import random
import re
import yaml

parser = argparse.ArgumentParser()
parser.add_argument('--dify-source', type=Path, required=True)
parser.add_argument('--fixtures', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--audit', type=Path)
args = parser.parse_args()
source = (args.dify_source / 'web/app/components/workflow/utils/elk-layout.ts').read_text()
options = {}
audit = []
for name in ('ROOT', 'CHILD'):
    body = re.search(r'const ' + name + r'_LAYOUT_OPTIONS = \{(.*?)\n\}', source, re.S)[1]
    options[name] = dict(re.findall(r"'([^']+)': '([^']*)'", body))


def build(nodes, edges, mode='ROOT'):
    by_node = {}
    for edge in edges:
        by_node.setdefault(edge['source'], []).append(edge)
    children, source_ports, outgoing = [], {}, {}
    for n in nodes:
        out = list(by_node.get(n['id'], []))
        data = n.get('data', {})
        kind = data.get('type')
        if kind in ('if-else', 'question-classifier', 'human-input'):
            entries = data.get({'if-else':'cases', 'question-classifier':'classes', 'human-input':'user_actions'}[kind], [])
            key = 'case_id' if kind == 'if-else' else 'id'
            order = [entry.get(key) for entry in entries]
            last = {'if-else':'false', 'human-input':'__timeout'}.get(kind)
            def cmp(a, b):
                x, y = a.get('sourceHandle'), b.get('sourceHandle')
                if not x or not y:
                    return 0
                if last and x == last:
                    return 1
                if last and y == last:
                    return -1
                return order.index(x) - order.index(y) if x in order and y in order else 0
            out.sort(key=cmp_to_key(cmp))
        outgoing[n['id']] = out
        ports = []
        for i, e in enumerate(out):
            port = f"{n['id']}-out-{e.get('sourceHandle') or i}"
            source_ports[e['id']] = port
            ports.append({'id': port, 'layoutOptions': {'elk.port.side': 'EAST', 'elk.port.index': str(i)}})
        child = {'id': n['id'], 'width': n.get('width', 244), 'height': n.get('height', 100)}
        if ports:
            child.update(ports=ports, layoutOptions={'elk.portConstraints': 'FIXED_ORDER'})
        children.append(child)
    node_ids = {n['id'] for n in nodes}
    visited, ordered = set(), []
    def dfs(n):
        if n in visited or n not in node_ids:
            return
        visited.add(n)
        ordered.append(n)
        for e in outgoing.get(n, []):
            dfs(e['target'])
    for n in nodes:
        if not any(e['target'] == n['id'] for e in edges):
            dfs(n['id'])
    for n in nodes:
        dfs(n['id'])
    children.sort(key=lambda n: ordered.index(n['id']))
    ordered_edges = []
    for n in ordered:
        for e in outgoing.get(n, []):
            ordered_edges.append({'id': f'elk-edge-{len(ordered_edges)}', 'sources': [e['source']],
                                  'targets': [e['target']], 'sourcePort': source_ports[e['id']]})
    graph = {'id': 'workflow-root', 'layoutOptions': options[mode], 'children': children, 'edges': ordered_edges}
    audit.append({'nodes': nodes, 'edges': edges, 'graph': graph})
    return graph


corpus = []
for path in sorted(args.fixtures.glob('*.yml')):
    doc = yaml.safe_load(path.read_text())
    graph = doc['workflow']['graph']
    ns, es = graph['nodes'], graph['edges']
    root_nodes = [n for n in ns if not n.get('parentId') and n.get('type') == 'custom']
    root_edges = [e for e in es if not e.get('data', {}).get('isInIteration') and not e.get('data', {}).get('isInLoop')]
    corpus.append({'id': f'sample/{path.stem}/root', 'graph': build(root_nodes, root_edges)})
    for parent in sorted({n['parentId'] for n in ns if n.get('parentId')}):
        cn = [n for n in ns if n.get('parentId') == parent]
        ce = [e for e in es if (e.get('data', {}).get('isInIteration') and e['data'].get('iteration_id') == parent)
              or (e.get('data', {}).get('isInLoop') and e['data'].get('loop_id') == parent)]
        corpus.append({'id': f'sample/{path.stem}/child/{parent}', 'graph': build(cn, ce, 'CHILD')})

# Separate simple named examples make changed relative coordinates easy to inspect.
for mode in ('ROOT', 'CHILD'):
    for kind in ('chain', 'diamond', 'cycle', 'disconnected', 'multiport'):
        ns = [{'id': f'n{i}', 'type': 'custom', 'data': {'type': 'code'}, 'width': 244, 'height': 100} for i in range(4)]
        pairs = {'chain': [(0,1),(1,2),(2,3)], 'diamond': [(0,1),(0,2),(1,3),(2,3)],
                 'cycle': [(0,1),(1,2),(2,0),(2,3)], 'disconnected': [(0,1)],
                 'multiport': [(0,1),(0,2),(0,3)]}[kind]
        es = [{'id': f'e{i}', 'source': f'n{a}', 'target': f'n{b}', 'sourceHandle': f'branch{i}'} for i,(a,b) in enumerate(pairs)]
        corpus.append({'id': f'basic/{mode.lower()}/{kind}', 'graph': build(ns, es, mode)})

for seed in range(100):
    rng = random.Random(seed)
    count = rng.randrange(4, 17)
    ns = [{'id': f'n{i}', 'type': 'custom', 'data': {'type': 'code'},
           'width': rng.choice((100, 244, 300)), 'height': rng.choice((48, 80, 100, 160))} for i in range(count)]
    pairs = [(a,b) for a in range(count) for b in range(a+1,count) if rng.random() < .19]
    if seed % 3 == 0:
        pairs += [(count-1,0)]
    es = [{'id': f'e{i}', 'source': f'n{a}', 'target': f'n{b}', 'sourceHandle': f'branch{i}'} for i,(a,b) in enumerate(pairs)]
    mode = 'CHILD' if seed % 2 else 'ROOT'
    corpus.append({'id': f'random/{seed}', 'graph': build(ns, es, mode)})
args.output.write_text(json.dumps(corpus, indent=2) + '\n')
if args.audit:
    args.audit.write_text(json.dumps(audit) + '\n')
print(f'Wrote {len(corpus)} graphs')
