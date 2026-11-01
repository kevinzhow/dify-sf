#!/usr/bin/env python3
"""The build demo: a plan for N clients who build one workflow together from a blank canvas, then run it.

    python3 tool/demo/build_storm/make_plan.py --out-dir /tmp/build-demo

Writes `start.yml` (a workflow with only a Start and an End node: import it as the app to build) and `plan.json`
(for `dart run collab_client:build_demo`): per client a join time and a list of steps, each an op in dify-sf's wire
format or a wait for nodes to exist. The finished workflow compares two texts (`text_a`, `text_b`) in ten lanes of
code, template, IF/ELSE and variable aggregator nodes, with links across lanes, and runs on the code sandbox.
"""
import argparse
import json
import math
import random
from pathlib import Path

NAMES = """Ava Ben Chloe Daniel Ella Felix Grace Hugo Isla Jack Kai Lena Mila Noah Olivia Pablo Quinn Ravi Sofia Theo
Uma Victor Wren Xavier Yara Zoe Aiden Bea Caleb Dara Emil Fiona Gabe Hana Ivan Jade Kenji Lucia Mateo Nina Omar Priya
Rosa Sam Tara Ulrich Vera Wes Ximena Yusuf Zara Amir Bianca Cyrus Daisy Elias Freya Gus Holly Ines Jonas Kira Liam
Maya Nico Opal Petra Rafael Selma Tomas Una Vik Willa Yosef Zeno Alma Bruno Carmen Dev Esme Farid Greta Hiro Ida Joel
Kat Leo Mira Nadia Oscar Pia Rhys Sana Tess Uri Vlad Wanda Yan Zia Arlo Beth Cole Dina Ezra Faye Gil Hope""".split()

KIND = {"code": "code", "tpl": "template-transform", "if": "if-else", "agg": "variable-aggregator"}


def ref(node, out):
    return {"$ref": {"node": node, "output": out}}


def items(pairs):
    return {"$items": [{"id": k, "value": v} for k, v in pairs]}


class Graph:
    def __init__(self):
        self.nodes, self.edges, self.order = {}, [], []

    def add(self, nid, kind, title, lane_row, col, inputs=(), body=None, outputs=None, cond=None, branch=None):
        """inputs: [(var, node, output)]. branch: (if_node, handle) for nodes right after an IF/ELSE."""
        cfg = {"_dify_node": {"type": "custom"}, "desc": ""}
        if kind == "code":
            cfg.update(code_language="python3", code=body,
                       variables=items([(v, {"variable": v, "value_selector": ref(n, o)}) for v, n, o in inputs]),
                       outputs=items([(k, {"children": None, "name": k, "type": t}) for k, t in outputs.items()]))
        elif kind == "tpl":
            cfg.update(template=body,
                       variables=items([(v, {"variable": v, "value_selector": ref(n, o)}) for v, n, o in inputs]))
        elif kind == "if":
            var, n, o, op, val, vtype = cond
            cfg.update(cases=items([("true", {"case_id": "true", "logical_operator": "and", "conditions": [
                {"id": "c1", "varType": vtype, "variable_selector": ref(n, o), "comparison_operator": op, "value": val}]})]))
        elif kind == "agg":
            cfg.update(output_type="string", variables=[ref(n, o) for _, n, o in inputs])
        node = {"id": nid, "type": KIND[kind], "title": title, "x": int(420 + col * 300), "y": int(lane_row * 150), "config": cfg}
        # A node after an IF/ELSE is reached only through its branch (its inputs come from further upstream); an
        # IF/ELSE from the node it tests; any other node from every node it reads.
        if branch:
            sources = [branch]
        elif kind == "if":
            sources = [(cond[1], "source")]
        else:
            sources = []
            for _, n, _o in inputs:
                if (n, "source") not in sources:
                    sources.append((n, "source"))
        for src, handle in sources:
            self.edges.append({"id": f"e-{src}-{handle}-{nid}", "source": src, "sourceHandle": handle,
                               "target": nid, "targetHandle": "target"})
        self.nodes[nid] = node
        self.order.append(nid)
        return nid

    def deps(self, nid):
        return sorted({e["source"] for e in self.edges if e["target"] == nid})


def lanes(g, s, base):
    """One text's lanes. s = 'a' or 'b'; base = first row. Returns {lane: line node}."""
    T = f"text_{s}"
    r = lambda k: base + k  # noqa: E731
    w1 = g.add(f"w1{s}", "code", "Split words", r(0), 0, [("text", "start", T)],
               "import re\n\ndef main(text: str) -> dict:\n    words = re.findall(r\"[A-Za-z']+\", text)\n"
               "    return {\"words\": ' '.join(words), \"count\": len(words)}\n", {"words": "string", "count": "number"})
    w2 = g.add(f"w2{s}", "code", "Lowercase", r(0), 1, [("words", w1, "words")],
               "def main(words: str) -> dict:\n    return {\"lower\": words.lower()}\n", {"lower": "string"})
    w3 = g.add(f"w3{s}", "code", "Drop stop words", r(0), 2, [("lower", w2, "lower")],
               "STOP = set('a an and are as at be but by for from has have i in is it its of on or so that the this to was were with my we our you they not very'.split())\n\n"
               "def main(lower: str) -> dict:\n    return {\"kept\": ' '.join(w for w in lower.split() if w not in STOP and len(w) > 2)}\n",
               {"kept": "string"})
    w4 = g.add(f"w4{s}", "code", "Top words", r(0), 3, [("kept", w3, "kept")],
               "from collections import Counter\n\ndef main(kept: str) -> dict:\n"
               "    return {\"top\": [f'{w} x{n}' for w, n in Counter(kept.split()).most_common(4)]}\n", {"top": "array[string]"})
    w5 = g.add(f"w5{s}", "tpl", "Words line", r(0), 4, [("count", w1, "count"), ("top", w4, "top")],
               "{{ count }} words; top: {{ top | join(', ') }}")
    s1 = g.add(f"s1{s}", "code", "Split sentences", r(1), 0, [("text", "start", T)],
               "import re\n\ndef main(text: str) -> dict:\n    parts = [p.strip() for p in re.split(r'(?<=[.!?])\\s+', text) if p.strip()]\n"
               "    return {\"sentences\": parts, \"count\": len(parts)}\n", {"sentences": "array[string]", "count": "number"})
    s2 = g.add(f"s2{s}", "code", "Sentence lengths", r(1), 1, [("sentences", s1, "sentences")],
               "def main(sentences: list) -> dict:\n    return {\"lengths\": [len(x.split()) for x in sentences]}\n",
               {"lengths": "array[number]"})
    s3 = g.add(f"s3{s}", "code", "Average length", r(1), 2, [("lengths", s2, "lengths")],
               "def main(lengths: list) -> dict:\n    return {\"avg\": round(sum(lengths) / max(1, len(lengths)), 1)}\n", {"avg": "number"})
    s4 = g.add(f"s4{s}", "code", "Longest sentence", r(1), 3, [("sentences", s1, "sentences")],
               "def main(sentences: list) -> dict:\n    longest = max(sentences, key=lambda x: len(x.split()), default='')\n"
               "    return {\"longest\": longest[:60] + ('...' if len(longest) > 60 else '')}\n", {"longest": "string"})
    s5 = g.add(f"s5{s}", "tpl", "Sentences line", r(1), 4,
               [("count", s1, "count"), ("avg", s3, "avg"), ("longest", s4, "longest")],
               "{{ count }} sentences, {{ avg }} words on average; longest: \"{{ longest }}\"")
    r1 = g.add(f"r1{s}", "code", "Count syllables", r(2), 2, [("lower", w2, "lower")],
               "import re\n\ndef main(lower: str) -> dict:\n    n = sum(max(1, len(re.findall(r'[aeiouy]+', w))) for w in lower.split())\n"
               "    return {\"syllables\": n}\n", {"syllables": "number"})
    r2 = g.add(f"r2{s}", "code", "Readability score", r(2), 3,
               [("words", w1, "count"), ("sentences", s1, "count"), ("syllables", r1, "syllables")],
               "def main(words: float, sentences: float, syllables: float) -> dict:\n"
               "    score = 206.835 - 1.015 * words / max(1, sentences) - 84.6 * syllables / max(1, words)\n"
               "    return {\"score\": round(score, 1)}\n", {"score": "number"})
    r3 = g.add(f"r3{s}", "if", "Easy to read?", r(2), 4, cond=("score", r2, "score", "≥", "60", "number"))
    r4 = g.add(f"r4{s}", "tpl", "Easy", r(2) - 0.4, 5, [("score", r2, "score")], "easy to read (score {{ score }})",
               branch=(r3, "true"))
    r5 = g.add(f"r5{s}", "tpl", "Hard", r(2) + 0.4, 5, [("score", r2, "score")], "hard to read (score {{ score }})",
               branch=(r3, "false"))
    r6 = g.add(f"r6{s}", "agg", "Readability", r(2), 6, [("easy", r4, "output"), ("hard", r5, "output")])
    e1 = g.add(f"e1{s}", "code", "Positive words", r(3), 2, [("lower", w2, "lower")],
               "GOOD = set('great love excellent fast happy easy good amazing helpful perfect friendly clean'.split())\n\n"
               "def main(lower: str) -> dict:\n    hits = [w for w in lower.split() if w in GOOD]\n    return {\"pos\": len(hits), \"hits\": hits[:4]}\n",
               {"pos": "number", "hits": "array[string]"})
    e2 = g.add(f"e2{s}", "code", "Negative words", r(3), 3, [("lower", w2, "lower")],
               "BAD = set('slow broken bad poor late rude noisy expensive confusing dirty worst cold'.split())\n\n"
               "def main(lower: str) -> dict:\n    return {\"neg\": sum(w in BAD for w in lower.split())}\n", {"neg": "number"})
    e3 = g.add(f"e3{s}", "code", "Tone score", r(3), 4, [("pos", e1, "pos"), ("neg", e2, "neg")],
               "def main(pos: float, neg: float) -> dict:\n    return {\"score\": pos - neg}\n", {"score": "number"})
    e4 = g.add(f"e4{s}", "if", "Positive?", r(3), 5, cond=("score", e3, "score", ">", "0", "number"))
    e5 = g.add(f"e5{s}", "tpl", "Positive tone", r(3) - 0.4, 6, [("hits", e1, "hits")],
               "positive ({{ hits | join(', ') }})", branch=(e4, "true"))
    e6 = g.add(f"e6{s}", "tpl", "Critical tone", r(3) + 0.4, 6, [("score", e3, "score")], "critical (score {{ score }})",
               branch=(e4, "false"))
    e7 = g.add(f"e7{s}", "agg", "Tone", r(3), 7, [("pos", e5, "output"), ("neg", e6, "output")])
    k1 = g.add(f"k1{s}", "code", "Word pairs", r(4), 3, [("kept", w3, "kept")],
               "def main(kept: str) -> dict:\n    w = kept.split()\n    return {\"pairs\": '|'.join(f'{a} {b}' for a, b in zip(w, w[1:]))}\n",
               {"pairs": "string"})
    k2 = g.add(f"k2{s}", "code", "Top pairs", r(4), 4, [("pairs", k1, "pairs")],
               "from collections import Counter\n\ndef main(pairs: str) -> dict:\n    return {\"top\": [p for p, _ in Counter(pairs.split('|')).most_common(3) if p]}\n",
               {"top": "array[string]"})
    n1 = g.add(f"n1{s}", "code", "Find numbers", r(5), 0, [("text", "start", T)],
               "import re\n\ndef main(text: str) -> dict:\n    return {\"nums\": [float(x) for x in re.findall(r'\\d+(?:\\.\\d+)?', text)]}\n",
               {"nums": "array[number]"})
    n2 = g.add(f"n2{s}", "code", "Sum and largest", r(5), 1, [("nums", n1, "nums")],
               "def main(nums: list) -> dict:\n    return {\"total\": sum(nums), \"largest\": max(nums, default=0)}\n",
               {"total": "number", "largest": "number"})
    q1 = g.add(f"q1{s}", "code", "Questions", r(5), 2, [("sentences", s1, "sentences")],
               "def main(sentences: list) -> dict:\n    q = [x for x in sentences if x.endswith('?')]\n    return {\"count\": len(q)}\n",
               {"count": "number"})
    c1 = g.add(f"c1{s}", "code", "Capitalized words", r(6), 1, [("words", w1, "words")],
               "def main(words: str) -> dict:\n    return {\"caps\": [w for w in words.split() if w[:1].isupper() and len(w) > 1][:30]}\n",
               {"caps": "array[string]"})
    c2 = g.add(f"c2{s}", "code", "Skip sentence starts", r(6), 2, [("caps", c1, "caps"), ("sentences", s1, "sentences")],
               "def main(caps: list, sentences: list) -> dict:\n    starts = {x.split()[0].strip('\"') for x in sentences if x.split()}\n"
               "    return {\"names\": [w for w in caps if w not in starts and w != 'I']}\n", {"names": "array[string]"})
    c3 = g.add(f"c3{s}", "code", "Rank names", r(6), 3, [("names", c2, "names")],
               "from collections import Counter\n\ndef main(names: list) -> dict:\n    return {\"top\": [n for n, _ in Counter(names).most_common(3)]}\n",
               {"top": "array[string]"})
    m1 = g.add(f"m1{s}", "code", "First and last sentence", r(4), 1, [("sentences", s1, "sentences")],
               "def main(sentences: list) -> dict:\n    return {\"first\": sentences[0] if sentences else '', \"last\": sentences[-1] if sentences else ''}\n",
               {"first": "string", "last": "string"})
    m2 = g.add(f"m2{s}", "code", "Shorten", r(4), 2, [("first", m1, "first"), ("last", m1, "last")],
               "def main(first: str, last: str) -> dict:\n    cut = lambda x: x if len(x) < 50 else x[:47] + '...'\n"
               "    return {\"summary\": cut(first) + ' / ' + cut(last)}\n", {"summary": "string"})
    l1 = g.add(f"l1{s}", "code", "Character classes", r(6), 0, [("text", "start", T)],
               "def main(text: str) -> dict:\n    return {\"letters\": sum(c.isalpha() for c in text), \"digits\": sum(c.isdigit() for c in text),"
               " \"marks\": sum(c in '!?.,;:' for c in text)}\n", {"letters": "number", "digits": "number", "marks": "number"})
    d1 = g.add(f"d1{s}", "code", "Exclamations", r(5), 3, [("text", "start", T), ("questions", q1, "count")],
               "def main(text: str, questions: float) -> dict:\n    return {\"line\": f\"exclamation marks: {text.count('!')}, questions: {int(questions)}\"}\n",
               {"line": "string"})
    return {"words": w5, "sentences": s5, "readability": r6, "tone": e7, "pairs": k2, "numbers": n2,
            "marks": d1, "names": c3, "summary": m2, "chars": l1}


def build(clients: int, seed: int, converge: dict | None = None):
    """converge (the convergence runs): {"contest_end_ms", "final_ms"}: reviews and nudges of other people's nodes are
    contested edits that are dropped after contest_end_ms; at final_ms every owner writes the final position and
    description of its nodes (marked final: re-applied until confirmed), which make_target() expects exactly."""
    rnd = random.Random(seed)
    g = Graph()
    a = lanes(g, "a", 0)
    b = lanes(g, "b", 7.5)
    cmp_specs = [
        ("words", "Compare words", "output", "output", "A: {{ a }}\nB: {{ b }}"),
        ("sentences", "Compare sentences", "output", "output", "A: {{ a }}\nB: {{ b }}"),
        ("readability", "Compare readability", "output", "output", "A is {{ a }}, B is {{ b }}"),
        ("tone", "Compare tone", "output", "output", "A sounds {{ a }}; B sounds {{ b }}"),
        ("pairs", "Compare word pairs", "top", "top", "A: {{ a | join(', ') }}\nB: {{ b | join(', ') }}"),
        ("numbers", "Compare numbers", "total", "total", "numbers add up to {{ a }} in A and {{ b }} in B"),
        ("marks", "Compare punctuation", "line", "line", "A: {{ a }}; B: {{ b }}"),
        ("names", "Compare names", "top", "top", "A mentions {{ a | join(', ') }}; B mentions {{ b | join(', ') }}"),
        ("summary", "Compare summaries", "summary", "summary", "A: {{ a }}\nB: {{ b }}"),
        ("chars", "Compare characters", "letters", "letters", "{{ a }} letters in A, {{ b }} in B"),
    ]
    cmps = []
    for i, (lane, title, oa, ob, tpl) in enumerate(cmp_specs):
        cmps.append(g.add(f"x{i}", "tpl", title, 1.5 + i * 1.3, 9, [("a", a[lane], oa), ("b", b[lane], ob)], tpl))
    report = g.add("report", "tpl", "Report", 7, 10.5, [(f"p{i}", c, "output") for i, c in enumerate(cmps)],
                   "\n\n".join(f"{{{{ p{i} }}}}" for i in range(len(cmps))))
    # Topological order (nodes are added after their sources already).
    order = g.order
    n_nodes = len(order)
    # Past the list, the same names again with an initial ("Ava B."): every client is its own person.
    names = [NAMES[k % len(NAMES)] + ('' if k < len(NAMES) else f' {chr(65 + k // len(NAMES) - 1)}.') for k in range(clients)]
    # Join times: one by one at first, then the room fills up faster and faster.
    span = 42000
    join = [int(span * (i / clients) ** 0.6) for i in range(clients)]
    plan_clients = []
    owner = {nid: i % clients for i, nid in enumerate(order)}
    for i in range(clients):
        steps = []
        mine = [nid for nid in order if owner[nid] == i]
        def cursor(x, y):  # the pointer (protocol 1.22 presence), a little inside a card's title row
            return {"presence": {"cursor": [x + 40, y + 22]}}

        for nid in mine:
            node = g.nodes[nid]
            deps = g.deps(nid)
            first = g.nodes.get(deps[0]) if deps and deps[0] in g.nodes else {"x": 0, "y": 7 * 150}
            sx, sy = first["x"] + 60, first["y"] + 50
            steps.append(cursor(sx, sy))
            steps.append({"wait": deps})
            tx, ty = node["x"], int(node["y"])
            node = {**node, "x": sx, "y": sy}
            steps.append({"op": {"t": "addNode", "node": node}})
            # Dragged into place like a person would: a position every 125 ms (the canvas's drag send rate), held a
            # little inside the title row (presence `drag`: the others draw the pointer there as the card moves).
            steps.append({"presence": {"cursor": [sx + 40, sy + 22], "drag": {"node": nid, "x": 40, "y": 22}}})
            for k in range(1, 11):
                f = 1 - (1 - k / 10) ** 2
                x, y = int(sx + (tx - sx) * f), int(sy + (ty - sy) * f)
                steps.append({"presence": {"cursor": [x + 40, y + 22]}})
                steps.append({"op": {"t": "moveNode", "node": nid, "x": x, "y": y}})
                steps.append({"sleep_ms": 125})
            steps.append({"presence": {"cursor": [tx + 40, ty + 22], "drag": None}})
            # The node is in place: open its panel (others see this person's avatar on it) while wiring it up.
            steps.append({"presence": {"panel": nid}})
            for e in g.edges:
                if e["target"] == nid:
                    steps.append({"op": {"t": "addEdge", "edge": e}})
            steps.append({"sleep_ms": rnd.randint(1500, 3000)})
            steps.append({"presence": {"panel": None}})
        if "report" in mine:
            steps.append({"op": {"t": "addEdge", "edge": {"id": "e-report-end", "source": "report", "sourceHandle": "source",
                                                         "target": "end", "targetHandle": "target"}}})
            steps.append({"op": {"t": "insertItem", "node": "end", "path": ["outputs"], "after": None,
                                 "item": {"id": "report", "value": {"variable": "report",
                                                                     "value_selector": ref("report", "output")}}}})
        # Then review other people's nodes: a short note in their description. Two reviewers may pick the same
        # node at the same moment: the later write is refused and its author told.
        for _ in range(2):
            # Mostly the last nodes (the comparisons and the report), which everyone wants to look at.
            target = order[n_nodes - 1 - int(rnd.random() ** 2 * 14)] if rnd.random() < 0.7 else rnd.choice(order)
            steps.append({"sleep_ms": rnd.randint(1000, 3000)})
            steps.append({"wait": [target]})
            tn = g.nodes[target]
            steps.append(cursor(tn["x"] + rnd.randint(-20, 120), int(tn["y"]) + rnd.randint(-10, 30)))
            steps.append({"presence": {"panel": target}})
            review = {"op": {"t": "setField", "node": target, "field": {"k": "config", "path": ["desc"]},
                             "value": f"Reviewed by {names[i]}"}}
            if converge:
                review["deadline_ms"] = converge["contest_end_ms"]
            steps.append(review)
            if converge:
                # And nudge it a little, as someone tidying the layout would: the owner puts it back at the end.
                steps.append({"op": {"t": "moveNode", "node": target, "x": int(tn["x"]) + rnd.randint(-60, 60),
                                     "y": int(tn["y"]) + rnd.randint(-40, 40)},
                              "deadline_ms": converge["contest_end_ms"]})
            steps.append({"sleep_ms": rnd.randint(800, 1800)})
            steps.append({"presence": {"panel": None}})
        if converge:
            # Bursts: everyone writes the description of the same node at the same moment (the later writers are
            # refused, each one told), three times; then the owners put the final values in.
            for j, hot in enumerate(converge["hot"]):
                steps.append({"at_ms": converge["contest_end_ms"] - 9000 + j * 3000 + rnd.randint(0, 120)})
                steps.append({"op": {"t": "setField", "node": hot, "field": {"k": "config", "path": ["desc"]},
                                     "value": f"{names[i]} was here ({j + 1})"}, "deadline_ms": converge["contest_end_ms"]})
        if converge and mine:
            steps.append({"at_ms": converge["final_ms"] + rnd.randint(0, 1500)})
            for nid in mine:
                tn = g.nodes[nid]
                steps.append({"op": {"t": "moveNode", "node": nid, "x": tn["x"], "y": int(tn["y"])}, "final": True})
                steps.append({"op": {"t": "setField", "node": nid, "field": {"k": "config", "path": ["desc"]},
                                     "value": final_desc(tn, names[i])}, "final": True})
        plan_clients.append({"index": i, "name": names[i], "join_ms": join[i], "steps": steps})
    return g, plan_clients


def final_desc(node, owner: str) -> str:
    return f"{node['title']}: built and kept by {owner}"


def make_target(g, clients) -> dict:
    """The document a convergence run must end with: every node where its owner put it, with its whole configuration
    and the owner's final description, and exactly the planned connections (plus the report's link to End)."""
    owner = {}
    for c in clients:
        for st in c["steps"]:
            op = st.get("op") or {}
            if op.get("t") == "addNode":
                owner[op["node"]["id"]] = c["name"]
    dsl = start_dsl()["workflow"]["graph"]["nodes"]
    nodes = {n["id"]: {"type": n["data"]["type"], "title": n["data"]["title"], "x": n["position"]["x"],
                       "y": n["position"]["y"], "desc": ""} for n in dsl}
    for nid, n in g.nodes.items():
        # The whole configuration as its owner added it, with the final description.
        nodes[nid] = {"type": n["type"], "title": n["title"], "x": n["x"], "y": int(n["y"]),
                      "desc": final_desc(n, owner[nid]),
                      "config": {**n.get("config", {}), "desc": final_desc(n, owner[nid])}}
    edges = {e["id"]: {k: e[k] for k in ("source", "sourceHandle", "target", "targetHandle")} for e in g.edges}
    edges["e-report-end"] = {"source": "report", "sourceHandle": "source", "target": "end", "targetHandle": "target"}
    return {"nodes": nodes, "edges": edges}


def start_dsl():
    sample = {"text_a": "", "text_b": ""}
    start = {"id": "start", "type": "custom", "position": {"x": 0, "y": 7 * 150},
             "data": {"type": "start", "title": "Two reviews", "desc": "", "variables": [
                 {"variable": "text_a", "label": "Review A", "type": "paragraph", "required": True, "max_length": 5000, "options": []},
                 {"variable": "text_b", "label": "Review B", "type": "paragraph", "required": True, "max_length": 5000, "options": []}]}}
    end = {"id": "end", "type": "custom", "position": {"x": 420 + 12 * 300, "y": 7 * 150},
           "data": {"type": "end", "title": "Comparison", "desc": "", "outputs": []}}
    del sample
    return {"app": {"mode": "workflow", "name": "Compare two reviews", "icon": "🔍", "icon_background": "#E0EAFF",
                    "description": "Built live by 100 clients", "use_icon_as_answer_icon": False},
            "kind": "app", "version": "0.3.1", "dependencies": [],
            "workflow": {"conversation_variables": [], "environment_variables": [], "features": {},
                         "graph": {"edges": [], "nodes": [start, end], "viewport": {"x": 0, "y": 0, "zoom": 0.3}}}}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--clients", type=int, default=100)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--converge", type=int, metavar="FINAL_MS",
                    help="convergence run: contested edits until FINAL_MS - 15000, final values at FINAL_MS; writes "
                         "target.json")
    a = ap.parse_args()
    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    converge = {"final_ms": a.converge, "contest_end_ms": a.converge - 15000,
                "hot": ["x1", "x4", "report"]} if a.converge else None
    g, clients = build(a.clients, a.seed, converge)
    if converge:
        (out / "target.json").write_text(json.dumps(make_target(g, clients), indent=1))
    (out / "plan.json").write_text(json.dumps({"nodes": len(g.nodes), "edges": len(g.edges) + 1, "clients": clients}))
    (out / "start.yml").write_text(json.dumps(start_dsl(), ensure_ascii=False, indent=1))
    print(f"{len(g.nodes)} nodes, {len(g.edges) + 1} edges, {len(clients)} clients")


if __name__ == "__main__":
    main()
