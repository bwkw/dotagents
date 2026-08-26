# Posting the review to the PR

Read this **only when a PR exists and the user wants comments on it.** The review report stands on its
own; this file is about the smaller thing that goes on the pull request.

**Nothing is posted until the user types `Go`.** Not the drafts, not a "harmless" nit, not a top-level
summary. Drafting is read-only; the only write in this whole file is Step 4, and it happens once.

---

## The report and the comments are not the same set

**The report keeps everything.** Every bucket, every count, every 🔬 line — that is the complete record
and it is what makes a clean result readable. **The comments are the subset worth another person's
attention**, and the two are different sizes on purpose.

That distinction is what stops this step from becoming the thing the toolkit keeps retracting: **a cap
that hides what it cut.** Nothing is dropped here — it is all still in the report, in the same session,
one scroll up. What Step 1 does is decide what to *say out loud*.

## Step 1. Select — by rule, never by rank

| Bucket | Goes on the PR as | When |
|---|---|---|
| ⛔ | inline comment on the line, and named in the top-level summary | **Always.** This is the one the PR exists to stop. |
| 🔴 | inline comment on the line | **Always.** |
| 🟡 | inline comment on the line | **Only when all three hold**: this change originates it, it names a concrete failure scenario (input and state → result), and **you would act on it yourself.** |
| 💡 | **one** rolled-up comment, `Nit:` prefixed, listing them as lines | Never one comment each. Five separate nits cost more trust than the five fixes are worth. |
| 🧭 | **in the review body**, phrased as a question | It is not a defect at a line, so it does not get a line. "This shape will cost us — is that priced in?" |
| 👤 | **in the review body**, naming what would settle it or whom to ask | Never phrased as a finding. It is a statement about what you did not read. |
| 🔬 refuted, or below the confidence threshold | **Nothing.** | It did not survive the verify pass. Posting it is exactly the false positive that pass exists to stop. |

**The filter, stated once:** the trust metric is the **adoption rate** of what you post (decision 14 —
below 50% and a reviewer gets routed around). So the test for every 🟡 and 💡 is not "is it true" but
**"would I decline this if it came back to me in `da-fix-plan`?"** If yes, it stays in the report and off
the PR.

**No count cap.** Not "the top 5". A change that genuinely has nine 🔴 gets nine comments, and the right
response to that is the one Step 1b already gives: say the change is too large to review as one unit.

## Step 2. Draft — in the user's voice, not the report's

The report is written to be **complete**. A review comment is written to be **acted on by a person who
did not read the report.** They are different registers and translating between them is the work here.

**Read `profiles/review-voice.md`** (in this repository's checkout — personal, untracked, like every
other profile). It carries the register: how direct, how much hedging, questions versus assertions,
Japanese or English, whether nits are marked.

**If that file does not exist, stop and ask for it. Do not infer a voice.** A comment posted under
someone's name in a register they do not use is worse than no comment: it reads as them, and they cannot
unsay it. Ask for two or three comments they have actually written, or a description of the register, and
offer to write the file from that.

Whatever the register, these hold because they are about the comment's job, not its tone:

- **The line, the reason, the fix** — in that order, and the reason is the part that must not be short.
  A comment that says what to change without why gets applied wrongly or argued with.
- **Cite what you read.** `file:line`. A comment whose evidence is "this pattern is usually wrong" is a
  comment about patterns, not about this code.
- **Say when you are unsure.** "I could not confirm X — does Y guard it?" is a better comment than a
  confident wrong one, and it is the honest form of 👤.
- **No praise padding, no apology padding.** Neither survives translation into a different register and
  both dilute the finding.

## Step 3. Show every draft, then wait

Print, for each comment: the **target** (`file:line`, or "top-level"), the **bucket** it came from, and
the **body verbatim** — exactly the bytes that would be posted. Then the ones you decided *not* to post,
one line each with the rule that excluded them, so the selection is auditable and not just asserted.

Then stop and say what `Go` would do: *"`Go` posts one review to PR #X — N inline comments plus a body
carrying the 🧭 and 👤 items. Nothing else."*

**Wait for the literal `Go`.** "Looks good", "sure", silence, or a reply about something else is not it.
Anything less than the token means keep drafting.

## Step 4. Post — once, as one review

**One call, all comments attached** — not N. A PR with fourteen notification emails from one review is
the reviewer's fault, not the author's.

**`gh pr review` cannot do this.** Its flags are `--body` / `--body-file` / `--approve` / `--comment` /
`--request-changes` and nothing else: it posts a review *body* and has no way to attach a comment to a
line. Reaching for it and then falling back to one `gh api` call per finding is exactly the N-call shape
this step exists to prevent. Post the review as one REST call instead:

```bash
# review.json: { "event": "COMMENT", "body": "<the top-level text>",
#                "comments": [ { "path": "src/a.ts", "line": 42, "side": "RIGHT", "body": "…" }, … ] }
gh api --method POST "repos/{owner}/{repo}/pulls/<number>/reviews" --input review.json
```

`line` + `side` anchors to a single line; `start_line` + `line` spans a range. **Both must be lines the
diff actually touches** — an anchor outside the diff is rejected for the whole call, so a bad 📍 loses
every comment, not one.

**`Go` authorizes this post and nothing after it.** A follow-up edit, a reply to the author's response, a
second round after they push — each needs its own `Go`. Approval does not carry forward, and it never
carries to `--approve` or `--request-changes`: **this step only ever posts comments.** Changing a PR's
review state is the human's call, always, and it is not what `Go` means.

## Step 5. Say what was posted

Link the review, list what went up, and state plainly that **the report is the complete set and the PR
has the subset** — so nobody later reads the PR thread as the whole review.
