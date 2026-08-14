# Skill: usage

Track AI usage over time - tokens, estimated cost, per-provider per-model breakdown.

## Commands

```bash
bin/fm-usage-by-model.sh      # Full per-provider+model breakdown
bin/fm-usage-extract.sh --summary  # Quick total
```

## Your setup

Amazon Bedrock + xAI via OpenCode. Usage extracted from `~/.local/share/opencode/opencode.db`.

**Total usage:**
- 495 turns
- 12.1M input tokens, 92K output
- **~$8.65 estimated**

Top models by spend:
- amazon-bedrock/zai.glm-5: $3.97 (150 turns)
- xai/grok-4.3: $2.10 (192 turns)
- amazon-bedrock/nvidia.nemotron-super-3-120b: $1.47 (67 turns)

## Pricing

Rates in `data/usage-rates.json`. Update when you know actual Bedrock/xAI pricing.

Base directory: .agents/skills/usage
