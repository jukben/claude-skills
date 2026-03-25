---
name: pr
description: >
  Get your branch ready for review and merged. Detects the current state of your branch
  and PR, then routes to the right flow: self-review starting with /simplify, then
  parallel agents (code review with fixes, test & CI evaluation), followed by test
  writing from recommendations and a quality gate, publish as a draft PR, and hand off
  to babysit-pr for monitoring through to merge. Use when the user says "publish",
  "open a PR", "create a PR", "push this up", "ship this", "review my changes",
  "self-review", "is this ready to ship", "prepare for review", "check my test coverage",
  "is this maintainable", "code quality check", or anything about getting code into a PR
  or evaluating whether changes are ready.
allowed-tools: Read, Grep, Glob, Bash, Agent, Skill(babysit-pr), Skill(simplify)
---

# PR Pipeline

One skill to go from local branch to merged PR. Detects where you are and picks up from there.

## Phase 0: Detect State

Run the state detection script first — it tells you everything about the current branch, diff, PR, and CI:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/detect_state.sh
```

This returns a JSON object. Use it to decide the route.

## Routing

The state JSON is structured as:

```
{
  repo:      { name, owner, default_branch }
  branch:    "feature/..."
  diff_base: "main" or "origin/main"
  diff:      { commits, additions, deletions, files_changed, changed_files[] }
  pr:        { exists, number, title, url, state, is_draft, mergeable, merge_state,
               review_decision, automerge, labels[], assignees[], reviewers_requested[],
               additions, deletions, changed_files, commit_count }
  ci:        { status: "passing|failing|pending|none", total, passing, failing, pending,
               checks[]: { name, status, conclusion, url } }
  workspace: { has_claude_md, has_uncommitted }
}
```

Based on this, follow the right path:

### Has uncommitted changes?
If `workspace.has_uncommitted` is true, tell the user: "You have uncommitted changes. Want me to commit them first, or should we review what's staged?" Handle it before proceeding.

### No diff from base?
If `diff.commits` is 0 and there are no additions or deletions, there's nothing to review or publish. Tell the user and stop.

### PR already exists?
If `pr.exists` is true, the PR is already published. Show a quick status summary (draft status, CI, review, automerge) from the state JSON, then ask if they want to babysit it:
> "PR #<number> already exists (<url>). CI is <ci.status>, review is <pr.review_decision>. Want me to babysit it through to merge?"
If yes → invoke `/babysit-pr`. If no → done.

### Branch has changes, no PR yet → full pipeline
This is the main flow. Continue to Phase 1.

## Phase 1: Self-Review

Read `references/self-review.md` for the full review flow.

**Ask the user before proceeding.** Use the `AskUserQuestion` tool to present a choice with the self-review as the recommended default (first option):

- Option 1: **"Run self-review first (Recommended)"** — description: "Starts with /simplify, then runs parallel agents for code review and test coverage before publishing."
- Option 2: **"Skip to publish"** — description: "Publish the PR as a draft without running a self-review."

- If **self-review** (the default) → follow the self-review reference. It runs `/simplify` first, then spawns 2 parallel report-only agents:
  1. **Code Review** — correctness + maintainability in one pass, reports findings with concrete fixes
  2. **Test & CI** — runs checks, evaluates coverage, produces test recommendations

  All agents are report-only — none modify files. After agents complete, the orchestrator applies code review fixes, writes tests from recommendations, then runs a **quality gate** — verifies test coverage and maintainability meet the bar.

  - If 🛑 → **stop and show the summary**. Do not proceed to publish.
  - If ⚠️ → show issues (including coverage gaps and maintainability concerns), ask whether to fix before publishing or publish as-is.
  - If ✅ → continue to Phase 2. Carry the suggested PR description forward.
- If **no** → skip to Phase 2.

## Phase 2: Publish

Read `references/publish.md` for the full publish flow.

This handles creating the draft PR (using the self-review's suggested description if available).

After the PR is created, show the URL and continue to Phase 3.

## Phase 3: Draft → Ready Decision

The PR was created as a draft. Now decide whether to mark it ready for review:

- **Self-review ran and passed ✅** → Recommend marking ready. Ask: "Self-review passed — mark this ready for review?"
- **Self-review ran but ⚠️ (published as-is)** → Keep as draft. Tell the user: "Keeping as draft since there are open issues. Mark it ready when you've addressed them, or I can do it later via `/babysit-pr`."
- **Self-review was skipped** → Ask: "Want to mark it ready for review now, or keep as draft?"

If marking ready:
```bash
gh pr ready
```

## Phase 4: Offer Babysit Handoff

Ask the user: "Want me to babysit this PR through to merge? I'll monitor CI, fix failures, handle rebases, and enable automerge."

- If **yes** → invoke `/babysit-pr`
- If **no** → done. Show the PR URL and exit.

**Note on automerge:** When `/babysit-pr` enables automerge via `gh pr merge --auto --squash`, the PR is NOT merged yet. Auto-merge tells GitHub to merge once all branch protection requirements pass. The PR remains open until GitHub processes it. Do not report the PR as merged just because automerge was enabled.
