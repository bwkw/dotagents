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

> **When `da-review-all` is reviewing someone else's PR, the layer reports are never printed** — the
> premise above would then be false, and the selection would be a cap that hides what it cut after all.
> On that path **the overview page is the report**: its 🔎 / 🔬 rows carry what was excluded, one line
> each. Check the page has them before selecting; if it does not, the selection is not auditable and
> the page is incomplete, not the comment set.

## Step 1. Select — by rule, never by rank

**Select from verified findings only.** The 🔬 row below is not a filter you apply while drafting — it
is a precondition. Run `verification.md` *before* this step, or the set you select from is the find
phase's set and the 🔬 row has nothing to act on. Measured on a real run of three findings taken into a
refutation pass: one 🔴 was refuted outright, one held with two sub-claims corrected, and one lost a
severity level and turned up an item nobody had raised. **Selecting first would have put the refuted one
at the top of the review.**

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

**Read `profiles/review-voice.md`** — the path is relative to **the toolkit root**, not to the calling
skill's `reference/` directory, and the file is personal and untracked like every other profile.
Resolving it under a skill's reference directory finds nothing, and "the profile is missing" then gets
reported to the user as fact while the file was there all along. It carries the register: how direct,
how much hedging, questions versus assertions, Japanese or English, whether nits are marked.
**`da-review-all` loads it back at Step 1** on the someone-else's-PR path; if you are arriving from
there it is already in context.

**If that file does not exist, stop and ask for it. Do not infer a voice.** A comment posted under
someone's name in a register they do not use is worse than no comment: it reads as them, and they cannot
unsay it. Ask for two or three comments they have actually written, or a description of the register, and
offer to write the file from that.

**Reconstructing the register from `gh api` instead of reading the profile loses the small things,
which are the ones that make it sound like them.** Observed on a real run, with the profile present and
unread: the sentence-final form the author actually uses, the lowercase `nit:` prefix, closing with a
request rather than an assertion, and writing light findings *lightly* — every comment came out at the
same weight. All four are in the file. **The profile outranks your reading of their past comments**,
and where they disagree, the examples quoted inside the profile win.

### The shape is not the register

The register is personal and lives in the profile. **The shape is neither** — it is what makes a comment
survive being opened as a phone notification, and it holds in any register:

1. **One bold line carrying the claim**, and nothing else on that line. The claim, not the topic: "この
   コードパスを守るテストが無いです", not "テストについて".
2. **A blank line after it.** Without one, the bold line and the mechanism render as a single paragraph
   and the claim stops being scannable — which was the entire reason for bolding it.
3. **At most two sentences of mechanism**, then the request that closes the comment. A mechanism that
   needs three sentences is either two findings, or one that belongs on the overview page.

**Do not append a references block.** A trailing `参考:` / `See also:` list of `file:line` from the same
repository is citation padding — the author can open any of those paths in one click, and the list grows
back exactly the reasoning the two-sentence limit just squeezed out. Fold the **one** load-bearing
citation into the sentence that needs it, the one whose absence would let the author reasonably
disagree, and drop the rest. A references block earns its own line only when it points **outside** the
repository: a vendor specification, an RFC, a ticket the author cannot grep for.

Then these, because they are about the comment's job rather than its tone:

- **The line, the reason, the fix** — in that order, and the reason must be **load-bearing**, which is
  not the same as long. It is the one sentence that still stands in front of an author who disagrees. A
  comment that says what to change without why gets applied wrongly or argued with; one that says it in
  six sentences gets skimmed down to the request and applied wrongly anyway.
- **Cite what you read, in prose.** `file:line` inside the sentence. A comment whose evidence is "this
  pattern is usually wrong" is a comment about patterns, not about this code.
- **Say when you are unsure.** "I could not confirm X — does Y guard it?" is a better comment than a
  confident wrong one, and it is the honest form of 👤.
- **No praise padding, no apology padding.** Neither survives translation into a different register and
  both dilute the finding.

## Step 2b. Resolve the target PR, and verify every anchor — before showing anything

Two failures live here. Both are silent until the POST, and the POST is all-or-nothing.

**Which PR does this file belong to.** A line comment can only be placed on a PR whose diff contains
that line. In a stacked set each PR's base is **the branch below it**, not the trunk, so a file added
in the second PR is absent from the third's diff entirely. Map it before drafting:

```bash
# for each PR in the stack, with its own base
git diff --name-only "$BASE_OF_THAT_PR" "$HEAD_OF_THAT_PR" | grep -E '<the files you want to comment on>'
```

**Which line.** Line numbers taken from a review that read the *top* of a stack, or from an earlier
version of the file, are wrong for the PR you are posting to. Re-derive each anchor from the head of
**that** PR:

```bash
git show "$HEAD_OF_THAT_PR:$path" | grep -n '<the distinctive text of the line>'
```

Observed: an anchor written as `:487` from a top-of-stack read was `:467` in the PR that owned the
file. It was caught by chance, at post time. **`start_line`/`line` must both be lines the diff touches
— one bad anchor rejects the whole call**, so this check is what stands between one typo and losing
every comment in the review.

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

**Write a body even when every finding is inline.** Do not send `event: COMMENT` with an empty `body`
(whether the API rejects it is unmeasured — see `docs/harness-facts.md`; a one-line body sidesteps the
question). One line saying what you read is the whole job: filling it with a summary of the review
duplicates the overview page and invites the author to read the body instead of the comments.

`line` + `side` anchors to a single line; `start_line` + `line` spans a range. **Both must be lines the
diff actually touches** — an anchor outside the diff is rejected for the whole call, so a bad 📍 loses
every comment, not one. Step 2b is what makes that safe.

**Always spell the repository out in the path.** `gh` resolves a bare PR number against the *current
working directory's* repository, and PR numbers collide across repositories — the same number is a live
PR in one and somebody's merged PR in another. Writing `repos/{owner}/{repo}/pulls/<n>/reviews` in full
removes the ambiguity; relying on cwd has already overwritten an unrelated merged PR once.

**One review per PR.** A stacked set gets one call per PR, each with its own comment list, not one call
carrying everything.

### Then verify it landed

```bash
gh api "repos/{owner}/{repo}/pulls/<n>/comments?per_page=50" \
  --jq '.[] | select(.user.login=="<you>") | "\(.path):\(.line) [\(if .position == null then "OUTDATED" else "ok" end)]"'
```

`position: null` means the comment posted but is **detached from the diff** — it renders collapsed under
"outdated" and the author may never see it. A 201 is not evidence the comment is readable; this is.

**`Go` authorizes this post and nothing after it.** A follow-up edit, a reply to the author's response, a
second round after they push — each needs its own `Go`. Approval does not carry forward, and it never
carries to `--approve` or `--request-changes`: **this step only ever posts comments.** Changing a PR's
review state is the human's call, always, and it is not what `Go` means.

## Step 5. Say what was posted

Link the review, list what went up, and state plainly that **the report is the complete set and the PR
has the subset** — so nobody later reads the PR thread as the whole review.
