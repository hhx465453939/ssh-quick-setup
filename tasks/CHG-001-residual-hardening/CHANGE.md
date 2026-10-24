# CHANGE — CHG-001 遗留加固项（跨平台语义对齐）

| 字段 | 值 |
|---|---|
| change_id | CHG-001 |
| 类型 | 缺陷修复 + 可移植性硬化（无新功能） |
| 来源 | CHG-000（`24104bb`）双向审查后遗留的 4 项，经用户显式指令要求实施 |
| 上报日期 | 2026-10-24 |
| 变更基线 | `main@24104bb`（远端已同步） |
| 涉及平台 | Windows PowerShell 5.1 / 7、Git Bash(MSYS2)、Linux、macOS(bash 3.2) |
| 涉及文件 | `ssh-setup.ps1`、`ssh-setup.sh`、`ssh-remove.ps1`、`ssh-remove.sh` |

## 背景

`CHG-000` 已修复四类真实缺陷（mapfile 在 macOS 崩溃、PS 5.1 读 config 静默丢条目、
`Host *` 误删、删除无回滚）。在双向审查过程中另记录 4 项未实施的增强，均有明确技术依据
但不属于当轮阻断性问题，故单独立项。

## 变更范围（In Scope）

| 编号 | 遗留项 | 现状缺陷（有据） |
|---|---|---|
| R1 | `Host a b c` 多别名单行 | 解析只取第一个 token；列表按"单别名"展示，用户无法看出该块服务多个别名，删除时的实际影响面（整块）与展示不一致 |
| R2 | `Match` 条件块 | 按普通行处理。删除某 Host 块时，块结束边界只认 `Host` 行，`Match` 块内行可能被误判为上一个 Host 块的成员 |
| R3 | `echo -e`（sh 侧颜色输出） | 脚本 shebang 为 bash，但若被 `sh script.sh` 方式调用（dash/POSIX sh），`echo -e` 会输出字面 `-e`，全部提示行出现噪声 |
| R4 | ps1 无 bash 通道时的空口令生成 | 当前降级为交互式 `ssh-keygen`（要求用户手动回车两次）。可尝试用 stdin 喂入两次回车实现非交互，需先验证 ssh-keygen 是否读取 stdin |

## 非目标（Out of Scope）

- 不实现完整的 OpenSSH config 语法解析器（`Include`、`CanonicalizeHostname` 等仍不展开）
- 不改动已通过真机验证的删除安全顺序（远端 → 本地私钥 → config）
- 不引入 shellcheck / PSScriptAnalyzer / CI（仓库当前无这些基础设施，本变更不扩大工具链承诺）
- 不改变交互流程与提示语气（除 R3 的输出通道修正）
- 不触碰 `ssh-setup` 的认证模式选择逻辑

## 约束

1. **不得虚构检查命令**：仓库原生只有 `bash -n`、PSParser 语法解析；无测试框架、无 lint、无 CI。
   证据一律由自建 fixture harness 产生。
2. **不得回退 CHG-000 的既有修复**：任何改动必须保证 M6 回归用例全部通过。
3. **bash 3.2 兼容**：sh 侧禁止使用 bash 4+ 专属特性（`mapfile`、关联数组、`${var,,}`、`local -n`）。
4. **PS 5.1 兼容**：ps1 侧禁用 `Get-Content` 读写 `~/.ssh/config`（ANSI 解码缺陷），禁用 `-Raw`
   动态参数（受限语言模式），不得依赖 PS 7 语法。
5. **探索性任务先 spike**：R4 若 exp 证明 stdin 不生效，必须保持现状并记录结论，不得强行落地。

## 假设

- A1：`Host` 行内多个别名共享同一配置块，删除粒度应为"整块"（OpenSSH 语义）。
- A2：`Match` 块与 `Host` 块在文件中共存时，`Match` 行可安全视为块边界。
- A3：`printf '%b\n'` 与 `echo -e` 在颜色转义上等价，可用于 POSIX 兼容替换。
- A4：用户交互习惯不变，R1/R2 只影响展示与边界判定，不新增提问。

## 未解决问题

- Q1：R1 中若同一块的多个别名里有通配符（如 `Host web1 web*.corp`），该块应整体视为"受保护"，
  还是仅对通配别名做保护？本 SPEC 采用"任一名含通配符即整块保护"（保守，见 ADR-01）。
- Q2：R2 的 `Match` 块是否需要在列表中显示为"受保护条目"？本 SPEC 选择"不显示，仅作边界"（见 ADR-02）。
