# claude-skills

A Claude Code plugin marketplace with curated skills by [jukben](https://github.com/jukben).

## Installation

Add the marketplace to Claude Code:

```
/plugin marketplace add jukben/claude-skills
```

Then install individual plugins:

```
/plugin install adversarial-review@jukben-skills
/plugin install pr-pipeline@jukben-skills
```

## Available Plugins

### adversarial-review

Adversarial reasoning and decision stress-testing. Pressure-test arguments, run pre-mortems, play devil's advocate, and generate structured Decision Records.

**Usage:** `/adversarial-review:adversarial-review` or triggered automatically when you mention decision records, ADRs, devil's advocate, pre-mortems, etc.

**Features:**
- Configurable intensity (Constructive / Moderate / Brutal)
- Quick mode (single pass) or Full Debate mode (multi-round)
- Generates structured Decision Records ready for team sharing

### pr-pipeline (v2.1.0)

PR lifecycle from branch to merge. Two skills that work together:

- **`/pr-pipeline:pr`** — Detects branch state, classifies changes into XS/S/M/L tiers, runs tier-aware parallel self-review, publishes as draft PR, and hands off to babysit
- **`/pr-pipeline:babysit-pr`** — Monitors CI, fixes failures, rebases, resolves review threads (human vs bot), enables automerge, watches until merged

**Features:**
- Deterministic XS/S/M/L tier classifier with Haiku sanity-check
- Parallel agents scaled to tier: code review, PR shape, test/CI, security (L only), requirements (when ticket detected)
- Haiku confidence scoring filters false positives before they reach you
- Breaking-API gate before publish; optional ticket-prefixed title for Linear/Jira-style workflows
- Smart review thread resolution (human comments individual, bot comments batched)
- Persistent state-diffing monitor (`Monitor` tool, 30s poll) emits events only when state actually changes — quiet until something happens; falls back to `/loop` when `Monitor` isn't available

## License

MIT
