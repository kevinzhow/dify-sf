------------------------------- MODULE Dify ---------------------------------
(***************************************************************************)
(* Formal model of Dify 1.17.1 collaborative workflow editing.             *)
(* Source mapping (details in REPORT.md section 3):                        *)
(*  - every client holds a Loro doc (CRDT, modelled as a SET OF WRITE OPS  *)
(*    whose materialisation is LWW per key by (lamport, peer)) and a       *)
(*    React-Flow "view" (graph).  They are different objects:              *)
(*      local edit: view' = f(view); then syncNodes() writes EVERY key of  *)
(*        the changed node(s) from the VIEW into the DOC, skipping keys    *)
(*        whose value equals the doc's current value                       *)
(*        [collaboration-manager.ts: syncNodes / populateNodeContainer]    *)
(*      remote msg: imported into the doc at once; the view is refreshed   *)
(*        later in a requestAnimationFrame callback [setupSubscriptions]   *)
(*  - graph_update messages carry the sender's whole doc (cumulative)      *)
(*  - fresh LoroDoc on every (re)connect; follower gets the leader's       *)
(*    snapshot; a leader with a fresh doc reloads the HTTP draft           *)
(*  - only the leader tab persists: 5 s debounce armed by LOCAL edits      *)
(*    only; a follower asks the leader (sync_request); unique_hash check;  *)
(*    leader election incl. visibility demotion; relay-only server         *)
(*  ListMode "whole": the list is one LWW value (e.g. code-node outputs    *)
(*    object, observed in the real-browser repro S2O)                      *)
(*  ListMode "index": the list is a Loro list written by an index-wise     *)
(*    diff (syncList; variables / prompt_template / parameters)            *)
(*  Clients are integers (Loro breaks Lamport ties by peer id).            *)
(***************************************************************************)
EXTENDS Common, TLC

CONSTANTS MaxFaults,
          ListMode,     \* "whole" | "index"
          ViewLag,      \* TRUE: doc import and view refresh are separate steps (rAF); FALSE: atomic
          UseVis,       \* TRUE: tabs can be hidden / shown (visibility demotion of the leader)
          FaultKinds,   \* subset of {"disc","close","crash","restart"}: which faults may occur (budget MaxFaults)
          Region,       \* Region[c] = nodes client c may edit (workload locality; = Nodes for a free-for-all)
          Unset, NoInc, DelV, NoOrg, NoRec, Root   \* sentinel model values (TLC cannot compare values of different sorts)

VARIABLES W, allW, view, dirty, dsave, up, conn, vis, trusted, hash, store, leader, net,
          issued, ncnt, gen, phase, fl, dovw

vars == <<W, allW, view, dirty, dsave, up, conn, vis, trusted, hash, store, leader, net,
          issued, ncnt, gen, phase, fl, dovw>>

(*********************** Loro-like doc: a set of write ops ******************)
\* write op shapes (all carry id = <<peer, tag>>, lam, peer):
\*  nm  : nodesMap key n  := container incarnation `val`  or "del"
\*  reg : map key g inside container `inc` := val ; hist/org = P2 lineage ghosts
\*  em  : edgesMap key e := "set" | "del"
\*  (index mode)  li : list element insert, origin = left neighbour ; ld : element delete
Gt(a, b) == \/ a.lam > b.lam
            \/ /\ a.lam = b.lam /\ a.peer > b.peer
            \/ /\ a.lam = b.lam /\ a.peer = b.peer /\ a.seq > b.seq   \* seq = doc generation (a fresh LoroDoc gets a new peer id)
MaxW(S) == CHOOSE w \in S : \A x \in S : x = w \/ Gt(w, x)
MaxLam(D) == IF D = {} THEN 0 ELSE LET m == CHOOSE w \in D : \A x \in D : x.lam <= w.lam IN m.lam

CurInc(D, n) == LET s == {w \in D : w.t = "nm" /\ w.n = n} IN
                IF s = {} THEN NoInc ELSE LET m == MaxW(s) IN IF m.val = DelV THEN NoInc ELSE m.val
RegOps(D, inc, g) == {w \in D : w.t = "reg" /\ w.inc = inc /\ w.g = g}
RegRec(D, inc, g) == IF RegOps(D, inc, g) = {} THEN NoRec ELSE MaxW(RegOps(D, inc, g))
RegVal(D, inc, g) == LET r == RegRec(D, inc, g) IN IF r = NoRec THEN Unset ELSE r.val
EdgeLive(D, e) == LET s == {w \in D : w.t = "em" /\ w.e = e} IN s # {} /\ MaxW(s).val = "set"

\* ----- list materialisation (index mode): RGA order of alive elements -----
RECURSIVE Visit(_, _)
RECURSIVE SortDesc(_)
SortDesc(S) == IF S = {} THEN <<>> ELSE LET m == MaxW(S) IN <<m>> \o SortDesc(S \ {m})
RECURSIVE Concat(_)
Concat(seqs) == IF seqs = <<>> THEN <<>> ELSE Head(seqs) \o Concat(Tail(seqs))
Visit(E, p) == LET ch == SortDesc({e \in E : e.origin = p})
               IN Concat([i \in DOMAIN ch |-> <<ch[i]>> \o Visit(E, ch[i].id)])
AliveElems(D, inc) ==
    LET E == {w \in D : w.t = "li" /\ w.inc = inc}
        dead == {w.tgt : w \in {x \in D : x.t = "ld"}}
    IN SelectSeq(Visit(E, Root), LAMBDA e : e.id \notin dead)
AliveItems(D, inc) == LET es == AliveElems(D, inc) IN [i \in DOMAIN es |-> es[i].item]
ListOf(D, inc) == IF ListMode = "whole"
                  THEN (LET r == RegRec(D, inc, "L") IN IF r = NoRec THEN <<>> ELSE r.lv)
                  ELSE AliveItems(D, inc)

\* ----- the React-Flow view derived from a doc (exportNode / edgesMap.values) -----
ExportView(D) ==
    LET live == {n \in Nodes : CurInc(D, n) # NoInc} IN
    [ nodes |-> live,
      val   |-> [n \in Nodes |-> [g \in Regs |-> IF n \in live /\ RegVal(D, CurInc(D, n), g) # Unset
                                                  THEN RegVal(D, CurInc(D, n), g) ELSE InitVal(g)]],
      hist  |-> [n \in Nodes |-> [g \in Regs |-> IF n \in live /\ RegRec(D, CurInc(D, n), g) # NoRec
                                                  THEN RegRec(D, CurInc(D, n), g).hist ELSE {}]],
      its   |-> [n \in Nodes |-> IF n \in live THEN ListOf(D, CurInc(D, n)) ELSE <<>>],
      edges |-> {e \in NodeEdges : EdgeLive(D, e)} ]

Range(s) == {s[i] : i \in DOMAIN s}
AbsOfView(V) == [nodes |-> V.nodes, val |-> V.val, its |-> [n \in Nodes |-> Range(V.its[n])], edges |-> V.edges]

InitView ==
    [ nodes |-> InitNodes,
      val   |-> [n \in Nodes |-> [g \in Regs |-> InitVal(g)]],
      hist  |-> [n \in Nodes |-> [g \in Regs |-> {}]],
      its   |-> [n \in Nodes |-> <<>>],
      edges |-> {} ]

\* a doc that materialises exactly to view V (used by the seeding: initial load / reload from HTTP draft)
SeedOps(V, c, g0) ==
    LET mk(n) == <<c, <<<<0, g0>>, "seed", n>>>>
    IN {[t |-> "nm", id |-> mk(n), seq |-> g0, lam |-> 1, peer |-> c, n |-> n, val |-> mk(n)] : n \in V.nodes}
       \cup {[t |-> "reg", id |-> <<c, <<<<0, g0>>, "seedR", n, g>>>>, seq |-> g0, lam |-> 1, peer |-> c, inc |-> mk(n), g |-> g,
              val |-> V.val[n][g], hist |-> V.hist[n][g], org |-> NoOrg] : n \in V.nodes, g \in Regs}
       \cup (IF ListMode = "whole"
             THEN {[t |-> "reg", id |-> <<c, <<<<0, g0>>, "seedL", n>>>>, seq |-> g0, lam |-> 1, peer |-> c, inc |-> mk(n), g |-> "L",
                    val |-> Zero, lv |-> V.its[n], hist |-> {}, org |-> NoOrg] : n \in V.nodes}
             ELSE {})
       \cup {[t |-> "em", id |-> <<c, <<<<0, g0>>, "seedE", e>>>>, seq |-> g0, lam |-> 1, peer |-> c, e |-> e, val |-> "set"] : e \in V.edges}

(*********************** a user edit on the view ****************************)
Explicit(o, n, g) ==
    /\ o.kind \in {"setField", "setRef", "moveNode"} /\ o.n = n /\ o.g = g

UserApply(V, o) ==
    CASE o.kind \in {"setField", "setRef", "moveNode"} ->
            [V EXCEPT !.val[o.n][o.g] = o.v, !.hist[o.n][o.g] = @ \cup {o.id}]
      [] o.kind = "listInsert" -> [V EXCEPT !.its[o.n] = Append(@, o.it)]
      [] o.kind = "listRemove" -> [V EXCEPT !.its[o.n] = SelectSeq(@, LAMBDA x : x # o.it)]
      [] o.kind = "addNode"    -> [V EXCEPT !.nodes = @ \cup {o.n}]
      [] o.kind = "removeNode" -> [V EXCEPT !.nodes = @ \ {o.n}, !.edges = {e \in @ : o.n \notin {e[1], e[2]}}]
      [] o.kind = "addEdge"    -> [V EXCEPT !.edges = @ \cup {o.e}]

EnabledOn(V, o) ==
    /\ KindOK(o)
    /\ CASE o.kind \in {"setField", "moveNode"} -> o.n \in V.nodes /\ V.val[o.n][o.g] # o.v
         [] o.kind = "setRef"     -> o.n \in V.nodes /\ o.v \in V.nodes /\ o.v # o.n /\ V.val[o.n]["r"] # o.v
         [] o.kind = "listInsert" -> o.n \in V.nodes
         [] o.kind = "listRemove" -> o.n \in V.nodes /\ o.it \in Range(V.its[o.n])
         [] o.kind = "addNode"    -> o.n \notin V.nodes /\ o.n \notin InitNodes
                                      /\ \A x \in issued : ~(x.kind = "addNode" /\ x.n = o.n)
         [] o.kind = "removeNode" -> o.n \in V.nodes
         [] o.kind = "addEdge"    -> o.e[1] \in V.nodes /\ o.e[2] \in V.nodes /\ o.e \notin V.edges

\* nodes whose React object changes (=> syncNodes -> populateNodeContainer runs on them).
\* edge ops also rewrite the endpoints' _connectedSource/TargetHandleIds (an allow-listed data key).
Changed(V, NV, o) ==
    {n \in NV.nodes : n \notin V.nodes \/ NV.val[n] # V.val[n] \/ NV.its[n] # V.its[n]}
    \cup (IF o.kind = "addEdge" THEN {o.e[1], o.e[2]} \cap NV.nodes ELSE {})
    \cup (IF o.kind = "removeNode"
          THEN {x \in NV.nodes : \E e \in V.edges : o.n \in {e[1], e[2]} /\ x \in {e[1], e[2]}} ELSE {})


\* syncList(): index-wise diff of the DOC's list against the view's array
\*   for i < min(len): if cur[i] != tgt[i]  { list.delete(i,1); list.insert(i, tgt[i]) }
\*   then trim the tail / append the rest.                  [collaboration-manager.ts syncList]
RECURSIVE SL(_, _, _, _, _, _, _, _, _, _)
SL(cur, tgt, i, prev, inc, o, c, n, lam, dummy) ==
    LET mkIns(nid, item, org, l) ==
            [t |-> "li", id |-> nid, seq |-> gen[c], lam |-> l, peer |-> c, inc |-> inc, item |-> item, origin |-> org]
        mkDel(tid, l) ==
            [t |-> "ld", id |-> <<c, <<o.id, "ld", tid>>>>, seq |-> gen[c], lam |-> l, peer |-> c, tgt |-> tid]
        nid == <<c, <<o.id, "li", n, i>>>>
    IN IF i > (IF Len(cur) > Len(tgt) THEN Len(cur) ELSE Len(tgt)) THEN {}
       ELSE IF i <= Len(cur) /\ i <= Len(tgt) THEN
              IF cur[i].item = tgt[i]
              THEN SL(cur, tgt, i + 1, cur[i].id, inc, o, c, n, lam, dummy)
              ELSE {mkDel(cur[i].id, lam + i), mkIns(nid, tgt[i], prev, lam + i)}
                   \cup SL(cur, tgt, i + 1, nid, inc, o, c, n, lam, dummy)
       ELSE IF i <= Len(cur)
            THEN {mkDel(cur[i].id, lam + i)} \cup SL(cur, tgt, i + 1, prev, inc, o, c, n, lam, dummy)
            ELSE {mkIns(nid, tgt[i], prev, lam + i)} \cup SL(cur, tgt, i + 1, nid, inc, o, c, n, lam, dummy)

IndexListOps(D, inc0, inc, tgt, o, c, n, lam) ==
    SL(IF inc0 = NoInc THEN <<>> ELSE AliveElems(D, inc0), tgt, 1, Root, inc, o, c, n, lam, 0)

\* ops written by populateNodeContainer for node n (container looked up / created in doc D)
PopulateOps(D, n, NV, o, c) ==
    LET lam  == MaxLam(D) + 1
        inc0 == CurInc(D, n)
        newInc == <<c, <<o.id, "nm", n>>>>
        inc  == IF inc0 = NoInc THEN newInc ELSE inc0
        nm   == IF inc0 = NoInc
                THEN {[t |-> "nm", id |-> newInc, seq |-> gen[c], lam |-> lam, peer |-> c, n |-> n, val |-> newInc]} ELSE {}
        cur(g) == IF inc0 = NoInc THEN Unset ELSE RegVal(D, inc0, g)
        regs == {[t |-> "reg", id |-> <<c, <<o.id, "reg", n, g>>>>, seq |-> gen[c], lam |-> lam, peer |-> c,
                  inc |-> inc, g |-> g, val |-> NV.val[n][g], hist |-> NV.hist[n][g],
                  org |-> IF Explicit(o, n, g) THEN o.id ELSE NoOrg] : g \in {x \in Regs : NV.val[n][x] # cur(x)}}
        lst  == IF ListMode = "whole"
                THEN (IF NV.its[n] # (IF inc0 = NoInc THEN Unset ELSE ListOf(D, inc0))
                      THEN {[t |-> "reg", id |-> <<c, <<o.id, "regL", n>>>>, seq |-> gen[c], lam |-> lam, peer |-> c,
                             inc |-> inc, g |-> "L", val |-> Zero, lv |-> NV.its[n], hist |-> {}, org |-> NoOrg]} ELSE {})
                ELSE IndexListOps(D, inc0, inc, NV.its[n], o, c, n, lam)
    IN nm \cup regs \cup lst

LocalOps(D, V, NV, o, c) ==
    LET ch == Changed(V, NV, o)
        lam == MaxLam(D) + 1
        dels == {[t |-> "nm", id |-> <<c, <<o.id, "del", n>>>>, seq |-> gen[c], lam |-> lam, peer |-> c, n |-> n, val |-> DelV]
                 : n \in V.nodes \ NV.nodes}
        pops == UNION {PopulateOps(D, n, NV, o, c) : n \in ch}
        ed   == {[t |-> "em", id |-> <<c, <<o.id, "em", e>>>>, seq |-> gen[c], lam |-> lam, peer |-> c, e |-> e, val |-> DelV]
                 : e \in V.edges \ NV.edges}
                \cup {[t |-> "em", id |-> <<c, <<o.id, "em", e>>>>, seq |-> gen[c], lam |-> lam, peer |-> c, e |-> e, val |-> "set"]
                 : e \in NV.edges \ V.edges}
    IN dels \cup pops \cup ed

(*********************** leader / room helpers ******************************)
Room == {c \in Clients : up[c] /\ conn[c]}
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Pick == LET vis_ == {c \in Room : vis[c]} IN
        IF vis_ # {} THEN Min(vis_) ELSE IF Room # {} THEN Min(Room) ELSE 0
LeaderValid == leader # 0 /\ leader \in Room
Ready(c) == up[c] /\ conn[c] /\ trusted[c] /\ vis[c]      \* canApplyLocalGraphMutation (+ visible)

InRegion(c, o) == IF o.kind = "addEdge" THEN {o.e[1], o.e[2]} \subseteq Region[c] ELSE o.n \in Region[c]

OpById(id) == CHOOSE o \in issued : o.id = id

(*********************** persisted draft ************************************)
\* leader-side save: hash must match; on mismatch only the hash is refreshed (no retry, no discard)
SaveBy(T, V, req) ==
    IF hash[T] = store.hash
    THEN /\ store' = [g |-> AbsOfView(V), hash |-> store.hash + 1]
         /\ hash' = [x \in Clients |-> IF x = T \/ x = req THEN store.hash + 1 ELSE hash[x]]
    ELSE /\ store' = store
         /\ hash' = [hash EXCEPT ![T] = store.hash]

(*********************** actions ********************************************)
Init ==
    LET D0 == SeedOps(InitView, 0, 0) IN
    /\ W = [c \in Clients |-> D0] /\ allW = D0
    /\ view = [c \in Clients |-> ExportView(D0)]
    /\ dirty = [c \in Clients |-> FALSE] /\ dsave = [c \in Clients |-> FALSE]
    /\ up = [c \in Clients |-> TRUE] /\ conn = [c \in Clients |-> TRUE]
    /\ vis = [c \in Clients |-> TRUE] /\ trusted = [c \in Clients |-> TRUE]
    /\ hash = [c \in Clients |-> 1] /\ store = [g |-> AbsOfView(InitView), hash |-> 1]
    /\ leader = Min(Clients) /\ net = {}
    /\ issued = {} /\ ncnt = [c \in Clients |-> 1] /\ gen = [c \in Clients |-> 0] /\ dovw = {}
    /\ phase = "run" /\ fl = 0

Edit(c) ==
    /\ phase = "run" /\ Ready(c) /\ ncnt[c] <= MaxOps
    /\ \E o \in {x \in CandidateOps(<<c, ncnt[c]>>) : EnabledOn(view[c], x) /\ InRegion(c, x)} :
         LET NV == UserApply(view[c], o)
             ops == LocalOps(W[c], view[c], NV, o, c)
             D2  == W[c] \cup ops
         IN /\ W' = [W EXCEPT ![c] = D2] /\ allW' = allW \cup ops
            /\ view' = [view EXCEPT ![c] = NV]
            /\ dsave' = [dsave EXCEPT ![c] = TRUE]
            /\ net' = net \cup {[to |-> x, ops |-> D2] : x \in Room \ {c}}      \* graph_update relay to the room
            /\ issued' = issued \cup {o}
            /\ ncnt' = [ncnt EXCEPT ![c] = @ + 1]
            \* P2 oracle for node removal: register writes to the node that the remover's view had not seen
            /\ dovw' = dovw \cup (IF o.kind = "removeNode"
                                 THEN {<<x, o>> : x \in {y \in issued : IsContentWrite(y) /\ y.n = o.n
                                                                        /\ y.id \notin view[c].hist[o.n][y.g]}}
                                 ELSE {})
    /\ UNCHANGED <<dirty, up, conn, vis, trusted, hash, store, leader, gen, phase, fl>>

\* remote update arrives: import into the doc at once; the view is refreshed later (rAF)
Import(m) ==
    /\ m.to \in Room
    /\ LET c == m.to IN
       /\ W' = [W EXCEPT ![c] = @ \cup m.ops]
       /\ IF ViewLag THEN /\ dirty' = [dirty EXCEPT ![c] = TRUE] /\ view' = view
          ELSE /\ dirty' = dirty /\ view' = [view EXCEPT ![c] = ExportView(W[c] \cup m.ops)]
    /\ net' = net \ {m}
    /\ UNCHANGED <<allW, dsave, up, conn, vis, trusted, hash, store, leader, issued, ncnt, gen, phase, fl, dovw>>

Refresh(c) ==     \* requestAnimationFrame: React view := doc  (paused while the tab is hidden)
    /\ up[c] /\ vis[c] /\ dirty[c]
    /\ view' = [view EXCEPT ![c] = ExportView(W[c])] /\ dirty' = [dirty EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<W, allW, dsave, up, conn, vis, trusted, hash, store, leader, net, issued, ncnt, gen, phase, fl, dovw>>

\* 5 s debounce fires on a tab that edited locally.
\* A follower's sync_request goes to the leader; if the leader is gone or hidden the relay re-elects first
\* (modelled by Elect, so Fire is simply not enabled until the room has a usable leader).
Fire(c) ==
    /\ up[c] /\ dsave[c]
    /\ (~(conn[c] /\ trusted[c] /\ vis[c]) \/ leader = c \/ (LeaderValid /\ vis[leader]))
    /\ dsave' = [dsave EXCEPT ![c] = FALSE]
    /\ IF ~(conn[c] /\ trusted[c] /\ vis[c]) THEN              \* canPersistLocalGraph() false: silently nothing
          UNCHANGED <<W, allW, view, dirty, hash, store>>
       ELSE IF leader = c THEN                                      \* leader saves its own React view
          /\ SaveBy(c, view[c], c)
          /\ UNCHANGED <<W, allW, view, dirty>>
       ELSE IF trusted[leader] THEN                                 \* follower: sync_request to the leader
          LET T == leader
              D2 == W[T] \cup W[c]                                  \* leader imports the follower's snapshot ...
              V2 == ExportView(D2)                                  \* ... refreshGraphSynchronously ...
          IN /\ W' = [W EXCEPT ![T] = D2] /\ view' = [view EXCEPT ![T] = V2] /\ dirty' = [dirty EXCEPT ![T] = FALSE]
             /\ SaveBy(T, V2, c)                                    \* ... and saves
             /\ UNCHANGED allW
       ELSE UNCHANGED <<W, allW, view, dirty, hash, store>>         \* leader not ready to save: request fails (no retry)
    /\ UNCHANGED <<up, conn, vis, trusted, leader, net, issued, ncnt, gen, phase, fl, dovw>>

RECURSIVE SetToSeq(_)
SetToSeq(S) == IF S = {} THEN <<>> ELSE LET x == CHOOSE y \in S : TRUE IN <<x>> \o SetToSeq(S \ {x})
ViewOfAbs(g) == [nodes |-> g.nodes, val |-> g.val,
                 hist |-> [n \in Nodes |-> [r \in Regs |-> {}]],
                 its |-> [n \in Nodes |-> SetToSeq(g.its[n])], edges |-> g.edges]

\* server picks / replaces the leader. A newly elected leader that is not "trusted" (fresh doc, awaiting a
\* snapshot) reloads the HTTP draft and re-seeds its doc from it (graphReloadRequired -> replaceGraphFromReactFlow).
Elect ==
    /\ \/ (~LeaderValid /\ Room # {})
       \/ (UseVis /\ LeaderValid /\ ~vis[leader] /\ \E x \in Room : vis[x])        \* hidden leader is demoted
    /\ LET L == Pick IN
       /\ leader' = L
       /\ IF L # 0 /\ ~trusted[L]
          THEN LET D0 == SeedOps(ViewOfAbs(store.g), L, gen[L] + 1) IN
               /\ W' = [W EXCEPT ![L] = D0] /\ allW' = allW \cup D0
               /\ view' = [view EXCEPT ![L] = ExportView(D0)]
               /\ trusted' = [trusted EXCEPT ![L] = TRUE] /\ dirty' = [dirty EXCEPT ![L] = FALSE]
               /\ hash' = [hash EXCEPT ![L] = store.hash]
               /\ gen' = [gen EXCEPT ![L] = @ + 1]
               /\ net' = net \cup {[to |-> x, ops |-> D0] : x \in Room \ {L}}
          ELSE UNCHANGED <<W, allW, view, trusted, dirty, hash, gen, net, dovw>>
    /\ UNCHANGED <<dsave, up, conn, vis, store, issued, ncnt, phase, fl, dovw>>

\* a follower with a fresh doc receives the leader's snapshot (graph_resync_request -> snapshot)
RecvSnapshot(c) ==
    /\ up[c] /\ conn[c] /\ ~trusted[c] /\ LeaderValid /\ leader # c /\ trusted[leader]
    /\ LET D2 == W[c] \cup W[leader] IN
       /\ W' = [W EXCEPT ![c] = D2]
       /\ view' = [view EXCEPT ![c] = ExportView(D2)]          \* local view (and any unsynced local edit) replaced
    /\ trusted' = [trusted EXCEPT ![c] = TRUE] /\ dirty' = [dirty EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<allW, dsave, up, conn, vis, hash, store, leader, net, issued, ncnt, gen, phase, fl, dovw>>

\* ---- faults and environment ----
Disconnect(c) ==      \* websocket drops (network); the tab stays open
    /\ phase = "run" /\ fl < MaxFaults /\ "disc" \in FaultKinds /\ up[c] /\ conn[c]
    /\ conn' = [conn EXCEPT ![c] = FALSE] /\ trusted' = [trusted EXCEPT ![c] = FALSE]
    /\ net' = {m \in net : m.to # c} /\ fl' = fl + 1
    /\ leader' = IF leader = c THEN 0 ELSE leader        \* handle_leader_disconnect: the room is leaderless until Elect
    /\ UNCHANGED <<W, allW, view, dirty, dsave, up, vis, hash, store, issued, ncnt, gen, phase, dovw>>

Reconnect(c) ==       \* socket.io reconnect: FRESH empty LoroDoc, graph not trusted until snapshot / reload
    /\ up[c] /\ ~conn[c]
    /\ conn' = [conn EXCEPT ![c] = TRUE]
    /\ W' = [W EXCEPT ![c] = {}] /\ gen' = [gen EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<allW, view, dirty, dsave, up, vis, trusted, hash, store, leader, net, issued, ncnt, phase, fl, dovw>>

CloseTab(c, flush) == \* tab closed (graceful: beforeunload flush by the leader) or crashed (flush = FALSE)
    /\ phase = "run" /\ fl < MaxFaults /\ up[c] /\ (IF flush THEN "close" ELSE "crash") \in FaultKinds
    /\ up' = [up EXCEPT ![c] = FALSE] /\ conn' = [conn EXCEPT ![c] = FALSE] /\ trusted' = [trusted EXCEPT ![c] = FALSE]
    /\ dsave' = [dsave EXCEPT ![c] = FALSE]
    /\ net' = {m \in net : m.to # c} /\ fl' = fl + 1
    /\ leader' = IF leader = c THEN 0 ELSE leader
    /\ IF flush /\ leader = c /\ trusted[c] /\ vis[c] THEN SaveBy(c, view[c], c) ELSE UNCHANGED <<hash, store, dovw>>
    /\ UNCHANGED <<W, allW, view, dirty, vis, issued, ncnt, gen, phase, dovw>>

ServerRestart ==      \* relay process dies: every socket drops, leader state cleared
    /\ phase = "run" /\ fl < MaxFaults /\ "restart" \in FaultKinds
    /\ conn' = [c \in Clients |-> FALSE] /\ trusted' = [c \in Clients |-> FALSE]
    /\ net' = {} /\ leader' = 0 /\ fl' = fl + 1
    /\ UNCHANGED <<W, allW, view, dirty, dsave, up, vis, hash, store, issued, ncnt, gen, phase, dovw>>

Hide(c) ==
    /\ UseVis /\ phase = "run" /\ up[c] /\ vis[c]
    /\ vis' = [vis EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<W, allW, view, dirty, dsave, up, conn, trusted, hash, store, leader, net, issued, ncnt, gen, phase, fl, dovw>>

Show(c) ==
    /\ up[c] /\ ~vis[c]
    /\ vis' = [vis EXCEPT ![c] = TRUE]
    /\ UNCHANGED <<W, allW, view, dirty, dsave, up, conn, trusted, hash, store, leader, net, issued, ncnt, gen, phase, fl, dovw>>

(*********************** phases / spec ***************************************)
Settled ==
    /\ phase = "heal" /\ net = {}
    /\ (Room = {} \/ LeaderValid)
    /\ \A c \in Clients : up[c] => (conn[c] /\ trusted[c] /\ vis[c] /\ ~dirty[c] /\ ~dsave[c])

Quiesce == /\ phase = "run" /\ phase' = "heal"
           /\ UNCHANGED <<W, allW, view, dirty, dsave, up, conn, vis, trusted, hash, store, leader, net, issued, ncnt, gen, fl, dovw>>

Done == Settled /\ UNCHANGED vars

UserEdit      == \E c \in Clients : Edit(c)
RenderViews   == \E c \in Clients : Refresh(c)
DebounceFires == \E c \in Clients : Fire(c)
SnapshotRecv  == \E c \in Clients : RecvSnapshot(c)
NetDrop       == \E c \in Clients : Disconnect(c)
NetReconnect  == \E c \in Clients : Reconnect(c)
TabClosed     == \E c \in Clients : CloseTab(c, TRUE)
TabCrashed    == \E c \in Clients : CloseTab(c, FALSE)
TabHidden     == \E c \in Clients : Hide(c)
TabShown      == \E c \in Clients : Show(c)
ImportUpdate  == \E m \in net : Import(m)

Next ==
    \/ UserEdit \/ RenderViews \/ DebounceFires \/ SnapshotRecv \/ NetDrop \/ NetReconnect
    \/ TabClosed \/ TabCrashed \/ TabHidden \/ TabShown \/ ImportUpdate
    \/ Elect \/ ServerRestart \/ Quiesce \/ Done

Spec == Init /\ [][Next]_vars

(*********************** properties *****************************************)
ContentKeys == {<<w.inc, w.g>> : w \in {x \in allW : x.t = "reg" /\ x.g \in Fields \cup {"r"}}}
\* a write whose author had not seen an earlier acknowledged write displaced it (value differs):
\* P2 oracle from the lineage ghosts, evaluated on every register ever written
OvwOf ==
    UNION { LET ops == RegOps(allW, k[1], k[2])
                win == MaxW(ops)
            IN {<<OpById(l.org), win.id>> : l \in {x \in ops : x # win /\ x.org # NoOrg /\ x.val # win.val
                                                            /\ x.org \notin win.hist}}
          : k \in ContentKeys }

LiveClients == {c \in Clients : up[c]}
Views == [c \in LiveClients |-> AbsOfView(view[c])]
Final == store.g

\* Cov_*: expected to be violated - proves the mechanism is reachable (repro M9: a tab that becomes leader keeps the hash it joined with)
Cov_StaleLeaderHash == ~(leader # 0 /\ up[leader] /\ hash[leader] # store.hash /\ dsave[leader])

Inv_P1 == Settled => P1(issued, Final)
Inv_P2 == P2(OvwOf \cup dovw)
Inv_P3 == Settled => P3(Views, Final)
Inv_P4 == Settled => P4(Final, Views)
Inv_P5 == Settled => P5(issued, issued, {}, Final, OvwOf \cup dovw)

(*********************** readable traces (TLC ALIAS, no effect on checking) ******************)
Compact(V) == [nodes |-> V.nodes, val |-> V.val, its |-> V.its, edges |-> V.edges]
OpTag(o) == <<o.id, o.kind, o.n, o.g, o.v, o.it, o.e>>
Alias == [ phase |-> phase, leader |-> leader, up |-> up, conn |-> conn, trusted |-> trusted, vis |-> vis,
           dirty |-> dirty, dsave |-> dsave, hash |-> hash, store |-> store.g.val, storehash |-> store.hash,
           storeits |-> store.g.its, storenodes |-> store.g.nodes,
           doc |-> [c \in Clients |-> Compact(ExportView(W[c]))],
           view |-> [c \in Clients |-> Compact(view[c])],
           net |-> {m.to : m \in net}, issued |-> {OpTag(o) : o \in issued}, fl |-> fl ]
=============================================================================
