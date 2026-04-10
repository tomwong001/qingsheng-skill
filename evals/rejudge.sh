#!/usr/bin/env bash
# rejudge.sh — re-parse any case-N-judge-raw.txt files in a results dir
# and rebuild results.jsonl + summary.md. Used to recover from old runs
# where the v3 buggy parser flagged valid-but-failing judgments as errors.
#
# Usage: ./rejudge.sh /path/to/results/<run-dir>

set -euo pipefail

RUN_DIR="${1:-}"
[[ -d "$RUN_DIR" ]] || { echo "usage: $0 <run-dir>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS_FILE="${EVALS_FILE:-$SCRIPT_DIR/evals.json}"
RESULTS_FILE="$RUN_DIR/results.jsonl"
SUMMARY_FILE="$RUN_DIR/summary.md"
NEW_RESULTS=$(mktemp)

PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0
SCORE_SUM=0
TOTAL=0

# For each case in the original results.jsonl, see if there's a raw judge file we can re-parse
while IFS= read -r line; do
  TOTAL=$((TOTAL + 1))
  CID=$(echo "$line" | jq -r '.id')
  PHASE=$(echo "$line" | jq -r '.phase // ""')
  RAW_FILE="$RUN_DIR/case-${CID}-judge-raw.txt"

  if [[ "$PHASE" == "judge_parse_error" && -f "$RAW_FILE" ]]; then
    # Try to re-extract the JSON
    JUDGE_CLEAN=$(python3 -c "
import sys, json, re
s = sys.stdin.read()
m = re.search(r'\{.*\}', s, re.DOTALL)
if m:
    try:
        json.loads(m.group(0))
        print(m.group(0))
    except Exception:
        pass
" < "$RAW_FILE")

    if echo "$JUDGE_CLEAN" | jq -e 'has("pass")' >/dev/null 2>&1; then
      NAME=$(jq -r --argjson id "$CID" '.evals[] | select(.id == $id) | .name' "$EVALS_FILE")
      PASS=$(echo "$JUDGE_CLEAN" | jq -r '.pass')
      SCORE=$(echo "$JUDGE_CLEAN" | jq -r '.score')
      REASON=$(echo "$JUDGE_CLEAN" | jq -r '.reasoning')
      MISSING=$(echo "$JUDGE_CLEAN" | jq -c '.missing // []')

      jq -nc \
        --arg id "$CID" --arg name "$NAME" \
        --argjson pass "$PASS" --argjson score "$SCORE" \
        --arg reason "$REASON" --argjson missing "$MISSING" \
        --arg note "rejudged" \
        '{id:$id, name:$name, pass:$pass, score:$score, reasoning:$reason, missing:$missing, note:$note}' \
        >> "$NEW_RESULTS"

      if [[ "$PASS" == "true" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "  case $CID: PASS  score=$SCORE  (rejudged)"
      else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  case $CID: FAIL  score=$SCORE  (rejudged)"
      fi
      SCORE_SUM=$((SCORE_SUM + SCORE))
      continue
    fi
  fi

  # Otherwise keep original line
  echo "$line" >> "$NEW_RESULTS"
  PASS=$(echo "$line" | jq -r '.pass')
  SCORE=$(echo "$line" | jq -r '.score')
  if [[ "$PHASE" == "" || "$PHASE" == "null" ]]; then
    if [[ "$PASS" == "true" ]]; then PASS_COUNT=$((PASS_COUNT + 1)); else FAIL_COUNT=$((FAIL_COUNT + 1)); fi
    SCORE_SUM=$((SCORE_SUM + SCORE))
  else
    ERROR_COUNT=$((ERROR_COUNT + 1))
  fi
done < "$RESULTS_FILE"

mv "$NEW_RESULTS" "$RESULTS_FILE"

AVG=$(awk "BEGIN {if ($TOTAL > 0) printf \"%.1f\", $SCORE_SUM/$TOTAL; else print \"0.0\"}")

{
  echo "# Eval Run Summary (rejudged)"
  echo ""
  echo "- **Run dir:** \`$RUN_DIR\`"
  echo "- **Cases:** $TOTAL"
  echo "- **Pass:** $PASS_COUNT"
  echo "- **Fail:** $FAIL_COUNT"
  echo "- **Errors:** $ERROR_COUNT"
  echo "- **Avg score:** $AVG / 10"
  echo ""
  echo "## Per-case results"
  echo ""
  echo "| ID | Name | Pass | Score | Notes |"
  echo "|----|------|:----:|:-----:|-------|"
  jq -r '. | "| \(.id) | \(.name) | \(if .pass then "PASS" else "FAIL" end) | \(.score) | \(.reasoning // .phase // "") |"' "$RESULTS_FILE"
} > "$SUMMARY_FILE"

echo ""
echo ">>> Pass: $PASS_COUNT  Fail: $FAIL_COUNT  Errors: $ERROR_COUNT  Avg: $AVG"
echo ">>> Updated: $SUMMARY_FILE"
