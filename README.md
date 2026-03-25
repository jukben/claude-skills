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
```

## Available Plugins

### adversarial-review

Adversarial reasoning and decision stress-testing. Pressure-test arguments, run pre-mortems, play devil's advocate, and generate structured Decision Records.

**Usage:** `/adversarial-review:adversarial-review` or triggered automatically when you mention decision records, ADRs, devil's advocate, pre-mortems, etc.

**Features:**
- Configurable intensity (Constructive / Moderate / Brutal)
- Quick mode (single pass) or Full Debate mode (multi-round)
- Generates structured Decision Records ready for team sharing

## License

MIT
