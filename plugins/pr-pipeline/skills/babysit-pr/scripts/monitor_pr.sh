#!/usr/bin/env bash
# Persistent PR state monitor for the Monitor tool.
# Polls CI checks, PR metadata, and review threads. Emits one-line events
# only when state changes. Designed to feed Claude Code's Monitor tool.
#
# Usage: monitor_pr.sh [PR_NUMBER_OR_URL] [POLL_INTERVAL_SECONDS]
#
# Default poll interval: 30 seconds.
#
# Event format (one line per state change):
#   [PR #N] Initial: CI Xpass,Yfail,Zpending | merge:STATUS review:STATUS conflicts:STATUS automerge:BOOL | threads:N unresolved (H human, B bot)
#   [PR #N] CI: Xpass,Yfail,Zpending — all green
#   [PR #N] CI: Xpass,Yfail,Zpending — FAILED: name1, name2
#   [PR #N] Conflicts: MERGEABLE -> CONFLICTING
#   [PR #N] Review: NONE -> APPROVED
#   [PR #N] Automerge: enabled
#   [PR #N] Draft: marked ready
#   [PR #N] Merge state: BLOCKED -> CLEAN
#   [PR #N] Threads: 3->1 unresolved (1 human, 0 bot)
#   [PR #N] Merged
#   [PR #N] Closed
#
# Exit codes:
#   0 — PR reached terminal state (merged/closed)
#   1 — no PR found / bad input
#   2 — missing tools or not authenticated

set -uo pipefail
# No set -e: transient API failures must not kill the monitor.

# --- Preflight ---

for cmd in gh jq git; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found" >&2
    exit 2
  fi
done

if ! gh auth status &>/dev/null; then
  echo "ERROR: gh is not authenticated" >&2
  exit 2
fi

# --- Resolve PR number ---

PR_INPUT="${1:-}"
INTERVAL="${2:-30}"

# REPO_FLAG is passed to all gh pr commands for cross-repo support.
REPO_FLAG=""

if [[ -n "$PR_INPUT" && "$PR_INPUT" =~ ^[0-9]+$ ]]; then
  PR="$PR_INPUT"
elif [[ -n "$PR_INPUT" && "$PR_INPUT" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  REPO_OWNER="${BASH_REMATCH[1]}"
  REPO_NAME="${BASH_REMATCH[2]}"
  PR="${BASH_REMATCH[3]}"
  REPO_FLAG="--repo ${REPO_OWNER}/${REPO_NAME}"
else
  PR=$(gh pr view --json number -q '.number' 2>/dev/null) || {
    echo "ERROR: No PR found for current branch. Pass a PR number or URL." >&2
    exit 1
  }
fi

# Resolve repo owner/name for GraphQL queries (if not already set from URL)
if [[ -z "${REPO_OWNER:-}" ]]; then
  REPO_OWNER=$(gh repo view --json owner -q '.owner.login' 2>/dev/null) || true
fi
if [[ -z "${REPO_NAME:-}" ]]; then
  REPO_NAME=$(gh repo view --json name -q '.name' 2>/dev/null) || true
fi

PREFIX="[PR #$PR]"

# --- State tracking ---

PREV_CI=""
PREV_STATE=""
PREV_REVIEWS=""
FIRST_RUN=true

# --- Helpers ---

fetch_ci() {
  # Returns: "Xpass,Yfail,Zpending,Wskip|failed_name1,failed_name2"
  # No checks: "none|"
  # On error: "ERROR"
  local raw
  raw=$(gh pr checks "$PR" $REPO_FLAG --json name,bucket 2>&1)
  local rc=$?

  # gh pr checks exits 1 with a text message when no checks exist
  if [[ $rc -ne 0 ]]; then
    if echo "$raw" | grep -qi "no checks"; then
      echo "none|"
    else
      echo "ERROR"
    fi
    return
  fi

  echo "$raw" | jq -r '
    if length == 0 then "none|"
    else
      (group_by(.bucket) | map({(.[0].bucket): length}) | add // {}) as $c |
      ($c.pass // 0) as $p |
      ($c.fail // 0) as $f |
      ($c.pending // 0) as $pend |
      ($c.skipping // 0) as $s |
      [.[] | select(.bucket == "fail") | .name] as $failed |
      "\($p)pass,\($f)fail,\($pend)pending,\($s)skip|\($failed | join(","))"
    end
  ' 2>/dev/null || echo "ERROR"
}

fetch_state() {
  # Returns: "STATE|MERGE_STATUS|REVIEW_DECISION|IS_DRAFT|MERGEABLE|AUTOMERGE"
  # On error: "ERROR"
  gh pr view "$PR" $REPO_FLAG --json state,mergeStateStatus,reviewDecision,isDraft,mergeable,autoMergeRequest 2>/dev/null |
    jq -r '
      (.reviewDecision // "") as $rd |
      "\(.state)|\(.mergeStateStatus)|\(if $rd == "" then "NONE" else $rd end)|\(.isDraft)|\(.mergeable)|\(if .autoMergeRequest then true else false end)"
    ' 2>/dev/null || echo "ERROR"
}

fetch_reviews() {
  # Returns: "UNRESOLVED|HUMAN|BOT"
  # On error: "ERROR"
  if [[ -z "$REPO_OWNER" || -z "$REPO_NAME" ]]; then
    echo "0|0|0"
    return
  fi

  gh api graphql \
    -f query='query($owner: String!, $repo: String!, $pr: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100) {
            nodes {
              isResolved
              comments(first: 1) { nodes { author { login } } }
            }
          }
        }
      }
    }' \
    -f owner="$REPO_OWNER" -f repo="$REPO_NAME" -F pr="$PR" 2>/dev/null |
    jq -r '
      def is_bot:
        (. // "unknown") | ascii_downcase |
        (endswith("[bot]") or test("-bot$") or test("^bot-") or
         test("^(cursor-review|cursor-ai|coderabbit|copilot|sweep-ai|sourcery-ai|codium-ai|ellipsis-dev|bloop-ai|pr-agent|greptile|what-the-diff|gitguardian|deepsource|snyk|sonarcloud|codecov|renovate|imgbot|stale|github-actions|vercel|netlify|railway|linear|sentry|datadog)"));

      .data.repository.pullRequest.reviewThreads.nodes as $t |
      [$t[] | select(.isResolved | not)] as $unresolved |
      [$unresolved[] | select(.comments.nodes[0].author.login | is_bot | not)] as $human |
      [$unresolved[] | select(.comments.nodes[0].author.login | is_bot)] as $bot |
      "\($unresolved | length)|\($human | length)|\($bot | length)"
    ' 2>/dev/null || echo "ERROR"
}

# --- Main loop ---

while true; do
  CI=$(fetch_ci)
  STATE=$(fetch_state)
  REVIEWS=$(fetch_reviews)

  if $FIRST_RUN; then
    CI_COUNTS="${CI%%|*}"
    CI_FAILED="${CI#*|}"

    IFS='|' read -r S_STATE S_MERGE S_REVIEW S_DRAFT S_MERGEABLE S_AUTOMERGE <<< "$STATE"
    IFS='|' read -r R_UNRESOLVED R_HUMAN R_BOT <<< "$REVIEWS"

    CI_SUMMARY="$CI_COUNTS"
    [[ -n "$CI_FAILED" ]] && CI_SUMMARY="$CI_SUMMARY FAILED: $CI_FAILED"

    echo "$PREFIX Initial: CI $CI_SUMMARY | merge:$S_MERGE review:$S_REVIEW draft:$S_DRAFT conflicts:$S_MERGEABLE automerge:$S_AUTOMERGE | threads:$R_UNRESOLVED unresolved ($R_HUMAN human, $R_BOT bot)"

    # Exit immediately on terminal states
    if [[ "$S_STATE" == "MERGED" ]]; then
      echo "$PREFIX Merged"
      exit 0
    fi
    if [[ "$S_STATE" == "CLOSED" ]]; then
      echo "$PREFIX Closed"
      exit 0
    fi

    PREV_CI="$CI"
    PREV_STATE="$STATE"
    PREV_REVIEWS="$REVIEWS"
    FIRST_RUN=false
    sleep "$INTERVAL"
    continue
  fi

  # --- CI changes ---
  if [[ "$CI" != "$PREV_CI" && "$CI" != "ERROR" ]]; then
    CI_COUNTS="${CI%%|*}"
    CI_FAILED="${CI#*|}"
    if [[ -z "$CI_FAILED" ]]; then
      echo "$PREFIX CI: $CI_COUNTS — all green"
    else
      echo "$PREFIX CI: $CI_COUNTS — FAILED: $CI_FAILED"
    fi
    PREV_CI="$CI"
  fi

  # --- PR state changes ---
  if [[ "$STATE" != "$PREV_STATE" && "$STATE" != "ERROR" ]]; then
    IFS='|' read -r OLD_S OLD_MS OLD_RD OLD_D OLD_M OLD_AM <<< "$PREV_STATE"
    IFS='|' read -r NEW_S NEW_MS NEW_RD NEW_D NEW_M NEW_AM <<< "$STATE"

    [[ "$OLD_M" != "$NEW_M" ]] && echo "$PREFIX Conflicts: $OLD_M -> $NEW_M"
    [[ "$OLD_RD" != "$NEW_RD" ]] && echo "$PREFIX Review: $OLD_RD -> $NEW_RD"
    [[ "$OLD_D" != "$NEW_D" && "$NEW_D" == "false" ]] && echo "$PREFIX Draft: marked ready"
    if [[ "$OLD_AM" != "$NEW_AM" ]]; then
      if [[ "$NEW_AM" == "true" ]]; then
        echo "$PREFIX Automerge: enabled"
      else
        echo "$PREFIX Automerge: disabled"
      fi
    fi
    [[ "$OLD_MS" != "$NEW_MS" ]] && echo "$PREFIX Merge state: $OLD_MS -> $NEW_MS"

    # Terminal states
    if [[ "$NEW_S" == "MERGED" ]]; then
      echo "$PREFIX Merged"
      exit 0
    fi
    if [[ "$NEW_S" == "CLOSED" ]]; then
      echo "$PREFIX Closed"
      exit 0
    fi

    PREV_STATE="$STATE"
  fi

  # --- Review thread changes ---
  if [[ "$REVIEWS" != "$PREV_REVIEWS" && "$REVIEWS" != "ERROR" ]]; then
    IFS='|' read -r OLD_U _ _ <<< "$PREV_REVIEWS"
    IFS='|' read -r NEW_U NEW_H NEW_B <<< "$REVIEWS"
    echo "$PREFIX Threads: ${OLD_U}->${NEW_U} unresolved ($NEW_H human, $NEW_B bot)"
    PREV_REVIEWS="$REVIEWS"
  fi

  sleep "$INTERVAL"
done
