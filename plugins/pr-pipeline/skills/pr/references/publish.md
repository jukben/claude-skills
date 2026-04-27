# Publish Flow

This reference is loaded by the `/pr` orchestrator when it's time to create the PR.
You already have the state JSON from `detect_state.sh` and (optionally) the self-review summary.

## Step 1: Note Ticket (if any)

Check `ticket.id` from the state JSON. The detector matches Linear/Jira-style ticket
patterns (`ABC-123`) in the branch name or recent commits.

- If a ticket was detected → use it to enrich the PR title and description.
- If not → proceed without one. Don't prompt the user for a ticket unless the project
  documents a ticket-prefix requirement (typically in `CLAUDE.md`).

## Step 2: Branch Naming (if project requires it)

Check `ticket.branch_has_ticket` from the state JSON.

If the project's CI requires the ticket in the branch name (look in `CLAUDE.md` or the
project's contributing docs for an explicit branch-naming rule) and the current branch
doesn't include it, offer to rename:

1. Propose: `<ticket-lowercase>-<descriptive-slug>`
2. Rename locally: `git branch -m <new-name>`
3. Push: `git push -u origin <new-name>`
4. Delete the old remote branch: `git push origin --delete <old-name>`

If the project doesn't enforce branch naming, skip this step — just push the existing branch.

## Step 3: Push the Branch

```bash
git push -u origin HEAD
```

## Step 4: Create Draft PR

Analyze all commits since the diff base and the full diff to write the PR.

If the self-review produced a suggested PR description, use it as the basis for the summary and test plan.

```bash
gh pr create --draft --title "<title>" --body "$(cat <<'EOF'
## Summary
<1-3 bullet points describing what changed and why>

## Test plan
<bulleted checklist of how to verify the changes>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### Title format

If a ticket was detected, prefix the title with it: `TICKET: concise description`.
If no ticket was detected, use a plain descriptive title.

Don't use conventional commit prefixes (`fix:`, `feat:`, `chore:`, etc.) unless the
project's commit history clearly uses them — match the project's existing style.

**With ticket:**
- `ABC-265: Land edit wizard on first empty step`
- `JBN-42: Add rate limiting to auth endpoints`

**Without ticket:**
- `Add rate limiting to auth endpoints`
- `Fix asset field tab counts on edit page`
- `Refactor webhook handler to support retries`

**Bad:**
- `Update code` — too vague
- `[ABC-265] fix: update wizard` — don't mix bracket-prefix and conventional commit format
- `ABC-265: fix: update wizard` — don't double up the prefix
- `Update wizard behavior and fix tab counts in asset fields for the alternate flow` — too long

### Other rules
- Always `--draft`
- Title under 70 characters
- If the changes address multiple concerns, pick the most important one for the title — details go in the body
- Body uses the template above
- If self-review produced a suggested PR description, use it for the body's summary and test plan
- Return the PR URL when done
