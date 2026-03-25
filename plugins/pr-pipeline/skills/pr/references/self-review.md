# Self-Review Flow

This reference is loaded by the `/pr` orchestrator when a self-review is needed.
You already have the state JSON from `detect_state.sh` — use it.

## Philosophy

- **Reviewer empathy first.** A PR should be a gift to the reviewer — small, clear, and obvious.
- **Signal over noise.** Only flag things that matter. Never nitpick formatting that a linter handles.
- **Fix, don't just report.** If you find something wrong, fix it. Only report things you can't auto-fix or need the author's judgment on.
- **Pragmatic, not pedantic.** Real bugs > style preferences. Missing edge cases > naming bikesheds.
- **Maintainability is not optional.** Every PR should leave the codebase easier to work with, not harder.

## Step 1: Get the Full Diff

The state JSON gives you stats at `diff` and file list at `diff.changed_files`. Now get the full diff:

```bash
git diff <diff_base>...HEAD
```

Also read `CLAUDE.md` if `workspace.has_claude_md` is true — it has project conventions and build commands.

## Step 2: Run /simplify First

Run `/simplify` **before** spawning any other agents. It reviews changed files for code reuse, quality, and efficiency, then applies fixes directly on the working branch.

Wait for `/simplify` to complete and commit its changes before proceeding. /simplify makes structural changes — extracting helpers, renaming, reorganizing — that would conflict with anything else running concurrently. Running it first means all subsequent agents review the cleaned-up code and their findings stay valid.

## Step 3: Spawn Parallel Review Agents

After `/simplify` is done, launch both agents simultaneously. Each agent gets the diff (re-diffed after `/simplify`'s changes), file list, and project config.

**Important:** Re-run the diff after `/simplify` so agents review the current state:

```bash
git diff <diff_base>...HEAD
```

**All agents are report-only — none of them modify files or commit.** This is deliberate: because no agent writes to the branch during this phase, the codebase is stable and there are no race conditions. The orchestrator applies all changes sequentially in Steps 4 and 5.

### Agent 1: Code Review

One agent, one pass over the diff — checking correctness, maintainability, and PR coherence together. This agent **reports findings and suggests fixes but does not apply them**. The orchestrator will apply fixes in Step 4.

```
Review this diff for correctness issues, maintainability, and PR coherence. Focus ONLY on changed lines.

Diff:
<full diff>

Project conventions:
<from CLAUDE.md if available>

### Correctness

Look for:
**Critical** — Logic errors, off-by-one, null/undefined access, race conditions, wrong variable used, hardcoded secrets, SQL injection, XSS, path traversal, unvalidated input, missing migrations, destructive operations without confirmation, public API signature changes, removed exports, changed return types.

**Important** — Unhandled promise rejections, empty catch blocks, missing null checks on external data, updated function signatures with missed call sites, renamed references that were missed, O(n²) where O(n) is simple, unnecessary re-renders, missing DB indexes for new queries.

### Maintainability

Evaluate — will the next engineer who touches this code thank us or curse us?

1. **Complexity** — Deeply nested conditionals (3+ levels)? Functions longer than ~50 lines? Complex boolean expressions that should be named helpers?
2. **Naming and readability** — Do names communicate intent? Would someone unfamiliar understand the code without reading the implementation?
3. **Separation of concerns** — Does each function/module do one thing? Business logic mixed with I/O or presentation?
4. **DRY without over-abstracting** — Duplicated logic to extract? Or premature abstraction making things harder to follow?

### PR Coherence

1. **Size** — Flag if > 400 lines changed. Suggest how to split.
2. **Coherence** — Does every change serve one purpose? Any drive-by changes?
3. **Missing pieces** — New env vars without docs? New deps duplicating existing ones? DB changes without migrations? UI changes without loading/error/empty states?

### What to skip
Style issues handled by formatters/linters, pre-existing problems, import ordering, whitespace, "I would have done it differently" preferences.

### Output
For each finding: file, line number, what's wrong, and a concrete fix. Classify as:
- **Critical** — Must fix before merge. Provide the exact code change.
- **Should fix** — Will cause problems if left. Provide the fix if straightforward, otherwise describe what to do.
- **Consider** — Author's judgment. Describe the tradeoff, don't provide a fix.

Do NOT modify any files. The orchestrator will apply your fixes after all agents complete.

If the diff is clean, say so — don't invent issues.
```

### Agent 2: Test & CI

This agent runs the project's checks and evaluates coverage, but **does not modify source files or commit**. It can execute tests, linters, and builds (these don't change source code), but it produces test recommendations rather than writing test files. The orchestrator will write tests in Step 5.

```
You are responsible for evaluating test coverage and CI health. Your workflow:

Diff:
<full diff>

Changed files:
<file list>

Project conventions:
<from CLAUDE.md if available — test framework, file naming, directory structure, build/test commands>

### Phase A: Run checks

Look at CLAUDE.md, package.json, Makefile, or pyproject.toml to figure out what to run.

Run whatever applies:
- Linter (eslint, ruff, clippy, etc.)
- Type checker (tsc --noEmit, mypy, etc.)
- Tests with coverage if available (jest --coverage, pytest --cov, go test -cover, etc.)
- Build (npm run build, cargo build, etc.)

Report pass/fail for each. Note any failures — the orchestrator will fix straightforward ones (unused imports, missing type annotations) when applying Agent 1's fixes. Flag anything needing judgment.

### Phase B: Evaluate coverage

From the coverage output (or by reading test files if no coverage tool is available):

1. Map every new or changed code path in the diff to whether it has a test.
2. New public functions/methods/endpoints — do they have at least happy-path tests?
3. Edge cases — empty inputs, nulls, boundary values, error states.
4. Changed behavior — do existing tests still match the new contract?

### Phase C: Recommend missing tests

For each untested path, produce a **test recommendation** with:
- **Target**: the file, function/method, and specific code path that needs coverage
- **Test file**: where the test should go (follow the project's existing patterns)
- **Test name**: descriptive name so a failure tells you what broke
- **What to assert**: the specific behavior, inputs, and expected outputs
- **Edge cases**: boundary values, error states, empty inputs to cover
- **Priority**: critical (error handling, security, data mutations) vs. nice-to-have

Do NOT write actual test files. The orchestrator will write tests from your recommendations after all agents complete.

### Output

Report:
- CI check results (pass/fail for each)
- CI failures that need fixing (for the orchestrator to address)
- Coverage assessment: which new paths are covered, which aren't
- Test recommendations: structured list per the format above
- Paths too complex to test without author guidance
```

## Step 4: Apply Code Review Fixes

After all agents complete, the orchestrator applies fixes from Agent 1's findings. This runs sequentially — no other agent is writing code.

1. **Review Agent 1's findings.** Apply Critical and Should-fix items where the suggested fix is concrete and confident.
2. **Cross-reference with Agent 2's CI failures.** If Agent 2 reported linter or type-check failures that overlap with Agent 1's findings, address them together.
3. **Commit each fix separately** with a clear message. Keep fixes in separate commits from the author's work.
4. **Flag** anything that needs the author's judgment — don't apply changes you're not confident about.

## Step 5: Write Tests from Recommendations

Next, write tests based on Agent 2's recommendations. This also runs sequentially, after fixes from Step 4 are committed.

1. **Re-assess recommendations against the current code.** Agent 1's fixes may have changed the code that Agent 2 analyzed. Skip recommendations that no longer apply, and adjust any that target modified code.
2. **Write tests** following the project's existing patterns (framework, file naming, assertion style). Keep tests focused — one assertion per behavior.
3. **Run the full test suite** including the new tests. Fix any failures.
4. **Commit** the new tests in a single commit: `test: add coverage for <area>`.

## Step 6: Quality Gate

After fixes and tests are applied, assess whether we're meeting the bar:

1. **Do all tests pass?** If not, that's a blocker.
2. **Are new code paths covered?** Critical paths (error handling, security, data mutations) need edge case coverage.
3. **Did coverage go down?** If the PR adds significant code but coverage dropped, flag it.
4. **Maintainability verdict** — Based on code review findings and fixes applied: is the code in a state where the next person can confidently modify it?

If coverage or maintainability doesn't meet the bar, add it to "Issues for your attention" with specific recommendations.

## Step 7: Produce Review Summary

Return this structure to the orchestrator:

```
### Review agents ran
- Simplify: [N improvements applied / no changes] (ran first, before other agents)
- Code Review: [N issues found / clean, N fixes recommended]
- Test & CI: [checks passing/failing, coverage assessment, N test recommendations]

### Quality gate
- Tests: [all passing / N failures]
- Coverage: [new code covered / gaps in <specific functions>]
- Maintainability: [good / N items to address]

### Changes made
- [/simplify improvements]
- [code review fixes applied by orchestrator]
- [tests written from recommendations]

### Issues for your attention
- [things needing author judgment — skip if none]

### Review readiness
- ✅ Ready for review
- ⚠️ Ready after addressing the above
- 🛑 Needs significant work (explain why)

### Suggested PR description
[Concise description a reviewer can scan in 30 seconds.
What changed, why, how to test, what to pay attention to.]
```

## Rules

1. **Never make a change you're not confident about.** When in doubt, flag it — don't fix it.
2. **If the diff is clean, say so.** Don't invent issues.
3. **Respect the project's conventions** over your own preferences.
4. **Be specific.** "This returns `undefined` when `items` is empty because of `.find()` on line 42" — not "this might have a bug."
5. **All agents are report-only.** No agent modifies files or commits. The orchestrator applies all changes sequentially after agents finish — first /simplify, then code review fixes, then tests.
6. **Tests are a deliverable, not a suggestion.** The orchestrator must write tests from Agent 2's recommendations — don't skip this step.
