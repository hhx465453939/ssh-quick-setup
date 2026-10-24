#!/usr/bin/env bash
# SSH 免密登录一键配置脚本 (Linux / macOS / WSL)
# 用法: bash ssh-setup.sh
#
# 两种模式：
#   [1] 服务端有密码     —— 本地生成密钥对，用密码上传公钥（传统流程）
#   [2] 服务端已下发私钥 —— 直接导入服务端下发的私钥，跳过生成与上传
# 脚本会先探测服务端允许的认证方式，并据此推荐模式。

set -euo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"

# Windows 上 HOME 可能未指向真实用户目录，则回退 USERPROFILE
if [[ ! -d "$HOME" && -n "${USERPROFILE:-}" ]]; then
    SSH_DIR="$USERPROFILE/.ssh"
    CONFIG_FILE="$SSH_DIR/config"
fi

# ── 颜色 ──────────────────────────────────────────────────────
step()  { echo -e "\n\033[36m>>> $1\033[0m"; }
ok()    { echo -e "  \033[32m[OK]\033[0m $1"; }
warn()  { echo -e "  \033[33m[!]\033[0m $1"; }
err()   { echo -e "  \033[31m[X]\033[0m $1"; }
info()  { echo -e "  \033[90m$1\033[0m"; }

# ════════════════════════════════════════════════════════════════
# 工具函数
# ════════════════════════════════════════════════════════════════

# 修复历史遗留的 UTF-8 BOM（OpenSSH 遇到 BOM 会放弃解析整个 config）
repair_config_bom() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local head3
    head3=$(head -c 3 "$CONFIG_FILE" | od -An -tx1 | tr -d ' \n')
    [[ "$head3" == "efbbbf" ]] || return 0
    # 已存在的备份不覆盖：留住最原始那份，便于回溯（与 ssh-setup.ps1 行为一致）
    [[ -f "$CONFIG_FILE.bak-bom" ]] || cp "$CONFIG_FILE" "$CONFIG_FILE.bak-bom"
    tail -c +4 "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    warn "检测到 config 带 UTF-8 BOM（OpenSSH 会拒绝解析整个 config），已自动修复"
    info "原始文件已备份: $CONFIG_FILE.bak-bom"
}

# 私钥权限收紧
set_key_perm() {
    chmod 600 "$1" 2>/dev/null || warn "chmod 600 失败: $1"
}

# 私钥格式识别
key_format() {
    local text="$1"
    if grep -q 'PuTTY-User-Key-File-[23]' <<< "$text"; then echo 'ppk'; return; fi
    if grep -q -- '-----BEGIN OPENSSH PRIVATE KEY-----' <<< "$text"; then echo 'openssh'; return; fi
    if grep -q -- '-----BEGIN RSA PRIVATE KEY-----' <<< "$text"; then echo 'pem-rsa'; return; fi
    if grep -q -- '-----BEGIN EC PRIVATE KEY-----' <<< "$text"; then echo 'pem-ec'; return; fi
    if grep -q -- '-----BEGIN DSA PRIVATE KEY-----' <<< "$text"; then echo 'pem-dsa'; return; fi
    if grep -q -- '-----BEGIN ENCRYPTED PRIVATE KEY-----' <<< "$text"; then echo 'pkcs8-enc'; return; fi
    if grep -q -- '-----BEGIN PRIVATE KEY-----' <<< "$text"; then echo 'pkcs8'; return; fi
    echo 'unknown'
}

# 读取指纹（-lf 只读公钥部分，无需口令）
key_fingerprint() {
    ssh-keygen -lf "$1" 2>/dev/null | head -1 || true
}

# 探测服务端允许的认证方式；失败返回空
probe_auth_methods() {
    local target_host="$1" port="$2" user="$3"
    local out
    out=$(ssh -F /dev/null -v \
            -o BatchMode=yes \
            -o ConnectTimeout=8 \
            -o PreferredAuthentications=none \
            -o StrictHostKeyChecking=accept-new \
            -p "$port" "${user}@${target_host}" true 2>&1 || true)
    local methods
    methods=$(grep -o 'Authentications that can continue:[^\r]*' <<< "$out" | head -1 | sed 's/.*: *//' | tr -d ' \r')
    echo "$methods"
}

# ── 模式 1：本地生成密钥对 ────────────────────────────────────
new_local_key() {
    local alias="$1"
    step "生成 Ed25519 密钥对..."

    KEY_FILE="$SSH_DIR/id_ed25519_$alias"

    # 注释里带时间戳：同一别名反复生成时，服务端 ssh-keygen -lf 能一眼看出哪把是最新的
    local COMMENT="${alias}-ssh-key-$(date +%Y%m%d-%H%M)"

    if [[ -f "$KEY_FILE" ]]; then
        warn "密钥文件已存在: $KEY_FILE"
        read -rp "  是否覆盖重新生成? (y/N): " REGEN
        if [[ "$REGEN" == "y" || "$REGEN" == "Y" ]]; then
            rm -f "$KEY_FILE" "$KEY_FILE.pub"
            if ! ssh-keygen -t ed25519 -C "$COMMENT" -f "$KEY_FILE" -N ""; then
                err "密钥生成失败。"
                return 1
            fi
            # 以产物为准：keygen 返回 0 但公钥没落地（磁盘满、权限异常）也算失败
            if [[ ! -f "$KEY_FILE" || ! -f "$KEY_FILE.pub" ]]; then
                err "密钥文件不完整 (私钥或公钥缺失)，已中止。"
                return 1
            fi
            ok "密钥已重新生成"
        else
            info "保留现有密钥，跳过生成。"
        fi
    else
        if ! ssh-keygen -t ed25519 -C "$COMMENT" -f "$KEY_FILE" -N ""; then
            err "密钥生成失败。"
            return 1
        fi
        if [[ ! -f "$KEY_FILE" || ! -f "$KEY_FILE.pub" ]]; then
            err "密钥文件不完整 (私钥或公钥缺失)，已中止。"
            return 1
        fi
    fi

    set_key_perm "$KEY_FILE"

    if ! ssh-keygen -y -P "" -f "$KEY_FILE" >/dev/null 2>&1; then
        warn "该私钥带口令，每次登录需输入口令（可执行 ssh-keygen -p -f \"$KEY_FILE\" 修改）。"
    fi

    ok "私钥: $KEY_FILE"
    ok "公钥: $KEY_FILE.pub"
    local FP1
    FP1=$( { key_fingerprint "$KEY_FILE" | sed -n 's/.*\(SHA256:[A-Za-z0-9+/=]*\).*/\1/p' | head -1; } || true )
    [[ -n "$FP1" ]] && info "指纹: $FP1  (复制留底，日后可在服务端核对)"
}

# ── 模式 2：导入服务端下发的私钥 ──────────────────────────────
import_server_key() {
    local alias="$1"
    step "导入服务端下发的私钥..."
    info "服务端已预置对应公钥，此模式不生成新密钥、也不上传任何东西。"

    local attempt src text fmt norm tmp fp type prefix dest
    for attempt in 1 2 3; do
        read -rp "  请输入私钥文件路径 (可直接把文件拖进终端): " src
        # 去掉两端空白与成对引号
        src="$(echo "$src" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
        if [[ -z "$src" ]]; then
            err "路径不能为空。"
            continue
        fi
        src="${src/#\~/$HOME}"
        if [[ ! -f "$src" ]]; then
            err "文件不存在: $src"
            continue
        fi

        text=$(cat "$src")
        fmt=$(key_format "$text")

        case "$fmt" in
            ppk)
                err "这是 PuTTY 专用格式 (.ppk)，OpenSSH 无法直接使用。"
                info "请先转换: puttygen \"$src\" -O private-openssh -o \"$SSH_DIR/id_rsa_$alias\""
                return 1 ;;
            pkcs8-enc)
                err "这是加密的 PKCS#8 私钥（BEGIN ENCRYPTED PRIVATE KEY），需先解密。"
                info "请执行: openssl pkcs8 -in \"$src\" -out \"$SSH_DIR/id_rsa_$alias\""
                return 1 ;;
            unknown)
                err "无法识别的私钥格式（未找到 -----BEGIN ... PRIVATE KEY----- 标记）。"
                info "请确认文件内容是完整私钥，而不是公钥或账号说明。"
                continue ;;
        esac

        # 归一化：剥离 CRLF（新版 OpenSSH 会以 invalid format 拒读 CRLF 私钥）
        norm=$(tr -d '\r' < "$src")
        [[ "$norm" == *$'\n' ]] || norm="$norm"$'\n'

        # 先落到临时文件校验，通过才动 $SSH_DIR
        tmp=$(mktemp)
        fp=$(printf '%s' "$norm" > "$tmp" && chmod 600 "$tmp" && key_fingerprint "$tmp")
        rm -f "$tmp"

        if [[ -z "$fp" ]]; then
            err "私钥无法解析。"
            info "常见原因: ① 从网页复制时漏行/串行；② 文件被换行符或 BOM 破坏；③ 需要口令。"
            [[ $attempt -lt 3 ]] && info "请重新提供文件路径（剩余 $((3 - attempt)) 次）。"
            continue
        fi

        type=$(sed -n 's/.*(\([A-Za-z0-9]*\)).*/\1/p' <<< "$fp" | tr '[:upper:]' '[:lower:]')
        case "$type" in
            ed25519) prefix="id_ed25519" ;;
            ecdsa)   prefix="id_ecdsa" ;;
            dsa)     prefix="id_dsa" ;;
            *)       prefix="id_rsa" ;;
        esac
        dest="$SSH_DIR/${prefix}_$alias"

        if [[ "$(cd "$(dirname "$src")" && pwd)/$(basename "$src")" == "$dest" ]]; then
            info "私钥已在目标位置，跳过复制。"
        elif [[ -e "$dest" ]]; then
            warn "目标已存在: $dest"
            read -rp "  是否覆盖? (y/N): " OV
            if [[ "$OV" != "y" && "$OV" != "Y" ]]; then
                info "已取消导入。"
                return 1
            fi
            printf '%s' "$norm" > "$dest"
        else
            printf '%s' "$norm" > "$dest"
        fi

        set_key_perm "$dest"

        # 顺带导出公钥便于核对；失败说明该私钥带口令
        if ssh-keygen -y -P "" -f "$dest" > "$dest.pub.raw" 2>/dev/null; then
            awk -v c="${alias}-ssh-key-$(date +%Y%m%d-%H%M)" '{print $1, $2, c}' "$dest.pub.raw" > "$dest.pub"
            rm -f "$dest.pub.raw"
            ok "已导出公钥: $dest.pub"
        else
            rm -f "$dest.pub.raw" "$dest.pub"
            warn "该私钥带口令，每次登录需输入口令（可执行 ssh-keygen -p -f \"$dest\" 修改）。"
        fi

        ok "已导入私钥: $dest"
        info "指纹: $fp"
        KEY_FILE="$dest"
        return 0
    done

    err "导入失败（已尝试 3 次）。"
    return 1
}

# ── 模式 1 的收尾：上传公钥 ───────────────────────────────────
send_public_key() {
    local key_file="$1" target_host="$2" port="$3" user="$4" auth="$5"

    step "上传公钥到服务器 (需要输入一次密码)..."

    # 公钥文件缺失时提前失败：给出可读的提示，而不是让 ssh-copy-id 报一串
    # 难懂的路径错误（脚本开了 pipefail，管道本身不会假绿）
    if [[ ! -f "$key_file.pub" ]]; then
        err "未找到公钥文件: $key_file.pub"
        info "请确认密钥已成功生成；若服务端已下发私钥，请改用模式 [2] 导入。"
        return 1
    fi

    if [[ -n "$auth" && "$auth" != *password* ]]; then
        warn "探测到服务端只允许 publickey 认证，本步骤大概率失败。"
        info "若这台服务器属于『服务端下发私钥』类型，请改用模式 [2] 导入。"
    fi

    read -rp "  现在上传公钥吗? (Y/n): " UPLOAD
    UPLOAD=${UPLOAD:-Y}

    local remote_cmd="mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys"

    if [[ "$UPLOAD" == "n" || "$UPLOAD" == "N" ]]; then
        warn "跳过上传。稍后可手动执行:"
        info "ssh-copy-id -i $key_file.pub -p $port ${user}@${target_host}"
        return 1
    fi

    local i
    for i in 1 2 3; do
        info "第 $i 次尝试..."
        if ssh-copy-id -i "$key_file.pub" -p "$port" "${user}@${target_host}" 2>/dev/null; then
            ok "公钥上传成功!"
            return 0
        fi
        # ssh-copy-id 失败时尝试 pipe 方式（脚本开了 pipefail，cat 读失败不会被
        # 静默吞掉成"上传成功"）
        if cat "$key_file.pub" | ssh -p "$port" "${user}@${target_host}" "$remote_cmd" 2>/dev/null; then
            ok "公钥上传成功!"
            return 0
        fi
        warn "上传失败，请检查密码是否正确。"
        warn "注意：每次密码错误都会计入服务端 fail2ban 计数，累计可能再次封禁你的 IP。"
        [[ $i -lt 3 ]] && read -rp "  确认密码无误后再按回车重试 (Ctrl+C 中止): " _
    done

    warn "自动上传失败。"
    if [[ -n "$auth" && "$auth" != *password* ]]; then
        info "服务端认证方式为 [$auth]，不含 password —— 无法用密码上传公钥。"
        info "请改用模式 [2] 导入服务端下发的私钥。"
    fi
    info "也可手动执行:"
    info "ssh-copy-id -i $key_file.pub -p $port ${user}@${target_host}"
    return 1
}

# ════════════════════════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════════════════════════

echo ""
echo -e "\033[35m=====================================\033[0m"
echo -e "\033[35m  SSH 免密登录配置向导 (Linux/WSL)\033[0m"
echo -e "\033[35m=====================================\033[0m"

for tool in ssh ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { err "未找到 $tool，请先安装 OpenSSH 客户端。"; exit 1; }
done

mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
repair_config_bom

# ── 第 1 步：收集信息 ─────────────────────────────────────────
read -rp $'\n  [1/4] 请输入服务器别名 (如 xiyou, nas, dev): ' ALIAS
[[ -z "$ALIAS" ]] && { echo "别名不能为空，退出。"; exit 1; }
ALIAS=$(echo "$ALIAS" | tr '[:upper:]' '[:lower:]')

read -rp "  [2/4] 请输入服务器地址 (IP 或域名): " HOSTNAME_VAL
[[ -z "$HOSTNAME_VAL" ]] && { echo "地址不能为空，退出。"; exit 1; }

read -rp "  [3/4] 请输入 SSH 端口 (直接回车默认 22): " PORT
PORT=${PORT:-22}

read -rp "  [4/4] 请输入登录用户名: " USERNAME
[[ -z "$USERNAME" ]] && { echo "用户名不能为空，退出。"; exit 1; }

# ── 第 2 步：探测认证方式并选择模式 ───────────────────────────
step "探测服务端允许的认证方式..."

AUTH_METHODS=$(probe_auth_methods "$HOSTNAME_VAL" "$PORT" "$USERNAME")
REC_MODE=1

if [[ -n "$AUTH_METHODS" ]]; then
    info "服务端允许: $AUTH_METHODS"
    if [[ "$AUTH_METHODS" != *password* ]]; then
        REC_MODE=2
        warn "服务端已关闭密码认证，只能用公钥登录 → 推荐模式 [2]"
    fi
else
    warn "未探测到认证方式（网络不可达 / 服务端未响应），按默认模式 [1] 继续。"
fi

step "请选择密钥模式"
if [[ -n "$AUTH_METHODS" ]]; then info "探测结果: 服务端允许的认证方式 = $AUTH_METHODS"; else info "探测结果: 未知"; fi
info "[1] 服务端有密码      —— 本地生成新密钥对，用密码上传公钥"
info "[2] 服务端已下发私钥  —— 导入下发的私钥，跳过生成与上传"

read -rp $'\n  请选择 (1/2，回车采用推荐 ['"$REC_MODE"']): ' MODE_INPUT
if [[ -z "$MODE_INPUT" ]]; then
    MODE=$REC_MODE
elif [[ "$MODE_INPUT" == "1" || "$MODE_INPUT" == "2" ]]; then
    MODE=$MODE_INPUT
else
    echo "无效输入，退出。"; exit 1
fi

# ── 第 3 步：准备私钥 ────────────────────────────────────────
# 两个函数把「私钥路径」写入全局 KEY_FILE，进度信息直接打印；
# 不能用 $(...) 捕获返回值，否则进度信息会被一起吞掉。
KEY_FILE=""
if [[ "$MODE" == "1" ]]; then
    new_local_key "$ALIAS" || { err "私钥准备失败，退出。"; exit 1; }
else
    import_server_key "$ALIAS" || { err "私钥准备失败，退出。"; exit 1; }
fi
if [[ -z "$KEY_FILE" || ! -f "$KEY_FILE" ]]; then
    err "私钥准备失败，退出。"
    if [[ -n "$KEY_FILE" ]]; then
        info "实际路径不存在: $KEY_FILE"
    fi
    exit 1
fi

# ── 第 4 步：上传公钥（仅模式 1） ─────────────────────────────
if [[ "$MODE" == "1" ]]; then
    send_public_key "$KEY_FILE" "$HOSTNAME_VAL" "$PORT" "$USERNAME" "$AUTH_METHODS" || true
else
    step "跳过公钥上传"
    info "模式 [2]：公钥已由服务端预置，无需上传。"
fi

# ── 第 5 步：写入 SSH config ─────────────────────────────────
step "配置 SSH config..."

touch "$CONFIG_FILE"

KEY_NAME=$(basename "$KEY_FILE")

# Host 名匹配放宽到 ps1 同等宽容度：行首可有空白、Host 与别名间可多空格。
# 原写法 "^Host $ALIAS$" 只认「行首 Host+单空格」，遇到手工整理的缩进/对齐写法会误判
# 为「不存在」而重复追写第二个 Host 块，且前一块的 IdentityFile 会覆盖后一块。
if grep -Eq "^[[:space:]]*Host[[:space:]]+${ALIAS}[[:space:]]*$" "$CONFIG_FILE" 2>/dev/null; then
    warn "SSH config 中已存在 Host $ALIAS 配置，跳过写入。"
    info "如需修改，请手动编辑: $CONFIG_FILE"

    # 旧配置里的 IdentityFile 可能指向已不存在的密钥（上次运行中断/写入坏路径的残留），
    # 这类残留会让免密测试必然失败，看起来却像『服务器问题』，所以单独校验一次。
    # 注：变量不用 local（此处位于脚本主体，非函数内）
    ID_FILES=()
    while IFS= read -r id_path; do
        [[ -n "$id_path" ]] || continue
        ID_FILES+=("${id_path/#\~/$HOME}")
    done < <(ssh -G "$ALIAS" 2>/dev/null | awk 'tolower($1) == "identityfile" { $1 = ""; sub(/^[[:space:]]+/, ""); print }')
    BAD_ID=()
    for id_path in ${ID_FILES[@]:+"${ID_FILES[@]}"}; do
        [[ -n "$id_path" ]] || continue
        [[ -f "$id_path" ]] || BAD_ID+=("$id_path")
    done
    if [[ ${#BAD_ID[@]} -gt 0 ]]; then
        warn "该 Host 的 IdentityFile 指向不存在的文件，免密测试必然失败:"
        for id_path in "${BAD_ID[@]}"; do info "  $id_path"; done
        info "修复：删掉 config 里 Host $ALIAS 整段后重跑本脚本（或把 IdentityFile 改为 ~/.ssh/$KEY_NAME）"
    fi
else
    # 写入标记行：记录模式/密钥/指纹，供日后核对与 ssh-remove 判断风险（mode=2 为服务端下发私钥）
    FP_HASH=$( { key_fingerprint "$KEY_FILE" | sed -n 's/.*\(SHA256:[A-Za-z0-9+/=]*\).*/\1/p' | head -1; } || true )
    CREATED=$(date +%Y%m%d-%H%M)

    cat >> "$CONFIG_FILE" <<EOF

Host $ALIAS
    # ssh-quick-setup: mode=$MODE key=$KEY_NAME ${FP_HASH:+fp=$FP_HASH }created=$CREATED
    HostName $HOSTNAME_VAL
    Port $PORT
    User $USERNAME
    IdentityFile ~/.ssh/$KEY_NAME
    IdentitiesOnly yes
    ServerAliveInterval 60
EOF
    ok "已添加 Host $ALIAS 到 SSH config"
fi

if ssh -G "$ALIAS" >/dev/null 2>&1; then
    ok "config 语法校验通过"
else
    warn "config 解析异常，请检查 $CONFIG_FILE"
fi

# ── 第 6 步：测试连接 ────────────────────────────────────────
step "测试免密连接..."

read -rp "  现在测试 ssh $ALIAS 连接吗? (Y/n): " TEST_CONN
TEST_CONN=${TEST_CONN:-Y}

if [[ "$TEST_CONN" != "n" && "$TEST_CONN" != "N" ]]; then
    info "执行: ssh $ALIAS 'echo SSH 免密连接成功!'\n"
    if ssh -o BatchMode=yes -o ConnectTimeout=15 "$ALIAS" "echo 'SSH 免密连接成功!'"; then
        ok "免密登录配置完成!"
    else
        warn "连接测试失败，请检查网络或服务器配置。"
        info "排查命令: ssh -v -i $KEY_FILE -p $PORT ${USERNAME}@${HOSTNAME_VAL}"
    fi
fi

# ── 总结 ──────────────────────────────────────────────────────
echo ""
echo -e "\033[35m=====================================\033[0m"
echo -e "\033[35m  配置总结\033[0m"
echo -e "\033[35m=====================================\033[0m"
if [[ "$MODE" == "1" ]]; then
    echo -e "  模式       : [1] 生成新密钥并上传公钥"
else
    echo -e "  模式       : [2] 导入服务端下发私钥"
fi
echo -e "  服务器别名 : $ALIAS"
echo -e "  地址       : $HOSTNAME_VAL"
echo -e "  端口       : $PORT"
echo -e "  用户       : $USERNAME"
echo -e "  私钥       : $KEY_FILE"
FP_OUT=$( { key_fingerprint "$KEY_FILE" | sed -n 's/.*\(SHA256:[A-Za-z0-9+/=]*\).*/\1/p' | head -1; } || true )
if [[ -n "$FP_OUT" ]]; then
    echo -e "  公钥指纹   : $FP_OUT"
    echo -e "  \033[90m远端核对   : ssh -p $PORT ${USERNAME}@${HOSTNAME_VAL} \"ssh-keygen -lf ~/.ssh/authorized_keys\"\033[0m"
fi
echo -e "  \033[32m快捷命令   : ssh $ALIAS\033[0m"
echo ""
echo -e "  \033[90m如需删除配置: bash ssh-remove.sh\033[0m"
echo -e "\033[35m=====================================\033[0m"
echo ""
