# HEALTH — ssh-quick-setup 健康基线

| 字段 | 值 |
|---|---|
| health_ref | HEALTH.md |
| 采集时间 | 2026-10-24 |
| 采集基线 | `main@24104bb` |
| 采集方式 | 仓库文件枚举 + 本机工具链探测（不虚构） |
| 性质 | 轻量基线（本项目首次引入 SPEC 体系，此前无基线） |

## 1. 规模

| 项 | 值 |
|---|---|
| 受版本控制文件 | 7 个（`.gitignore`、`README.md`、`doc/ssh-manual-setup.md`、4 个脚本） |
| 脚本代码量 | `ssh-setup.ps1` 715 行 / `ssh-setup.sh` 470 行 / `ssh-remove.ps1` 415 行 / `ssh-remove.sh` 340 行 |
| 文档 | `README.md` 288 行、`doc/ssh-manual-setup.md` 约 250 行 |
| 依赖 | 零运行时依赖（仅系统 OpenSSH + Windows 下可选 Git for Windows bash） |

## 2. 工具链现状（实测）

| 能力 | 状态 | 说明 |
|---|---|---|
| 包管理器 | ❌ 无 | 无 `package.json` / `Makefile` / `pyproject.toml` |
| CI | ❌ 无 | 无 `.github/workflows/` |
| Lint | ❌ 无 | `shellcheck`、`shfmt` 本机均不可用；未配置 PSScriptAnalyzer |
| 单元/集成测试框架 | ❌ 无 | 无 `tests/` 目录 |
| bash 语法检查 | ✅ `bash -n` | GNU bash 5.2.37 可用 |
| PowerShell 语法检查 | ✅ PSParser | pwsh 7.6.3 与 powershell.exe 5.1 均可用 |
| 行为测试 | ⚠️ 需自建 | 依赖隔离假 HOME 的 fixture harness（CHG-001 M1 建立） |

**结论**：本仓库的检查能力 = 语法检查 + 自建行为测试。任何"静态分析通过"的表述不得超出此范围。

## 3. 验证能力边界（重要，诚实标注）

| 目标平台 | 本机能否真实验证 | 依据 |
|---|---|---|
| Windows PowerShell 5.1 | ✅ 可 | `powershell.exe` 实测可用 |
| Windows PowerShell 7 | ✅ 可 | `pwsh` 7.6.3 |
| Git Bash / MSYS2 | ✅ 可（作为 Linux 近似） | `/usr/bin/bash` 5.2 |
| Linux 发行版 | ⚠️ 部分 | 无容器/远端 Linux，仅能近似 Git Bash 环境 |
| **macOS bash 3.2** | ❌ **不能** | 无 macOS 主机；bash 3.2 兼容只能靠"不使用 bash 4+ 特性"的静态约束 + 代码审查保证 |
| 真实 SSH 服务端 | ✅ 可（曾有真机验证） | CHG-000 期间对 `xiyou` 服务器完成真机免密验证 |

**风险声明**：`ssh-remove.sh` 的 macOS 兼容性属于"设计保证"而非"实测保证"。后续若要闭环，需在 macOS 或 bash 3.2 容器中跑一次 M1 harness。

## 4. 已知债务清单

| ID | 债务 | 严重度 | 归属 |
|---|---|---|---|
| D1 | `Host a b c` 多别名：ps1 完全不匹配该行（配置被并入前一块，属数据错乱）；sh 只取第一个名 | 高 | CHG-001 R1 |
| D2 | `Match` 块未被当作边界，删除相邻 Host 块时可能误删 Match 内容 | 中 | CHG-001 R2 |
| D3 | `echo -e` 在 POSIX sh 下输出字面 `-e` | 低 | CHG-001 R3 |
| D4 | ps1 无 bash 通道时降级为交互式生成（需手输两次回车） | 低 | CHG-001 R4 |
| D5 | 无自动化回归测试，依赖人工双平台验证 | 中 | CHG-001 M1 缓解 |
| D6 | `parse_partial`（codebase-memory）：两侧 `Write-*`/`step` 等单行 `param()`/函数体解析不完整，图谱缺内部调用边 | 低 | 不修（薄壳函数，无调用链价值） |
| D7 | README 出现裸文件名引用（doc_links below_bar_tier），未建立文档→代码边 | 低 | 不修 |

## 5. 历史修复（不得回归）

| 提交 | 内容 |
|---|---|
| `1216470` | 交互式 ssh-keygen stdout 污染 PowerShell 函数返回值 → 公钥上传失败 |
| `24104bb` | mapfile 在 macOS 崩溃、PS 5.1 读 config 丢条目、`Host *` 误删、删除无回滚、别名正则未转义、BOM 备份被覆盖等 |

## 6. 健康度判据（本变更的唯一准入/准出依据）

- 准入：无 CI 不得作为阻断条件（现实如此），但必须建立可重复的行为测试（M1）。
- 准出：语法检查全通过 + 行为测试全绿 + 每条 PRD AC 有证据文件。不得以"人工看过没问题"作为证据。
