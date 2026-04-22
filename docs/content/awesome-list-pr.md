# PR 模板：提交到 laolaoshiren/claude-code-skills-zh

**目标 repo**：https://github.com/laolaoshiren/claude-code-skills-zh

---

## PR 标题
```
新增：情圣 (qingsheng-skill) — 中文恋爱教练 skill
```

## PR 描述（body）

```markdown
## 新增 Skill：情圣 (qingsheng-skill)

**类型**：外部社区 skill（独立 repo，MIT 协议）

### 一句话描述
一个面向中文用户的 Claude Code 恋爱教练 skill。读懂微信/探探/Soul/Bumble/青藤之恋/Tinder 聊天截图，分析女生信号，生成高情商回复，追踪多目标关系阶段。

### 特点
- 📸 聊天截图 OCR + 中文语义分析
- 🪜 7 阶段关系推进模型（破冰 → 好感 → 升温 → 邀约 → 约会 → 亲密 → 确立）
- 👥 多目标档案管理（同时追几个妹子不会串频道）
- 🔒 本地运行，所有数据不上传
- 💬 1400+ 真实对话语料 + 社会心理学实证研究
- 🎯 真实性原则（永远不替用户编故事，档案里没有的会先问）

### 子命令
- `/换一个` — 换角度重新给建议
- `/急` — 跳过采集 3-5 句直接出答案
- `/复盘 <称呼>` — 读档案串历史
- `/展示面` — 头像/bio/朋友圈诊断
- `/挽回` — 冷启动 / 关系恢复
- `/自动` — Autopilot 对话树规划

### 安装
\`\`\`bash
bash <(curl -fsSL https://raw.githubusercontent.com/tomwong001/qingsheng-skill/main/setup)
\`\`\`

或直接让 Claude 帮装：\`帮我安装情圣 skill：https://github.com/tomwong001/qingsheng-skill\`

### Repo 信息
- **GitHub**: https://github.com/tomwong001/qingsheng-skill
- **License**: MIT
- **Stars**: 17（持续更新中）
- **语言**: 纯中文
- **维护状态**: Active（每周 commit，配套 eval 回归测试）

希望能加入中文精选集，也欢迎审阅内容质量后给反馈 🙏
```

---

## 要加的表格行

把下面这行加入 README.md 中合适的分类（建议：在「生活/娱乐」或「其他」，如果没有这类可建新分类「情感/社交」）：

```markdown
| [qingsheng-skill](https://github.com/tomwong001/qingsheng-skill) | 💬 中文恋爱教练，读懂聊天截图、生成高情商回复、追踪多目标关系阶段 | 17+ |
```

或如果分类表头是 `| 技能 | 分类 | 说明 |`：

```markdown
| [qingsheng-skill](https://github.com/tomwong001/qingsheng-skill) | 情感/社交 | 中文恋爱教练 · 读懂聊天截图 · 高情商回复生成 · 7 阶段关系模型 |
```

---

## 操作步骤（等 GitHub Pages 上线后再发 PR）

1. Fork `laolaoshiren/claude-code-skills-zh` 到自己账户
2. Clone 下来，切新分支：`git checkout -b add-qingsheng-skill`
3. 编辑 README.md，在合适分类加入表格行
4. commit & push：`git commit -am "add qingsheng-skill to community list" && git push`
5. 到 GitHub 创建 PR，粘贴上面的 body
6. 如果 repo owner 回复有格式问题，按 review comment 调整

## 注意

- 先确认 repo 最近还在维护（看最近 commit）
- 如果对方 repo 有 CONTRIBUTING.md 要先看
- 不要一次性提交太多内容，先用最简单的表格行 + 短描述
- PR 语气要真诚、不要像自卖自夸，表达出"希望能让更多中文用户知道"的意思
