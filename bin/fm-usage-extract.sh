#!/usr/bin/env bash
set -euo pipefail

SUMMARY_MODE=
DISPLAY_HELP_AND_EXIT=

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--summary) SUMMARY_MODE=1; shift ;;
        -h|--help) DISPLAY_HELP_AND_EXIT=1; shift ;;
        *) shift ;;
    esac
done

if [[ -n "${DISPLAY_HELP_AND_EXIT:-}" ]]; then
    cat << 'EOF'
fm-usage-extract.sh - Extract usage summary from opencode.db

USAGE:
    fm-usage-extract.sh [OPTIONS]

OPTIONS:
    -s, --summary    Output total usage across all provider+model combinations
    -h, --help       Show this help message

DESCRIPTION:
    Queries the opencode SQLite database to extract usage metrics.
    In summary mode, outputs aggregated totals across all provider+model combinations.
    Without summary flag, delegates to fm-usage-by-model.sh for full breakdown.

OUTPUT (summary mode):
    JSON object with aggregated token counts, turns, and estimated cost.

DATABASE:
    Default: ~/.local/share/opencode/opencode.db
    Override: OPENCODE_DB_PATH environment variable

EXAMPLES:
    fm-usage-extract.sh --summary
    fm-usage-extract.sh -s | jq '.estimated_cost_usd'
    fm-usage-extract.sh  # full breakdown via fm-usage-by-model.sh
EOF
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RATES_FILE="${SCRIPT_DIR}/../data/usage-rates.json"
DB_PATH="${OPENCODE_DB_PATH:-$HOME/.local/share/opencode/opencode.db}"

if [[ -z "${SUMMARY_MODE:-}" ]]; then
    exec "${SCRIPT_DIR}/fm-usage-by-model.sh" "$@"
fi

if [[ ! -f "${DB_PATH}" ]]; then
    echo '{"error": "database not found", "path": "'"${DB_PATH}"'"}' >&2
    exit 1
fi

if [[ ! -f "${RATES_FILE}" ]]; then
    echo '{"error": "rates file not found", "path": "'"${RATES_FILE}"'"}' >&2
    exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo '{"error": "sqlite3 not found"}' >&2
    exit 1
fi

sqlite3 -separator $'\t' "${DB_PATH}" "
SELECT 
    json_extract(data, '$.providerID') as provider,
    json_extract(data, '$.modelID') as model,
    SUM(CAST(json_extract(data, '$.tokens.input') AS INTEGER)) as input,
    SUM(CAST(json_extract(data, '$.tokens.output') AS INTEGER)) as output,
    SUM(CAST(CASE WHEN json_extract(data, '$.tokens.cache.read') IS NULL THEN 0 ELSE json_extract(data, '$.tokens.cache.read') END AS INTEGER)) as cache_read,
    SUM(CAST(CASE WHEN json_extract(data, '$.tokens.cache.write') IS NULL THEN 0 ELSE json_extract(data, '$.tokens.cache.write') END AS INTEGER)) as cache_write,
    COUNT(*) as turns
FROM message 
WHERE json_extract(data, '$.role') = 'assistant'
  AND json_extract(data, '$.modelID') IS NOT NULL
GROUP BY json_extract(data, '$.providerID'), json_extract(data, '$.modelID')
" | python3 -c "
import json
import sys
from datetime import datetime, timezone

rates_json = open('${RATES_FILE}').read()
rates = json.loads(rates_json)

total_input = 0
total_output = 0
total_cache_read = 0
total_cache_write = 0
total_turns = 0
total_cost = 0.0

def get_rate(provider, model, rate_type):
    provider_lower = provider.lower()
    model_lower = model.lower()
    
    if 'claude-opus' in model_lower:
        model_key = 'claude-opus-5' if '5' in model_lower else 'claude-opus-4'
    elif 'claude-sonnet' in model_lower:
        model_key = 'claude-sonnet-5' if '5' in model_lower else 'claude-sonnet-4'
    elif 'claude-haiku' in model_lower:
        model_key = 'claude-haiku-4'
    elif 'gpt-5' in model_lower:
        model_key = 'gpt-5'
    elif 'gpt-4' in model_lower:
        model_key = 'gpt-4o'
    elif 'grok' in model_lower:
        if '5' in model_lower:
            model_key = 'grok-5'
        elif 'build' in model_lower:
            model_key = 'grok-4'
        else:
            model_key = 'grok-4'
    elif 'deepseek' in model_lower:
        model_key = 'v3'
    elif 'nemotron' in model_lower:
        if 'super' in model_lower or '120b' in model_lower:
            model_key = 'nemotron-super'
        elif 'nano' in model_lower or '30b' in model_lower:
            model_key = 'nemotron-nano'
        else:
            model_key = 'nemotron'
    elif 'glm' in model_lower:
        model_key = 'glm-5' if '5' in model_lower else 'glm'
    elif 'big-pickle' in model_lower:
        model_key = 'big-pickle'
    else:
        return rates.get('fallback', {}).get(rate_type, 0.0)
    
    try:
        return rates['rates'][provider_lower][model_key].get(rate_type, 0.0)
    except (KeyError, TypeError):
        pass
    
    for prov_category in rates['rates'].values():
        if model_key in prov_category:
            return prov_category[model_key].get(rate_type, 0.0)
    
    return rates.get('fallback', {}).get(rate_type, 0.0)

for line in sys.stdin:
    parts = line.strip().split('\t')
    if len(parts) != 7:
        continue
    
    provider = parts[0] or 'unknown'
    model = parts[1]
    input_tokens = int(parts[2]) if parts[2] else 0
    output_tokens = int(parts[3]) if parts[3] else 0
    cache_read = int(parts[4]) if parts[4] else 0
    cache_write = int(parts[5]) if parts[5] else 0
    turns = int(parts[6]) if parts[6] else 0
    
    input_rate = get_rate(provider, model, 'input')
    output_rate = get_rate(provider, model, 'output')
    cache_read_rate = get_rate(provider, model, 'cache_read')
    cache_write_rate = get_rate(provider, model, 'cache_write')
    
    cost = 0.0
    cost += (input_tokens / 1_000_000) * input_rate
    cost += (output_tokens / 1_000_000) * output_rate
    cost += (cache_read / 1_000_000) * cache_read_rate
    cost += (cache_write / 1_000_000) * cache_write_rate
    
    total_input += input_tokens
    total_output += output_tokens
    total_cache_read += cache_read
    total_cache_write += cache_write
    total_turns += turns
    total_cost += cost

output = {
    'tokens': {
        'input': total_input,
        'output': total_output,
        'cache_read': total_cache_read,
        'cache_write': total_cache_write
    },
    'turns': total_turns,
    'estimated_cost_usd': round(total_cost, 6),
    'rate_basis': 'per-provider+model pricing (per-model breakdown requires fm-usage-by-model.sh)',
    'query_time': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'database': '${DB_PATH}'
}

print(json.dumps(output, indent=2))
"
