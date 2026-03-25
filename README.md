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

### pr-pipeline

PR lifecycle from branch to merge. Two skills that work together:

- **`/pr-pipeline:pr`** — Detects branch state, runs self-review (`/simplify` + parallel code review & test agents), publishes as draft PR, and hands off to babysit
- **`/pr-pipeline:babysit-pr`** — Monitors CI, fixes failures, rebases, resolves review threads (human vs bot), enables automerge, loops until merged

**Features:**
- Auto-detects branch/PR state and routes to the right flow
- Self-review with `/simplify` + 2 parallel agents (code review, test & CI)
- Quality gate before publishing
- Smart review thread resolution (human comments get individual attention, bot comments triaged in batch)
- Continuous monitoring via `/loop`

## License

MIT
