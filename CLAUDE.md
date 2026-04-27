# claude-skills

Plugin marketplace. Source of truth for what's published is `.claude-plugin/marketplace.json`.

## README hygiene

- Keep `README.md` **concise**: install steps + one short blurb per plugin. No deep docs — those live in each plugin's `SKILL.md` and `references/`.
- When bumping a plugin's version in `marketplace.json`, update the matching section in `README.md` in the same change. Version bump and README must ship together.
- If a feature in the README no longer matches the plugin's current behavior, fix the README rather than restoring the old behavior.
