#!/usr/bin/env python3
"""Convert candidates.jsonl → eval JSON file for run_evals.sh.

Eval design rationale:
  - PROMPT:   full context (situation + stage + her message) → ask skill for a reply
  - EXPECTED: judge rubric with why_good as the PRIMARY evaluation axis.
              The judge scores whether the skill's response achieves the same
              strategic EFFECT as described in why_good — not whether it matches
              the reference answer verbatim.

Usage:
  python3 gen_evals_from_candidates.py
  python3 gen_evals_from_candidates.py --input /path/to/candidates.jsonl
  python3 gen_evals_from_candidates.py --max 50   # sample max N per stage
"""

import argparse
import json
import sys
from pathlib import Path
from collections import defaultdict

SCRIPT_DIR = Path(__file__).parent
DEFAULT_INPUT = Path.home() / "qingsheng-corpus" / "distilled" / "eval-cases" / "candidates.jsonl"
DEFAULT_OUTPUT = SCRIPT_DIR.parent / "evals_candidates_v1.json"

STAGE_LABEL = {
    "open":         "阶段1 开场破冰",
    "attract":      "阶段2 建立吸引",
    "build":        "阶段3 建立好感",
    "bridge":       "阶段4 邀约铺垫",
    "escalate":     "阶段5 升温推进",
    "date":         "阶段5 约会实战",
    "relationship": "阶段6 确立关系",
    "recovery":     "阶段7 关系修复",
}

BAD_STAGES = {"unknown", "transition", "λήψη", ""}


def is_valid(c: dict) -> bool:
    if c.get("stage", "") in BAD_STAGES:
        return False
    her_msg  = (c.get("her_message")  or "").strip()
    good_resp = (c.get("good_response") or "").strip()
    context  = (c.get("context")      or "").strip()
    why_good = (c.get("why_good")     or "").strip()
    if not her_msg or not good_resp or not context or not why_good:
        return False
    # Filter corrupted entries
    for field in [her_msg, good_resp, context, why_good]:
        if "127.0.0.1" in field or "oopss://" in field or len(field) > 600:
            return False
    return True


def build_prompt(c: dict) -> str:
    stage_label = STAGE_LABEL.get(c["stage"], c["stage"])
    her_msg = c['her_message']
    return (
        f"【情境】{c['context']}\n"
        f"【当前阶段】{stage_label}\n"
        f"\n"
        f"她刚发来：\u201c{her_msg}\u201d\n"
        f"\n"
        f"帮我分析这条消息，给出最好的回复话术。"
    )


def build_expected(c: dict) -> str:
    stage_label = STAGE_LABEL.get(c["stage"], c["stage"])
    also = c.get("also_considered") or []
    also_lines = "\n".join(f'  - "{a}"' for a in also) if also else "  （无）"

    her_msg = c['her_message']
    good_resp = c['good_response']
    why_good = c['why_good']
    return (
        f"## 评分标准\n"
        f"\n"
        f"### 情境背景（judge 评分时参考）\n"
        f"- 情境：{c['context']}\n"
        f"- 阶段：{stage_label}\n"
        f"- 她说：\u201c{her_msg}\u201d\n"
        f"\n"
        f"### 核心策略目标（最重要的评分维度）\n"
        f"{why_good}\n"
        f"\n"
        f"### 参考优秀答案\n"
        f"\u201c{good_resp}\u201d\n"
        f"\n"
        f"### 不好的选项（避免出现类似内容）\n"
        f"{also_lines}\n"
        f"\n"
        f"### 评分说明（score \u2265 7 = pass）\n"
        f"**首要评分轴：话术是否达到「核心策略目标」的效果。** 不要求与参考答案相同——\n"
        f"方向对、效果到位即可得高分。\n"
        f"\n"
        f"扣分项：\n"
        f"- 只给策略建议，没有具体可发的话术 (-3)\n"
        f"- 话术方向与核心策略目标相悖 (-4)\n"
        f"- 与不好的选项相似（低价值/讨好/自降） (-3)\n"
        f"- 话术太长或解释过多，实际无法直接发出 (-2)"
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input",  default=str(DEFAULT_INPUT))
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    parser.add_argument("--max",    type=int, default=0,
                        help="max cases per stage (0 = no limit)")
    args = parser.parse_args()

    with open(args.input) as f:
        raw = [json.loads(l) for l in f if l.strip()]

    valid = [c for c in raw if is_valid(c)]
    print(f"Valid candidates: {len(valid)} / {len(raw)}", file=sys.stderr)

    if args.max > 0:
        by_stage = defaultdict(list)
        for c in valid:
            by_stage[c["stage"]].append(c)
        valid = []
        for stage, cases in sorted(by_stage.items()):
            valid.extend(cases[:args.max])
        print(f"After sampling {args.max}/stage: {len(valid)}", file=sys.stderr)

    evals = []
    for i, c in enumerate(valid):
        cid = 2001 + i
        stage = c.get("stage", "unknown")
        name = f"candidate-{stage}-{cid}"
        evals.append({
            "id": cid,
            "name": name,
            "prompt": build_prompt(c),
            "expected_output": build_expected(c),
        })

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({"evals": evals}, ensure_ascii=False, indent=2))
    print(f"Wrote {len(evals)} cases → {out_path}", file=sys.stderr)

    by_stage = defaultdict(int)
    for c in valid:
        by_stage[c.get("stage", "unknown")] += 1
    for stage, count in sorted(by_stage.items()):
        print(f"  {stage}: {count}", file=sys.stderr)


if __name__ == "__main__":
    main()
