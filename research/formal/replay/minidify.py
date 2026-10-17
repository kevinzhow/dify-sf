"""A faithful miniature of Dify 1.17.1's collaboration data path, running on the REAL Loro library
(python `loro`; Dify pins loro-crdt 1.15.1 JS/WASM, same core).  Used to replay the TLA+ counterexamples of
Dify.tla on the real CRDT and show that each abstract counterexample is executable.

Mirrors web/app/components/workflow/collaboration/core/collaboration-manager.ts:
  populate_node_container  <- populateNodeContainer()   (writes EVERY key of the node; Loro skips equal values)
  sync_list                <- syncList()                (index-wise delete+insert against the DOC list)
  sync_nodes / sync_edges  <- syncNodes() / syncEdges() (diff old view vs new view; delete removed ids)
  Client.import_update     <- doc.import(update)         (view is NOT refreshed here)
  Client.refresh_view      <- subscribe() rAF callback   (view := export of every node in the doc)
  Client.export_update     <- doc.export({mode:'update'}) (cumulative)
"""
import copy
import loro
from loro import LoroDoc, LoroMap, LoroList

LIST_FIELDS = {"variables", "prompt_template", "parameters"}


def vv():  # empty version vector -> full update export
    return loro.ExportMode.Updates(loro.VersionVector())


class Client:
    def __init__(self, name, peer, seed_snapshot=None):
        self.name = name
        self.doc = LoroDoc()
        self.doc.peer_id = peer
        if seed_snapshot is not None:
            self.doc.import_(seed_snapshot)
        self.nodes = self.doc.get_map("nodes")
        self.edges = self.doc.get_map("edges")
        self.view = {"nodes": {}, "edges": {}}
        self.refresh_view()

    # ---- doc <-> view ----
    def export_node(self, nid):
        v = self.nodes.get(nid)
        return None if v is None else copy.deepcopy(self.nodes.get_deep_value()[nid])

    def refresh_view(self):
        d = self.nodes.get_deep_value()
        self.view["nodes"] = {nid: copy.deepcopy(n) for nid, n in d.items()}
        self.view["edges"] = copy.deepcopy(self.edges.get_deep_value())

    def export_update(self):
        return self.doc.export(vv())

    def import_update(self, blob):
        self.doc.import_(blob)          # NOTE: the view is NOT refreshed here (rAF later)

    # ---- the write path ----
    def _container(self, nid, node):
        cur = self.nodes.get(nid)
        if cur is None or not hasattr(cur, "container"):
            m = self.nodes.insert_container(nid, LoroMap())   # getNodeContainer(): recreate if missing
            self._populate(m, node)
            return None
        return cur.container

    def _populate(self, cont, node):
        cont.insert("id", node["id"])
        data_c = cont.get("data")
        if data_c is None:
            data_c = cont.insert_container("data", LoroMap())
        else:
            data_c = data_c.container
        handled = set()
        for k, v in node["data"].items():
            handled.add(k)
            if k in LIST_FIELDS:
                self._sync_list(data_c, k, v)
            else:
                data_c.insert(k, v)                            # Loro: no-op when equal
        for k in list(data_c.get_deep_value().keys()):
            if k not in handled:
                data_c.delete(k)

    def _sync_list(self, data_c, key, desired):
        cur = data_c.get(key)
        lst = data_c.insert_container(key, LoroList()) if cur is None else cur.container
        current = lst.get_deep_value()
        n = min(len(current), len(desired))
        for i in range(n):
            if current[i] != desired[i]:
                lst.delete(i, 1)
                lst.insert(i, desired[i])
        if len(current) > len(desired):
            lst.delete(len(desired), len(current) - len(desired))
        else:
            for i in range(len(current), len(desired)):
                lst.insert(i, desired[i])

    def set_nodes(self, new_nodes, new_edges=None):
        """collaborationManager.setNodes(old=view, new): old view vs new view -> doc writes; then React store := new."""
        old = self.view["nodes"]
        for nid in old:
            if nid not in new_nodes:
                self.nodes.delete(nid)
        for nid, node in new_nodes.items():
            if nid in old and old[nid] == node:
                continue
            cur = self.nodes.get(nid)
            if cur is None or not hasattr(cur, "container"):
                m = self.nodes.insert_container(nid, LoroMap())
                self._populate(m, node)
            else:
                self._populate(cur.container, node)
        if new_edges is not None:
            oe = self.view["edges"]
            for eid in oe:
                if eid not in new_edges:
                    self.edges.delete(eid)
            for eid, e in new_edges.items():
                if eid not in oe or oe[eid] != e:
                    self.edges.insert(eid, e)
        self.doc.commit()
        self.view["nodes"] = copy.deepcopy(new_nodes)
        if new_edges is not None:
            self.view["edges"] = copy.deepcopy(new_edges)

    # convenience: user edits through the node panel -- the panel writes its FULL data copy
    def edit(self, nid, **patch):
        new = copy.deepcopy(self.view["nodes"])
        new[nid]["data"].update(patch)
        self.set_nodes(new)

    def delete_node(self, nid):
        new = copy.deepcopy(self.view["nodes"])
        del new[nid]
        self.set_nodes(new)

    def data(self, nid):
        n = self.nodes.get_deep_value().get(nid)
        return None if n is None else n["data"]


def make_room(graph, names=("A", "B", "C")):
    """graph: {node_id: data dict}; returns clients that all start from the same seeded doc"""
    seed = LoroDoc(); seed.peer_id = 1000
    nm = seed.get_map("nodes")
    for nid, data in graph.items():
        c = nm.insert_container(nid, LoroMap())
        c.insert("id", nid)
        dc = c.insert_container("data", LoroMap())
        for k, v in data.items():
            if k in LIST_FIELDS:
                l = dc.insert_container(k, LoroList())
                for i, x in enumerate(v):
                    l.insert(i, x)
            else:
                dc.insert(k, v)
    seed.commit()
    snap = seed.export(loro.ExportMode.Snapshot())
    return [Client(n, i + 1, snap) for i, n in enumerate(names)]
