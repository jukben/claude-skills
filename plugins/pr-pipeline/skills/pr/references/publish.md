# Publish Flow

This reference is loaded by the `/pr` orchestrator when it's time to create the PR.
You already have the state JSON from `detect_state.sh` and (optionally) the self-review summary.

## Step 1: Push the Branch

Ensure the branch is pushed to the remote:

```bash
git push -u origin HEAD
```

## Step 2: Create Draft PR

Analyze all commits since the diff base and the full diff to write the PR.

If the self-review produced a suggested PR description, use it as the basis for the summary and test plan.

```bash
gh pr create --draft --title "<concise title>" --body "$(cat <<'EOF'
## Summary
<1-3 bullet points describing what changed and why>

## Test plan
<bulleted checklist of how to verify the changes>
EOF
)"
```

### Title format

Keep it simple and descriptive. Under 72 characters. Use lowercase after the first word unless it's a proper noun.

**Good:**
- `Add rate limiting to auth endpoints`
- `Fix asset field tab counts on edit page`
- `Refactor webhook handler to support retries`

**Bad:**
- `Update code` — too vague
- `Fix bug in the webhook handler that was causing issues with retry logic and timeout handling` — too long

### Other rules
- Always `--draft`
- Title under 72 characters
- If the changes address multiple concerns, pick the most important one for the title — details go in the body
- Body uses the template above
- If self-review produced a suggested PR description, use it for the body's summary and test plan
- Return the PR URL when done
