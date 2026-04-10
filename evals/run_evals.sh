#!/usr/bin/env bash
# run_evals.sh — execute the qingsheng eval suite using `claude -p` headless mode.
#
# Why headless `claude -p`:
#   - Uses your existing Claude Code subscription (no Anthropic API key needed)
#   - Each eval runs in an isolated subprocess with --no-session-persistence
#   - --append-system-prompt injects the SKILL.md content directly
#   - --add-dir lets the SUT load reference files on demand
#
# Two-pass design:
#   Pass 1 (SUT)   — model + skill answers each eval prompt
#   Pass 2 (JUDGE) — fresh model session scores response vs expected_output
#
# Output: results/<timestamp>/results.jsonl + results/<timestamp>/summary.md
#
# Usage:
#   ./run_evals.sh                       # full run, all 18 cases
#   ./run_evals.sh --only 1,3,5          # only specific case ids
#   ./run_evals.sh --skill-dir <path>    # override skill location
#   ./run_evals.sh --label baseline-v3   # label the run

set -euo pipefail

# ---- defaults (auto-resolved relative to this script) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$REPO_ROOT/skill"
EVALS_FILE="$SCRIPT_DIR/evals.json"
OUT_ROOT="$SCRIPT_DIR/results"
ONLY=""
LABEL=""
MODEL="sonnet"
MAX_TURNS=8

# ---- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill-dir) SKILL_DIR="$2"; shift 2 ;;
    --evals-file) EVALS_FILE="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---- preflight ----
[[ -f "$SKILL_DIR/SKILL.md" ]] || { echo "SKILL.md not found at $SKILL_DIR" >&2; exit 1; }
[[ -f "$EVALS_FILE" ]] || { echo "evals file not found at $EVALS_FILE" >&2; exit 1; }
command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
RUN_DIR="$OUT_ROOT/$TS${LABEL:+-$LABEL}"
mkdir -p "$RUN_DIR"

RESULTS_FILE="$RUN_DIR/results.jsonl"
SUMMARY_FILE="$RUN_DIR/summary.md"

# Run from a clean cwd so CLAUDE.md auto-discovery doesn't pollute the skill
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

SKILL_CONTENT=$(cat "$SKILL_DIR/SKILL.md")

JUDGE_SYSTEM='You are an evaluator for a Chinese-language dating coach skill called "qingsheng". Your job: read a test prompt, the expected output criteria, and the actual model response, then decide if the response satisfies the criteria.

Be strict but fair. Do NOT require exact wording — match on intent and content.

Output ONLY valid JSON with this exact shape, no markdown, no prose:
{"pass": true|false, "score": 0-10, "missing": ["criterion 1 not met", ...], "reasoning": "1-2 sentence explanation"}

Scoring guide:
- 10: response covers all criteria with high quality
- 7-9: covers all criteria but quality is uneven
- 4-6: covers most but missing 1-2 criteria
- 0-3: missing core criteria or wrong direction
- pass = true if score >= 7'

# ---- get list of cases ----
if [[ -n "$ONLY" ]]; then
  CASE_IDS=$(echo "$ONLY" | tr ',' ' ')
else
  CASE_IDS=$(jq -r '.evals[].id' "$EVALS_FILE" | tr '\n' ' ')
fi

TOTAL=$(echo "$CASE_IDS" | wc -w | tr -d ' ')
echo ">>> Running $TOTAL eval cases against $SKILL_DIR/SKILL.md"
echo ">>> Output: $RUN_DIR"
echo ""

PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0
SCORE_SUM=0

i=0
for CID in $CASE_IDS; do
  i=$((i+1))
  CASE=$(jq --argjson id "$CID" '.evals[] | select(.id == $id)' "$EVALS_FILE")
  NAME=$(echo "$CASE" | jq -r '.name')
  PROMPT=$(echo "$CASE" | jq -r '.prompt')
  EXPECTED=$(echo "$CASE" | jq -r '.expected_output')

  echo "[$i/$TOTAL] case $CID: $NAME"

  # ---- SUT pass ----
  SUT_START=$(date +%s)
  SUT_JSON=$(cd "$WORK_DIR" && claude -p \
    --no-session-persistence \
    --model "$MODEL" \
    --append-system-prompt "$SKILL_CONTENT" \
    --add-dir "$SKILL_DIR" \
    --output-format json \
    --max-turns "$MAX_TURNS" \
    -- "$PROMPT" 2>"$RUN_DIR/case-${CID}-sut.stderr" || echo '{"is_error":true,"result":""}')
  SUT_END=$(date +%s)
  SUT_DUR=$((SUT_END - SUT_START))

  SUT_ERROR=$(echo "$SUT_JSON" | jq -r '.is_error // false')
  if [[ "$SUT_ERROR" == "true" ]] || ! echo "$SUT_JSON" | jq -e '.result' >/dev/null 2>&1; then
    echo "  !! SUT error after ${SUT_DUR}s — see case-${CID}-sut.stderr"
    ERROR_COUNT=$((ERROR_COUNT + 1))
    jq -nc \
      --arg id "$CID" --arg name "$NAME" \
      --arg phase "sut_error" --arg dur "$SUT_DUR" \
      '{id:$id, name:$name, phase:$phase, sut_duration_s:($dur|tonumber), pass:false, score:0}' \
      >> "$RESULTS_FILE"
    continue
  fi

  SUT_RESPONSE=$(echo "$SUT_JSON" | jq -r '.result')
  echo "$SUT_RESPONSE" > "$RUN_DIR/case-${CID}-response.txt"

  # ---- JUDGE pass ----
  JUDGE_INPUT=$(jq -nc \
    --arg prompt "$PROMPT" \
    --arg expected "$EXPECTED" \
    --arg response "$SUT_RESPONSE" \
    '{prompt:$prompt, expected_output:$expected, actual_response:$response}')

  JUDGE_PROMPT="Evaluate this test case. Return JSON only.

PROMPT GIVEN TO MODEL:
$PROMPT

EXPECTED OUTPUT CRITERIA:
$EXPECTED

ACTUAL MODEL RESPONSE:
$SUT_RESPONSE

Score the actual response against the expected criteria. Return ONLY the JSON object."

  JUDGE_START=$(date +%s)
  JUDGE_JSON=$(cd "$WORK_DIR" && claude -p \
    --no-session-persistence \
    --model "$MODEL" \
    --system-prompt "$JUDGE_SYSTEM" \
    --output-format json \
    --max-turns 2 \
    -- "$JUDGE_PROMPT" 2>"$RUN_DIR/case-${CID}-judge.stderr" || echo '{"is_error":true,"result":""}')
  JUDGE_END=$(date +%s)
  JUDGE_DUR=$((JUDGE_END - JUDGE_START))

  JUDGE_RESULT=$(echo "$JUDGE_JSON" | jq -r '.result // ""')
  # Strip any leading/trailing prose, keep just the JSON object.
  # Try the raw value first; if it's not valid JSON, attempt to extract a {...} block.
  if echo "$JUDGE_RESULT" | jq -e 'has("pass")' >/dev/null 2>&1; then
    JUDGE_RESULT_CLEAN="$JUDGE_RESULT"
  else
    # Use python to find the first balanced {...} block
    JUDGE_RESULT_CLEAN=$(python3 -c "
import sys, json, re
s = sys.stdin.read()
m = re.search(r'\{.*\}', s, re.DOTALL)
if m:
    try:
        json.loads(m.group(0))
        print(m.group(0))
    except Exception:
        pass
" <<< "$JUDGE_RESULT")
  fi

  if ! echo "$JUDGE_RESULT_CLEAN" | jq -e 'has("pass")' >/dev/null 2>&1; then
    echo "  !! JUDGE returned non-JSON — recording as error"
    echo "$JUDGE_RESULT" > "$RUN_DIR/case-${CID}-judge-raw.txt"
    ERROR_COUNT=$((ERROR_COUNT + 1))
    jq -nc \
      --arg id "$CID" --arg name "$NAME" --arg phase "judge_parse_error" \
      --arg sut_dur "$SUT_DUR" --arg judge_dur "$JUDGE_DUR" \
      '{id:$id, name:$name, phase:$phase, sut_duration_s:($sut_dur|tonumber), judge_duration_s:($judge_dur|tonumber), pass:false, score:0}' \
      >> "$RESULTS_FILE"
    continue
  fi

  PASS=$(echo "$JUDGE_RESULT_CLEAN" | jq -r '.pass')
  SCORE=$(echo "$JUDGE_RESULT_CLEAN" | jq -r '.score')
  REASON=$(echo "$JUDGE_RESULT_CLEAN" | jq -r '.reasoning')
  MISSING=$(echo "$JUDGE_RESULT_CLEAN" | jq -c '.missing // []')

  if [[ "$PASS" == "true" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  PASS  score=$SCORE  (sut ${SUT_DUR}s, judge ${JUDGE_DUR}s)"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "  FAIL  score=$SCORE  $REASON"
  fi
  SCORE_SUM=$((SCORE_SUM + SCORE))

  jq -nc \
    --arg id "$CID" --arg name "$NAME" \
    --arg sut_dur "$SUT_DUR" --arg judge_dur "$JUDGE_DUR" \
    --argjson pass "$PASS" --argjson score "$SCORE" \
    --arg reason "$REASON" --argjson missing "$MISSING" \
    '{id:$id, name:$name, pass:$pass, score:$score, reasoning:$reason, missing:$missing, sut_duration_s:($sut_dur|tonumber), judge_duration_s:($judge_dur|tonumber)}' \
    >> "$RESULTS_FILE"
done

# ---- summary ----
AVG=$(awk "BEGIN {if ($TOTAL > 0) printf \"%.1f\", $SCORE_SUM/$TOTAL; else print \"0.0\"}")

{
  echo "# Eval Run Summary"
  echo ""
  echo "- **Run:** $TS${LABEL:+ ($LABEL)}"
  echo "- **Skill:** \`$SKILL_DIR/SKILL.md\`"
  echo "- **Model:** $MODEL"
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
echo ">>> DONE"
echo ">>> Pass: $PASS_COUNT / $TOTAL  Fail: $FAIL_COUNT  Errors: $ERROR_COUNT  Avg: $AVG"
echo ">>> Summary: $SUMMARY_FILE"
echo ">>> Raw:     $RESULTS_FILE"
