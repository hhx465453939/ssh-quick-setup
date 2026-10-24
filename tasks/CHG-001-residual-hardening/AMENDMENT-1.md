# AMENDMENT-1 — CHG-001 范围收敛（R3 关闭 / R4 关闭）

| 字段 | 值 |
|---|---|
| 修订对象 | `PRD.md`（AC-3.x / AC-4.x）、`SPEC.md`（M4 / M5 / ADR-03 / ADR-04） |
| 触发原因 | 实施前 spike 的实测证据推翻 PRD 中两项需求的前提假设 |
| 依据规范 | `/ai-spec` §Approval and execution rules："Material scope or architecture changes require an amendment/version bump" |
| 决策人 | 用户（本会话显式授权全流程）；技术判断与证据由实施者提供 |
| 时间 | 2026-10-24 |

**不覆盖原文**：`PRD.md` / `SPEC.md` 保持 v1 原样，本文件为唯一有效修订。冲突处以本文件为准。

---

## 1. R3（echo -e → printf）：**关闭（WITHDRAWN）**

### 1.1 原假设
> 若被 `sh script.sh` 方式调用（dash/POSIX sh），`echo -e` 会输出字面 `-e`，全部提示行出现噪声。

### 1.2 实测证据

| 验证项 | 命令 | 结果 |
|---|---|---|
| 本机 `/bin/sh` 身份 | `ls -l /bin/sh` | 2,553,064 字节原生二进制；Git Bash 中 `/bin/sh` 为 bash 副本，**非 dash** |
| xpg_echo 模式下 `echo -e` | `bash -O xpg_echo -c 'echo -e "  \033[32m[OK]\033[0m test"' \| od -c` | 输出 `033 [ 3 2 m [ O K ] 033 [ 0 m ...`，**ANSI 正常，无字面 `-e`** |
| 默认模式下 `echo -e` | 同上不带 `-O xpg_echo` | 与 xpg_echo 结果**逐字节相同** |

### 1.3 结论
1. 目标场景**不存在**：`xpg_echo` 下 bash 的 `echo -e` 行为不变；真正 POSIX sh（dash）下本脚本因 `[[ ]]`、`=~`、`<<<`、`local` 等 bash 特性**根本无法运行**，`echo -e` 不是可移植性瓶颈。
2. 该需求源于 CHG-000 审查时的**推测，缺乏实测依据**，属伪需求。
3. 改动涉及 60+ 处 `echo -e`，回归风险高、行为收益为 0，**净价值为负**。

### 1.4 处置
- PRD `AC-3.1` / `AC-3.2` / `AC-3.3` → **WITHDRAWN**
- SPEC `ADR-03`、`M4` → **CANCELLED**，不实施
- 保留观察：若未来确有 dash/POSIX 支持需求，应作为独立变更（因为需先移除全部 bash 特性），届时再评估 `printf`

---

## 2. R4（无 bash 通道时的 stdin 空口令生成）：**关闭（WITHDRAWN）**

### 2.1 原假设
> 可用 stdin 提供两次回车实现非交互空口令生成，替代交互式降级。

### 2.2 实测证据

| 环境 | 操作 | 退出码 | 私钥是否空口令 |
|---|---|---|---|
| bash (MSYS) | `printf '\n\n' \| ssh-keygen -t ed25519 -C r4spike -f KEY -q` | 0 | ✅ 空口令（`ssh-keygen -y -P ''` 成功） |
| PowerShell 管道 | `"" , "" \| & ssh-keygen -t ed25519 -C r4spike -f KEY -q` | 0 | ❌ **带口令**（`-y -P ''` → exit=1） |
| PowerShell .NET | `ProcessStartInfo{RedirectStandardInput=true}` + `Write("\n\n")` | 0 | ❌ **带口令**（`-y -P ''` → exit=1） |

### 2.3 结论
1. Windows 版 ssh-keygen 从**控制台**读取口令，不消费 stdin；stdin 喂入既无效也**不报错**。
2. 更危险的是它返回 `exit=0` 并产出一个**带口令私钥**——完全复现 `CHG-000` 中修复的致命故障
   （带口令私钥 → BatchMode 下 publickey 被跳过 → 免密永不成立）。
3. 因此实施该方案会把一个"需手输两次回车的不便"换成"静默失败"，**危害大于原问题**。
4. bash 侧虽然有效，但 bash 通道存在时本来就无需此方案（`-N ''` 已可靠），故无适用场景。

### 2.4 处置
- PRD `AC-4.1`~`AC-4.4` → **WITHDRAWN**（其中 AC-4.1"有可复现实验记录"实际**已满足**，证据即本节表格）
- SPEC `ADR-04`、`M5` → **CANCELLED**，不实施；维持现状（交互式降级）
- 将实测结论写入 `ssh-setup.ps1` 的降级分支注释，防止后人再次"优化"回此坑
- 保留：现有代码已在降级后通过 `Test-KeyPassphraseFree` 做三态校验，并明确告警，符合 AC-4.4 精神

---

## 3. 收敛后的范围

| 需求 | 状态 | Milestone |
|---|---|---|
| R1 多别名 | **实施** | M2 |
| R2 `Match` 边界 | **实施** | M3 |
| R3 `echo -e` | 关闭 | M4 取消 |
| R4 stdin 空口令 | 关闭 | M5 取消（改为"结论落地到注释"） |
| M1 测试基础设施 | 实施（范围收敛为 R1/R2 + CHG-000 回归） | M1 |
| M6 回归 + 文档 | 实施 | M6 |

## 4. 对 Traceability 的影响

`TRACEABILITY.md` 中 R3/R4 各行状态改为 `WITHDRAWN`，并在证据列指向本文件 §1/§2。
`M4-r3-printf.txt` / `M5-r4-spike.txt` 不再产出；改为产出 `AMENDMENT-1` 自带证据（本文件即证据记录）。

## 5. 教训（写入流程改进）

1. **PRD 的每条 AC 必须在写契约前先做 30 秒可行性验证**。本次 R3 的"目标场景"与 R4 的"API 假设"
   都是在一行命令内即可证伪的，却先进入了契约。
2. **"提升可移植性"类需求必须明确目标运行时**，否则容易把 bash 脚本当 POSIX 脚本对待。
3. **危险方向（生成密钥/凭据）的实验必须在隔离目录 + 立即校验产物属性**，本次正是靠
   `ssh-keygen -y -P ''` 的退出码才发现"exit=0 但产物带口令"的陷阱。
