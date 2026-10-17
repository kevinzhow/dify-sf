------------------------------ MODULE DifySF --------------------------------
(***************************************************************************)
(* Formal model of the dify-sf collaboration protocol (server-sequenced    *)
(* ops, durable log, per-client idempotent cseq, base-version stale-write  *)
(* rule, optimistic client with outbox).  Mirrors proto/Sources/CollabCore *)
(* plus the three decisions taken after the prototype:                     *)
(*   D1 layout ("p") is last-writer-wins: no stale rejection               *)
(*   D2 a stale-based write whose value equals the committed value is      *)
(*      accepted (no conflict)                                             *)
(*   D3 lists are item-level ops with stable ids (distinct items never     *)
(*      conflict; only the same item can be gone)                          *)
(*                                                                         *)
(* Abstractions (all conservative for safety, see REPORT):                 *)
(*  - snapshots/compaction are not modelled: welcome carries the log       *)
(*    prefix (a snapshot is just a compressed prefix).                     *)
(*  - server->client traffic (commit broadcasts, rejected/ack replies,     *)
(*    welcome catch-up) carries only information that is a function of the *)
(*    durable log and of the server's handled-cseq counter. It is modelled *)
(*    as client-initiated "pull" (CatchUp, or lazily just before an Edit)  *)
(*    that may happen at any time while the client has a server session: loss,       *)
(*    duplication and reordering of such messages are observationally the  *)
(*    same as delay (a later hello/welcome delivers exactly the same data).*)
(*    Client->server SUBMIT messages are explicit network messages with    *)
(*    loss / duplication / arbitrary delay+reordering.  Hello+welcome (the *)
(*    session handshake) is one atomic step Sync(c): a lost, duplicated or *)
(*    delayed hello is equivalent to "Sync not yet taken" (hello is        *)
(*    idempotent and monotone in `from`).                                  *)
(*  - clients are journaled (outbox survives client crash).                *)
(*  - time = steps; client timers are "Tick" actions, bounded in heal.     *)
(***************************************************************************)
EXTENDS Common, TLC

CONSTANTS MaxFaults,
          NoStale, NoCascade, NoDedup, EarlyAck, NoFrom, NoResend,   \* mutation switches (all FALSE = real protocol)
          Region,      \* Region[c] = nodes client c may edit (workload locality)
          NoTouch,     \* TRUE = removeNode ignores concurrent edits of the node (delete-vs-edit rule off)
          EqualStamp   \* TRUE = equal-value writes still take the version stamp (the BUGGY form of decision D2, found by TLC)

VARIABLES log, dur, sd, high, sess, toS,
          conn, sopen, hasSt, seen, outbox, ncs,
          issued, acked, notified, lw, ovw, phase, fl

vars == <<log, dur, sd, high, sess, toS, conn, sopen, hasSt, seen, outbox, ncs,
          issued, acked, notified, lw, ovw, phase, fl>>

Big == 100   \* local (optimistic) version stamp: larger than any server seq

(*************************** document & rules ******************************)
EmptyDoc ==
    [ nodes |-> InitNodes, dead |-> {},
      val   |-> [n \in Nodes |-> [g \in Regs |-> InitVal(g)]],
      ver   |-> [n \in Nodes |-> [g \in Regs |-> [seq |-> 0, by |-> 0]]],
      tch   |-> [n \in Nodes |-> [c \in Clients |-> 0]],
      its   |-> [n \in Nodes |-> {}], idead |-> {},
      edges |-> {}, edead |-> {} ]

\* stale-write rule on register (n,g): someone else wrote it after `base`, and the value would change.
Stale(D, n, g, base, c, v) ==
    /\ ~NoStale
    /\ g # "p"                               \* D1
    /\ D.ver[n][g].seq > base
    /\ D.ver[n][g].by # c                    \* same-client exemption (proto section 7)
    /\ D.val[n][g] # v                       \* D2

Valid(D, o, base, c) ==
    CASE o.kind = "setField"   -> o.n \in D.nodes /\ ~Stale(D, o.n, o.g, base, c, o.v)
      [] o.kind = "setRef"     -> /\ o.n \in D.nodes /\ o.v \in D.nodes /\ o.v # o.n
                                  /\ ~Stale(D, o.n, "r", base, c, o.v)
      [] o.kind = "moveNode"   -> o.n \in D.nodes
      [] o.kind = "listInsert" -> o.n \in D.nodes /\ o.it \notin D.idead /\ o.it \notin D.its[o.n]
      [] o.kind = "listRemove" -> o.n \in D.nodes /\ o.it \in D.its[o.n]
      [] o.kind = "addNode"    -> o.n \notin D.nodes /\ o.n \notin D.dead
      [] o.kind = "removeNode" -> /\ o.n \in D.nodes
                                  /\ (NoTouch \/ \A c2 \in Clients \ {c} : D.tch[o.n][c2] <= base)     \* delete vs edit
                                  /\ \A x \in D.nodes \ {o.n} :                          \* cascade is a write too
                                        D.val[x]["r"] = o.n => ~Stale(D, x, "r", base, c, Broken)
      [] o.kind = "addEdge"    -> /\ o.e[1] \in D.nodes /\ o.e[2] \in D.nodes
                                  /\ o.e \notin D.edges /\ o.e \notin D.edead

\* the registers an op writes (explicit + cascade), as <<node, reg, value>>
WritesOf(D, o) ==
    CASE o.kind \in {"setField","setRef"} -> {<<o.n, o.g, o.v>>}
      [] o.kind = "removeNode" -> IF NoCascade THEN {}
                                  ELSE {<<x, "r", Broken>> : x \in {y \in D.nodes \ {o.n} : D.val[y]["r"] = o.n}}
      [] OTHER -> {}

\* An accepted equal-value write (decision D2) changes nothing, so it must NOT take the register's version stamp
\* (otherwise the same-client exemption of Stale() would later let this client overwrite foreign writes it never saw).
IsNoop(D, o) == o.kind \in {"setField","setRef"} /\ o.n \in D.nodes /\ D.val[o.n][o.g] = o.v /\ ~EqualStamp

Apply(D, o, seq, c) ==
    CASE IsNoop(D, o) -> D
      [] o.kind \in {"setField","setRef","moveNode"} ->
            IF o.n \notin D.nodes THEN D ELSE
            [D EXCEPT !.val[o.n][o.g] = o.v,
                      !.ver[o.n][o.g] = [seq |-> seq, by |-> c],
                      !.tch[o.n][c]   = seq]
      [] o.kind = "listInsert" ->
            IF o.n \notin D.nodes THEN D ELSE
            [D EXCEPT !.its[o.n] = @ \cup {o.it}, !.tch[o.n][c] = seq]
      [] o.kind = "listRemove" ->
            IF o.n \notin D.nodes THEN D ELSE
            [D EXCEPT !.its[o.n] = @ \ {o.it}, !.idead = @ \cup {o.it}, !.tch[o.n][c] = seq]
      [] o.kind = "addNode" ->
            IF o.n \in D.nodes \/ o.n \in D.dead THEN D ELSE
            [D EXCEPT !.nodes = @ \cup {o.n}, !.tch[o.n][c] = seq]
      [] o.kind = "addEdge" ->
            IF o.e \in D.edges \/ o.e \in D.edead \/ o.e[1] \notin D.nodes \/ o.e[2] \notin D.nodes THEN D ELSE
            [D EXCEPT !.edges = @ \cup {o.e}, !.tch[o.e[1]][c] = seq, !.tch[o.e[2]][c] = seq]
      [] o.kind = "removeNode" ->
            IF o.n \notin D.nodes THEN D ELSE
            LET brk == {x \in D.nodes \ {o.n} : D.val[x]["r"] = o.n /\ ~NoCascade}
                gone == {e \in D.edges : o.n \in {e[1], e[2]}}
            IN [D EXCEPT !.nodes = @ \ {o.n}, !.dead = @ \cup {o.n},
                         !.edges = @ \ gone, !.edead = @ \cup gone,
                         !.val = [x \in Nodes |-> IF x \in brk THEN [D.val[x] EXCEPT !["r"] = Broken] ELSE D.val[x]],
                         !.ver = [x \in Nodes |-> IF x \in brk THEN [D.ver[x] EXCEPT !["r"] = [seq |-> seq, by |-> c]] ELSE D.ver[x]],
                         !.tch = [x \in Nodes |-> IF x \in brk THEN [D.tch[x] EXCEPT ![c] = seq] ELSE D.tch[x]]]

AbsOf(D) == [nodes |-> D.nodes, val |-> D.val, its |-> D.its, edges |-> D.edges]

RECURSIVE Replay(_, _)
Replay(lg, k) == IF k = 0 THEN EmptyDoc
                 ELSE LET e == lg[k] IN Apply(Replay(lg, k-1), e.op, k, e.c)

Min(a, b) == IF a < b THEN a ELSE b
Confirmed(c) == Replay(log, Min(seen[c], Len(log)))

RECURSIVE FoldOut(_, _, _, _)
FoldOut(D, ob, i, c) ==
    IF i > Len(ob) THEN D
    ELSE LET e == ob[i]
             D2 == IF e.out = "none" /\ Valid(D, e.op, e.base, c) THEN Apply(D, e.op, Big, c) ELSE D
         IN FoldOut(D2, ob, i+1, c)
View(c) == FoldOut(Confirmed(c), outbox[c], 1, c)

(*************************** helpers *****************************************)
HighOf(lg, c) == LET cs == {lg[k].cs : k \in {j \in 1..Len(lg) : lg[j].c = c}}
                 IN IF cs = {} THEN 0 ELSE CHOOSE m \in cs : \A x \in cs : x <= m

Committed(c, cs) == \E k \in 1..Len(log) : log[k].c = c /\ log[k].cs = cs

\* hello promise: the client will never (re)send a cseq below `from`
HelloFrom(c) == IF NoFrom THEN 1
                ELSE LET un == {outbox[c][i].cs : i \in 1..Len(outbox[c])}
                     IN IF un = {} THEN ncs[c] ELSE CHOOSE m \in un : \A x \in un : m <= x
SubMsg(c, e) == [c |-> c, cs |-> e.cs, base |-> e.base, op |-> e.op]
ResendOf(c, ob) == IF NoResend THEN {}
                   ELSE {SubMsg(c, ob[i]) : i \in {j \in 1..Len(ob) : ob[j].out = "none"}}

InFlight(c) == \E m \in toS : m.c = c

\* leading resolved entries of an outbox are released to the user (in cseq order)
RelLen(ob) == CHOOSE k \in 0..Len(ob) :
                 /\ \A i \in 1..k : ob[i].out # "none"
                 /\ (k = Len(ob) \/ ob[k+1].out = "none")
Rest(ob)        == SubSeq(ob, RelLen(ob) + 1, Len(ob))
AckedOps(ob)    == {ob[i].op : i \in {j \in 1..RelLen(ob) : ob[j].out = "committed"}}
NotifiedOps(ob) == {ob[i].op : i \in {j \in 1..RelLen(ob) : ob[j].out # "committed"}}

\* own entries among log[from+1..upto] become "committed"
IngestOut(c, ob, from, upto) ==
    [i \in DOMAIN ob |-> IF ob[i].out = "none" /\ \E k \in (from+1)..upto : log[k].c = c /\ log[k].cs = ob[i].cs
                         THEN [ob[i] EXCEPT !.out = "committed"] ELSE ob[i]]

Init ==
    /\ log = <<>> /\ dur = 0 /\ sd = EmptyDoc
    /\ high = [c \in Clients |-> 0] /\ sess = Clients       \* everybody starts connected with an open session
    /\ toS = {}
    /\ conn = [c \in Clients |-> TRUE] /\ sopen = [c \in Clients |-> TRUE] /\ hasSt = [c \in Clients |-> TRUE]
    /\ seen = [c \in Clients |-> 0] /\ outbox = [c \in Clients |-> <<>>] /\ ncs = [c \in Clients |-> 1]
    /\ issued = {} /\ acked = {} /\ notified = {}
    /\ lw = [n \in Nodes |-> [g \in Regs |-> {}]]          \* ghost: all committed writes per register {[k,c,v,op]}
    /\ ovw = {}
    /\ phase = "run" /\ fl = 0

(*************************** user actions ************************************)
\* Edit: the user edits against what the client has seen so far. Pulling committed entries is lazy: just
\* before an edit the client may have received any prefix of the log (k in seen..Len(log)); between edits the
\* intermediate catch-up steps are unobservable (they only matter for the edit's base/view), so they are not
\* separate actions.  (Over-approximation: a disconnected client with state may also have pulled before it
\* dropped - every real behaviour is included.)
Edit(c) ==
    /\ phase = "run" /\ hasSt[c] /\ ncs[c] <= MaxOps
    /\ \E k \in seen[c]..Len(log) :
         LET ob0 == IngestOut(c, outbox[c], seen[c], k)
             ob1 == Rest(ob0)
             V   == FoldOut(Replay(log, k), ob1, 1, c)
             id  == <<c, ncs[c]>>
             ok(o) == KindOK(o) /\ Valid(V, o, k, c) /\ (IsRegWrite(o) => V.val[o.n][o.g] # o.v)
                     /\ (IF o.kind = "addEdge" THEN {o.e[1], o.e[2]} \subseteq Region[c] ELSE o.n \in Region[c])
         IN \E o \in {x \in CandidateOps(id) : ok(x)} :
              LET e == [cs |-> ncs[c], base |-> k, op |-> o, out |-> "none"]
              IN /\ outbox' = [outbox EXCEPT ![c] = Append(ob1, e)]
                 /\ seen' = [seen EXCEPT ![c] = k]
                 /\ acked' = acked \cup AckedOps(ob0) /\ notified' = notified \cup NotifiedOps(ob0)
                 /\ ncs' = [ncs EXCEPT ![c] = @ + 1]
                 /\ issued' = issued \cup {o}
                 /\ toS' = IF conn[c] /\ sopen[c] THEN toS \cup {SubMsg(c, e)} ELSE toS
    /\ UNCHANGED <<log, dur, sd, high, sess, conn, sopen, hasSt, lw, ovw, phase, fl>>

(*************************** server ******************************************)
LwUpd(L, ws, k, c, op) ==
    [n \in Nodes |-> [g \in Regs |->
        L[n][g] \cup {[k |-> k, c |-> c, op |-> op, v |-> w[3]] : w \in {x \in ws : x[1] = n /\ x[2] = g}}]]

\* the server handles one submit (the message leaves the network unless `keep` = duplication)
ServerRecv(m, keep) ==
    /\ toS' = IF keep THEN toS ELSE toS \ {m}
    /\ IF m.c \notin sess THEN                              \* no session (server restarted): ignored
          UNCHANGED <<log, dur, sd, high, lw, ovw>>
       ELSE IF m.cs <= high[m.c] /\ ~NoDedup THEN          \* retransmit of a handled op: never apply twice
          UNCHANGED <<log, dur, sd, high, lw, ovw>>
       ELSE IF m.cs > high[m.c] + 1 /\ ~NoDedup THEN        \* gap: ignore, the client retransmits in order
          UNCHANGED <<log, dur, sd, high, lw, ovw>>
       ELSE IF ~Valid(sd, m.op, m.base, m.c) THEN          \* reject (the sender learns it via CatchUp)
          /\ high' = [high EXCEPT ![m.c] = m.cs]
          /\ UNCHANGED <<log, dur, sd, lw, ovw>>
       ELSE                                                \* commit: durable append, then memory
          LET k   == Len(log) + 1
              ent == [c |-> m.c, cs |-> m.cs, base |-> m.base, op |-> m.op]
              ws0 == WritesOf(sd, m.op)
              cur(w) == IF lw[w[1]][w[2]] = {} THEN InitVal(w[2])
                        ELSE (CHOOSE x \in lw[w[1]][w[2]] : \A y \in lw[w[1]][w[2]] : y.k <= x.k).v
              ws  == {z \in ws0 : cur(z) # z[3]}          \* only writes that change a value count as writes
              \* P2 oracle (strict, independent of the server's last-writer shortcut): the op changes the value of a
              \* register although ANOTHER client wrote it after m.base  =>  it overwrote a write it never saw
              bad == UNION {{<<x.op, m.op>> : x \in {y \in lw[w[1]][w[2]] : y.k > m.base /\ y.c # m.c}} : w \in ws}
              \* same oracle for node removal: a removeNode must not discard another client's unseen change to the node
              rn == m.op.n
              regtouch == UNION {{r.k : r \in {y \in lw[rn][g] : y.k > m.base /\ y.c # m.c}} : g \in Regs}
              othertouch == {j \in (m.base+1)..Len(log) :
                                /\ log[j].c # m.c
                                /\ \/ log[j].op.kind \in {"listInsert", "listRemove", "moveNode"} /\ log[j].op.n = rn
                                   \/ log[j].op.kind = "addEdge" /\ rn \in {log[j].op.e[1], log[j].op.e[2]}}
              delbad == IF m.op.kind = "removeNode"
                        THEN {<<log[j].op, m.op>> : j \in (regtouch \cup othertouch) \cap 1..Len(log)}
                        ELSE {}
          IN /\ log' = Append(log, ent)
             /\ dur' = IF EarlyAck THEN dur ELSE k
             /\ sd' = Apply(sd, m.op, k, m.c)
             /\ high' = [high EXCEPT ![m.c] = m.cs]
             /\ lw' = LwUpd(lw, ws, k, m.c, m.op)
             /\ ovw' = ovw \cup bad \cup delbad
    /\ UNCHANGED <<sess, conn, sopen, hasSt, seen, outbox, ncs, issued, acked, notified>>

DeliverS(m) == ServerRecv(m, FALSE) /\ UNCHANGED <<phase, fl>>
DupS(m)     == /\ phase = "run" /\ fl < MaxFaults /\ ServerRecv(m, TRUE) /\ fl' = fl + 1 /\ UNCHANGED phase
DropS(m)    == /\ phase = "run" /\ fl < MaxFaults /\ toS' = toS \ {m} /\ fl' = fl + 1
               /\ UNCHANGED <<log, dur, sd, high, sess, conn, sopen, hasSt, seen, outbox, ncs,
                              issued, acked, notified, lw, ovw, phase>>

Persist ==     \* only meaningful with the EarlyAck mutation (ack before the log write is durable)
    /\ EarlyAck /\ dur < Len(log)
    /\ dur' = dur + 1
    /\ UNCHANGED <<log, sd, high, sess, toS, conn, sopen, hasSt, seen, outbox, ncs,
                   issued, acked, notified, lw, ovw, phase, fl>>

ServerCrash ==   \* fault: memory lost (sessions, handled counters), recover from the durable log
    /\ phase = "run" /\ fl < MaxFaults
    /\ LET lg == SubSeq(log, 1, dur) IN
       /\ log' = lg /\ dur' = Len(lg)
       /\ sd' = Replay(lg, Len(lg))
       /\ high' = [c \in Clients |-> HighOf(lg, c)]
    /\ sess' = {}
    /\ fl' = fl + 1
    /\ UNCHANGED <<toS, conn, sopen, hasSt, seen, outbox, ncs, issued, acked, notified, lw, ovw, phase>>

(*************************** client ******************************************)
Avail(c) == conn[c] /\ c \in sess      \* client is connected and the server holds its session

CatchUp(c) ==    \* receive every committed entry (broadcast / welcome catch-up) and the server's answers
    /\ Avail(c) /\ hasSt[c]
    /\ LET ob0 == IngestOut(c, outbox[c], seen[c], Len(log))
           ob1 == [i \in DOMAIN ob0 |-> IF ob0[i].out = "none" /\ ob0[i].cs <= high[c] /\ ~Committed(c, ob0[i].cs)
                                        THEN [ob0[i] EXCEPT !.out = "rejected"] ELSE ob0[i]]
       IN /\ seen' = [seen EXCEPT ![c] = Len(log)]
          /\ outbox' = [outbox EXCEPT ![c] = Rest(ob1)]
          /\ acked' = acked \cup AckedOps(ob1) /\ notified' = notified \cup NotifiedOps(ob1)
    /\ (seen' # seen \/ outbox' # outbox)                 \* a catch-up that changes nothing is not a step
    /\ UNCHANGED <<log, dur, sd, high, sess, toS, conn, sopen, hasSt, ncs, issued, lw, ovw, phase, fl>>

Sync(c) ==       \* hello + welcome: session (re)opened, client resends everything unresolved
    /\ conn[c]
    /\ ~sopen[c] \/ c \notin sess                       \* hello is only needed when no session is open
    /\ LET h == IF high[c] > HelloFrom(c) - 1 THEN high[c] ELSE HelloFrom(c) - 1 IN
       /\ sess' = sess \cup {c}
       /\ high' = [high EXCEPT ![c] = h]
    /\ sopen' = [sopen EXCEPT ![c] = TRUE] /\ hasSt' = [hasSt EXCEPT ![c] = TRUE]
    /\ IF hasSt[c]
       THEN UNCHANGED <<seen, outbox, acked, notified>>
       ELSE \* a restarted client gets a snapshot at the server head and learns its own commits from it
            LET ob == IngestOut(c, outbox[c], 0, Len(log)) IN
            /\ seen' = [seen EXCEPT ![c] = Len(log)]
            /\ outbox' = [outbox EXCEPT ![c] = Rest(ob)]
            /\ acked' = acked \cup AckedOps(ob) /\ notified' = notified \cup NotifiedOps(ob)
    /\ toS' = toS \cup ResendOf(c, IF hasSt[c] THEN outbox[c] ELSE Rest(IngestOut(c, outbox[c], 0, Len(log))))
    /\ UNCHANGED <<log, dur, sd, conn, ncs, issued, lw, ovw, phase, fl>>

Resend(c) ==     \* retransmit timer (modelled only when it can matter: nothing in flight and the server has not handled the op)
    /\ conn[c] /\ sopen[c] /\ ~InFlight(c)
    /\ \E i \in 1..Len(outbox[c]) : /\ outbox[c][i].out = "none"
                                   /\ outbox[c][i].cs > high[c]          \* server has not handled it
                                   /\ (outbox[c][i].cs <= high[c] + 1 \/ NoDedup)   \* and could accept it now (else the resend is a no-op)
    /\ ResendOf(c, outbox[c]) # {}
    /\ toS' = toS \cup ResendOf(c, outbox[c])
    /\ UNCHANGED <<log, dur, sd, high, sess, conn, sopen, hasSt, seen, outbox, ncs,
                   issued, acked, notified, lw, ovw, phase, fl>>

Reconnect(c) ==
    /\ ~conn[c]
    /\ conn' = [conn EXCEPT ![c] = TRUE] /\ sopen' = [sopen EXCEPT ![c] = FALSE]
    /\ UNCHANGED <<log, dur, sd, high, sess, toS, hasSt, seen, outbox, ncs, issued, acked, notified, lw, ovw, phase, fl>>

LinkDown(c) ==    \* the connection drops: in-flight messages of c are lost, the server forgets the session
    /\ conn' = [conn EXCEPT ![c] = FALSE] /\ sopen' = [sopen EXCEPT ![c] = FALSE]
    /\ sess' = sess \ {c}
    /\ toS' = {m \in toS : m.c # c}

Disconnect(c) ==  \* fault
    /\ phase = "run" /\ fl < MaxFaults /\ conn[c]
    /\ LinkDown(c) /\ fl' = fl + 1
    /\ UNCHANGED <<log, dur, sd, high, hasSt, seen, outbox, ncs, issued, acked, notified, lw, ovw, phase>>

ClientCrash(c) == \* fault: in-memory state lost; the journaled outbox survives and is retried
    /\ phase = "run" /\ fl < MaxFaults
    /\ LinkDown(c) /\ fl' = fl + 1
    /\ hasSt' = [hasSt EXCEPT ![c] = FALSE] /\ seen' = [seen EXCEPT ![c] = 0]
    /\ outbox' = [outbox EXCEPT ![c] = [i \in DOMAIN outbox[c] |-> [outbox[c][i] EXCEPT !.out = "none"]]]
    /\ UNCHANGED <<log, dur, sd, high, ncs, issued, acked, notified, lw, ovw, phase>>

(*************************** phases / spec ***********************************)
Settled ==
    /\ phase = "heal" /\ toS = {}
    /\ \A c \in Clients : /\ conn[c] /\ sopen[c] /\ hasSt[c] /\ c \in sess
                          /\ outbox[c] = <<>> /\ seen[c] = Len(log)

Quiesce == /\ phase = "run" /\ phase' = "heal"
           /\ UNCHANGED <<log, dur, sd, high, sess, toS, conn, sopen, hasSt, seen, outbox, ncs,
                          issued, acked, notified, lw, ovw, fl>>

Done == Settled /\ UNCHANGED vars

UserEdit        == \E c \in Clients : Edit(c)
ClientSync      == \E c \in Clients : Sync(c)
ClientResend    == \E c \in Clients : Resend(c)
ClientCatchUp   == \E c \in Clients : CatchUp(c)
ClientReconnect == \E c \in Clients : Reconnect(c)
LinkDrop        == \E c \in Clients : Disconnect(c)
ClientCrashes   == \E c \in Clients : ClientCrash(c)
ServerHandles   == \E m \in toS : DeliverS(m)
NetDuplicates   == \E m \in toS : DupS(m)
NetDrops        == \E m \in toS : DropS(m)

Next ==
    \/ UserEdit \/ ClientSync \/ ClientResend \/ ClientCatchUp \/ ClientReconnect
    \/ LinkDrop \/ ClientCrashes \/ ServerHandles \/ NetDuplicates \/ NetDrops
    \/ ServerCrash \/ Persist \/ Quiesce \/ Done

Spec == Init /\ [][Next]_vars

Sym == Permutations(Clients) \cup Permutations(Vals) \cup Permutations(InitNodes)   \* clients, values and the initial nodes are interchangeable

(*************************** properties ***************************************)
Views == [c \in Clients |-> AbsOf(View(c))]
Final == AbsOf(sd)

\* ---- checked in every reachable state ----
Inv_P2    == P2(ovw)                                           \* no silent stale overwrite (log-level oracle)
Inv_P4    == NoDangling(AbsOf(sd)) /\ \A c \in Clients : NoDangling(AbsOf(View(c)))
Inv_Acked == \A o \in acked : \E k \in 1..Len(log) : log[k].op = o                 \* ack => durable in the log
Inv_Truth == /\ acked \cap notified = {}
             /\ \A o \in notified : \A k \in 1..Len(log) : log[k].op # o            \* "not saved" is truthful
Inv_Log   == /\ \A i, j \in 1..Len(log) : (i # j) => ~(log[i].c = log[j].c /\ log[i].cs = log[j].cs)
             /\ \A i, j \in 1..Len(log) : (log[i].c = log[j].c /\ i < j) => log[i].cs < log[j].cs
Inv_Recover == sd = Replay(log, Len(log))                                          \* recovery == live state

\* ---- checked on settled states (after faults stop and the network drains) ----
Inv_P1 == Settled => P1(acked, Final)
Inv_P3 == Settled => P3(Views, Final)
Inv_P5 == Settled => P5(issued, acked, notified, Final, ovw)

(*********************** bounded-liveness (P3 convergence) ***********************************)
\* After Quiesce (no more edits/faults) every fair execution must reach Settled.  Checked with TLC's temporal
\* checker on small configurations (SFlive_*.cfg; symmetry reduction is not used for temporal properties).
LiveSpec == Spec /\ WF_vars(ClientSync) /\ WF_vars(ClientResend) /\ WF_vars(ClientCatchUp)
                 /\ WF_vars(ClientReconnect) /\ WF_vars(ServerHandles)      \* every timer / delivery eventually fires
Conv == (phase = "heal") ~> Settled

(*********************** coverage (non-vacuity) probes ***********************************)
\* Each Cov_X is EXPECTED TO BE VIOLATED: the violation trace proves the interesting behaviour is reachable
\* inside the explored bounds (so "no property violated" is not an artefact of unreachable code paths).
Cov_Rejected     == notified = {}                                        \* some op is rejected and the user is told
Cov_RejectDelete == ~(\E o \in notified : o.kind = "removeNode")        \* a delete-vs-edit / stale delete is rejected
Cov_EqualAccept  == ~(\E k \in 1..Len(log) : /\ IsNoop(Replay(log, k-1), log[k].op) /\ log[k].base < k-1)   \* decision D2 taken
Cov_Broken       == ~(\E x \in Nodes : x \in sd.nodes /\ sd.val[x]["r"] = Broken)                    \* cascade wrote a broken marker
Cov_Concurrent   == ~(\E k \in 2..Len(log) : log[k].base < k-1 /\ log[k].c # log[k-1].c)              \* committed on a stale base
Cov_DupInFlight  == ~(\E m \in toS : m.cs <= high[m.c])                                               \* handled op still in the network
Cov_ServerCrash  == ~(Len(log) > 0 /\ sess = {})                                                       \* crash after commits
Cov_ClientCrash  == ~(\E c \in Clients : ~hasSt[c])                                                    \* client lost its state
Cov_CommitAfterCrash == ~(\E c \in Clients : conn[c] /\ c \notin sess /\ outbox[c] # <<>> /\ high[c] = 0 /\ Len(log) > 0)

(*********************** readable traces (TLC ALIAS, no effect on checking) ******************)
OpTag(o) == <<o.id, o.kind, o.n, o.g, o.v, o.it, o.e>>
Alias == [ phase |-> phase, fl |-> fl, log |-> [k \in 1..Len(log) |-> <<log[k].c, log[k].cs, log[k].base, OpTag(log[k].op)>>],
           sd |-> [nodes |-> sd.nodes, val |-> sd.val, its |-> sd.its, edges |-> sd.edges],
           seen |-> seen, high |-> high, sess |-> sess, conn |-> conn, sopen |-> sopen, hasSt |-> hasSt,
           outbox |-> [c \in Clients |-> [i \in DOMAIN outbox[c] |-> <<outbox[c][i].cs, outbox[c][i].base, outbox[c][i].out, OpTag(outbox[c][i].op)>>]],
           toS |-> {<<m.c, m.cs, m.base, OpTag(m.op)>> : m \in toS},
           acked |-> {o.id : o \in acked}, notified |-> {o.id : o \in notified}, ovw |-> {<<p[1].id, p[2].id>> : p \in ovw} ]
=============================================================================
