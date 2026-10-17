------------------------------- MODULE Common -------------------------------
(***************************************************************************)
(* Shared abstract interface of the two models (Dify.tla, DifySF.tla):     *)
(*   - the same constants / bounds                                         *)
(*   - the same user operations (setField, listInsert, listRemove, addNode,*)
(*     removeNode, moveNode, addEdge, setRef) as op records                *)
(*   - the same abstract document ("Abs") used to compare states           *)
(*   - the same property definitions P1..P5                                *)
(*                                                                         *)
(* A model plugs in by providing, for its final / settled state:           *)
(*   Issued   : set of op records the users actually performed             *)
(*   Acked    : set of op records the user was told "saved/accepted"       *)
(*              (Dify: every performed op - the UI shows it applied;       *)
(*               dify-sf: ops the server committed and told the client)    *)
(*   Notified : set of op records the user was explicitly told "NOT saved" *)
(*              (rejected with reason / lost)                              *)
(*   Final    : Abs of the authoritative persisted state                   *)
(*   Ovw      : set of <<victim, overwriter>> op pairs: a write that       *)
(*              replaced a content-register value written by `victim`      *)
(*              without having seen it (value differs, register != layout) *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS
    Clients,      \* set of integers, e.g. {1,2,3} (ordered: Loro breaks ties by peer id)
    Nodes,        \* all node ids that may ever exist, e.g. {"n1","n2","n3"}
    InitNodes,    \* nodes present in the initial graph
    Fields,       \* content fields, e.g. {"f1","f2"}
    Vals,         \* values a setField can write, e.g. {1,2}
    MaxOps,       \* max user ops per client
    OpKinds,      \* subset of {"setField","listInsert","listRemove","addNode","removeNode",
                  \*            "moveNode","addEdge","setRef"}
    NoRef,        \* model value: "no reference" (initial value of every reference field)
    Broken        \* model value: explicit "reference broken" marker (dify-sf only)

Regs     == Fields \cup {"r", "p"}   \* "r" = variable reference field, "p" = position (layout, LWW)
Zero     == "v0"                   \* initial value of content registers (a string: keeps all values the same sort)
InitVal(g) == IF g = "r" THEN NoRef ELSE Zero
OpIds    == Clients \X (1..MaxOps)
NodeEdges == {<<s,t>> \in Nodes \X Nodes : s # t}
NoEdge   == <<"-","-">>

(* ---------- op records (one shape for everything) ---------- *)
MkOp(id, kind, n, g, v, it, e) ==
    [id |-> id, kind |-> kind, n |-> n, g |-> g, v |-> v, it |-> it, e |-> e]

\* every op the user could possibly issue with this id (each model filters by its own view)
CandidateOps(id) ==
      {MkOp(id,"setField", n, g, v, "-", NoEdge) : n \in Nodes, g \in Fields, v \in Vals}
          \* (only kinds listed in OpKinds are produced - see filters below)
   \cup {MkOp(id,"setRef", n, "r", m, "-", NoEdge) : n \in Nodes, m \in Nodes}
   \cup {MkOp(id,"moveNode", n, "p", v, "-", NoEdge) : n \in Nodes, v \in Vals}
   \cup {MkOp(id,"listInsert", n, "-", "-", id, NoEdge) : n \in Nodes}
   \cup {MkOp(id,"listRemove", n, "-", "-", it, NoEdge) : n \in Nodes, it \in OpIds}
   \cup {MkOp(id,"addNode", n, "-", "-", "-", NoEdge) : n \in Nodes}
   \cup {MkOp(id,"removeNode", n, "-", "-", "-", NoEdge) : n \in Nodes}
   \cup {MkOp(id,"addEdge", e[1], "-", "-", "-", e) : e \in NodeEdges}

KindOK(o) == o.kind \in OpKinds

\* workload locality (TLC cfg: `CONSTANT Region <- RegionAll` or `RegionSplit`)
RegionAll   == [c \in Clients |-> Nodes]
RegionSplit == LET a == CHOOSE n \in InitNodes : TRUE
                   first == CHOOSE x \in Clients : TRUE
               IN [c \in Clients |-> IF c = first THEN {a} ELSE InitNodes \ {a}]

IsRegWrite(o) == o.kind \in {"setField", "setRef", "moveNode"}
IsContentWrite(o) == o.kind \in {"setField", "setRef"}

(* ---------- abstract document ---------- *)
\* Abs = [nodes |-> SUBSET Nodes, val |-> [Nodes -> [Regs -> Value]],
\*        its |-> [Nodes -> SUBSET OpIds], edges |-> SUBSET NodeEdges]
AbsEq(a, b) ==
    /\ a.nodes = b.nodes
    /\ \A n \in a.nodes : /\ a.its[n] = b.its[n]
                          /\ \A g \in Regs : a.val[n][g] = b.val[n][g]
    /\ a.edges = b.edges

\* Property P4 on one abstract document: no unmarked dangling reference
\*   (a ref field naming a node that is not alive, or an edge with a missing endpoint).
NoDangling(a) ==
    /\ \A n \in a.nodes : LET v == a.val[n]["r"] IN
          (v \in Nodes) => v \in a.nodes
    /\ \A e \in a.edges : e[1] \in a.nodes /\ e[2] \in a.nodes

(* ---------- P1 / P5 building blocks ---------- *)
RemovedBy(A, n) == \E o \in A : o.kind = "removeNode" /\ o.n = n

\* Is the effect of acknowledged op o visible in the final document F?
Reflected(o, F, A) ==
    CASE o.kind \in {"setField","moveNode","setRef"} ->
            \/ o.n \notin F.nodes /\ RemovedBy(A, o.n)
            \/ o.n \in F.nodes /\ F.val[o.n][o.g] = o.v
            \/ o.kind = "setRef" /\ RemovedBy(A, o.v)       \* referenced node deleted: ref legitimately broken
      [] o.kind = "listInsert" ->
            \/ o.n \notin F.nodes /\ RemovedBy(A, o.n)
            \/ o.n \in F.nodes /\ o.id \in F.its[o.n]
            \/ \E r \in A : r.kind = "listRemove" /\ r.it = o.id
      [] o.kind = "listRemove" ->
            \/ o.n \notin F.nodes /\ RemovedBy(A, o.n)
            \/ o.n \in F.nodes /\ o.it \notin F.its[o.n]
      [] o.kind = "addNode"   -> o.n \in F.nodes \/ RemovedBy(A, o.n)
      [] o.kind = "removeNode" -> o.n \notin F.nodes
      [] o.kind = "addEdge"   -> \/ o.e \in F.edges
                                 \/ o.e[1] \notin F.nodes \/ o.e[2] \notin F.nodes

\* A *competing* acknowledged write on the same register legitimately explains a missing value
\* for P1 (whoever wins, one of them must lose; P2 judges whether the loser was treated fairly).
Competes(o, A) ==
    IsRegWrite(o) /\ \E o2 \in A : o2 # o /\ IsRegWrite(o2) /\ o2.n = o.n /\ o2.g = o.g

\* P1 violation witness: acknowledged, not reflected, not explained by a competitor.
LostAcked(o, F, A) == ~Reflected(o, F, A) /\ ~Competes(o, A)

NodesAccounted(F, A) ==
    \A n \in Nodes :
        ((n \in InitNodes) \/ (\E o \in A : o.kind = "addNode" /\ o.n = n))
            => (n \in F.nodes \/ RemovedBy(A, n))

(* ---------- the five properties (evaluated on a settled state) ---------- *)
\* Victims(Ovw): ops whose value was silently replaced by a write that had not seen it
Victims(Ovw) == {p[1] : p \in Ovw}

P1(A, F)                == NodesAccounted(F, A) /\ \A o \in A : ~LostAcked(o, F, A)
P2(Ovw)                 == Ovw = {}
P3(views, F)            == \A c \in DOMAIN views : AbsEq(views[c], F)
P4(F, views)            == NoDangling(F) /\ \A c \in DOMAIN views : NoDangling(views[c])
P5(Issued, A, N, F, Ovw) ==
    /\ \A o \in Issued : (o \in A) \/ (o \in N)                     \* every op reaches a terminal outcome
    /\ \A o \in A : (LostAcked(o, F, A) \/ o \in Victims(Ovw)) => o \in N   \* silently dropped => must have been told
=============================================================================
