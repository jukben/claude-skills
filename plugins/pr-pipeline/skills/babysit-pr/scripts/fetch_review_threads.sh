#!/usr/bin/env bash
# Fetch unresolved review threads for a PR and classify authors as human or bot.
#
# Usage: fetch_review_threads.sh [PR_URL_OR_NUMBER]
#
# Can be called from any directory — resolves its own location.
# If no argument is given, auto-detects from the current branch.
#
# Outputs JSON to stdout:
#   { pr, threads: [...], summary: { total, resolved, unresolved, unresolved_human, unresolved_bot, outdated } }
#
# Exit codes:
#   0 — success
#   1 — no PR found / bad input
#   2 — gh CLI not found or not authenticated
#   3 — GraphQL query failed

set -euo pipefail

# --- Preflight checks ---

if ! command -v gh &>/dev/null; then
  echo '{"error": "gh CLI not found. Install from https://cli.github.com/"}' >&2
  exit 2
fi

if ! command -v jq &>/dev/null; then
  echo '{"error": "jq not found. Install with: brew install jq (or apt-get install jq)"}' >&2
  exit 2
fi

if ! gh auth status &>/dev/null; then
  echo '{"error": "gh is not authenticated. Run: gh auth login"}' >&2
  exit 2
fi

# --- Resolve PR number and repo ---

if [[ $# -ge 1 ]]; then
  PR_INPUT="$1"
else
  PR_INPUT=""
fi

if [[ -n "$PR_INPUT" && "$PR_INPUT" =~ ^[0-9]+$ ]]; then
  PR_NUMBER="$PR_INPUT"
  REPO_INFO=$(gh repo view --json owner,name -q '"\(.owner.login)/\(.name)"')
  OWNER=$(echo "$REPO_INFO" | cut -d/ -f1)
  REPO=$(echo "$REPO_INFO" | cut -d/ -f2)
elif [[ -n "$PR_INPUT" && "$PR_INPUT" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  PR_NUMBER="${BASH_REMATCH[3]}"
else
  # Auto-detect from current branch
  PR_JSON=$(gh pr view --json number,url 2>/dev/null || echo "")
  if [[ -z "$PR_JSON" ]]; then
    echo '{"error": "No PR found for current branch. Pass a PR number or URL."}' >&2
    exit 1
  fi
  PR_NUMBER=$(echo "$PR_JSON" | jq -r '.number')
  PR_URL=$(echo "$PR_JSON" | jq -r '.url')
  if [[ "$PR_URL" =~ github\.com/([^/]+)/([^/]+)/pull/ ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
  else
    REPO_INFO=$(gh repo view --json owner,name -q '"\(.owner.login)/\(.name)"')
    OWNER=$(echo "$REPO_INFO" | cut -d/ -f1)
    REPO=$(echo "$REPO_INFO" | cut -d/ -f2)
  fi
fi

# --- Fetch review threads via GraphQL ---

QUERY='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          comments(first: 30) {
            nodes {
              id
              author { login }
              body
              createdAt
              url
            }
          }
        }
      }
    }
  }
}
'

RAW=$(gh api graphql \
  -f query="$QUERY" \
  -f owner="$OWNER" \
  -f repo="$REPO" \
  -F pr="$PR_NUMBER" 2>&1) || {
  echo "{\"error\": \"GraphQL query failed\", \"details\": $(echo "$RAW" | jq -Rs .)}" >&2
  exit 3
}

# --- Classify authors and build output ---

echo "$RAW" | jq --arg pr "$PR_NUMBER" '
  # Bot detection function
  def is_bot:
    . as $login |
    ($login | ascii_downcase) as $lower |
    (
      # Explicit [bot] suffix
      ($lower | endswith("[bot]")) or
      # Known bot logins (prefix match)
      ($lower | test("^(cursor-review|cursor-ai|coderabbit|copilot|sweep-ai|sourcery-ai|codium-ai|ellipsis-dev|bloop-ai|pr-agent|greptile|what-the-diff|gitguardian|deepsource|snyk|sonarcloud|codecov|renovate|imgbot|stale|github-actions|vercel|netlify|railway|linear|sentry|datadog)")) or
      # Generic bot patterns
      ($lower | test("\\[bot\\]$")) or
      ($lower | test("-bot$")) or
      ($lower | test("^bot-"))
    );

  .data.repository.pullRequest.reviewThreads.nodes as $threads |

  # Enrich each thread
  [
    $threads[] |
    . as $thread |
    ($thread.comments.nodes[0].author.login // "unknown") as $author |
    ($author | is_bot) as $bot |
    {
      id: $thread.id,
      path: $thread.path,
      line: $thread.line,
      isResolved: $thread.isResolved,
      isOutdated: $thread.isOutdated,
      authorLogin: $author,
      authorType: (if $bot then "bot" else "human" end),
      commentCount: ($thread.comments.nodes | length),
      firstComment: $thread.comments.nodes[0].body,
      lastComment: ($thread.comments.nodes | last).body,
      lastAuthor: (($thread.comments.nodes | last).author.login // "unknown"),
      comments: [
        $thread.comments.nodes[] | {
          author: (.author.login // "unknown"),
          body: .body,
          createdAt: .createdAt,
          url: .url
        }
      ]
    }
  ] as $enriched |

  # Build summary
  {
    pr: ($pr | tonumber),
    threads: $enriched,
    summary: {
      total: ($enriched | length),
      resolved: ([$enriched[] | select(.isResolved)] | length),
      unresolved: ([$enriched[] | select(.isResolved | not)] | length),
      unresolved_human: ([$enriched[] | select((.isResolved | not) and .authorType == "human")] | length),
      unresolved_bot: ([$enriched[] | select((.isResolved | not) and .authorType == "bot")] | length),
      outdated: ([$enriched[] | select(.isOutdated)] | length)
    }
  }
'
