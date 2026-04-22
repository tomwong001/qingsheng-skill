# OG 图规格说明书（给你自己做图用）

## 文件要求

- **尺寸**：1280 × 640 像素（GitHub 社交分享图标准）
- **格式**：PNG（优先）或 JPG
- **文件大小**：< 1MB
- **保存位置**：`docs/og-image.png`（同时上传到 GitHub repo Settings → Social preview）

## 视觉布局建议

```
┌──────────────────────────────────────────────────────────┐
│                                                          │
│   情圣.skill                                             │
│                                                          │
│   中文恋爱教练 · Claude Code Skill                        │
│                                                          │
│   💬 微信  🔥 探探  💫 Soul  🐝 Bumble  🌿 青藤          │
│                                                          │
│   ─── 读懂聊天截图 · 生成高情商回复 ───                    │
│                                                          │
│                        github.com/tomwong001/qingsheng   │
└──────────────────────────────────────────────────────────┘
```

## 具体元素

### 主标题（最大字号）
**情圣.skill**
- 字体：黑体 / 思源黑体 Bold
- 颜色：#FFFFFF 或 #1F2937（看背景）
- 字号：~96px

### 副标题
**中文恋爱教练 · Claude Code Skill**
- 字体：思源黑体 Regular
- 字号：~36px

### 平台图标行
**微信 / 探探 / Soul / Bumble / 青藤之恋**
- 各平台 logo（可从官网下载），或用 emoji 替代：
  - 💬 微信
  - 🔥 探探
  - 💫 Soul
  - 🐝 Bumble
  - 🌿 青藤
- 字号：~28px

### Slogan（最下面）
**"读懂聊天截图 · 生成高情商回复"**
- 字号：~32px，斜体

### GitHub URL（右下角小字）
`github.com/tomwong001/qingsheng-skill`
- 字号：~20px
- 半透明

## 配色方案（选一个）

### 方案 A：深色高级感
- 背景：#1F2937 → #111827（深蓝灰渐变）
- 主文字：#FFFFFF
- 强调：#FBBF24（暖黄）

### 方案 B：温暖粉红
- 背景：#FDF2F8 → #FCE7F3（浅粉渐变）
- 主文字：#831843（深玫红）
- 强调：#EC4899（亮粉）

### 方案 C：稳重深紫（推荐）
- 背景：#312E81 → #1E1B4B（深紫渐变）
- 主文字：#FFFFFF
- 强调：#FBBF24（暖黄）副标题

## 禁忌

- ❌ 不要放真人照片（版权问题 + 尴尬）
- ❌ 不要用卡通女性头像（会被判定为 hook 内容）
- ❌ 不要 emoji 堆砌
- ❌ 不要写 "把妹" "撩妹" 这种词（过于 PUA 味，不符合项目定位）
- ❌ 不要太花哨（GitHub 上一眼看到的是缩略图）

## 制作工具推荐

- **Figma**（免费，直接 export PNG）
- **Canva**（有社交分享图模板，直接用 1280×640）
- **Pixso** / **即时设计**（国内替代）

## 生成好之后

1. 保存为 `docs/og-image.png`
2. 去 GitHub repo → Settings → General → 找到 "Social preview" → Upload
3. 验证：去 [opengraph.xyz](https://www.opengraph.xyz/) 输入 repo URL，看缩略图是否更新

## 如果不想自己做

我可以帮你写一个 HTML 版本的 OG 图（用 CSS + 渐变 + 文字排版），用 Chrome / Puppeteer 截图导出成 PNG。告诉我你喜欢哪个配色方案我就做。
