# AMENDMENT-2 — CHG-001 范围再收敛（R2 关闭）

| 字段 | 值 |
|---|---|
| 修订对象 | `PRD.md`（AC-2.x）、`SPEC.md`（M3 / ADR-02） |
| 触发原因 | M1 harness 在**修复前版本 `24104bb`** 上跑 AC-2.x 全部 PASS，证明该缺陷不存在 |
| 依据规范 | `/ai-spec` §Approval and execution rules（material scope change 需 amendment） |
| 时间 | 2026-10-24 |

**不覆盖原文**：`PRD.md` / `SPEC.md` 保持 v1；`AMENDMENT-1.md` 继续有效。本文件为第二份修订。

---

## 1. R2（`Match` 块边界）：**关闭（WITHDRAWN）**

### 1.1 原假设
> 删除某 Host 块时，块结束边界只认 `Host` 行，`Match` 块内行可能被误判为上一个 Host 块的成员，导致连带删除。

### 1.2 实测证据（M1 harness，被测对象 = `24104bb` 的 `ssh-remove.ps1` / `ssh-remove.sh`）

命令：
```bash
git show 24104bb:ssh-remove.sh  > /tmp/base24104bb/ssh-remove.sh
git show 24104bb:ssh-remove.ps1 > /tmp/base24104bb/ssh-remove.ps1
REMOVE_SH=/tmp/base24104bb/ssh-remove.sh \
REMOVE_PS1=/tmp/base24104bb/ssh-remove.ps1 \
BASELINE=1 bash tests/run_checks.sh
```

夹具 `tests/fixtures/match-mixed.config`（`Host before-block` → `Match all` → `Host after-block`）：

| AC | 断言 | `24104bb` 结果 |
|---|---|---|
| AC-2.1 | 删 before-block 后 `ServerAliveInterval 30` 保留 | **PASS** |
| AC-2.1 | 删 before-block 后 `TCPKeepAlive yes` 保留 | **PASS** |
| AC-2.1 | 删 before-block 后 `Match all` 行保留 | **PASS** |
| AC-2.1 | sh 侧同断言 | **PASS** |
| AC-2.2 | `ServerAliveInterval` 不作为条目出现 | **PASS** |
| AC-2.3 | 后续 `after-block` 保留 | **PASS**（两侧） |

完整输出见 `evidence/M1-baseline-24104bb.txt`。

### 1.3 根因分析（为何假设不成立）

旧代码的块结束判定并非只认 `Host`：

```powershell
# ssh-remove.ps1 Remove-SshConfigEntry
if ($line -match "^\s*Host\s+\S+" -or ($line -match "\S" -and $line -notmatch "^\s")) { $skip = $false }
```
```bash
# ssh-remove.sh remove_config_entry
if [[ "$line" =~ ^[[:space:]]*Host[[:space:]]+ ]] || { [[ -n "$line" ]] && [[ ! "$line" =~ ^[[:space:]] ]]; }; then
    skip=false
```

`Match all` 是**顶格（非缩进）行**，第二个条件分支即命中 → 已被当作边界。
真正会漏判的是"缩进的伪边界行"，而 OpenSSH config 中 `Match` 语法不允许缩进书写，因此该风险不存在。

### 1.4 处置
- PRD `AC-2.1` / `AC-2.2` / `AC-2.3` → **WITHDRAWN**
- SPEC `ADR-02`、`M3` → **CANCELLED**，不实施任何代码改动
- `match-mixed.config` 夹具**保留**，转为**回归用例**（防止未来重构破坏该正确行为）

---

## 2. R1（多别名）：**维持实施**，且范围比原判断更严重

M1 baseline 精确检出 11 个 FAIL，其中 ps1 侧性质比 PRD 描述的更重：

| 客户端 | `24104bb` 实际行为 | 严重度 |
|---|---|---|
| ps1 | 正则 `^\s*Host\s+(\S+)\s*$` 要求"单 token + 行尾"，`Host alpha beta gamma` **完全不匹配**；该行与其配置被丢弃或并入前一块 → 数据错乱，且该块**无法被删除** | 高（高于 PRD 原描述"展示不全"） |
| sh | 能识别块但只取首名 → 展示不全；删除按首名匹配，**含通配符的多别名块会被误删**（`web1 web*.corp` 被当普通块删掉） | 高（原描述未识别此风险） |

→ PRD R1 的 AC-1.1~1.4 全部保留有效，且 **AC-1.3 的安全含义升级**：不仅是"展示受保护"，而是"防止误删通配块"。

---

## 3. 收敛后的最终范围

| 需求 | 状态 | Milestone |
|---|---|---|
| R1 多别名（+通配块保护） | **实施** | M2 |
| R2 `Match` 边界 | 关闭（已正确） | M3 取消 |
| R3 `echo -e` | 关闭（AMENDMENT-1） | M4 取消 |
| R4 stdin 空口令 | 关闭（AMENDMENT-1） | M5 取消 |
| M1 测试基础设施 | **完成**（harness 已验证有效） | — |
| M6 回归 + 文档 | 实施 | M6 |

**本变更最终只改一处需求（R1），涉及 2 个文件、4 个函数。**

---

## 4. 累积教训（两次 amendment 的共性）

1. **AMENDMENT-1 教训 1 在 AMENDMENT-2 再次发生**：R2 同样是"读代码时凭直觉认为边界处理有漏洞"，一行测试即可证伪。
   → **流程修正**：后续 `/ai-spec` 立项时，PRD 每条 AC 必须先有一个**能在旧代码上跑的执行证据**（红），否则不得进入 SPEC。
2. **M1 的价值得到验证**：若跳过 harness 直接按契约改代码，会为不存在的缺陷（R2）引入真实回归风险，同时浪费对 R3/R4 的高危改动机会。
3. 4 项遗留项中 **3 项被实测证伪**（R2/R3/R4），仅 1 项（R1）为真实缺陷——
   说明"读代码得出的优化直觉"命中率低，必须用证据过滤。
