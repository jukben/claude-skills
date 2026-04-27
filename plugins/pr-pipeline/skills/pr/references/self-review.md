# Self-Review Flow

This reference is loaded by the `/pr` orchestrator when a self-review is needed.
You already have the state JSON from `detect_state.sh` — use it.

**Tier awareness:** Phase 1 of the orchestrator picks a tier (XS/S/M/L). This reference handles **M and L**. XS skips self-review entirely; S runs only `/simplify` from the orchestrator and doesn't enter this flow.

The only tier-specific branch inside this flow is **Agent 4 (Security)** — it runs on L only. Everything else runs on both M and L.

## Philosophy

- **Reviewer empathy first.** A PR should be a gift to the reviewer — small, clear, and obvious.
- **Signal over noise.** Only flag things that matter. Never nitpick formatting that a linter handles.
- **Fix, don't just report.** If you find something wrong, fix it. Only report things you can't auto-fix or need the author's judgment on.
- **Pragmatic, not pedantic.** Real bugs > style preferences. Missing edge cases > naming bikesheds.
- **Maintainability is not optional.** Every PR should leave the codebase easier to work with, not harder. Tests protect the next person who touches this code.

## Step 0: Check for Existing Review

Before running a fresh review, check if one already exists for this branch:

```bash
# Use ticket ID if available, otherwise the current branch name (slashes → underscores)
CACHE_KEY="${TICKET_ID:-$(git branch --show-current | tr '/' '_')}"
REVIEW_FILE=".reviews/${CACHE_KEY}.review.md"
```

If the file exists:
1. Read its YAML frontmatter and check the `head_sha` field
2. Compare against the current `HEAD` SHA

- **SHA matches** — The review is current. Ask the user: "A review already exists for this branch at the current commit. Want to see the previous results, or run a fresh review?"
  - If show previous → display the saved summary and stop
  - If fresh review → continue to Step 1
- **SHA differs** — The code has changed since the last review. Tell the user: "Found a previous review for this branch, but it has moved (<N> new commits). Running a fresh review." Continue to Step 1.
- **No file** — First review. Continue to Step 1.

## Step 1: Get the Full Diff

The state JSON gives you stats at `diff` and file list at `diff.changed_files`. Now get the full diff:

```bash
git diff <diff_base>...HEAD
```

Also read `CLAUDE.md` if `workspace.has_claude_md` is true — it has project conventions and build commands.

## Step 2: Run /simplify First

Invoke `Skill(simplify)` **before** spawning any other agents. It reviews changed files for code reuse, quality, and efficiency, then applies fixes directly on the working branch.

Wait for `/simplify` to complete and commit its changes before proceeding. /simplify makes structural changes — extracting helpers, renaming, reorganizing — that would conflict with anything else running concurrently. Running it first means all subsequent agents review the cleaned-up code and their findings stay valid.

## Step 3: Spawn Parallel Review Agents

After `/simplify` is done, launch all agents simultaneously. Each agent gets the diff (re-diffed after `/simplify`'s changes), file list, and project config.

**Important:** Re-run the diff after `/simplify` so agents review the current state:

```bash
git diff <diff_base>...HEAD
```

**All agents are report-only — none of them modify files or commit.** This is deliberate: because no agent writes to the branch during this phase, the codebase is stable and there are no race conditions. The orchestrator applies all changes sequentially in Steps 5 and 6.

### Agent 1: Code Review (Sonnet)

One agent, one pass over the diff — checking both correctness and maintainability together. This agent **reports findings and suggests fixes but does not apply them**. The orchestrator will apply fixes in Step 5.

Read `references/agent-code-review.md` for the full agent prompt.

### Agent 2: PR Shape & Coherence (Sonnet)

Report-only — this agent does not modify any files.

Read `references/agent-pr-shape.md` for the full agent prompt.

### Agent 3: Test & CI (Sonnet)

This agent runs the project's checks and evaluates coverage, but **does not modify source files or commit**. It can execute tests, linters, and builds (these don't change source code), but it produces test recommendations rather than writing test files. The orchestrator will write tests in Step 6.

Read `references/agent-test-ci.md` for the full agent prompt.

### Agent 4: Security Review (Opus) — L tier only

A dedicated security agent for deeper analysis than Agent 1's correctness pass covers. Read `references/security-review.md` for the full agent prompt.

**Skip this agent on M tier.** Only spawn it on L tier. M tier is reserved for changes that don't touch the security surface (auth, API, middleware, migrations) — the classifier and Haiku have already confirmed this before we get here. Running Opus on every normal PR is expensive and adds little signal.

When it does run (on L), it runs in parallel with Agents 1-3. Opus is justified there because the classifier has identified something sensitive and security analysis requires tracing data flow across files.

### Agent 5: Requirements Review (Sonnet) — Optional

Only spawn this agent when `ticket.id` is present in the state JSON AND a ticketing MCP can fetch the ticket without prompting the user. Read `references/requirements-review.md` for the full agent prompt.

Before spawning, fetch the ticket content:
1. If a ticketing MCP is available (Linear, Jira, etc.), fetch the ticket by ID
2. If no MCP is available, skip this agent — don't ask the user to paste ticket content during an automated review

## Step 4: Score Findings

After all agents complete, run a confidence scoring pass before acting on anything. Read `references/confidence-scoring.md` for the scoring agent prompt and rubric.

Collect all findings from Agents 1, 2, 3, and 4 into a numbered list. Pass the list and the full diff to a Haiku agent for scoring.

Apply the threshold:
- **>= 75**: Act on these (fix in Step 5, include in summary)
- **50-74**: Include in summary as "Low confidence" for awareness, but do NOT auto-fix
- **< 50**: Drop silently

This step exists because review agents tend to over-report. The false-positive checklist catches the common patterns: flagging pre-existing issues, linter territory, test-only code, and things that are already handled elsewhere in the diff. Running this before Step 5 avoids wasting time fixing non-issues.

## Step 5: Apply Code Review Fixes

After scoring, the orchestrator applies fixes from high-confidence findings. This runs sequentially — no other agent is writing code.

1. **Review scored findings.** Apply Critical and Should-fix items that scored >= 75 and have concrete fixes.
2. **Cross-reference with Agent 3's CI failures.** If Agent 3 reported linter or type-check failures that overlap with Agent 1's findings, address them together.
3. **Commit each fix separately** with a clear message. Keep fixes in separate commits from the author's work.
4. **Flag** anything that needs the author's judgment — don't apply changes you're not confident about.

## Step 6: Write Tests from Recommendations

Next, write tests based on Agent 3's recommendations. This also runs sequentially, after fixes from Step 5 are committed.

1. **Re-assess recommendations against the current code.** Agent 1's fixes may have changed the code that Agent 3 analyzed. Skip recommendations that no longer apply, and adjust any that target modified code.
2. **Write tests** following the project's existing patterns (framework, file naming, assertion style). Keep tests focused — one assertion per behavior.
3. **Run the full test suite** including the new tests. Fix any failures.
4. **Commit** the new tests in a single commit: `test: add coverage for <area>`.

## Step 7: Aggregate Findings

Once fixes and tests are applied:

1. **Collect** all findings into a unified list, preserving their confidence scores.
2. **Deduplicate** — merge overlapping issues. Common overlaps:
   - Agent 1 (code review) and Agent 4 (security) may flag the same issue — keep the more detailed version
   - /simplify and Agent 1 may identify the same complexity problem — note it was already fixed by /simplify
3. **Prioritize** — Critical > Should fix > Consider. Within each level, higher confidence first.
4. **Flag** issues needing author judgment.

## Step 8: Quality Gate

After fixes and tests are applied, assess whether we're meeting the bar:

1. **Do all tests pass?** If not, that's a blocker.
2. **Are new code paths covered?** Cross-reference the diff with coverage results. Critical paths (error handling, security, data mutations) need edge case coverage.
3. **Did coverage go down?** If the PR adds significant code but coverage dropped, flag it.
4. **Maintainability verdict** — Based on code review findings and fixes applied: is the code in a state where the next person can confidently modify it?
5. **Security verdict** — Based on Agent 4's findings: are there unresolved security issues? If any Critical or High findings scored >= 75 and weren't fixed, that's a blocker.
6. **REST API backward compatibility** — If any `[BREAKING API]` findings exist, include the specific breaking changes in "Issues for your attention" with the `[BREAKING API]` label. This does not downgrade the verdict on its own — Phase 1.5 in the orchestrator handles the user confirmation gate separately.

If coverage, maintainability, or security doesn't meet the bar, add it to "Issues for your attention" with specific recommendations.

## Step 9: Save Review State

Save the review results so future runs can detect an existing review:

```bash
mkdir -p .reviews
```

Write `.reviews/<CACHE_KEY>.review.md` (using the same cache key as Step 0) with this format:

```markdown
---
ticket: <ticket ID or empty>
branch: <branch name>
head_sha: <current HEAD SHA>
timestamp: <ISO 8601>
verdict: <ready/warning/blocked>
---

<the review summary from Step 10, verbatim>
```

Add `.reviews/` to `.gitignore` if it isn't already — these are local artifacts, not committed.

## Step 10: Produce Review Summary

Return this structure to the orchestrator:

```
### Review agents ran
- Simplify: [N improvements applied / no changes] (ran first, before other agents)
- Code Review (Sonnet): [N issues found / clean, N fixes applied, N flagged for author]
- PR Shape (Sonnet): [assessment]
- Test & CI (Sonnet): [checks passing/failing, coverage assessment, N tests written]
- Security (Opus): [N findings / clean] (or "skipped — no security-relevant changes")
- Requirements (Sonnet): [X/Y criteria met, Z gaps] (or "skipped — no ticket detected")
- Confidence scoring (Haiku): [N findings scored, M passed threshold, K filtered as false positives]

### Quality gate
- Tests: [all passing / N failures]
- Coverage: [new code covered / gaps in <specific functions>]
- Maintainability: [good / N items to address]
- Security: [clean / N unresolved findings]
- API compatibility: [No REST API changes / Additive only (backward compatible) / BREAKING: <list changes>]
- Requirements: [all met / N gaps] (or "N/A — no ticket")

### Changes made
- [/simplify improvements]
- [code review fixes applied by orchestrator]
- [tests written from recommendations]

### Issues for your attention
- [things needing author judgment — skip if none]
- [low-confidence findings (scored 50-74) — skip if none]

### Review readiness
- ready — Ready for review
- warning — Ready after addressing the above
- blocked — Needs significant work (explain why)

### Suggested PR description
[Concise description a reviewer can scan in 30 seconds.
What changed, why, how to test, what to pay attention to.]
```

## Rules

1. **Never make a change you're not confident about.** When in doubt, flag it — don't fix it.
2. **If the diff is clean, say so.** Don't invent issues.
3. **Respect the project's conventions** over your own preferences.
4. **Be specific.** "This returns `undefined` when `items` is empty because of `.find()` on line 42" — not "this might have a bug."
5. **All agents are report-only.** No agent modifies files or commits. The orchestrator applies all changes sequentially after agents finish — first /simplify, then code review fixes, then tests. This eliminates race conditions and merge conflicts.
6. **Tests are a deliverable, not a suggestion.** The orchestrator must write tests from Agent 3's recommendations — don't skip this step.
7. **Confidence scoring filters noise.** Don't skip Step 4. False positives waste time and erode trust in the review process.
