---
name: babysit-pr
description: >
  Babysit a PR through to merge — monitor CI, fix failures, rebase on main,
  resolve review conversations, mark ready for review, enable automerge, and
  keep checking until merged. Use when the user says "babysit", "watch my PR",
  "monitor CI", "shepherd this to merge", or after publishing a PR via /pr.
allowed-tools: Bash(gh:*), Bash(git:*), Skill(loop), Monitor
---

# Babysit PR

Actively shepherd a PR to merge. Fix problems, resolve conversations, keep watching.

## Phase 1: Gather State

Two scripts in `scripts/` handle data gathering. Both accept a PR number or URL; if omitted they auto-detect from the current branch.

Run in parallel — don't suppress stderr (errors are diagnostic):

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/fetch_pr_state.sh" $PR_NUMBER
```

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/fetch_review_threads.sh" $PR_NUMBER
```

**`fetch_pr_state.sh`** → `{ pr, checks, fetchedMain }`
- `pr`: number, title, url, head/base, isDraft, mergeable, mergeStateStatus, reviewDecision, autoMergeRequest
- `checks`: total/passed/failed/pending/skipped counts + `details[]` (name, status, elapsed, url)
- `fetchedMain`: whether the default branch fetch succeeded

**`fetch_review_threads.sh`** → `{ pr, threads, summary }`
- `summary`: total/resolved/unresolved/unresolved_human/unresolved_bot/outdated
- `threads[]`: id, path, line, isResolved, isOutdated, authorLogin, authorType ("human"|"bot"), comments[]

Present the status table, then move to Phase 2.

## Phase 2: Fix Everything Fixable

Work in priority order. Commit and push after each fix.

### 2a. Draft → Ready

If `isDraft` is true: wait until CI is green and no conflicts, then ask "CI is green — ready to mark for review?" Apply with `gh pr ready $PR_NUMBER`.

### 2b. CI Failures

If `checks.failed > 0`:

1. Get failure details from the check URLs in the state JSON, or use `gh run view` to inspect logs. If a CI-provider MCP server is configured (CircleCI, GitHub Actions, etc.), prefer it for richer failure context.
2. Propose concrete fixes (file + line)
3. Ask before applying
4. Commit, push — CI re-runs

### 2c. Merge Conflicts

If `mergeable` is `CONFLICTING`:

1. Show conflicting files: `git diff --name-only HEAD...origin/<base>` (use the PR's `base` from state JSON)
2. Rebase: `git rebase origin/<base>`
3. Resolve if straightforward, otherwise ask
4. Ask before force-pushing

### 2d. Automerge

If not enabled and no blockers remain (or only review pending), suggest: `gh pr merge $PR_NUMBER --auto --squash`. Ask before enabling.

**Important:** `--auto` does NOT merge the PR immediately. It tells GitHub to merge automatically once all branch protection requirements are satisfied (CI passing, required reviews, etc.). After enabling auto-merge, the PR is still open — continue monitoring in Phase 3 until GitHub actually merges it.

### 2e. Unresolved Conversations

Unresolved threads block merge. Skip if `summary.unresolved` is 0.

For each unresolved thread, follow three steps:

#### Step 1: Summarize

Read the full thread and the code at `path`:`line`. State in one sentence what the reviewer is asking for or pointing out.

#### Step 2: Assess validity

Classify the feedback:

- **Valid** — real bug, security issue, missing edge case, or reasonable improvement
- **Misunderstanding** — reviewer misread the code or missed context elsewhere in the PR
- **Subjective** — style preference, naming opinion, or approach the project doesn't enforce

#### Step 3: Propose resolution

Based on the assessment, pick one:

- **Code change** — describe the specific fix with file and line. Ask before applying.
- **Reply** — draft a response explaining the current approach (for misunderstandings or intentional decisions). Get user approval before posting.
- **Resolve without action** — explain why: already addressed elsewhere, out of scope, or conflicts with project conventions.

After any fix is pushed, resolve the thread:
```bash
gh api graphql -f query='mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }' -f id=THREAD_ID
```

#### Prioritization

Work through comments by severity: bugs → security → performance → style nits.

#### Human vs. bot handling

**Human threads** (`authorType: "human"`) get individual attention through all three steps above. Always ask the user before applying fixes or posting replies.

**Bot threads** (`authorType: "bot"`) get triaged in batch. Most bot comments fall into predictable buckets:

- **Real issue** (security flags, type errors, actual bugs) → treat like a human comment
- **Style nit** (formatting, naming conventions the project doesn't follow) → resolve without action
- **Noise** (PR summaries, redundant linting CI already covers) → resolve without action

Present bot comments grouped: "Bot left 4 comments: 2 nits, 1 null-check issue, 1 noise." Ask before bulk-resolving.

#### Many threads (5+)

Show a grouped summary first, then work in order: human changes → human questions → bot real issues → bot nits.

### 2f. Review Status

After resolving conversations, reassess:
- `CHANGES_REQUESTED` + all threads resolved → "Waiting for re-approval from @reviewer"
- `REVIEW_REQUIRED` → note who needs to review
- `APPROVED` → move on

## Phase 3: Monitor

A PR is merge-ready when: CI green, no conflicts, conversations resolved, review approved, automerge enabled. Until then, keep watching.

### Start the monitor

A persistent polling script watches CI checks, PR metadata, and review threads every 30 seconds. It emits one-line events **only when state changes**, keeping notifications quiet until something actually happens.

```
Monitor({
  command: "bash \"${CLAUDE_SKILL_DIR}/scripts/monitor_pr.sh\" $PR_NUMBER 30",
  description: "PR #<number> status",
  persistent: true
})
```

The script emits events in this format:

| Event | Meaning | Action |
|-------|---------|--------|
| `CI: ... — all green` | All checks pass | Check if merge-ready |
| `CI: ... — FAILED: name1, name2` | CI failure | Re-enter Phase 2b |
| `Conflicts: MERGEABLE -> CONFLICTING` | New conflicts | Re-enter Phase 2c |
| `Review: ... -> APPROVED` | Review approved | Check if merge-ready |
| `Threads: X->Y unresolved (H human, B bot)` | Review thread changes | Re-enter Phase 2e if increased |
| `Automerge: enabled/disabled` | Automerge toggled | Re-enter Phase 2d if disabled |
| `Draft: marked ready` | No longer a draft | Note — continue monitoring |
| `Merged` | PR merged | Report success and stop |
| `Closed` | PR closed | Report and stop |

### React to events

When a monitor notification arrives indicating a problem, re-enter the relevant Phase 2 step. Do not re-run both fetch scripts — the monitor event tells you exactly what changed.

After fixing an issue (CI failure, conflict, review thread), the monitor will detect the new state on its next poll cycle and emit an updated event.

### Loop fallback

If the Monitor tool is not available, fall back to the polling loop. The loop re-fetches everything each cycle rather than tracking incremental state — simpler and more robust, at the cost of slightly more work per iteration.

```
/loop 5m /babysit-pr
```

Each iteration re-runs both scripts from Phase 1 and checks all conditions:

| Condition              | What to check                          | Action if unmet             |
|------------------------|----------------------------------------|-----------------------------|
| CI green               | `checks.failed == 0`                   | Re-enter Phase 2b           |
| No conflicts           | `mergeable != "CONFLICTING"`           | Re-enter Phase 2c           |
| Conversations resolved | `summary.unresolved == 0`              | Re-enter Phase 2e           |
| Review approved        | `reviewDecision == "APPROVED"`         | Note — can't force this     |
| Automerge enabled      | `autoMergeRequest == true`             | Re-enter Phase 2d           |

### Completion

When all conditions are met and automerge is enabled → report "All checks are green and automerge is enabled. GitHub will merge automatically once branch protection requirements are satisfied — nothing left for us to do." Then stop the monitor (or loop).

Do NOT report the PR as merged at this point. Automerge means GitHub will handle it, but the merge hasn't happened yet. The PR is still open until GitHub processes it. The monitor will emit a `Merged` event when GitHub completes the merge.

If the user doesn't want continuous monitoring, present the final status and exit.

## Report Format

This format enables quick scanning of PR health — status table first for at-a-glance assessment, then conversations requiring attention, then actions taken. Consistent structure means the user can skim the same positions each time.

```
## PR #<number> — <title>

| Check           | Status |
|-----------------|--------|
| CI              | ...    |
| Conflicts       | ...    |
| Conversations   | 2 unresolved (1 human, 1 bot) |
| Review          | ...    |
| Automerge       | ...    |

## Unresolved Conversations
### Human
- @reviewer in `path/to/file.ts:42` — wants null check added → **code change**: add guard at line 44
- @reviewer in `path/to/utils.ts:18` — asks why we use X over Y → **reply**: drafted response explaining tradeoff
### Bot
- bot-review: 3 style nits (resolve), 1 potential null deref (code change)

## Actions Taken
<what was fixed>

## Remaining
<what still needs attention>
```

## Example

PR #142 is a draft, CI has one failing check, and a reviewer left 3 comments:
> "babysit this"

1. Fetch state → draft, 1 CI failure, 3 unresolved threads (2 human, 1 bot)
2. Fix CI: read failure logs, apply missing import fix, push → CI re-runs
3. Wait for CI green, then ask to mark ready → `gh pr ready`
4. Resolve threads: human comment about null check → code change; human question about naming → draft reply for approval; bot style nit → resolve without action
5. Enable automerge → `gh pr merge --auto --squash`
6. Monitor until GitHub merges

## Guidelines

- **Fix, don't narrate.** Address CI, conflicts, conversations, automerge — then report what you did.
- Always ask before: force-pushing, enabling automerge, marking ready, applying review fixes, posting replies, bulk-resolving bot threads.
- Every comment gets: summarize → assess validity → propose resolution. "No action" is a valid resolution when the suggestion conflicts with project conventions, is already handled, or the current approach is intentional.
- For subjective feedback, note both perspectives and recommend a path forward.
- Prioritize by severity: bugs → security → performance → style.
- Human comments get individual attention. Bot comments get grouped and triaged.
- Unresolved conversations are merge blockers — treat them with the same urgency as CI failures.
- Concise output: status table + conversations + actions + remaining. No filler.
