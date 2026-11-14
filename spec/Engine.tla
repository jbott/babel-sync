------------------------------- MODULE Engine -------------------------------
(***************************************************************************)
(* One device's sync engine, step by step, against a server that anyone    *)
(* else may change at any moment.                                          *)
(*                                                                         *)
(* Sync.tla treats "take the server's value" and "push mine" as single     *)
(* steps over a fixed set of entries with opaque values.  It answers a     *)
(* different question (do several devices converge when changes are        *)
(* missed or records forgotten, and is the audit needed) and is kept as    *)
(* it is.  This module opens up what that one abstracts away:              *)
(*                                                                         *)
(*   - an engine action is several steps (fetch, vacate, intend, check     *)
(*     the disk, write, record), and the user may edit or delete a file,   *)
(*     someone else may change the server, and the device may crash,       *)
(*     between any two of them;                                            *)
(*   - an entry has an identity and a path, entries are created, renamed   *)
(*     and deleted, a path is held by different identities over time, and  *)
(*     the feed replays every historical event in order, each carrying     *)
(*     the path it had then, not the path the entry has now;               *)
(*   - a note's text is a set of tokens and a note is a two-phase set      *)
(*     (tokens added, tokens deleted), which is the smallest thing that    *)
(*     merges like the Yjs document does.  Taking a file F into a note     *)
(*     against base B adds F \ B and deletes B \ F, so on a server text S  *)
(*     the result is (S \cup (F \ B)) \ (B \ F).  Against the wrong base   *)
(*     this visibly deletes a token nobody chose to delete, or adds again  *)
(*     a token the note already had.                                       *)
(*                                                                         *)
(* WHY ONE DEVICE IS ENOUGH                                                *)
(*                                                                         *)
(* Devices never talk to each other.  Everything a device observes of the  *)
(* others is a sequence of changes to the server, each of which the        *)
(* server's rules allow.  The Srv* actions below allow every such change   *)
(* at every moment, so the behaviours of device d in a system of n         *)
(* devices are a subset of the behaviours of the one device here.  A       *)
(* safety property proved here of the one device against all server        *)
(* behaviours therefore holds of each device among any number.             *)
(*                                                                         *)
(* What this does not give directly: agreement between devices.  It        *)
(* follows in a second step.  SyncedMeansEqual says a device that reports  *)
(* synced equals the server, so two devices that both report synced at     *)
(* the same server state equal each other.  The liveness property is       *)
(* weaker than it looks for many devices: it assumes the server            *)
(* eventually stops changing, and with n devices "the server stops" needs  *)
(* each device to stop pushing, which is what is being proved.  Sync.tla   *)
(* checks that circular part directly for two devices.  Also not covered:  *)
(* two engines on one disk.                                                *)
(*                                                                         *)
(* WHY 3 PATHS AND 4 IDENTITIES                                            *)
(*                                                                         *)
(* One engine action reads and writes at most three paths: where the       *)
(* entry is (source), where the server says it should be (destination),    *)
(* and a free path for a conflict copy of whatever was in the way.  It     *)
(* involves at most four identities: the entry acted on, the entry         *)
(* recorded at the destination, the entry the server now has at that path  *)
(* (which may be neither), and the identity a conflict copy gets when it   *)
(* is sent as a new note.  Every interaction inside a single action is     *)
(* therefore present at this size.  Interactions that need a chain of      *)
(* actions over more paths than that (a three-way rotation of names, two   *)
(* conflict copies alive at once) are not, and when the model runs out of  *)
(* free paths or identities it stops and says so (starved) rather than     *)
(* inventing a behaviour.                                                  *)
(*                                                                         *)
(* WHAT IS ASSUMED                                                         *)
(*                                                                         *)
(* Listed in docs/sync.md under "What the engine model assumes".  The      *)
(* ones that matter most: the engine runs one task at a time; a single     *)
(* write to the record store is atomic and durable; reading a file and     *)
(* then writing or removing it is one step (no edit lands between the      *)
(* re-read and the write; add "write-window" to Bugs to drop this and see  *)
(* the edit lost); the server refuses to delete a note whose text is not   *)
(* the text the device names.                                              *)
(*                                                                         *)
(* THE SWITCHES                                                            *)
(*                                                                         *)
(* Recovery is what a restarted engine does with an intent it finds        *)
(* pending.  "briefed" is the rule as first written down: adopt the        *)
(* intent if the file equals its text, or there was no base, or the file   *)
(* is closer to its text than to the base.  "closer" drops the no-base     *)
(* clause, "exact" also drops the closer clause.  All three fail.  "safe"  *)
(* is the rule this model passes with; see Recover.                        *)
(*                                                                         *)
(* Vacate is the order in which a note in the way of an arriving one is    *)
(* let go: "file-first" removes its file and then its record, as the code  *)
(* did when this was written, and fails; "record-first" passes.            *)
(*                                                                         *)
(* Bugs puts back, one name each, the faults this model exists to see:     *)
(*   "check-before-intent"        the disk is read before the intent is    *)
(*                                recorded instead of after                *)
(*   "first-check-before-intent"  the same for a note's first write        *)
(*   "no-intent"                  the file is written with no intent       *)
(*   "send-before-record"         a local edit is sent before its base is  *)
(*                                recorded                                 *)
(*   "seq-without-entry"          a displaced note keeps its seq           *)
(*   "write-window"               an edit may land between the re-read     *)
(*                                and the write                            *)
(*                                                                         *)
(* THE GHOSTS                                                              *)
(*                                                                         *)
(* discarded holds every token someone removed while looking at it: the    *)
(* user deleting it from a file or deleting the file, someone else         *)
(* deleting it from a note or deleting the note.  truth[i] is the text     *)
(* the engine last wrote to, or found in, the file of entry i.             *)
(* duplicated collects tokens the engine took for new typing although the  *)
(* note already had them.  None of the three is read by any action.        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Paths, Ids, MaxLocal, MaxRemote, MaxCrashes, Recovery, Vacate, Bugs

Symmetry == Permutations(Paths) \cup Permutations(Ids)

Missing == {0}
EmptyDoc == [a |-> {}, d |-> {}]
Text(D) == D.a \ D.d
Join(D, E) == [a |-> D.a \cup E.a, d |-> D.d \cup E.d]
Fork(B, F) == [a |-> B.a \cup (F \ Text(B)), d |-> B.d \cup (Text(B) \ F)]
Whole(F) == [a |-> F, d |-> {}]
Max(x, y) == IF x >= y THEN x ELSE y
Distance(F, G) == Cardinality((F \ G) \cup (G \ F))

NoIntent == [on |-> FALSE, doc |-> EmptyDoc]
NoRec == [on |-> FALSE, path |-> "none", doc |-> EmptyDoc, has |-> FALSE,
          dirty |-> FALSE, seq |-> 0, next |-> NoIntent]
NoEntry == [state |-> "unused", path |-> "none", doc |-> EmptyDoc]
NoCur == [i |-> "none", p |-> "none", s |-> 0, b |-> 0, d |-> EmptyDoc,
          feed |-> FALSE, was |-> Missing]

VARIABLES
  srv, log,
  file, rec, cursor,
  pc, cur, buried,
  nLocal, nRemote, nCrash, ntok,
  discarded, truth, duplicated, starved

server == <<srv, log>>
durable == <<file, rec, cursor>>
volatile == <<pc, cur, buried>>
budget == <<nLocal, nRemote, nCrash>>
ghost == <<discarded, truth, duplicated, starved>>
vars == <<srv, log, file, rec, cursor, pc, cur, buried,
          nLocal, nRemote, nCrash, ntok, discarded, truth, duplicated, starved>>

Init ==
  /\ srv = [i \in Ids |-> NoEntry]
  /\ log = <<>>
  /\ file = [p \in Paths |-> Missing]
  /\ rec = [i \in Ids |-> NoRec]
  /\ cursor = 0
  /\ pc = "idle"
  /\ cur = NoCur
  /\ buried = [i \in Ids |-> 0]
  /\ nLocal = 0
  /\ nRemote = 0
  /\ nCrash = 0
  /\ ntok = 0
  /\ discarded = {}
  /\ truth = [i \in Ids |-> Missing]
  /\ duplicated = {}
  /\ starved = FALSE

Bug(b) == b \in Bugs
Fresh == ntok + 1
Live(i) == srv[i].state = "live"
ServerAt(p) == {i \in Ids : Live(i) /\ srv[i].path = p}
Unused == {i \in Ids : srv[i].state = "unused"}
Events(i, upTo) == {k \in 1..upTo : log[k].id = i}
Last(S) == IF S = {} THEN 0 ELSE CHOOSE k \in S : \A m \in S : m <= k
SeqOf(i) == Last(Events(i, Len(log)))
Happened(i, p, live) == Append(log, [id |-> i, path |-> p, live |-> live])

RecAt(p) == {i \in Ids : rec[i].on /\ rec[i].path = p}
FreePaths == {c \in Paths : file[c] = Missing /\ RecAt(c) = {}}
Seen(i) == IF rec[i].on THEN rec[i].seq ELSE buried[i]
PendingIntent == \E i \in Ids : rec[i].on /\ rec[i].next.on
At(l) == pc = l /\ ~starved
Idle == At("idle")
Ready == Idle /\ ~PendingIntent
Untouched(j) == rec[j].has /\ ~rec[j].dirty /\ file[rec[j].path] = Text(rec[j].doc)

(***************************************************************************)
(* Someone else.  Any change the server allows, at any time.               *)
(***************************************************************************)

SrvCreate(i, p) ==
  /\ nRemote < MaxRemote /\ ~starved
  /\ srv[i].state = "unused"
  /\ ServerAt(p) = {}
  /\ srv' = [srv EXCEPT ![i] = [state |-> "live", path |-> p, doc |-> Whole({Fresh})]]
  /\ log' = Happened(i, p, TRUE)
  /\ ntok' = ntok + 1
  /\ nRemote' = nRemote + 1
  /\ UNCHANGED <<durable, volatile, nLocal, nCrash, ghost>>

SrvAdd(i) ==
  /\ nRemote < MaxRemote /\ ~starved
  /\ Live(i)
  /\ srv' = [srv EXCEPT ![i].doc.a = @ \cup {Fresh}]
  /\ log' = Happened(i, srv[i].path, TRUE)
  /\ ntok' = ntok + 1
  /\ nRemote' = nRemote + 1
  /\ UNCHANGED <<durable, volatile, nLocal, nCrash, ghost>>

SrvCut(i) ==
  /\ nRemote < MaxRemote /\ ~starved
  /\ Live(i)
  /\ \E t \in Text(srv[i].doc) :
       /\ srv' = [srv EXCEPT ![i].doc.d = @ \cup {t}]
       /\ discarded' = discarded \cup {t}
  /\ log' = Happened(i, srv[i].path, TRUE)
  /\ nRemote' = nRemote + 1
  /\ UNCHANGED <<durable, volatile, nLocal, nCrash, ntok, truth, duplicated, starved>>

SrvRename(i, p) ==
  /\ nRemote < MaxRemote /\ ~starved
  /\ Live(i)
  /\ ServerAt(p) = {}
  /\ srv' = [srv EXCEPT ![i].path = p]
  /\ log' = Happened(i, p, TRUE)
  /\ nRemote' = nRemote + 1
  /\ UNCHANGED <<durable, volatile, nLocal, nCrash, ntok, ghost>>

SrvDelete(i) ==
  /\ nRemote < MaxRemote /\ ~starved
  /\ Live(i)
  /\ srv' = [srv EXCEPT ![i].state = "gone"]
  /\ log' = Happened(i, srv[i].path, FALSE)
  /\ discarded' = discarded \cup Text(srv[i].doc)
  /\ nRemote' = nRemote + 1
  /\ UNCHANGED <<durable, volatile, nLocal, nCrash, ntok, truth, duplicated, starved>>

Elsewhere ==
  \E i \in Ids :
    \/ SrvAdd(i) \/ SrvCut(i) \/ SrvDelete(i)
    \/ \E p \in Paths : SrvCreate(i, p) \/ SrvRename(i, p)

(***************************************************************************)
(* The user of this device, and the power cord.                            *)
(***************************************************************************)

Calm(p) == Bug("write-window") \/ ~(pc = "write" /\ rec[cur.i].path = p)

Edit(p) ==
  /\ nLocal < MaxLocal /\ ~starved
  /\ Calm(p)
  /\ \/ /\ file' = [file EXCEPT ![p] = (IF @ = Missing THEN {} ELSE @) \cup {Fresh}]
        /\ ntok' = ntok + 1
        /\ UNCHANGED discarded
     \/ /\ file[p] # Missing
        /\ \E t \in file[p] :
             /\ file' = [file EXCEPT ![p] = @ \ {t}]
             /\ discarded' = discarded \cup {t}
        /\ UNCHANGED ntok
  /\ nLocal' = nLocal + 1
  /\ UNCHANGED <<server, rec, cursor, volatile, nRemote, nCrash, truth, duplicated, starved>>

Remove(p) ==
  /\ nLocal < MaxLocal /\ ~starved
  /\ Calm(p)
  /\ file[p] # Missing
  /\ file' = [file EXCEPT ![p] = Missing]
  /\ discarded' = discarded \cup file[p]
  /\ nLocal' = nLocal + 1
  /\ UNCHANGED <<server, rec, cursor, volatile, nRemote, nCrash, ntok, truth, duplicated, starved>>

Crash ==
  /\ nCrash < MaxCrashes /\ ~starved
  /\ pc # "idle" \/ buried # [i \in Ids |-> 0]
  /\ pc' = "idle"
  /\ cur' = NoCur
  /\ buried' = [i \in Ids |-> 0]
  /\ nCrash' = nCrash + 1
  /\ UNCHANGED <<server, durable, nLocal, nRemote, ntok, ghost>>

(***************************************************************************)
(* The engine.  One task at a time; pc says where in the task it is and    *)
(* cur holds what the task has in memory.                                  *)
(***************************************************************************)

Begin(i, p, s, feed) ==
  /\ cur' = [NoCur EXCEPT !.i = i, !.p = p, !.s = s, !.feed = feed]
  /\ pc' = IF ~rec[i].on THEN "fetch" ELSE IF rec[i].path # p THEN "vacate" ELSE "absorb"

Finish ==
  /\ cursor' = IF cur.feed THEN cur.s ELSE cursor
  /\ pc' = "idle"
  /\ cur' = NoCur

StaleCheck(has) == IF has THEN Bug("check-before-intent") ELSE Bug("first-check-before-intent")
First(has) == IF StaleCheck(has) THEN "check" ELSE "intend"

(***************************************************************************)
(* A crash left an intent beside the base.  Either the file was written    *)
(* or it was not, and the user may have edited or deleted it since.  The   *)
(* "safe" rule: the file equals the intent's text, so it was written:      *)
(* adopt.  The file is missing, or equals the base, or there was no base:  *)
(* keep what was there.  Anything else cannot be told apart, so forget     *)
(* the base and let the next pass keep the file as a conflict copy.        *)
(*                                                                         *)
(* Two cases stay ambiguous and are accepted.  If the file was written     *)
(* and the user then restored the old text exactly, or deleted the file,   *)
(* the old base is kept and the user's change in that window is undone.    *)
(* Nothing is lost by it, so truth follows the engine's choice there.      *)
(***************************************************************************)
Recover(i) ==
  /\ Idle
  /\ rec[i].on /\ rec[i].next.on
  /\ LET r == rec[i]
         F == file[r.path]
         N == r.next.doc
         adopt == [r EXCEPT !.doc = N, !.has = TRUE, !.dirty = FALSE, !.next = NoIntent]
         drop == [r EXCEPT !.next = NoIntent]
         reset == [r EXCEPT !.next = NoIntent, !.has = FALSE]
         equal == F = Text(N)
         closer == /\ F # Missing /\ r.has
                   /\ Distance(F, Text(N)) < Distance(F, Text(r.doc))
     IN  /\ rec' = [rec EXCEPT ![i] =
              CASE Recovery = "briefed" -> IF equal \/ ~r.has \/ closer THEN adopt ELSE drop
                [] Recovery = "closer" -> IF equal \/ closer THEN adopt ELSE drop
                [] Recovery = "exact" -> IF equal THEN adopt ELSE drop
                [] Recovery = "safe" ->
                     IF equal THEN adopt
                     ELSE IF F = Missing \/ ~r.has \/ F = Text(r.doc) THEN drop
                     ELSE reset]
         /\ truth' = [truth EXCEPT ![i] =
              IF equal THEN F
              ELSE IF r.has /\ F \in {Missing, Text(r.doc)} /\ ~closer THEN Text(r.doc)
              ELSE @]
  /\ UNCHANGED <<server, file, cursor, volatile, budget, ntok, discarded, duplicated, starved>>

Feed ==
  /\ Ready
  /\ cursor < Len(log)
  /\ LET k == cursor + 1
         e == log[k]
     IN  IF Seen(e.id) >= k
           THEN cursor' = k /\ UNCHANGED <<pc, cur, buried>>
           ELSE IF e.live
             THEN Begin(e.id, e.path, k, TRUE) /\ UNCHANGED <<cursor, buried>>
             ELSE IF rec[e.id].on
               THEN /\ pc' = "gone"
                    /\ cur' = [NoCur EXCEPT !.i = e.id, !.s = k, !.b = k, !.feed = TRUE]
                    /\ UNCHANGED <<cursor, buried>>
               ELSE /\ buried' = [buried EXCEPT ![e.id] = k]
                    /\ cursor' = k
                    /\ UNCHANGED <<pc, cur>>
  /\ UNCHANGED <<server, file, rec, budget, ntok, ghost>>

Fetch ==
  /\ At("fetch")
  /\ IF Live(cur.i)
       THEN /\ cur' = [cur EXCEPT !.d = srv[cur.i].doc]
            /\ pc' = "vacate"
            /\ UNCHANGED <<cursor, buried>>
       ELSE /\ buried' = [buried EXCEPT ![cur.i] = SeqOf(cur.i)]
            /\ Finish
  /\ UNCHANGED <<server, file, rec, budget, ntok, ghost>>

Vacating ==
  /\ At("vacate")
  /\ LET H == RecAt(cur.p) \ {cur.i} IN
       \/ /\ cur.was # Missing
          /\ file' = [file EXCEPT ![cur.p] = IF @ = cur.was THEN Missing ELSE @]
          /\ cur' = [cur EXCEPT !.was = Missing]
          /\ UNCHANGED <<rec, pc, buried>>
       \/ /\ cur.was = Missing
          /\ \E j \in H :
               IF Untouched(j) /\ Vacate = "file-first"
                 THEN /\ file' = [file EXCEPT ![cur.p] = Missing]
                      /\ UNCHANGED <<rec, cur, pc, buried>>
                 ELSE /\ rec' = [rec EXCEPT ![j] = NoRec]
                      /\ cur' = [cur EXCEPT !.was = IF Untouched(j) THEN file[cur.p] ELSE Missing]
                      /\ buried' = [buried EXCEPT ![j] =
                           IF Bug("seq-without-entry") THEN rec[j].seq ELSE @]
                      /\ UNCHANGED <<file, pc>>
       \/ /\ cur.was = Missing
          /\ H = {}
          /\ IF rec[cur.i].on
               THEN pc' = "movefile" /\ UNCHANGED rec
               ELSE /\ rec' = [rec EXCEPT ![cur.i] = [NoRec EXCEPT !.on = TRUE, !.path = cur.p]]
                    /\ pc' = First(FALSE)
          /\ UNCHANGED <<file, cur, buried>>
  /\ UNCHANGED <<server, cursor, budget, ntok, ghost>>

SetAside(p, then) ==
  IF FreePaths = {}
    THEN starved' = TRUE /\ UNCHANGED <<file, pc>>
    ELSE /\ \E c \in FreePaths : file' = [file EXCEPT ![c] = file[p], ![p] = Missing]
         /\ pc' = then
         /\ UNCHANGED starved

MoveFile ==
  /\ At("movefile")
  /\ LET r == rec[cur.i]
         from == file[r.path]
         to == file[cur.p]
         alreadyThere == from = Missing /\ r.has /\ to = Text(r.doc)
     IN  IF to # Missing /\ ~alreadyThere
           THEN SetAside(cur.p, "movefile")
           ELSE /\ file' = IF from = Missing THEN file
                           ELSE [file EXCEPT ![cur.p] = from, ![r.path] = Missing]
                /\ pc' = "moverec"
                /\ UNCHANGED starved
  /\ UNCHANGED <<server, rec, cursor, cur, buried, budget, ntok, discarded, truth, duplicated>>

MoveRec ==
  /\ At("moverec")
  /\ rec' = [rec EXCEPT ![cur.i].path = cur.p]
  /\ pc' = "absorb"
  /\ UNCHANGED <<server, file, cursor, cur, buried, budget, ntok, ghost>>

Absorb ==
  /\ At("absorb")
  /\ LET i == cur.i
         r == rec[i]
         F == file[r.path]
         fork == Fork(r.doc, F)
     IN  IF F = Missing /\ r.has
           THEN /\ rec' = [rec EXCEPT ![i].seq = Max(@, cur.s)]
                /\ Finish
                /\ UNCHANGED <<truth, duplicated>>
           ELSE IF F # Missing /\ r.has /\ F # Text(r.doc)
             THEN /\ duplicated' = duplicated \cup ((F \ Text(r.doc)) \cap (r.doc.a \cup srv[i].doc.a))
                  /\ IF Bug("send-before-record")
                       THEN UNCHANGED <<rec, truth>>
                       ELSE /\ rec' = [rec EXCEPT ![i].doc = fork, ![i].dirty = TRUE]
                            /\ truth' = [truth EXCEPT ![i] = F]
                  /\ cur' = [cur EXCEPT !.d = fork]
                  /\ pc' = "exchange"
                  /\ UNCHANGED cursor
             ELSE /\ cur' = [cur EXCEPT !.d = r.doc]
                  /\ pc' = "exchange"
                  /\ UNCHANGED <<rec, cursor, truth, duplicated>>
  /\ UNCHANGED <<server, file, buried, budget, ntok, discarded, starved>>

Exchange ==
  /\ At("exchange")
  /\ LET i == cur.i
         r == rec[i]
         new == Join(srv[i].doc, cur.d)
     IN  IF ~Live(i)
           THEN /\ cur' = [cur EXCEPT !.b = SeqOf(i)]
                /\ pc' = "gone"
                /\ UNCHANGED server
           ELSE /\ IF new = srv[i].doc
                     THEN UNCHANGED server
                     ELSE /\ srv' = [srv EXCEPT ![i].doc = new]
                          /\ log' = Happened(i, srv[i].path, TRUE)
                /\ cur' = [cur EXCEPT !.d = new]
                /\ pc' = IF file[r.path] = Text(new) THEN "record" ELSE First(r.has)
  /\ UNCHANGED <<durable, buried, budget, ntok, ghost>>

Intend ==
  /\ At("intend")
  /\ rec' = [rec EXCEPT ![cur.i].next =
       IF Bug("no-intent") THEN NoIntent ELSE [on |-> TRUE, doc |-> cur.d]]
  /\ pc' = IF StaleCheck(rec[cur.i].has) THEN "write" ELSE "check"
  /\ UNCHANGED <<server, file, cursor, cur, buried, budget, ntok, ghost>>

Check ==
  /\ At("check")
  /\ LET i == cur.i
         r == rec[i]
         F == file[r.path]
         then == IF StaleCheck(r.has) THEN "intend" ELSE "write"
     IN  IF r.has /\ F = Missing
           THEN /\ rec' = [rec EXCEPT ![i].next = NoIntent, ![i].seq = Max(@, cur.s)]
                /\ Finish
                /\ UNCHANGED <<file, starved>>
           ELSE IF r.has /\ F # Text(r.doc)
             THEN /\ rec' = [rec EXCEPT ![i].next = NoIntent]
                  /\ pc' = "absorb"
                  /\ UNCHANGED <<file, cursor, cur, starved>>
             ELSE IF r.has \/ F = Missing \/ F = Text(cur.d)
               THEN /\ pc' = then
                    /\ UNCHANGED <<file, rec, cursor, cur, starved>>
               ELSE /\ SetAside(r.path, then)
                    /\ UNCHANGED <<rec, cursor, cur>>
  /\ UNCHANGED <<server, buried, budget, ntok, discarded, truth, duplicated>>

Write ==
  /\ At("write")
  /\ file' = [file EXCEPT ![rec[cur.i].path] = Text(cur.d)]
  /\ truth' = [truth EXCEPT ![cur.i] = Text(cur.d)]
  /\ pc' = "record"
  /\ UNCHANGED <<server, rec, cursor, cur, buried, budget, ntok, discarded, duplicated, starved>>

Record ==
  /\ At("record")
  /\ rec' = [rec EXCEPT ![cur.i] = [@ EXCEPT !.doc = cur.d, !.has = TRUE, !.dirty = FALSE,
                                            !.next = NoIntent, !.seq = Max(@, cur.s)]]
  /\ truth' = [truth EXCEPT ![cur.i] = Text(cur.d)]
  /\ Finish
  /\ UNCHANGED <<server, file, buried, budget, ntok, discarded, duplicated, starved>>

Gone ==
  /\ At("gone")
  /\ LET i == cur.i IN
       IF Untouched(i)
         THEN /\ file' = [file EXCEPT ![rec[i].path] = Missing]
              /\ UNCHANGED <<rec, cursor, pc, cur, buried>>
         ELSE /\ rec' = [rec EXCEPT ![i] = NoRec]
              /\ buried' = [buried EXCEPT ![i] = Max(@, cur.b)]
              /\ Finish
              /\ UNCHANGED file
  /\ UNCHANGED <<server, budget, ntok, ghost>>

Orphan(p) == file[p] # Missing /\ RecAt(p) = {}

Create(p) ==
  /\ Ready
  /\ Orphan(p)
  /\ IF ServerAt(p) # {}
       THEN /\ \E h \in ServerAt(p) : Begin(h, p, SeqOf(h), FALSE)
            /\ UNCHANGED <<server, starved>>
       ELSE IF Unused = {}
         THEN starved' = TRUE /\ UNCHANGED <<server, pc, cur>>
         ELSE /\ \E n \in Unused :
                   /\ srv' = [srv EXCEPT ![n] = [state |-> "live", path |-> p, doc |-> Whole(file[p])]]
                   /\ log' = Happened(n, p, TRUE)
                   /\ cur' = [NoCur EXCEPT !.i = n, !.p = p, !.s = Len(log) + 1, !.d = Whole(file[p])]
              /\ pc' = "created"
              /\ UNCHANGED starved
  /\ UNCHANGED <<durable, buried, budget, ntok, discarded, truth, duplicated>>

Created ==
  /\ At("created")
  /\ rec' = [rec EXCEPT ![cur.i] = [NoRec EXCEPT !.on = TRUE, !.path = cur.p, !.doc = cur.d,
                                                !.has = TRUE, !.seq = cur.s]]
  /\ truth' = [truth EXCEPT ![cur.i] = Text(cur.d)]
  /\ Finish
  /\ UNCHANGED <<server, file, buried, budget, ntok, discarded, duplicated, starved>>

Unsettled(i) ==
  /\ rec[i].on
  /\ LET F == file[rec[i].path] IN
       IF F = Missing THEN ~rec[i].has
       ELSE F # Text(rec[i].doc) \/ rec[i].dirty \/ ~rec[i].has

Settle(i) ==
  /\ Ready
  /\ Unsettled(i)
  /\ pc' = "absorb"
  /\ cur' = [NoCur EXCEPT !.i = i, !.p = rec[i].path]
  /\ UNCHANGED <<server, durable, buried, budget, ntok, ghost>>

Vanished(i) == rec[i].on /\ rec[i].has /\ file[rec[i].path] = Missing

Drop(i) ==
  /\ Ready
  /\ Vanished(i)
  /\ IF ~Live(i)
       THEN /\ rec' = [rec EXCEPT ![i] = NoRec]
            /\ UNCHANGED <<server, pc, cur>>
       ELSE IF Text(srv[i].doc) # Text(rec[i].doc)
         THEN /\ rec' = [rec EXCEPT ![i].has = FALSE]
              /\ Begin(i, srv[i].path, SeqOf(i), FALSE)
              /\ UNCHANGED server
         ELSE /\ srv' = [srv EXCEPT ![i].state = "gone"]
              /\ log' = Happened(i, srv[i].path, FALSE)
              /\ rec' = [rec EXCEPT ![i] = NoRec]
              /\ UNCHANGED <<pc, cur>>
  /\ UNCHANGED <<file, cursor, buried, budget, ntok, ghost>>

Engine ==
  \/ Feed \/ Fetch \/ Vacating \/ MoveFile \/ MoveRec \/ Absorb \/ Exchange
  \/ Intend \/ Check \/ Write \/ Record \/ Gone \/ Created
  \/ \E i \in Ids : Recover(i) \/ Settle(i) \/ Drop(i)
  \/ \E p \in Paths : Create(p)

Next ==
  \/ Engine
  \/ Elsewhere
  \/ Crash
  \/ \E p \in Paths : Edit(p) \/ Remove(p)

Spec == Init /\ [][Next]_vars /\ WF_vars(Engine)

(***************************************************************************)
(* What must hold.                                                         *)
(***************************************************************************)

Kept ==
  UNION {Text(srv[i].doc) : i \in {j \in Ids : Live(j)}}
    \cup UNION {file[p] : p \in {q \in Paths : file[q] # Missing}}

NothingLost == (1..ntok) \subseteq (Kept \cup discarded)

NothingDuplicated == duplicated = {}

InFlight(i) == pc # "idle" /\ cur.i = i

BaseMatchesFile ==
  \A i \in Ids :
    (rec[i].on /\ rec[i].has /\ ~rec[i].next.on /\ ~InFlight(i)) => Text(rec[i].doc) = truth[i]

OnePerPath ==
  \A i, j \in Ids : (rec[i].on /\ rec[j].on /\ i # j) => rec[i].path # rec[j].path

SeqOnlyIfHeldOrGone ==
  \A i \in Ids : (~rec[i].on /\ buried[i] > 0) => srv[i].state = "gone"

CursorHonest ==
  \A i \in Ids :
    LET k == Last(Events(i, cursor)) IN
      k > 0 =>
        IF log[k].live
          THEN (rec[i].on /\ rec[i].seq >= k) \/ srv[i].state = "gone" \/ SeqOf(i) > cursor
          ELSE ~rec[i].on

Synced ==
  /\ Ready
  /\ cursor = Len(log)
  /\ \A p \in Paths : ~Orphan(p)
  /\ \A i \in Ids : ~Unsettled(i) /\ ~Vanished(i)

SyncedMeansEqual ==
  Synced =>
    /\ \A i \in Ids : Live(i) <=> rec[i].on
    /\ \A i \in Ids : Live(i) => rec[i].path = srv[i].path /\ file[rec[i].path] = Text(srv[i].doc)

Converges == <>[](Synced \/ starved)

=============================================================================
