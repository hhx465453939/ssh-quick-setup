# TRACEABILITY — CHG-001

> ## ⚠️ 当前生效状态（优先于下表）
>
> 下表为 SPEC v1 原样保留的历史映射，**实际状态以本节为准**：
>
> | 需求 | 状态 | 依据 |
> |---|---|---|
> | R1 多别名 | ✅ **VERIFIED** | M2 完成；harness `40 PASS / 0 FAIL`（基线 `29 PASS / 11 FAIL`），证据 `evidence/M2-r1-multi-alias.txt` |
> | R2 `Match` 边界 | ⛔ **WITHDRAWN** | 基线实测旧代码本就正确，缺陷不存在 → `AMENDMENT-2.md` |
> | R3 `echo -e` | ⛔ **WITHDRAWN** | 目标场景（POSIX sh）不成立，`xpg_echo` 下也无异常 → `AMENDMENT-1.md` §1 |
> | R4 stdin 空口令 | ⛔ **WITHDRAWN** | PowerShell 下会**静默产出带口令私钥**，危害大于原问题 → `AMENDMENT-1.md` §2 |
> | M1 测试基础设施 | ✅ **DONE** | `evidence/M1-baseline-24104bb.txt`（证明测试有效性） |
> | M6 回归与文档 | ✅ **DONE** | `evidence/M6-regression.txt` |
>
> 下表 R2/R3/R4 行的「待执行」不再有效，保留仅供追溯。

映射规则：PRD 验收标准 → SPEC 决策/接口 → Milestone → 证据文件 → 状态。

## 1. 需求→验收→实现→证据

| PRD 需求 | AC | SPEC 依据 | Milestone | 证据文件 | 状态 |
|---|---|---|---|---|---|
| R1 多别名 | AC-1.1 列表含全部别名 | §3 ADR-01(B)、§4.1 `Aliases[]`/`Name` | M2 | `M2-r1-remove-ps1.txt` / `-sh.txt` | 待执行 |
| R1 多别名 | AC-1.2 删除后三名同消、他块不变 | §3 ADR-01、§4.1 `NameRaw` 精确匹配 | M2 | 同上 | 待执行 |
| R1 多别名 | AC-1.3 任一名含通配则整块受保护 | §3 ADR-01、§4.2 安全 | M2 | 同上 | 待执行 |
| R1 多别名 | AC-1.4 单别名不回归 | §3 ADR-01 约束 4 | M2 | 同上 + `M6-regression.txt` | 待执行 |
| R2 Match | AC-2.1 删 Host 后 Match 段完好 | §3 ADR-02(B)、§5 M3 | M3 | `M3-r2-match-ps1.txt` / `-sh.txt` | 待执行 |
| R2 Match | AC-2.2 Match 内行不污染 Host 解析 | §3 ADR-02(B)「不列为条目」 | M3 | 同上 | 待执行 |
| R2 Match | AC-2.3 前后 Match 均不受连带删除 | §3 ADR-02(B)、§5 M3 风险 | M3 | 同上 | 待执行 |
| R3 printf | AC-3.1 `sh` 调用无字面 `-e` | §3 ADR-03(B) | M4 | `M4-r3-printf.txt` | 待执行 |
| R3 printf | AC-3.2 bash 下 ANSI 仍存在 | §3 ADR-03(B) | M4 | 同上 | 待执行 |
| R3 printf | AC-3.3 文本内容与改动前一致 | §3 ADR-03(B) | M4 | 同上 | 待执行 |
| R4 无 bash | AC-4.1 有可复现实验记录 | §3 ADR-04「先 spike」 | M5 | `M5-r4-spike.txt` | 待执行 |
| R4 无 bash | AC-4.2 若生效则私钥为空口令 | §5 M5 验收 | M5 | 同上 | 待执行 |
| R4 无 bash | AC-4.3 若不生效则保持现状并记录 | §3 ADR-04 决策分支 | M5 | 同上 | 待执行 |
| R4 无 bash | AC-4.4 不得静默生成带口令私钥 | §4.2 安全、§5 M5 风险 | M5 | 同上 | 待执行 |

## 2. 约束→检查点

| 约束 | 检查点 | 证据 |
|---|---|---|
| C1 不虚构检查命令 | 只使用 `bash -n` / PSParser / harness | `M6-regression.txt` 记录实际命令 |
| C2 bash 3.2 兼容 | 代码审查 + 禁用 bash4+ 特性清单 | `M6-regression.txt` 附 `grep` 结果（无 mapfile/readarray/declare -A） |
| C3 PS 5.1 兼容 | 双版本跑 harness；`grep` 确认 config 读写无 `Get-Content` | `M2/M6` 证据 |
| C4 不回退 CHG-000 | 回归用例：`Host *` 保护 / 中文往返 / 备份生成 / 别名转义 / BOM 备份保护 | `M6-regression.txt` |
| C5 不放宽删除安全 | 检查确认仍是「确认 yes → 远端默认N → 本地密钥 → config」 | 代码审查 + `M6` |
| C6 零新增依赖 | `git ls-files` 无新增依赖文件 | `M6` |

## 3. 债务闭环

| 债务 | 本变更处理 | 证据 |
|---|---|---|
| D1 多别名 | R1 修复 | M2 证据 |
| D2 Match 边界 | R2 修复 | M3 证据 |
| D3 echo -e | R3 修复 | M4 证据 |
| D4 无 bash 空口令 | R4 spike，按证据落地 | M5 证据 |
| D5 无自动化回归 | M1 建立 harness（长期资产） | `tests/` + `M1` 证据 |
| D6 图谱 parse_partial | 不修（DECISION：薄壳函数无调用链价值） | 本行即决策记录 |
| D7 doc_links 未建边 | 不修（二进制/文档引用，收益低） | 本行即决策记录 |

## 4. 假设→验证方式

| 假设 | 验证 |
|---|---|
| A1 多别名共享块、删除粒度=块 | AC-1.2 删除后三名同消 |
| A2 Match 可作块边界 | AC-2.1/2.3 |
| A3 printf 与 echo -e 颜色等价 | AC-3.2/3.3 |
| A4 不新增用户提问 | 交互流程 diff 审查（提问次数不变） |
