"""Graph builders for the repro workflows (plain Dify DSL graph JSON)."""

def start_node(nid="start", x=80, y=200):
    return {"id": nid, "type": "custom", "position": {"x": x, "y": y}, "positionAbsolute": {"x": x, "y": y},
            "width": 244, "height": 90, "sourcePosition": "right", "targetPosition": "left",
            "data": {"type": "start", "title": "Start", "desc": "", "variables": [
                {"variable": "q", "label": "q", "type": "text-input", "required": False, "max_length": 48, "options": []}]}}

def code_node(nid, title, x, y, desc="", src=("start", "q")):
    return {"id": nid, "type": "custom", "position": {"x": x, "y": y}, "positionAbsolute": {"x": x, "y": y},
            "width": 244, "height": 54, "sourcePosition": "right", "targetPosition": "left",
            "data": {"type": "code", "title": title, "desc": desc, "code_language": "python3",
                     "code": "def main(a: str) -> dict:\n    return {'result': a}\n",
                     "variables": [{"variable": "a", "value_selector": list(src)}],
                     "outputs": {"result": {"type": "string", "children": None}}}}

def end_node(nid, x, y, src_id, title="End"):
    return {"id": nid, "type": "custom", "position": {"x": x, "y": y}, "positionAbsolute": {"x": x, "y": y},
            "width": 244, "height": 90, "sourcePosition": "right", "targetPosition": "left",
            "data": {"type": "end", "title": title, "desc": "",
                     "outputs": [{"variable": "out", "value_selector": [src_id, "result"]}]}}

def edge(src, tgt, src_type="start", tgt_type="code"):
    return {"id": f"{src}-source-{tgt}-target", "type": "custom", "source": src, "sourceHandle": "source",
            "target": tgt, "targetHandle": "target",
            "data": {"sourceType": src_type, "targetType": tgt_type, "isInIteration": False, "isInLoop": False},
            "zIndex": 0}

def base_graph(n_code=4):
    """start -> c1 -> c2 ... -> cN -> end ; code nodes are arranged on a grid, plenty of room."""
    nodes = [start_node()]
    edges = []
    prev, ptype = "start", "start"
    for i in range(1, n_code + 1):
        nid = f"c{i}"
        nodes.append(code_node(nid, f"Code {i}", 80 + 320 * i, 200 + (i % 2) * 160, src=("start", "q") if i == 1 else (prev, "result")))
        edges.append(edge(prev, nid, ptype, "code"))
        prev, ptype = nid, "code"
    nodes.append(end_node("end", 80 + 320 * (n_code + 1), 200, prev))
    edges.append(edge(prev, "end", "code", "end"))
    return {"nodes": nodes, "edges": edges, "viewport": {"x": 0, "y": 0, "zoom": 0.6}}
