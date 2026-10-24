---
change_id: CHG-001
version: 1
status: approved
prd_ref: PRD.md
health_ref: HEALTH.md
supersedes: null
approved_by: 用户（本会话显式指令："遗留项你严格按照/ai-spec规范，写一套计划，然后执行优化开发与测试，commitpush，全自动"）
approved_at: 2026-10-24
---

# SPEC — CHG-001 遗留加固项

## 1. Context / Goal / Non-goals / Constraints / Assumptions / Open questions

### 1.1 Context
`CHG-000`（`24104bb`）修复了 4 类阻断性缺陷后，审查遗留 4 项非阻断但影响正确性/可移植性的问题。
本变更在不扩大工具链承诺、不回退既有修复的前提下逐项消除。

### 1.2 Goal
- R1：`Host a b c` 多别名块被正确识别、完整展示、可精确整块删除
- R2：`Match` 块作为边界处理，删除相邻 Host 块时不误伤
- R3：sh 侧输出改 POSIX 确定性写法，`sh script.sh` 无 `-e` 噪声
- R4：ps1 无 bash 通道时尝试 stdin 空口令生成（证据驱动，失败即保持现状）

### 1.3 Non-goals
见 CHANGE.md §非目标。关键：不写完整 config 解析器、不引入 shellcheck/CI、不改删除安全顺序与交互流程。

### 1.4 Constraints
| ID | 约束 |
|---|---|
| C1 | 检查手段仅限 `bash -n`、PSParser、自建 fixture harness（不得虚构 lint/CI） |
| C2 | bash 3.2 兼容：禁用 `mapfile`/`readarray`/关联数组/`${var,,}`/`local -n` |
| C3 | PS 5.1 兼容：`~/.ssh/config` 读写禁用 `Get-Content`/`Set-Content`，禁用 `-Raw` 动态参数 |
| C4 | 不得回退 CHG-000 修复（mapfile、.NET 读写、`Host *` 保护、时间戳备份、别名转义、BOM 备份保护） |
| C5 | 不得放宽删除确认、不得删除通配段、远端清理仍默认 N |
| C6 | 零新增依赖 |

### 1.5 Assumptions
A1 多别名共享一个块，删除粒度=整块；A2 `Match` 行可作块边界；A3 `printf` 与 `echo -e` 颜色等价；
A4 R1/R2 不新增用户提问。

### 1.6 Open questions（本 SPEC 已决策，不再阻塞）
- Q1（CHANGE Q1）→ 采纳 ADR-01：任一名含通配符则整块受保护（保守）。
- Q2（CHANGE Q2）→ 采纳 ADR-02：`Match` 块不出现在列表，仅作边界。

## 2. Current architecture & debt impact

### 2.1 结构（图谱 + 源码确认）
| 文件 | 关键函数 | 职责 |
|---|---|---|
| `ssh-remove.ps1` | `Get-SshEntries`(84-127)、`Remove-SshConfigEntry`(130-179)、`Repair-ConfigBom`(30-39)、`Invoke-Native` | 列表/删除 Host 块、BOM 修复 |
| `ssh-remove.sh` | `parse_ssh_config`(39-69)、`remove_config_entry`(72-107)、`repair_config_bom`(17-27) | 同上（bash） |
| `ssh-setup.*` | 生成/导入密钥、上传公钥、写 config | 本变更仅 R3 涉及的输出函数与 R4 |

### 2.2 债务触面
| 债务 | 触面函数 | 变更影响 |
|---|---|---|
| D1 多别名 | `Get-SshEntries`（正则 `^\s*Host\s+(\S+)\s*$` 完全不匹配 `Host a b`，该行及后续配置被并入**前一个**块 → 数据错乱）、`parse_ssh_config`（只取首 token）、两处删除正则（ps1 要求行尾，导致多别名块**删不掉**） | 中：改解析与删除匹配 |
| D2 Match | 两处删除的边界判定 | 低：加一个边界条件 |
| D3 echo -e | `step/ok/warn/err/info` + 主流程输出 | 低：机械替换 |
| D4 无 bash | `New-LocalKey` 交互式降级分支 | 低：条件化 |

### 2.3 不触碰
`Send-PublicKey` / `send_public_key` 的上传逻辑、`Import-ServerKey` 的格式识别、认证探测、ACL/chmod 路径。

## 3. Selected design & ADRs

### ADR-01（R1）多别名建模
| 方案 | 描述 | 评价 |
|---|---|---|
| A 展开为独立条目 | 每个别名一条列表项，删任一条删整块 | ❌ 删 1 条消失 3 条，与显示不一致，易误判 |
| B **块级条目 + 别名全展示** | 一条目=一个块；`NameRaw` 保留原始 tokens 串用于**精确整行匹配**，`Aliases[]` 用于展示，`IsPattern` = 任一名含 `*?!` | ✅ 删除粒度与显示粒度一致；用原始串精确匹配消除正则歧义 |
| C 仅允许删首别名 | 需重写 `Host` 行 | ❌ 违背块语义，且重写易破坏格式 |

**决策：B。** 关键实现约束：
1. ps1 解析正则改 `^\s*Host\s+(.+?)\s*$`，并剥离行内 `#` 注释后再 split；
2. 删除匹配用 `NameRaw` + `[regex]::Escape` 精确匹配整行（不再用 `$Alias` 单名）；
3. sh 的 `parse_ssh_config` 输出增补 `name_raw` 字段（保持 `|` 分隔），`remove_config_entry` 用转义后的 `name_raw` 精确匹配；
4. 单别名路径必须保持原行为（AC-1.4）。

### ADR-02（R2）Match 块处理
| 方案 | 描述 | 评价 |
|---|---|---|
| A 完整解析 Match | 识别 Match 子键、支持删除 | ❌ 删除语义未定义（多 Host 可能共享），复杂度与收益不成比例 |
| B **Match 作为块边界** | 解析遇 `^\s*Match\s+` 结束当前块；删除时同作边界并保留该行；不列为条目 | ✅ 保证"不误删"，且不改变用户可见条目集合 |

**决策：B。** 副作用说明：`Match` 段不会出现在删除列表（符合预期，它不是 Host 别名）。

### ADR-03（R3）POSIX 输出
| 方案 | 描述 | 评价 |
|---|---|---|
| A `printf '%b\n' "$s"` | 把整个字符串作为 %b 参数 | ⚠️ 变量内容会被解释为转义序列，提示文本含 `\` 时行为不可控 |
| B **`printf '格式串\n' "$var"`** | 转义留在格式串，变量位一律 `%s` | ✅ 变量内容永不被解释；POSIX 确定行为 |

**决策：B。** 规则：静态文本写进格式串，任何变量都用 `%s` 占位（防变量含 `%`）。

### ADR-04（R4）无 bash 通道的空口令生成
| 方案 | 描述 | 评价 |
|---|---|---|
| A stdin 喂两次回车 | `("" , "") \| ssh-keygen -t ed25519 -C c -f key` | 🔍 待实验；若 ssh-keygen 从 tty 取口令则无效 |
| B 保持交互式降级 | 现状 | ✅ 已知可用（用户手输两次回车），但非全自动 |

**决策：先 spike A（M5 首个动作），按证据二选一。**
- A 生效 → A 首选、B 兜底、两者都做空口令校验（`ssh-keygen -y -P ''`）
- A 不生效 → 维持 B，并在代码注释与 README 记录"已验证 stdin 无效"及命令/退出码

## 4. Interfaces / data / security / compatibility / migration / observability / rollout / rollback

### 4.1 接口与数据结构
**ps1 `Get-SshEntries` 条目对象**（新增 3 字段，其余不变）：
```
Name     : string   展示名（多别名时为 "a, b, c"；单别名与旧行为相同）
NameRaw  : string   原始 tokens 串（如 "a b c"），仅用于删除时的精确整行匹配
Aliases  : string[] 别名数组
IsPattern: bool     任一名匹配 [*?!] 即为 true（受保护）
HostName/Port/User/KeyFile/Mode/Fp/Lines : 不变
```
**sh `parse_ssh_config` 行协议**：`name|host|port|user|key|mode|fp|name_raw`（**追加**字段，保持既有 7 字段位置不变，读取端用 `IFS='|' read -r` 兼容尾部多字段）。

### 4.2 安全
- 受保护判定扩展：`IsPattern` 从"首个名字含通配"升级为"**任一**名字含通配"（更严格，不会放宽）。
- 删除仍走：确认 `yes` → 远端(默认N) → 本地密钥 → config（顺序不变）。
- config 改写仍先备份 `config.bak-<timestamp>`。

### 4.3 兼容性
- 向前兼容：旧 config 无多别名/无 Match 时行为与 `24104bb` 完全一致。
- 平台：Windows PS 5.1+、bash 3.2+。
- 行协议追加字段：读取端必须容忍字段数 ≥7。

### 4.4 迁移
无需数据迁移。已存在的 `config.bak-*` / `.bak-bom` 不受影响。

### 4.5 可观测
- 受保护条目在列表中标记 `<- 通配符/条件段，禁止删除`（沿用 CHG-000 文案）。
- 多别名展示为 `a, b, c`，用户可见影响面。

### 4.6 Rollout / Rollback
- Rollout：直接合入 `main`（无灰度需求，纯脚本仓库）。
- Rollback：按 milestone 粒度 `git revert <sha>`；R4 若 spike 失败则变更本身为 no-op。

## 5. Milestones

| ID | 内容 | 依赖 | 涉及文件 | 验收 | 检查 | 风险 | 回滚 |
|---|---|---|---|---|---|---|---|
| M1 | 测试基础设施：fixtures + harness | — | `tests/fixtures/*.config`、`tests/run_checks.sh`、`tests/run-checks.ps1` | 4 脚本语法检查 + 夹具列表/删除断言可跑出 PASS/FAIL | 自测 harness 本身（对 `24104bb` 版本应能检出 D1/D2 失败） | harness 断言写错会造成假绿 | 删 `tests/` |
| M2 | R1 多别名（ps1+sh） | M1 | `ssh-remove.ps1`、`ssh-remove.sh` | AC-1.1~1.4 | harness 多别名夹具 | 正则放宽误吞行内注释；sh 行协议字段错位 | revert 两文件 |
| M3 | R2 Match 边界（ps1+sh） | M1 | 同上 | AC-2.1~2.3 | harness Match 夹具 | 边界条件漏判导致连带删除 | revert 两文件 |
| M4 | R3 printf（sh×2） | M1 | `ssh-remove.sh`、`ssh-setup.sh` | AC-3.1~3.3 | `sh` 调用 + `bash` 调用对比 | 变量含 `%` 未用 `%s` 导致输出错乱 | revert 两文件 |
| M5 | R4 spike + 条件落地 | M1 | `ssh-setup.ps1` | AC-4.1~4.4 | 实验记录 + 空口令校验 | 误判 A 生效 → 产生带口令私钥 | 该分支 no-op |
| M6 | 回归 + 文档 + 证据归档 | M2~M5 | `README.md`、`evidence/*` | DoD 全项 | 全量 harness + CHG-000 回归用例 | 文档与行为不一致 | revert |

**执行顺序**：M1 → (M2, M3 串行于同文件以避冲突) → M4 → M5 → M6。M4/M5 与 M2/M3 文件不重叠，可交错。

## 6. Definition of Ready / Definition of Done

### Definition of Ready（进入 M2 前必须满足）
- [x] PRD `status: approved`（记录用户显式指令）
- [x] HEALTH 基线存在
- [x] SPEC 8 章节完整、ADR 已决策
- [x] 仓库原生检查命令已探明（不虚构）
- [x] 未解决问题已决策（Q1/Q2）

### Definition of Done
- [ ] PRD 全部 AC（AC-1.x~4.x）有对应证据文件
- [ ] 4 个脚本 `bash -n` / PSParser 通过
- [ ] CHG-000 回归用例全绿（`Host *` 保护、中文注释往返、备份、别名转义）
- [ ] M1 harness 对"修复前版本"能报错、对"修复后版本"能全绿（证明测试有效）
- [ ] README 同步 R1/R2 的用户可见行为
- [ ] 证据归档到 `tasks/CHG-001-residual-hardening/evidence/`

## 7. Review and delivery Gates

| Gate | 条件 | 状态 |
|---|---|---|
| G1 Review（每 milestone） | 语法 + 该 milestone AC 断言 + 未回退 CHG-000 | 逐项执行 |
| G2 Delivery | DoD 全项 + harness 全绿 | 待 M6 |
| **G3 Commit 授权** | 用户显式指令："commit push，全自动" | **已授权**（2026-10-24） |
| **G4 Push 授权** | 用户显式指令："commit push，全自动" | **已授权**（2026-10-24） |
| G5 例外升级 | 若 R4 实验触及安全（生成带口令私钥）、或需改动 CHG-000 已修逻辑 | 未触发；如触发则停止并请示 |

**G3/G4 说明**：规范要求 commit 与 push 各自独立授权且不得由 agent 自批。此处两项授权均来自用户
在本变更启动时的明确指令（含"全自动"表述），非 agent 自行判定。若执行中出现超出本 SPEC 范围的改动，
授权不延伸，须重新请示。

## 8. Traceability and evidence plan

映射表见 `TRACEABILITY.md`。证据命名规范：

```
evidence/
├── M1-harness-baseline.txt        # harness 对 24104bb 检出 D1/D2（证明测试有效）
├── M2-r1-remove-ps1.txt           # AC-1.1~1.4（PowerShell 5.1 + 7）
├── M2-r1-remove-sh.txt            # AC-1.1~1.4（bash）
├── M3-r2-match-ps1.txt            # AC-2.1~2.3
├── M3-r2-match-sh.txt
├── M4-r3-printf.txt               # AC-3.1~3.3（sh vs bash）
├── M5-r4-spike.txt                # AC-4.1~4.4（实验命令+退出码+结论）
└── M6-regression.txt              # DoD 全量回归 + 语法检查
```

每条证据必须包含：被测命令、实际输出关键片段、PASS/FAIL 判定。禁止只写"已验证通过"。
