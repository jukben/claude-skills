#!/usr/bin/env bash
# Fetch the full state of a PR: metadata, CI checks, and merge readiness.
#
# Usage: fetch_pr_state.sh [PR_NUMBER_OR_URL]
#
# If no argument is given, auto-detects from the current branch.
#
# Outputs JSON to stdout:
#   {
#     pr: { number, title, url, head, base, isDraft, mergeable, mergeStateStatus,
#            reviewDecision, autoMergeRequest },
#     checks: { total, passed, failed, pending, details: [...] },
#     fetchedMain: true/false
#   }
#
# Exit codes:
#   0 — success
#   1 — no PR found / bad input
#   2 — gh/jq/git not found or gh not authenticated

set -euo pipefail

# --- Preflight checks ---

for cmd in gh jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "{\"error\": \"$cmd not found\"}" >&2
    exit 2
  fi
done

if ! gh auth status &>/dev/null; then
  echo '{"error": "gh is not authenticated. Run: gh auth login"}' >&2
  exit 2
fi

# --- Resolve PR number ---

PR_INPUT="${1:-}"

if [[ -n "$PR_INPUT" && "$PR_INPUT" =~ ^[0-9]+$ ]]; then
  PR_NUMBER="$PR_INPUT"
elif [[ -n "$PR_INPUT" && "$PR_INPUT" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  PR_NUMBER="${BASH_REMATCH[3]}"
else
  PR_NUMBER=$(gh pr view --json number -q '.number' 2>/dev/null) || {
    echo '{"error": "No PR found for current branch. Pass a PR number or URL."}' >&2
    exit 1
  }
fi

# --- Fetch PR metadata ---

PR_JSON=$(gh pr view "$PR_NUMBER" --json \
  number,title,url,headRefName,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,autoMergeRequest,isDraft)

# --- Fetch CI checks ---
# gh pr checks can exit non-zero when checks are failing/pending — that's expected, not an error.

CHECKS_RAW=$(gh pr checks "$PR_NUMBER" 2>&1) || true

# Parse checks into structured JSON.
# gh pr checks outputs tab-separated lines like:
#   name\tstatus\telapsed\turl

CHECKS_JSON=$(echo "$CHECKS_RAW" | awk -F'\t' '
  BEGIN { printf "[" ; first=1 }
  NF >= 2 {
    name = $1; gsub(/^[ \t]+|[ \t]+$/, "", name)
    status_raw = $2; gsub(/^[ \t]+|[ \t]+$/, "", status_raw)
    elapsed = (NF >= 3) ? $3 : ""
    url = (NF >= 4) ? $4 : ""

    # Normalize status
    status_lower = tolower(status_raw)
    if (status_lower ~ /pass/) status = "pass"
    else if (status_lower ~ /fail/) status = "fail"
    else if (status_lower ~ /pending|waiting|queued|in_progress/) status = "pending"
    else if (status_lower ~ /cancel|skipped/) status = "skipped"
    else status = status_raw

    if (!first) printf ","
    first = 0

    # Escape JSON strings
    gsub(/"/, "\\\"", name)
    gsub(/"/, "\\\"", status)
    gsub(/"/, "\\\"", elapsed)
    gsub(/"/, "\\\"", url)
    printf "{\"name\":\"%s\",\"status\":\"%s\",\"elapsed\":\"%s\",\"url\":\"%s\"}", name, status, elapsed, url
  }
  END { printf "]" }
')

# --- Fetch main branch ---

DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "main")
FETCH_OK="true"
git fetch origin "$DEFAULT_BRANCH" --quiet 2>/dev/null || FETCH_OK="false"

# --- Assemble output ---

echo "$PR_JSON" | jq \
  --argjson checks "$CHECKS_JSON" \
  --argjson fetchedMain "$FETCH_OK" \
  '{
    pr: {
      number: .number,
      title: .title,
      url: .url,
      head: .headRefName,
      base: .baseRefName,
      isDraft: .isDraft,
      mergeable: .mergeable,
      mergeStateStatus: .mergeStateStatus,
      reviewDecision: .reviewDecision,
      autoMergeRequest: (if .autoMergeRequest then true else false end)
    },
    checks: {
      total: ($checks | length),
      passed: ([$checks[] | select(.status == "pass")] | length),
      failed: ([$checks[] | select(.status == "fail")] | length),
      pending: ([$checks[] | select(.status == "pending")] | length),
      skipped: ([$checks[] | select(.status == "skipped")] | length),
      details: $checks
    },
    fetchedMain: $fetchedMain
  }'
