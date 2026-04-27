---
name: pr
description: >
  Use when the user says "publish", "open a PR", "create a PR", "push this up",
  "ship this", "review my changes", "self-review", "is this ready to ship",
  "prepare for review", "check my test coverage", "is this maintainable",
  "code quality check", or anything about getting code into a PR or evaluating
  whether changes are ready for review.
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
  ticket:    { id: "ABC-123" or "", branch_has_ticket: true/false }
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

Read `references/self-review.md` and follow its steps inline — this is a reference file, not a skill to invoke.

Review depth should match the change. A docs tweak doesn't need the same battery as a change that touches auth. Pick a tier, then ask the user to confirm.

### Step 1.1: Classify the change

Run the classifier script — it's deterministic, returns diff stats + path categorization + a preliminary tier:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/classify_changes.sh
```

Output shape:
```
{
  stats:             { files_changed, lines_changed, commits },
  categories:        { docs_only, tests_only, config_only, touches_sensitive },
  sensitive_paths:   [...],
  preliminary_tier:  "XS" | "S" | "M" | "L"
}
```

### Step 1.2: Let Haiku sanity-check the tier

The script picks a tier from file paths and stats alone. Haiku adds nuance — catching cases like "this 'docs' change includes an executable example" or "this 20-line diff modifies a payment calculation". Spawn a Haiku agent with:

- The classifier JSON
- The first ~200 lines of `git diff <diff_base>...HEAD`
- The tier rubric below

Ask it to return `{"tier": "XS|S|M|L", "reason": "<one sentence>"}`. Use its answer as the recommended tier.

**Tier rubric:**
| Tier | When                                                                 | Agents run                                                   |
|------|----------------------------------------------------------------------|--------------------------------------------------------------|
| XS   | Docs / config / comments only. No executable code changes.           | None — skip self-review, go straight to publish.             |
| S    | Small, low-risk change. Tests-only, or a tiny prod tweak.            | `/simplify` only.                                            |
| M    | Normal prod change. No security surface touched.                     | `/simplify`, code review, PR shape, test/CI, requirements.   |
| L    | Large diff, or touches sensitive paths (auth, api, migrations, etc). | All of the above + security.                                 |

### Step 1.3: Ask the user

Use `AskUserQuestion` with the four tiers as options. Put the recommended tier first with `(Recommended)` appended, and include Haiku's one-sentence reason in the description so the user can see why. Example — if Haiku picks M:

- **"Standard review (Recommended)"** — "M tier: /simplify + code review + PR shape + test/CI + requirements. <Haiku's reason>"
- **"Deep review"** — "L tier: adds security review on Opus. Pick this if you're unsure about the blast radius."
- **"Light review"** — "S tier: run /simplify only. Pick this for trivially safe changes."
- **"Skip review"** — "XS tier: go straight to publish. Pick this for docs/config-only changes."

Always offer all four so the user can override. Keep the descriptions tight — the user should be able to pick in a glance.

### Step 1.4: Execute the chosen tier

Self-review.md is tier-aware — pass the chosen tier and it runs the right subset.

- **XS** → Skip self-review entirely. Go to Phase 2. Note: no `[BREAKING API]` gate runs — XS excludes code changes by definition.
- **S** → Invoke `Skill(simplify)`, let it commit any fixes, then go to Phase 2. No agents run, no quality gate.
- **M / L** → Follow `references/self-review.md` inline. It handles /simplify, agents, confidence scoring, fixes, tests, and the quality gate.

After M or L completes:
  - If `blocked` → **stop and show the summary**. Do not proceed to publish.
  - If `warning` → show issues, ask whether to fix before publishing or publish as-is. If publishing as-is, continue to Phase 1.5, then Phase 2.
  - If `ready` → continue to Phase 1.5, then Phase 2. Carry the suggested PR description forward.

## Phase 1.5: Breaking API Compatibility Check

If the self-review summary includes any `[BREAKING API]` findings:

1. Display the specific breaking changes clearly to the user.
2. Prompt: "This PR contains breaking REST API changes that are NOT backward compatible: \<list\>. Publishing requires all API consumers to update. Do you acknowledge and take responsibility for these breaking changes? (yes/no)"
3. If **no** → stop. Do not proceed to publish.
4. If **yes** → proceed to Phase 2.

If there are no `[BREAKING API]` findings, skip directly to Phase 2.

## Phase 2: Publish

Read `references/publish.md` for the full publish flow.

This handles:
1. Noting the detected ticket (if any) for the title and description
2. Branch renaming — only if the project requires the ticket in the branch name
3. Creating the draft PR (using the self-review's suggested description if available)

After the PR is created, show the URL and continue to Phase 3.

## Phase 3: Draft → Ready Decision

The PR was created as a draft. Now decide whether to mark it ready for review:

- **M or L review passed (`ready`)** → Recommend marking ready. Ask: "Self-review passed — mark this ready for review?"
- **M or L review `warning` (published as-is)** → Keep as draft. Tell the user: "Keeping as draft since there are open issues. Mark it ready when you've addressed them, or I can do it later via `/babysit-pr`."
- **XS or S tier** (no verdict produced) → Ask: "Want to mark it ready for review now, or keep as draft?"

If marking ready:
```bash
gh pr ready
```

## Phase 4: Offer Babysit Handoff

Ask the user: "Want me to babysit this PR through to merge? I'll monitor CI, fix failures, handle rebases, and enable automerge."

- If **yes** → invoke `/babysit-pr`
- If **no** → done. Show the PR URL and exit.

**Note on automerge:** When `/babysit-pr` enables automerge via `gh pr merge --auto --squash`, the PR is NOT merged yet. Auto-merge tells GitHub to merge once all branch protection requirements pass. The PR remains open until GitHub processes it. Do not report the PR as merged just because automerge was enabled.

## Example

User on branch `jukben/abc-265-edit-wizard` with 3 commits, no PR yet:
> "ship this"

1. `detect_state.sh` → branch has changes, no PR, ticket ABC-265 found
2. `classify_changes.sh` → 180 lines across 4 files, none sensitive → preliminary tier M
3. Haiku agrees: M tier, "adds wizard navigation logic in the settings flow"
4. User picks M (the default)
5. `/simplify` runs, cleans up a duplicated helper
6. 4 parallel agents report (code review, PR shape, test/CI, requirements): one null-check issue (Critical), PR shape clean, 2 test recommendations, all ticket criteria met. Security is skipped because tier is M.
7. Confidence scoring filters 1 false positive from code review
8. Orchestrator applies the null-check fix, writes 2 tests, all pass
9. Quality gate: ready
10. Publish as draft PR `ABC-265: Land edit wizard on first empty step`
11. Mark ready, offer babysit → user accepts → `/babysit-pr` takes over
