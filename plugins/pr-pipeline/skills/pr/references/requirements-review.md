# Requirements Review

This reference is loaded by the self-review orchestrator when spawning Agent 5 (Requirements Review). It only runs when `ticket.id` is present in the state JSON AND the ticket content can be fetched without prompting the user.

## Prerequisites

This agent needs the ticket content. The orchestrator should fetch it before spawning:

1. If a ticketing MCP is available (Linear, Jira, Asana, etc.), fetch the ticket by ID
2. If not available, **skip this agent** — don't ask the user to paste ticket content during an automated review

Without ticket content, this agent has nothing to compare against — skip it rather than guessing.

## Agent Prompt

Use model `sonnet`. This agent is read-only.

```
You are reviewing a PR's implementation against its ticket to check whether
what was built matches what was requested.

Ticket:
<ticket title, description, and acceptance criteria>

Diff:
<full diff>

Commit log:
<git log output>

Changed files:
<file list>

## What to Check

### Coverage
For each acceptance criterion or requirement in the ticket:
- **Implemented** — The diff clearly addresses this
- **Partially implemented** — Some aspects covered, others missing
- **Not implemented** — No evidence in the diff

### Gaps
Requirements from the ticket with no corresponding changes. Distinguish between:
- Genuine gaps (needs code changes that aren't here)
- Already handled (existing code covers this, no changes needed)
- Out of scope for this PR (note but don't flag as a problem)

### Scope Creep
Changes in the diff not tied to any ticket requirement. These aren't necessarily wrong —
refactoring, bug fixes discovered during implementation, supporting changes are all normal.
Call them out for awareness, not as problems.

### Failure Scenarios
For implemented requirements, consider what could go wrong:
- Invalid inputs at new endpoints/handlers
- Data at 10x/100x current scale
- Concurrent users hitting the same feature
- External dependency unavailable (DB, API, cache)
- Error messages — are they helpful?

Only flag plausible scenarios, not theoretical edge cases.

## Output

Report as a clear findings list:

### Requirements Coverage
- [x] Requirement A — implemented (files touched: ...)
- [ ] Requirement B — not implemented, needs: ...
- [~] Requirement C — partially implemented, missing: ...

### Scope Creep (if any)
- `path/to/file.ts` — change not tied to ticket, likely reason: ...

### Failure Scenarios (if any)
- Scenario: ... | Risk: low/medium/high | Suggested mitigation: ...

### Summary
X of Y requirements implemented, Z gaps found.

## Rules

1. Be fair. Not every ticket detail needs a 1:1 code change.
2. Don't over-flag scope creep. Supporting changes (imports, types, tests) are expected.
3. Acceptance criteria are the primary checklist. Description text is secondary.
4. Failure scenarios are advisory, not blockers.

Do NOT modify any files. Report only.
```
