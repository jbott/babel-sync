------------------------------- MODULE Sync -------------------------------
EXTENDS Naturals, FiniteSets

CONSTANTS Devices, Entries, MaxEdits, MaxFaults, UseAudit

None == 0

VARIABLES
  srvVal, srvSeq, clock,
  file, known, cursor,
  edits, faults,
  written, saved, superseded

vars == <<srvVal, srvSeq, clock, file, known, cursor, edits, faults, written, saved, superseded>>

Init ==
  /\ srvVal = [e \in Entries |-> None]
  /\ srvSeq = [e \in Entries |-> 0]
  /\ clock = 0
  /\ file = [d \in Devices |-> [e \in Entries |-> None]]
  /\ known = [d \in Devices |-> [e \in Entries |-> [val |-> None, seq |-> 0]]]
  /\ cursor = [d \in Devices |-> 0]
  /\ edits = 0
  /\ faults = 0
  /\ written = {}
  /\ saved = {}
  /\ superseded = {}

Kept(v) == IF v = None THEN {} ELSE {v}

Edit(d, e) ==
  /\ edits < MaxEdits
  /\ edits' = edits + 1
  /\ file' = [file EXCEPT ![d][e] = edits + 1]
  /\ written' = written \cup {edits + 1}
  /\ superseded' = superseded \cup Kept(file[d][e])
  /\ UNCHANGED <<srvVal, srvSeq, clock, known, cursor, faults, saved>>

Remove(d, e) ==
  /\ edits < MaxEdits
  /\ file[d][e] # None
  /\ edits' = edits + 1
  /\ file' = [file EXCEPT ![d][e] = None]
  /\ superseded' = superseded \cup {file[d][e]}
  /\ UNCHANGED <<srvVal, srvSeq, clock, known, cursor, faults, written, saved>>

TakeServer(d, e) ==
  /\ file' = [file EXCEPT ![d][e] = srvVal[e]]
  /\ known' = [known EXCEPT ![d][e] = [val |-> srvVal[e], seq |-> srvSeq[e]]]
  /\ saved' = IF file[d][e] \in {known[d][e].val, srvVal[e]} THEN saved ELSE saved \cup Kept(file[d][e])

Push(d, e) ==
  /\ file[d][e] # known[d][e].val
  /\ IF known[d][e].seq = srvSeq[e]
       THEN /\ clock' = clock + 1
            /\ srvVal' = [srvVal EXCEPT ![e] = file[d][e]]
            /\ srvSeq' = [srvSeq EXCEPT ![e] = clock + 1]
            /\ known' = [known EXCEPT ![d][e] = [val |-> file[d][e], seq |-> clock + 1]]
            /\ superseded' = superseded \cup Kept(srvVal[e])
            /\ UNCHANGED <<file, saved>>
       ELSE /\ TakeServer(d, e)
            /\ UNCHANGED <<srvVal, srvSeq, clock, superseded>>
  /\ UNCHANGED <<cursor, edits, faults, written>>

Pending(d) == {e \in Entries : srvSeq[e] > cursor[d]}

Next1(d) == CHOOSE e \in Pending(d) : \A o \in Pending(d) : srvSeq[e] <= srvSeq[o]

Feed(d) ==
  /\ Pending(d) # {}
  /\ LET e == Next1(d) IN
       /\ IF known[d][e].seq >= srvSeq[e]
            THEN UNCHANGED <<file, known, saved>>
            ELSE TakeServer(d, e)
       /\ cursor' = [cursor EXCEPT ![d] = srvSeq[e]]
  /\ UNCHANGED <<srvVal, srvSeq, clock, edits, faults, written, superseded>>

Audit(d, e) ==
  /\ UseAudit
  /\ known[d][e].seq # srvSeq[e]
  /\ TakeServer(d, e)
  /\ UNCHANGED <<srvVal, srvSeq, clock, cursor, edits, faults, written, superseded>>

MissChange(d) ==
  /\ faults < MaxFaults
  /\ Pending(d) # {}
  /\ faults' = faults + 1
  /\ cursor' = [cursor EXCEPT ![d] = srvSeq[Next1(d)]]
  /\ UNCHANGED <<srvVal, srvSeq, clock, file, known, edits, written, saved, superseded>>

ForgetRecord(d, e) ==
  /\ faults < MaxFaults
  /\ known[d][e].seq # 0
  /\ faults' = faults + 1
  /\ known' = [known EXCEPT ![d][e] = [val |-> None, seq |-> 0]]
  /\ UNCHANGED <<srvVal, srvSeq, clock, file, cursor, edits, written, saved, superseded>>

Sync(d) == Feed(d) \/ \E e \in Entries : Push(d, e) \/ Audit(d, e)

Next ==
  \E d \in Devices :
    \/ Sync(d)
    \/ MissChange(d)
    \/ \E e \in Entries : Edit(d, e) \/ Remove(d, e) \/ ForgetRecord(d, e)

Spec == Init /\ [][Next]_vars /\ \A d \in Devices : WF_vars(Sync(d))

Synced(d) ==
  /\ Pending(d) = {}
  /\ \A e \in Entries : file[d][e] = known[d][e].val
  /\ UseAudit => \A e \in Entries : known[d][e].seq = srvSeq[e]

SyncedMeansEqual == \A d \in Devices : Synced(d) => \A e \in Entries : file[d][e] = srvVal[e]

Held == {srvVal[e] : e \in Entries} \cup {file[d][e] : d \in Devices, e \in Entries}

NothingLost == written \subseteq (Held \cup saved \cup superseded)

Converges == <>[](\A d \in Devices : Synced(d))

=============================================================================
