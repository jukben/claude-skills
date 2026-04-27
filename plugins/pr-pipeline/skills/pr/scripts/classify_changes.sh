#!/usr/bin/env bash
# Classify the current branch's changes to pick a review tier.
# Deterministic — no LLM call. The orchestrator passes this output to Haiku
# for a final tier decision (Haiku can override, e.g. spotting business logic
# hidden in a "docs-only" diff).
#
# Outputs JSON with: stats, category flags, matched sensitive paths, and a
# preliminary tier (XS/S/M/L).
#
# Relies on: git, jq.

set -euo pipefail

# ─── Determine diff base ───

DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

DIFF_BASE=""
if git rev-parse --verify "$DEFAULT_BRANCH" >/dev/null 2>&1; then
  DIFF_BASE="$DEFAULT_BRANCH"
elif git rev-parse --verify "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
  DIFF_BASE="origin/$DEFAULT_BRANCH"
fi

if [ -z "$DIFF_BASE" ]; then
  echo '{"error": "no diff base found"}' >&2
  exit 1
fi

# ─── Gather diff stats ───

FILES=$(git diff "$DIFF_BASE"...HEAD --name-only 2>/dev/null || true)
NUMSTAT=$(git diff "$DIFF_BASE"...HEAD --numstat 2>/dev/null || true)
COMMITS=$(git rev-list --count "$DIFF_BASE"..HEAD 2>/dev/null || echo "0")

if [ -z "$FILES" ]; then
  jq -n '{stats:{files_changed:0,lines_changed:0,commits:0}, categories:{docs_only:false,tests_only:false,config_only:false,touches_sensitive:false}, sensitive_paths:[], preliminary_tier:"XS"}'
  exit 0
fi

FILES_CHANGED=$(echo "$FILES" | wc -l | tr -d ' ')
LINES_CHANGED=$(echo "$NUMSTAT" | awk '{s+=$1+$2} END {print s+0}')

# ─── Category pattern matching ───
#
# A category is "only" if EVERY changed file matches the pattern.
# Sensitive paths are a list — any match promotes the tier to L.

is_docs()      { [[ "$1" =~ \.md$ ]] || [[ "$1" =~ ^docs/ ]] || [[ "$1" == README* ]] || [[ "$1" =~ \.txt$ ]]; }
is_tests()     { [[ "$1" =~ (^|/)__tests__/ ]] || [[ "$1" =~ \.(test|spec)\.[a-z]+$ ]] || [[ "$1" =~ (^|/)tests?/ ]]; }
is_config()    { [[ "$1" =~ \.(json|ya?ml|toml|ini|cfg)$ ]] || [[ "$1" =~ (^|/)\.env ]] || [[ "$1" == .gitignore ]] || [[ "$1" == .editorconfig ]]; }
is_sensitive() {
  [[ "$1" =~ (^|/)(auth|authn|authz|session|crypto|secrets?|iam|rbac)/ ]] ||
  [[ "$1" =~ (^|/)rest/ ]] ||
  [[ "$1" =~ (^|/)api/ ]] ||
  [[ "$1" =~ (^|/)middleware/ ]] ||
  [[ "$1" =~ (^|/)migrations?/ ]] ||
  [[ "$1" =~ \.sql$ ]] ||
  [[ "$1" =~ (^|/)webhooks?/ ]]
}

DOCS_ONLY=true
TESTS_ONLY=true
CONFIG_ONLY=true
TOUCHES_SENSITIVE=false
SENSITIVE_PATHS=()

while IFS= read -r f; do
  [ -z "$f" ] && continue
  is_docs      "$f" || DOCS_ONLY=false
  is_tests     "$f" || TESTS_ONLY=false
  is_config    "$f" || CONFIG_ONLY=false
  if is_sensitive "$f"; then
    TOUCHES_SENSITIVE=true
    SENSITIVE_PATHS+=("$f")
  fi
done <<< "$FILES"

# ─── Preliminary tier ───
#
# Rules, in order:
#   - docs/config only  → XS (no code paths affected)
#   - tests only, small → S (limited blast radius)
#   - sensitive paths   → L (security surface)
#   - big diff          → L (>400 lines or >20 files — reviewer needs all the help)
#   - medium diff       → M
#   - else              → S

TIER="S"
if $DOCS_ONLY || $CONFIG_ONLY; then
  TIER="XS"
elif $TESTS_ONLY && [ "$LINES_CHANGED" -lt 200 ]; then
  TIER="S"
elif $TOUCHES_SENSITIVE; then
  TIER="L"
elif [ "$LINES_CHANGED" -gt 400 ] || [ "$FILES_CHANGED" -gt 20 ]; then
  TIER="L"
elif [ "$LINES_CHANGED" -gt 100 ] || [ "$FILES_CHANGED" -gt 5 ]; then
  TIER="M"
fi

# ─── Assemble output ───

SENSITIVE_JSON=$(printf '%s\n' "${SENSITIVE_PATHS[@]:-}" | jq -R -s 'split("\n") | map(select(. != ""))')

jq -n \
  --argjson files_changed "$FILES_CHANGED" \
  --argjson lines_changed "$LINES_CHANGED" \
  --argjson commits "$COMMITS" \
  --argjson docs_only "$DOCS_ONLY" \
  --argjson tests_only "$TESTS_ONLY" \
  --argjson config_only "$CONFIG_ONLY" \
  --argjson touches_sensitive "$TOUCHES_SENSITIVE" \
  --argjson sensitive_paths "$SENSITIVE_JSON" \
  --arg tier "$TIER" \
  '{
    stats: {files_changed:$files_changed, lines_changed:$lines_changed, commits:$commits},
    categories: {
      docs_only:$docs_only,
      tests_only:$tests_only,
      config_only:$config_only,
      touches_sensitive:$touches_sensitive
    },
    sensitive_paths: $sensitive_paths,
    preliminary_tier: $tier
  }'
