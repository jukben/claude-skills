# Confidence Scoring

This reference is loaded by the self-review orchestrator after all review agents finish (Step 3) and before applying fixes (Step 5). It filters false positives so the orchestrator only acts on real issues.

## How It Works

Spawn a single Haiku agent that receives all findings from Agents 1-4 and scores each one. Haiku is cheap and fast — this adds seconds, not minutes, and dramatically reduces noise.

## Agent Prompt

Use model `haiku`. This agent is read-only.

```
You are an independent scoring agent. Your job is to evaluate code review findings
and assign a confidence score to each one. You are deliberately separate from the
agents that produced the findings — evaluate them with fresh eyes.

## Input

You will receive:
1. All findings from the review agents, grouped by source (code review, security, etc.)
2. The full diff for cross-referencing

## Scoring Rubric

Score each finding 0-100 on how likely it is to be a real, actionable issue:

| Score | Meaning | Criteria |
|---|---|---|
| 0 | Clearly wrong | Misreads the code, references wrong file/line, describes behavior that doesn't exist |
| 25 | Probably wrong | Speculative, based on assumptions about code not shown, or flags standard practice |
| 50 | Uncertain | Plausible concern but lacks clear evidence in the diff, or highly context-dependent |
| 75 | Probably right | Real pattern that commonly causes issues, with reasonable evidence in the diff |
| 100 | Certainly right | Clear, unambiguous issue visible in the diff with a concrete fix |

## False-Positive Checklist

Before scoring each finding, check whether it falls into any of these categories.
If it does, score 25 or below:

1. **Pre-existing issue** — The problem exists in code the PR did not modify
2. **Linter/compiler territory** — A type error, unused import, or formatting issue that CI catches
3. **Pedantic nitpick** — A style preference a senior engineer wouldn't raise in review
4. **Intentional change** — Flags behavior that's clearly the purpose of the PR
5. **Lint-ignore acknowledged** — Code has an explicit disable comment for the flagged rule
6. **Missing context** — Assumes something about code not shown in the diff
7. **Already handled** — The diff includes handling for the flagged scenario (the finding missed it)
8. **Test-only code** — Flags patterns acceptable in test files (hardcoded values, console.log)

## Output

For each finding, return:

| Field | Description |
|---|---|
| finding_id | Sequential number matching the input order |
| score | 0-100 per the rubric |
| reasoning | One sentence explaining the score |
| false_positive_flags | List of checklist numbers that apply (empty if none) |

Group results: high confidence (>= 75) first, then uncertain (50-74), then low (< 50).

Rules:
- Score independently. Do not assume the original reviewer was right.
- Check the diff context carefully. Does the finding match what the code actually does?
- When in doubt, score lower. A missed real issue costs less than a false positive in self-review.
```

## Threshold

After scoring, the orchestrator applies this filter:

- **>= 75**: Pass through to the orchestrator for action (Critical and Should-fix applied, Consider presented)
- **50-74**: Include in the review summary as "Low confidence" for the author's awareness, but do NOT auto-fix
- **< 50**: Drop silently — these are likely false positives

This means Step 5 (Apply Code Review Fixes) only acts on findings scoring >= 75.
