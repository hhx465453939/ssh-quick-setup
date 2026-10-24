#!/usr/bin/env bash
# CHG-001 行为测试 harness
#
# 设计原则（见 tasks/CHG-001-residual-hardening/SPEC.md §1.4 C1）：
#   - 只使用仓库原生可用的检查手段：bash -n、PSParser、本 harness
#   - 断言基于【被改写的 config 文件内容】而非脚本 stdout，规避中文编码差异
#   - 每个用例在独立假 HOME 中运行，绝不触碰真实 ~/.ssh
#
# 用法：
#   bash tests/run_checks.sh                        # 测仓库当前版本
#   REMOVE_SH=/tmp/base/ssh-remove.sh \
#   REMOVE_PS1=/tmp/base/ssh-remove.ps1 \
#     bash tests/run_checks.sh                      # 测指定版本（用于证明测试能检出旧缺陷）
#
# 退出码：0 = 全部通过；1 = 存在失败
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FIX="$REPO/tests/fixtures"
REMOVE_SH=${REMOVE_SH:-$REPO/ssh-remove.sh}
REMOVE_PS1=${REMOVE_PS1:-$REPO/ssh-remove.ps1}
PS_EXE=${PS_EXE:-powershell.exe}
BASELINE=${BASELINE:-0}

PASS=0
FAIL=0
FAILED=()

section() { printf '\n==== %s ====\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() {
    FAIL=$((FAIL + 1))
    FAILED+=("$1")
    printf '  FAIL  %s\n' "$1"
    [ -n "${2:-}" ] && printf '        ↳ %s\n' "$2"
}

assert_out_has()   { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "stdout 未包含 [$3]" ;; esac; }
assert_out_lacks() { case "$2" in *"$3"*) fail "$1" "stdout 不应包含 [$3]" ;; *) pass "$1" ;; esac; }
assert_file_has()   { grep -qF -- "$3" "$2" && pass "$1" || fail "$1" "$(basename "$2") 缺少 [$3]" ; }
assert_file_lacks() { grep -qF -- "$3" "$2" && fail "$1" "$(basename "$2") 仍含 [$3]" || pass "$1" ; }
assert_eq()         { [ "$2" = "$3" ] && pass "$1" || fail "$1" "期望 [$3] 实际 [$2]" ; }

# 造隔离假 HOME：复制夹具为 config，并放占位密钥（删除流程需要，非真实凭据）
new_home() {
    local fixture="$1" h
    h=$(mktemp -d)
    mkdir -p "$h/.ssh"
    cp "$FIX/$fixture" "$h/.ssh/config"
    local k
    for k in alpha before after single normal-block zh; do
        printf 'PLACEHOLDER-PRIVATE-KEY\n' > "$h/.ssh/id_ed25519_$k"
        printf 'ssh-ed25519 PLACEHOLDER-BLOB %s\n' "$k" > "$h/.ssh/id_ed25519_$k.pub"
    done
    printf '%s\n' "$h"
}

# 跑 sh 侧：run_sh <home> <stdin 内容（printf %b 格式）>
run_sh() { printf '%b' "$2" | HOME="$1" bash "$REMOVE_SH" 2>&1; }

# 跑 ps1 侧：需要 Windows 形式路径
run_ps() {
    local hwin
    hwin=$(cygpath -w "$1" 2>/dev/null || printf '%s' "$1")
    printf '%b' "$2" | HOME="$hwin" "$PS_EXE" -NoProfile -ExecutionPolicy Bypass \
        -File "$(cygpath -w "$REMOVE_PS1" 2>/dev/null || printf '%s' "$REMOVE_PS1")" 2>&1
}

count_hosts() { grep -cE '^[[:space:]]*Host[[:space:]]' "$1" 2>/dev/null || printf '0'; }

printf '被测脚本:\n  sh : %s\n  ps1: %s\n' "$REMOVE_SH" "$REMOVE_PS1"
[ "$BASELINE" = "1" ] && printf '  (BASELINE 模式：预期部分用例失败，用于验证测试有效性)\n'

# ─────────────────────────────────────────────────────────────
section '0. 语法检查（仓库原生手段）'
# ─────────────────────────────────────────────────────────────
for f in "$REPO/ssh-setup.sh" "$REPO/ssh-remove.sh" "$REMOVE_SH"; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/dev/null; then pass "bash -n $(basename "$f")"; else fail "bash -n $(basename "$f")"; fi
done
if command -v pwsh >/dev/null 2>&1; then
    for f in "$REPO/ssh-setup.ps1" "$REMOVE_PS1"; do
        [ -f "$f" ] || continue
        if pwsh -NoProfile -Command "\$e=\$null; \$null=[System.Management.Automation.Language.Parser]::ParseFile('$(cygpath -w "$f")',[ref]\$null,[ref]\$e); if (\$e -and \$e.Count -gt 0) { exit 1 }" >/dev/null 2>&1; then
            pass "PSParser $(basename "$f")"
        else
            fail "PSParser $(basename "$f")"
        fi
    done
fi

# ─────────────────────────────────────────────────────────────
section '1. R1 多别名解析（sh 侧 / AC-1.1~1.2）'
# ─────────────────────────────────────────────────────────────
H=$(new_home multi-alias.config)
OUT=$(run_sh "$H" '\n')
assert_out_has 'AC-1.1 sh 列表含 beta' "$OUT" 'beta'
assert_out_has 'AC-1.1 sh 列表含 gamma' "$OUT" 'gamma'
OUT2=$(run_sh "$H" '1\nyes\n\n')
assert_file_lacks 'AC-1.2 sh 删除后 alpha 消失' "$H/.ssh/config" 'alpha'
assert_file_lacks 'AC-1.2 sh 删除后 beta 消失' "$H/.ssh/config" 'beta'
assert_file_lacks 'AC-1.2 sh 删除后 gamma 消失' "$H/.ssh/config" 'gamma'
assert_file_has 'AC-1.2 sh 删除后 single 块保留' "$H/.ssh/config" 'single'
assert_file_has 'AC-1.2 sh single 的 HostName 保留' "$H/.ssh/config" 'single.example.com'

# ─────────────────────────────────────────────────────────────
section '2. R1 多别名解析（ps1 侧 / AC-1.1~1.2）'
# ─────────────────────────────────────────────────────────────
H=$(new_home multi-alias.config)
OUT=$(run_ps "$H" '\n')
assert_out_has 'AC-1.1 ps1 列表含 beta' "$OUT" 'beta'
assert_out_has 'AC-1.1 ps1 列表含 gamma' "$OUT" 'gamma'
OUT2=$(run_ps "$H" '1\nyes\n\n')
assert_file_lacks 'AC-1.2 ps1 删除后 alpha 消失' "$H/.ssh/config" 'alpha'
assert_file_lacks 'AC-1.2 ps1 删除后 beta 消失' "$H/.ssh/config" 'beta'
assert_file_lacks 'AC-1.2 ps1 删除后 gamma 消失' "$H/.ssh/config" 'gamma'
assert_file_has 'AC-1.2 ps1 删除后 single 块保留' "$H/.ssh/config" 'single'

# ─────────────────────────────────────────────────────────────
section '3. R1 通配保护（AC-1.3~1.4）'
# ─────────────────────────────────────────────────────────────
H=$(new_home wildcard.config)
BASE_LINES=$(count_hosts "$H/.ssh/config")
# 3 号条目是 normal-block（前两个是通配/受保护段）
OUT=$(run_ps "$H" '3\nyes\n\n')
assert_file_has 'AC-1.3 ps1 删除普通块后 Host * 仍保留' "$H/.ssh/config" 'Host *'
assert_file_has 'AC-1.3 ps1 删除普通块后通配块仍保留' "$H/.ssh/config" 'web*.corp'

H=$(new_home wildcard.config)
BASE_HOSTS=$(count_hosts "$H/.ssh/config")
# 2 号条目是 web1 web*.corp（含通配符→整块受保护），删除应被拒绝
OUT=$(run_ps "$H" '2\nyes\n\n')
assert_file_has 'AC-1.3 ps1 多别名含通配时整块受保护（未被删）' "$H/.ssh/config" 'web*.corp'
assert_eq 'AC-1.3 ps1 拒绝删除后 Host 行数不变' "$(count_hosts "$H/.ssh/config")" "$BASE_HOSTS"

H=$(new_home wildcard.config)
BASE_HOSTS=$(count_hosts "$H/.ssh/config")
OUT=$(run_sh "$H" '2\nyes\n\n')
assert_file_has 'AC-1.3 sh 多别名含通配时整块受保护（未被删）' "$H/.ssh/config" 'web*.corp'
assert_eq 'AC-1.3 sh 拒绝删除后 Host 行数不变' "$(count_hosts "$H/.ssh/config")" "$BASE_HOSTS"

# ─────────────────────────────────────────────────────────────
section '4. R2 Match 块边界（AC-2.1~2.3）'
# ─────────────────────────────────────────────────────────────
H=$(new_home match-mixed.config)
OUT=$(run_ps "$H" '\n')
assert_out_lacks 'AC-2.2 ps1 Match 段内键名不出现为条目' "$OUT" 'ServerAliveInterval'
OUT=$(run_ps "$H" '1\nyes\n\n')
assert_file_lacks 'AC-2.1 ps1 删除 before-block' "$H/.ssh/config" 'before-block'
assert_file_has 'AC-2.1 ps1 Match 段键值保留(ServerAliveInterval)' "$H/.ssh/config" 'ServerAliveInterval 30'
assert_file_has 'AC-2.1 ps1 Match 段键值保留(TCPKeepAlive)' "$H/.ssh/config" 'TCPKeepAlive yes'
assert_file_has 'AC-2.1 ps1 Match 行保留' "$H/.ssh/config" 'Match all'
assert_file_has 'AC-2.3 ps1 后续 Host 块保留' "$H/.ssh/config" 'after-block'

H=$(new_home match-mixed.config)
OUT=$(run_sh "$H" '1\nyes\n\n')
assert_file_has 'AC-2.1 sh Match 段键值保留' "$H/.ssh/config" 'ServerAliveInterval 30'
assert_file_has 'AC-2.1 sh Match 行保留' "$H/.ssh/config" 'Match all'
assert_file_has 'AC-2.3 sh 后续 Host 块保留' "$H/.ssh/config" 'after-block'

# ─────────────────────────────────────────────────────────────
section '5. CHG-000 回归（不得回退）'
# ─────────────────────────────────────────────────────────────
H=$(new_home chinese-comment.config)
OUT=$(run_ps "$H" '\n')
assert_out_has 'REG ps1 PS5.1 中文注释下仍识别 zh-block' "$OUT" 'zh-block'
assert_out_has 'REG ps1 中文注释下仍识别 zh-second' "$OUT" 'zh-second'
run_ps "$H" '1\nyes\n\n' >/dev/null
assert_file_has 'REG ps1 中文注释完好保留' "$H/.ssh/config" '生产服务器，别乱删'
assert_file_lacks 'REG ps1 zh-block 已删除' "$H/.ssh/config" 'zh-block'
if ls "$H/.ssh/"config.bak-* >/dev/null 2>&1; then pass 'REG ps1 config 时间戳备份已生成'; else fail 'REG ps1 config 时间戳备份已生成'; fi

H=$(new_home chinese-comment.config)
OUT=$(run_sh "$H" '\n')
assert_out_has 'REG sh 中文注释下仍识别 zh-block' "$OUT" 'zh-block'
run_sh "$H" '1\nyes\n\n' >/dev/null
assert_file_has 'REG sh 中文注释完好保留' "$H/.ssh/config" '生产服务器，别乱删'

# ─────────────────────────────────────────────────────────────
printf '\n══════════ 结果 ══════════\n'
printf '  PASS: %d\n  FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '\n失败用例:\n'
    for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n临时假 HOME 目录（可手工清理）: /tmp/tmp.*\n'
    exit 1
fi
printf '\n全部通过。\n'
exit 0
