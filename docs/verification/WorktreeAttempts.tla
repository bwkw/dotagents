-------------------------- MODULE WorktreeAttempts --------------------------
EXTENDS Naturals

CONSTANT Shared
VARIABLES stored, failures

Trees == {"A", "B"}
Limit == 3
Key(w) == IF Shared THEN "A" ELSE w

\* stored はゲートが読む回数。failures は各ツリーで実際に起きた失敗を数える。
Init ==
    /\ stored = [w \in Trees |-> 0]
    /\ failures = [w \in Trees |-> 0]

Fail(w) ==
    /\ stored[Key(w)] < Limit
    /\ stored' = [stored EXCEPT ![Key(w)] = @ + 1]
    /\ failures' = [failures EXCEPT ![w] = @ + 1]

Next ==
    \/ \E w \in Trees : Fail(w)
    \/ /\ \A w \in Trees : stored[Key(w)] = Limit
       /\ UNCHANGED <<stored, failures>>

Isolated == \A w \in Trees : stored[Key(w)] = failures[w]
=============================================================================
