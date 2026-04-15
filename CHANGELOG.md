# Changelog

## v0.9.0 — 2026-04-15 (stage judgment fix + autopilot + self-update)

### 1. Stage judgment accuracy (advisory mode)

Added a "强信号强制升级规则" table in SKILL.md mapping specific observable signals to minimum stage numbers. Fixes systematic under-staging where the model defaulted to 阶段3 on any ambiguous signal:

- 女方用亲昵称呼 → 最低阶段4
- 深夜主动联系 / 持续高频回复 → 最低阶段5
- 对话出现性话题且女方参与配合 → 最低阶段6
- etc.

### 2. Autopilot format hardening

Strengthened `[发送]` output rules in both SKILL.md and `references/autopilot-guide.md`:
- First line MUST be unconditional `[发送]` — not inside an if/else branch
- Banned Markdown formatting (`**`, `—`, `·`) inside `[发送]` messages
- Fixed safety boundary: refusing autopilot for normal escalate-stage intimate conversation is now an error; only pause for explicit media/violence or explicit rejection

### 3. Eval improvements (v2 chatlog suite)

Built 30-case advisory + 30-case autopilot eval suite from real transcribed chatlog corpus. Final results: advisory 97% (29/30), autopilot 83% (25/30) — both above 80% target.

### 4. Self-update mechanism (`/qingsheng-upgrade`)

New `setup` script + `skill/qingsheng-upgrade.md` upgrade skill. Features:
- One-liner install: `curl -fsSL https://raw.githubusercontent.com/tomwong001/qingsheng-skill/main/setup | bash`
- Detects install type: git-managed (uses `git pull`) or vendored (re-downloads tarball)
- Platform support: macOS/Linux (`~/.claude/skills/`) + Windows MINGW/MSYS/WSL (`$APPDATA/.claude/skills/`)
- Auto-registers in `~/.claude/CLAUDE.md`
- Shows CHANGELOG summary after upgrade

---

## v5 — 2026-04-10 (behavior rewrite on top of v4 refactor)

v4 was a maintainability refactor that held behavior constant. v5 is an **opinionated rewrite** of the behavior itself, driven by live user testing. Five changes:

### 1. Frontmatter trigger description rewritten

From a keyword-stuffed SEO blob to a scenario-based description listing real user phrasings ("她这话什么意思", "我该怎么回", "这截图你给我分析一下") plus explicit platform names. Keeps semantic match specific without being robotic.

### 2. Role identity + opening preamble (gstack-style)

Introduced a new role: **情感导师 + 僚机 + 好兄弟** (replaces "老哥"). Added an opening preamble block — on first contact with a new target, the skill introduces itself and naturally rolls into the information gate. Old users coming back skip the preamble and resume from the last checkpoint.

### 3. Hard information gate (第零步)

Old: "ask about platform if you want". New: **5 required facts (platform / how-you-met / met-in-person / chat history / her feeds) gate ALL analysis**. Missing any → ask 2-3 questions, no analysis, no speech act. `/急` is the only legal bypass. This fixes the "you didn't notice my platform is WeChat" and "you skipped asking about our backstory" issues from user testing.

### 4. Explicit platform callout (第一步)

First sentence of every coached response must start `"{platform}场景，你们现在在阶段 X（阶段名）——"`. No more implicit platform awareness; user needs to see the skill name the platform.

### 5. Output length hard cap (第二步 + 语气规范)

Old: 8 mandatory sections (局势判断 / 信号解读 / 方案ABC / 不回复 / 主动出击 / 引领规划 / 下一步预判 / 教练点评). New: **2-3 paragraphs + exactly 1 follow-up question, full stop**. Banned specific section names by name. Banned ABC-triple-option playbooks (1 main recommendation, optionally 1 alt). User quote that drove this: "这又不是读报告".

### 6. Slash commands consolidated and Chinese-ified

v3 had `/regenerate` and `/ask`. v5 has three, all Chinese, no aliases:

- `/换一个` — regenerate from a different angle
- `/急` — bypass info gate, 3-5 line quick answer
- `/复盘 <称呼>` — full history recap for a target (requires explicit name; no name → `AskUserQuestion` picker)

### 7. AskUserQuestion-driven storage setup

First-time storage location is no longer auto-picked. The skill probes for agent-native memory/notes locations (Claude Code / Cursor / Claude Desktop / Codex / git repo root / $HOME), generates 2-4 real-path options, and uses `AskUserQuestion` to let the user click. `storage_root` is persisted in `user-profile.md` frontmatter so subsequent sessions don't re-ask.

### Files touched

```
skill/SKILL.md                       rewritten (v4 154 lines → v5 ~170 lines)
skill/references/user-context.md     persistence section rewritten
.gitignore                           new
CHANGELOG.md                         this file
```

---

## v4 — 2026-04-10

### What changed

This release is a refactor for **maintainability and portability**, not new features. The skill behavior is held constant (verified against the 18-case eval suite).

#### 1. Progressive disclosure (652 → 137 lines in `SKILL.md`)

The previous `SKILL.md` was 652 lines and loaded entirely into the agent's context window every time the skill was invoked. v4 splits it into a 137-line core + five `references/*.md` files that are only loaded on demand.

| File | Purpose | When loaded |
|---|---|---|
| `SKILL.md` | Skill router, workflow shell, output structure, behavior rules | always |
| `references/stages.md` | Seven-stage system | when locating user's stage |
| `references/signals-tools.md` | Method toolbox (IOI/IOD, push-pull, humor, leading) | when analyzing signals |
| `references/user-context.md` | Profile + multi-target management + persistence strategy | first use or target switch |
| `references/advanced-techniques.md` | Detailed playbooks (3-step invitation, shit tests, Kino, DHV) | stages 3-6 |
| `references/platform-guide.md` | WeChat / Tantan / Momo / Soul / Bumble / Qingteng | platform-specific advice |

#### 2. Agent-portable persistence

Removed all hardcoded `~/.claude/qingsheng/` paths. The skill no longer assumes Claude Code is the host — it works in Cursor, Codex, Claude Desktop, or anywhere Markdown-based skills load.

`references/user-context.md` now has a "持久化" section that describes a priority order: agent's built-in memory > project notes/scratch > fallback to a `$HOME` namespace. The skill picks at runtime; it doesn't dictate.

#### 3. Eval suite + automated runner

Added `evals/run_evals.sh` — a shell script that executes the 18 existing eval cases against any version of `SKILL.md`. Runs in two passes (SUT + LLM judge), uses `claude -p` headless mode against the user's existing Claude Code subscription (no Anthropic API key needed). Results land in `evals/results/<timestamp>-<label>/`.

```bash
./evals/run_evals.sh --label baseline-v3   # full run, all 18 cases
./evals/run_evals.sh --only 1,3,5          # subset
```

#### 4. Human review marker in README

README now states who last reviewed the skill and on what date, with a pointer to the eval results. Closes the human-in-the-loop gap.

#### 5. Restored content from v3 that the v2 split had dropped

While migrating, three v3 items were missing from the v2 reference split. These have been restored:

- `SKILL.md` 行动方案: "至少一个选项运用幽默，至少一个体现引领感"
- `SKILL.md` 行动方案: 教练点评 (when user is in passive mode)
- `SKILL.md` 关键行为规范: 隐私意识 + 尊重边界 (rules 5 and 6)

See `v4-diff-report.md` for the full delta.

#### 6. Bug fixes

- `evals/evals.json` had 6 unescaped inner double-quotes in 4 prompt strings, making the file invalid JSON. All fixed.

### Migration notes

- No public API changes. Drop-in replacement for v3.
- Existing user-profile / target-profile data at `~/.claude/qingsheng/` will continue to work — the skill just won't hardcode that location going forward. If you switch agents, follow the new persistence priority order in `references/user-context.md`.
