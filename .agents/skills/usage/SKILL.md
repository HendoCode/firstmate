# Skill: usage

Track AI usage over time - tokens, estimated cost, per-provider per-model breakdown.

## Commands

```bash
bin/fm-usage-by-model.sh      # Full per-provider+model breakdown
bin/fm-usage-extract.sh --summary  # Quick total
```

## Your setup

Sources are local harness stores, aggregated by `bin/fm-usage-by-model.sh`:
- OpenCode SQLite (`~/.local/share/opencode/opencode.db`)
- Claude Code JSONL (`~/.claude/projects/**/*.jsonl`)
- Pi session JSONL (`~/.pi/agent/sessions/**/*.jsonl`)

On this box only Pi sessions exist today; the laptop-era OpenCode and Claude Code stores are gone, so those sources contribute zero. Run the commands above for live numbers instead of trusting any snapshot here.

## Pricing

Rates in `data/usage-rates.json`. Update when you know actual provider pricing for models not covered by Pi's own computed cost.

Base directory: .agents/skills/usage
