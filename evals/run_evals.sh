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
#   ./run_evals.sh                                    # full run, all cases
#   ./run_evals.sh --only 1,3,5                       # only specific case ids
#   ./run_evals.sh --parallel 10                      # run 10 cases concurrently
#   ./run_evals.sh --skill-dir <path>                 # override skill location
#   ./run_evals.sh --label v6.1-advisory-v2           # label the run
#   ./run_evals.sh --sut-model sonnet --judge-model opus

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
SUT_MODEL=""
JUDGE_MODEL=""
MAX_TURNS=8
PARALLEL=1

# ---- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill-dir)   SKILL_DIR="$2";   shift 2 ;;
    --evals-file)  EVALS_FILE="$2";  shift 2 ;;
    --only)        ONLY="$2";        shift 2 ;;
    --label)       LABEL="$2";       shift 2 ;;
    --model)       MODEL="$2";       shift 2 ;;
    --sut-model)   SUT_MODEL="$2";   shift 2 ;;
    --judge-model) JUDGE_MODEL="$2"; shift 2 ;;
    --parallel)    PARALLEL="$2";    shift 2 ;;
    -h|--help)
      sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --sut-model / --judge-model override --model individually; otherwise fall back to --model.
SUT_MODEL="${SUT_MODEL:-$MODEL}"
JUDGE_MODEL="${JUDGE_MODEL:-$MODEL}"

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
echo ">>> SUT model:   $SUT_MODEL"
echo ">>> Judge model: $JUDGE_MODEL"
echo ">>> Parallel:    $PARALLEL"
echo ">>> Output: $RUN_DIR"
echo ""

# ---- parallel semaphore (bash 3.x compatible via named pipe + fixed fd 9) ----
_SEM_PIPE=$(mktemp -u)
mkfifo "$_SEM_PIPE"
exec 9<>"$_SEM_PIPE"
rm -f "$_SEM_PIPE"
# Fill the pipe with PARALLEL tokens (each token = one byte)
for _i in $(seq 1 "$PARALLEL"); do printf . >&9; done

# ---- process_case function (runs in background subshell) ----
process_case() {
  local CID="$1"
  local i="$2"
  local RESULT_FILE="$RUN_DIR/case-${CID}.result.json"

  local CASE NAME PROMPT EXPECTED
  CASE=$(jq --argjson id "$CID" '.evals[] | select(.id == $id)' "$EVALS_FILE")
  NAME=$(echo "$CASE" | jq -r '.name')
  PROMPT=$(echo "$CASE" | jq -r '.prompt')
  EXPECTED=$(echo "$CASE" | jq -r '.expected_output')

  echo "[$i/$TOTAL] case $CID: $NAME"

  # ---- SUT pass ----
  local SUT_START SUT_END SUT_DUR SUT_JSON SUT_ERROR SUT_RESPONSE
  SUT_START=$(date +%s)
  SUT_JSON=$(cd "$WORK_DIR" && claude -p \
    --no-session-persistence \
    --model "$SUT_MODEL" \
    --append-system-prompt "$SKILL_CONTENT" \
    --add-dir "$SKILL_DIR" \
    --output-format json \
    --max-turns "$MAX_TURNS" \
    -- "$PROMPT" 2>"$RUN_DIR/case-${CID}-sut.stderr" || echo '{"is_error":true,"result":""}')
  SUT_END=$(date +%s)
  SUT_DUR=$((SUT_END - SUT_START))

  SUT_ERROR=$(echo "$SUT_JSON" | jq -r '.is_error // false')
  if [[ "$SUT_ERROR" == "true" ]] || ! echo "$SUT_JSON" | jq -e '.result' >/dev/null 2>&1; then
    # Detect policy violation vs generic error
    local POLICY_HIT=false
    if grep -qiE "usage.?policy|content.?policy|violat|prohibited|cannot assist|against our|I cannot help|I'm not able" \
        "$RUN_DIR/case-${CID}-sut.stderr" 2>/dev/null; then
      POLICY_HIT=true
    fi
    local SUT_TEXT
    SUT_TEXT=$(echo "$SUT_JSON" | jq -r '.result // .error.message // ""' 2>/dev/null || true)
    if echo "$SUT_TEXT" | grep -qiE "usage.?policy|cannot (help|assist) with|violat|not able to"; then
      POLICY_HIT=true
    fi

    if [[ "$POLICY_HIT" == "true" ]]; then
      echo "  ⏭  SKIPPED (policy) after ${SUT_DUR}s — case $CID"
      jq -nc --arg id "$CID" --arg name "$NAME" --arg dur "$SUT_DUR" \
        '{id:$id, name:$name, phase:"skipped", sut_duration_s:($dur|tonumber), pass:false, score:0}' \
        > "$RESULT_FILE"
    else
      echo "  !! SUT error after ${SUT_DUR}s — see case-${CID}-sut.stderr"
      jq -nc --arg id "$CID" --arg name "$NAME" --arg phase "sut_error" --arg dur "$SUT_DUR" \
        '{id:$id, name:$name, phase:$phase, sut_duration_s:($dur|tonumber), pass:false, score:0}' \
        > "$RESULT_FILE"
    fi
    return
  fi

  SUT_RESPONSE=$(echo "$SUT_JSON" | jq -r '.result')
  echo "$SUT_RESPONSE" > "$RUN_DIR/case-${CID}-response.txt"

  # ---- JUDGE pass ----
  local JUDGE_PROMPT JUDGE_JSON JUDGE_START JUDGE_END JUDGE_DUR JUDGE_RESULT JUDGE_RESULT_CLEAN
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
    --model "$JUDGE_MODEL" \
    --system-prompt "$JUDGE_SYSTEM" \
    --output-format json \
    --max-turns 2 \
    -- "$JUDGE_PROMPT" 2>"$RUN_DIR/case-${CID}-judge.stderr" || echo '{"is_error":true,"result":""}')
  JUDGE_END=$(date +%s)
  JUDGE_DUR=$((JUDGE_END - JUDGE_START))

  JUDGE_RESULT=$(echo "$JUDGE_JSON" | jq -r '.result // ""')
  # Strip any leading/trailing prose, keep just the JSON object.
  if echo "$JUDGE_RESULT" | jq -e 'has("pass")' >/dev/null 2>&1; then
    JUDGE_RESULT_CLEAN="$JUDGE_RESULT"
  else
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
    echo "  !! JUDGE returned non-JSON — recording as error (case $CID)"
    echo "$JUDGE_RESULT" > "$RUN_DIR/case-${CID}-judge-raw.txt"
    jq -nc --arg id "$CID" --arg name "$NAME" --arg phase "judge_parse_error" \
      --arg sut_dur "$SUT_DUR" --arg judge_dur "$JUDGE_DUR" \
      '{id:$id, name:$name, phase:$phase, sut_duration_s:($sut_dur|tonumber), judge_duration_s:($judge_dur|tonumber), pass:false, score:0}' \
      > "$RESULT_FILE"
    return
  fi

  local PASS SCORE REASON MISSING
  PASS=$(echo "$JUDGE_RESULT_CLEAN" | jq -r '.pass')
  SCORE=$(echo "$JUDGE_RESULT_CLEAN" | jq -r '.score')
  REASON=$(echo "$JUDGE_RESULT_CLEAN" | jq -r '.reasoning')
  MISSING=$(echo "$JUDGE_RESULT_CLEAN" | jq -c '.missing // []')

  if [[ "$PASS" == "true" ]]; then
    echo "  PASS  score=$SCORE  (sut ${SUT_DUR}s, judge ${JUDGE_DUR}s)  [case $CID]"
  else
    echo "  FAIL  score=$SCORE  $REASON  [case $CID]"
  fi

  jq -nc \
    --arg id "$CID" --arg name "$NAME" \
    --arg sut_dur "$SUT_DUR" --arg judge_dur "$JUDGE_DUR" \
    --argjson pass "$PASS" --argjson score "$SCORE" \
    --arg reason "$REASON" --argjson missing "$MISSING" \
    '{id:$id, name:$name, pass:$pass, score:$score, reasoning:$reason, missing:$missing, sut_duration_s:($sut_dur|tonumber), judge_duration_s:($judge_dur|tonumber)}' \
    > "$RESULT_FILE"
}

export -f process_case
export TOTAL EVALS_FILE WORK_DIR RUN_DIR SUT_MODEL JUDGE_MODEL SKILL_CONTENT SKILL_DIR MAX_TURNS JUDGE_SYSTEM

# ---- main loop with parallel semaphore ----
i=0
for CID in $CASE_IDS; do
  i=$((i+1))
  # Acquire semaphore token (blocks if all PARALLEL slots are busy)
  read -r -n1 -u 9
  (
    process_case "$CID" "$i"
    # Release semaphore token
    printf . >&9
  ) &
done

# Wait for all background jobs to finish
wait
exec 9>&-

# ---- merge per-case result files into results.jsonl ----
for f in "$RUN_DIR"/case-*.result.json; do
  [[ -f "$f" ]] && cat "$f" >> "$RESULTS_FILE"
done

# ---- compute summary stats from merged JSONL ----
PASS_COUNT=$(jq -s '[.[] | select(.pass == true)] | length' "$RESULTS_FILE")
FAIL_COUNT=$(jq -s '[.[] | select(.pass == false and (.phase == null or (.phase != "skipped" and .phase != "sut_error" and .phase != "judge_parse_error")))] | length' "$RESULTS_FILE")
ERROR_COUNT=$(jq -s '[.[] | select(.phase == "sut_error" or .phase == "judge_parse_error")] | length' "$RESULTS_FILE")
SKIP_COUNT=$(jq -s '[.[] | select(.phase == "skipped")] | length' "$RESULTS_FILE")
SCORE_SUM=$(jq -s '[.[] | select(.pass == true) | .score] | add // 0' "$RESULTS_FILE")
SCORED=$(jq -s '[.[] | select(.phase == null or (.phase != "skipped" and .phase != "sut_error" and .phase != "judge_parse_error"))] | length' "$RESULTS_FILE")
AVG=$(awk "BEGIN {if ($SCORED > 0) printf \"%.1f\", $SCORE_SUM/$SCORED; else print \"0.0\"}")

# ---- summary ----
{
  echo "# Eval Run Summary"
  echo ""
  echo "- **Run:** $TS${LABEL:+ ($LABEL)}"
  echo "- **Skill:** \`$SKILL_DIR/SKILL.md\`"
  echo "- **SUT model:** $SUT_MODEL"
  echo "- **Judge model:** $JUDGE_MODEL"
  echo "- **Parallel workers:** $PARALLEL"
  echo "- **Cases:** $TOTAL"
  echo "- **Pass:** $PASS_COUNT"
  echo "- **Fail:** $FAIL_COUNT"
  echo "- **Errors:** $ERROR_COUNT"
  echo "- **Skipped (policy):** $SKIP_COUNT"
  echo "- **Avg score (scored only):** $AVG / 10"
  echo ""
  echo "## Per-case results"
  echo ""
  echo "| ID | Name | Pass | Score | Notes |"
  echo "|----|------|:----:|:-----:|-------|"
  jq -r '. | "| \(.id) | \(.name) | \(if .pass then "✅ PASS" elif .phase == "skipped" then "⏭ SKIP" elif .phase then "⚠️ \(.phase)" else "❌ FAIL" end) | \(.score) | \(.reasoning // .phase // "") |"' "$RESULTS_FILE"
} > "$SUMMARY_FILE"

echo ""
echo ">>> DONE"
echo ">>> Pass: $PASS_COUNT / $TOTAL  Fail: $FAIL_COUNT  Errors: $ERROR_COUNT  Skipped: $SKIP_COUNT  Avg: $AVG"
echo ">>> Summary: $SUMMARY_FILE"
echo ">>> Raw:     $RESULTS_FILE"
