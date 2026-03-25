#!/usr/bin/env bash
# Detect the current state of the branch/PR using gh CLI + git.
# Outputs a single JSON object with everything the orchestrator needs to route.
#
# Relies on: gh (GitHub CLI, authenticated), git, jq

set -euo pipefail

# ─── Helpers ───

json_bool() { if "$@" 2>/dev/null; then echo "true"; else echo "false"; fi; }

# ─── Verify gh is authenticated ───

if ! gh auth status >/dev/null 2>&1; then
  echo '{"error": "gh CLI is not authenticated. Run `gh auth login` first."}' >&2
  exit 1
fi

# ─── Repo info (from gh, not hardcoded) ───

REPO_JSON=$(gh repo view --json defaultBranchRef,name,owner 2>/dev/null || echo '{}')
DEFAULT_BRANCH=$(echo "$REPO_JSON" | jq -r '.defaultBranchRef.name // "main"')
REPO_NAME=$(echo "$REPO_JSON" | jq -r '.name // empty')
REPO_OWNER=$(echo "$REPO_JSON" | jq -r '.owner.login // empty')

# ─── Branch info ───

BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Determine diff base
DIFF_BASE=""
if git rev-parse --verify "$DEFAULT_BRANCH" >/dev/null 2>&1; then
  DIFF_BASE="$DEFAULT_BRANCH"
elif git rev-parse --verify "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
  DIFF_BASE="origin/$DEFAULT_BRANCH"
fi

# ─── Diff stats (git — always available, even without a PR) ───

DIFF_JSON='{"commits":0,"additions":0,"deletions":0,"files_changed":0,"changed_files":[]}'
if [ -n "$DIFF_BASE" ]; then
  COMMITS=$(git rev-list --count "$DIFF_BASE"..HEAD 2>/dev/null || echo "0")
  NUMSTAT=$(git diff "$DIFF_BASE"...HEAD --numstat 2>/dev/null || true)
  if [ -n "$NUMSTAT" ]; then
    ADD=$(echo "$NUMSTAT" | awk '{s+=$1} END {print s+0}')
    DEL=$(echo "$NUMSTAT" | awk '{s+=$2} END {print s+0}')
    NFILES=$(echo "$NUMSTAT" | wc -l | tr -d ' ')
    FILES=$(git diff "$DIFF_BASE"...HEAD --name-only 2>/dev/null | head -50 | jq -R -s 'split("\n") | map(select(. != ""))')
  else
    ADD=0; DEL=0; NFILES=0; FILES="[]"
  fi
  DIFF_JSON=$(jq -n \
    --argjson commits "$COMMITS" \
    --argjson additions "$ADD" \
    --argjson deletions "$DEL" \
    --argjson files_changed "$NFILES" \
    --argjson changed_files "${FILES:-[]}" \
    '{commits:$commits, additions:$additions, deletions:$deletions, files_changed:$files_changed, changed_files:$changed_files}')
fi

# ─── PR info (single gh pr view call with all fields we need) ───

PR_FIELDS="number,title,url,state,body,isDraft,mergeable,mergeStateStatus,reviewDecision,autoMergeRequest,labels,baseRefName,headRefName,additions,deletions,changedFiles,commits,reviewRequests,assignees,statusCheckRollup"
PR_JSON=$(gh pr view --json "$PR_FIELDS" 2>/dev/null || echo "")

PR_SECTION='{"exists":false}'
CHECKS_SECTION='{"status":"none","total":0,"passing":0,"failing":0,"pending":0,"checks":[]}'

if [ -n "$PR_JSON" ]; then
  # ── Core PR data ──
  PR_SECTION=$(echo "$PR_JSON" | jq '{
    exists: true,
    number: .number,
    title: .title,
    url: .url,
    state: .state,
    is_draft: .isDraft,
    base: .baseRefName,
    head: .headRefName,
    mergeable: .mergeable,
    merge_state: .mergeStateStatus,
    review_decision: (.reviewDecision // "NONE"),
    automerge: (if .autoMergeRequest != null then true else false end),
    additions: .additions,
    deletions: .deletions,
    changed_files: .changedFiles,
    commit_count: (.commits | length),
    labels: [.labels[]?.name],
    assignees: [.assignees[]?.login],
    reviewers_requested: [.reviewRequests[]? | (.login // .name // .slug)]
  }')

  # ── CI checks breakdown (from same gh pr view call) ──
  CHECKS_SECTION=$(echo "$PR_JSON" | jq '{
    checks: [
      .statusCheckRollup[]? | {
        name: .name,
        status: .status,
        conclusion: .conclusion,
        url: .detailsUrl
      }
    ]
  } | {
    total: (.checks | length),
    passing: ([.checks[] | select(.conclusion == "SUCCESS")] | length),
    failing: ([.checks[] | select(.conclusion == "FAILURE")] | length),
    pending: ([.checks[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING")] | length),
    status: (
      if ([.checks[] | select(.conclusion == "FAILURE")] | length) > 0 then "failing"
      elif ([.checks[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING")] | length) > 0 then "pending"
      elif (.checks | length) > 0 then "passing"
      else "none"
      end
    ),
    checks: .checks
  }')
fi

# ─── Workspace context ───

HAS_CLAUDE_MD=$(json_bool test -f "CLAUDE.md")
HAS_UNCOMMITTED=$(json_bool test -n "$(git status --porcelain 2>/dev/null)")

# ─── Assemble final output ───

jq -n \
  --arg branch "$BRANCH" \
  --arg default_branch "$DEFAULT_BRANCH" \
  --arg diff_base "$DIFF_BASE" \
  --arg repo_name "$REPO_NAME" \
  --arg repo_owner "$REPO_OWNER" \
  --argjson diff "$DIFF_JSON" \
  --argjson pr "$PR_SECTION" \
  --argjson ci "$CHECKS_SECTION" \
  --argjson has_claude_md "$HAS_CLAUDE_MD" \
  --argjson has_uncommitted "$HAS_UNCOMMITTED" \
  '{
    repo: {name: $repo_name, owner: $repo_owner, default_branch: $default_branch},
    branch: $branch,
    diff_base: $diff_base,
    diff: $diff,
    pr: $pr,
    ci: $ci,
    workspace: {has_claude_md: $has_claude_md, has_uncommitted: $has_uncommitted}
  }'
