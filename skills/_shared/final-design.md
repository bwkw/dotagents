# Write it as the design, not as the route you took to it

Two skills need this and neither owns it: `da-spec` writes the change, `da-adr` writes the decision.
Both produce a document that **outlives the conversation that produced it**, and both fail the same
way when they forget that.

## The reader

**The reader is a newcomer who was not in the conversation.** They have the repository and this
document. They do not know what was proposed first, what was withdrawn, what the third option was
before it collapsed into the second, or which sentence answers a question someone asked out loud.

A sentence that only parses if you were there is not a shorter sentence. It is an **unreadable**
one — and it reads as authoritative while being unreadable, which is worse than being absent.

## Cut on sight

| Shape | Example | Why it fails |
|---|---|---|
| Discovery narrative | "we first tried X, but it turned out that…" | The reader never tried X. The route is not the design |
| Contrast with something unseen | "this is not a new constraint, it is…", "unlike the earlier approach" | Negates a thing that exists only in the conversation |
| Positional cross-reference | "as noted above", "the fact cited earlier", "the second option" | Resolves only when read in one order, by someone who remembers |
| Chronological numbering | decisions numbered by when they were made | The reader needs them ordered by what depends on what |
| Correction traces | "revised", "withdrawn", "superseded in review" | The document is the final state. A superseded thing is simply absent |
| Attribution to the session | "as the review found", "per the grilling" | The finding is either load-bearing — then state it as fact with its evidence — or it is not, and it goes |

**Dated repository history stays.** A measurement, an incident, a commit that established a
constraint, a configuration value observed in production — those are evidence a newcomer can check,
not conversation. Cite them.

**Rejected alternatives stay.** They are what makes a decision a decision. Write them as *alternatives
considered and why they lose*, never as *things we tried and abandoned*. The first is design; the
second is a diary.

## The test

Read the document as though you have never seen this repository's chat history. **Every sentence that
raises the question "compared to what?" or "found by whom?" and does not answer it in the same
paragraph is a rewrite, not a polish.**

Ordering is part of this. Present decisions so each one only depends on ones already stated. If
decision 5 explains itself by pointing at decision 7, the order is the conversation's, not the
design's.

## What this is not

This is not a rule against detail, length, or strong claims. A final design can be long and sharp.
It is a rule against **a document that encodes its own history** — which is the default output of any
process where the document is edited as the understanding changes, and therefore the default output
of every skill that writes one.
