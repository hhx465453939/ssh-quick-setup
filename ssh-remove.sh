#!/usr/bin/env bash
# SSH 配置删除脚本 (Linux / macOS / WSL)
# 用法: bash ssh-remove.sh

set -euo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"

# ── 颜色 ──────────────────────────────────────────────────────
step()  { echo -e "\n\033[36m>>> $1\033[0m"; }
ok()    { echo -e "  \033[32m[OK]\033[0m $1"; }
warn()  { echo -e "  \033[33m[!]\033[0m $1"; }
err()   { echo -e "  \033[31m[X]\033[0m $1"; }
info()  { echo -e "  \033[90m$1\033[0m"; }

# ── 解析 SSH config ───────────────────────────────────────────
parse_ssh_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then return; fi

    local entry_name="" entry_host="" entry_port="" entry_user="" entry_key=""
    local in_block=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*Host[[:space:]]+([^#[:space:]]+) ]]; then
            # 输出上一个条目
            if [[ -n "$entry_name" ]]; then
                echo "$entry_name|$entry_host|${entry_port:-22}|$entry_user|$entry_key"
            fi
            entry_name="${BASH_REMATCH[1]}"
            entry_host=""; entry_port=""; entry_user=""; entry_key=""
            in_block=true
        elif $in_block; then
            [[ "$line" =~ ^[[:space:]]*HostName[[:space:]]+([^#[:space:]]+) ]] && entry_host="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^[[:space:]]*Port[[:space:]]+([^#[:space:]]+) ]]     && entry_port="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^[[:space:]]*User[[:space:]]+([^#[:space:]]+) ]]      && entry_user="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^[[:space:]]*IdentityFile[[:space:]]+([^#[:space:]]+) ]] && entry_key="${BASH_REMATCH[1]}"
        fi
    done < "$CONFIG_FILE"

    # 输出最后一个条目
    if [[ -n "$entry_name" ]]; then
        echo "$entry_name|$entry_host|${entry_port:-22}|$entry_user|$entry_key"
    fi
}

# ── 从 config 中删除指定 Host ─────────────────────────────────
remove_config_entry() {
    local alias="$1"
    local tmpfile
    tmpfile=$(mktemp)

    local in_block=false skip=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*Host[[:space:]]+${alias}([[:space:]]|$) ]]; then
            skip=true
            continue
        fi
        if $skip; then
            # 下一个 Host 段开始 或 非缩进的非空行 → 停止跳过
            if [[ "$line" =~ ^[[:space:]]*Host[[:space:]]+ ]] || { [[ -n "$line" ]] && [[ ! "$line" =~ ^[[:space:]] ]]; }; then
                skip=false
            else
                continue
            fi
        fi
        echo "$line"
    done < "$CONFIG_FILE" > "$tmpfile"

    # 清理尾部空行
    local content
    content=$(sed -e :a -e '/^\n*$/{$d;N;ba' "$tmpfile")
    echo "$content" > "$CONFIG_FILE"
    rm -f "$tmpfile"
}

# ════════════════════════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════════════════════════

echo ""
echo -e "\033[35m=====================================\033[0m"
echo -e "\033[35m  SSH 配置管理 - 删除连接\033[0m"
echo -e "\033[35m=====================================\033[0m"

# ── 检查 config ────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
    err "未找到 SSH config: $CONFIG_FILE"
    info "没有任何已配置的 SSH 快捷连接。"
    exit 0
fi

# ── 列出已有配置 ──────────────────────────────────────────────
mapfile -t ENTRIES < <(parse_ssh_config)

if [[ ${#ENTRIES[@]} -eq 0 ]] || [[ -z "${ENTRIES[0]:-}" ]]; then
    warn "SSH config 中没有已配置的 Host。"
    exit 0
fi

echo ""
echo -e "  当前已配置的 SSH 连接:"
echo -e "  \033[90m-------------------------------\033[0m"
for i in "${!ENTRIES[@]}"; do
    IFS='|' read -r name host port user key <<< "${ENTRIES[$i]}"
    printf "  \033[97m[%d] %-12s %s@%s:%s\033[0m\n" "$((i+1))" "$name" "$user" "$host" "$port"
done
echo -e "  \033[90m-------------------------------\033[0m"

# ── 选择 ───────────────────────────────────────────────────────
read -rp $'\n  输入编号选择要删除的连接 (直接回车取消): ' CHOICE
[[ -z "$CHOICE" ]] && { info "已取消。"; exit 0; }

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [[ "$CHOICE" -lt 1 ]] || [[ "$CHOICE" -gt ${#ENTRIES[@]} ]]; then
    err "无效的编号。"; exit 1
fi

IFS='|' read -r ALIAS HOST_NAME PORT USER_NAME KEY_FILE <<< "${ENTRIES[$((CHOICE-1))]}"
KEY_BASENAME="id_ed25519_$ALIAS"
KEY_PATH="$SSH_DIR/$KEY_BASENAME"
KEY_PUB_PATH="$KEY_PATH.pub"

echo ""
echo -e "  \033[33m即将删除:\033[0m"
echo -e "  \033[90m-------------------------------\033[0m"
echo -e "  别名   : $ALIAS"
echo -e "  地址   : $HOST_NAME"
echo -e "  端口   : $PORT"
echo -e "  用户   : $USER_NAME"
[[ -f "$KEY_PATH" ]] && echo -e "  密钥   : $KEY_PATH"
echo -e "  \033[90m-------------------------------\033[0m"

# ── 确认 ───────────────────────────────────────────────────────
echo ""
echo -e "  \033[31m[!] 此操作不可自动撤销\033[0m"
read -rp "  确认删除? 请输入 yes 继续: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && { info "已取消。"; exit 0; }

# ── 执行删除 ──────────────────────────────────────────────────
DELETED=()

# 1. 删除密钥
if [[ -f "$KEY_PATH" ]] || [[ -f "$KEY_PUB_PATH" ]]; then
    rm -f "$KEY_PATH" "$KEY_PUB_PATH"
    ok "已删除密钥: $KEY_BASENAME / ${KEY_BASENAME}.pub"
    DELETED+=("密钥文件")
fi

# 2. 从 config 移除
remove_config_entry "$ALIAS"
ok "已从 SSH config 移除 Host $ALIAS"
DELETED+=("SSH config 条目")

# 3. 可选：清理远程公钥
echo ""
read -rp "  是否同时从远程服务器移除公钥? (y/N): " CLEAN_REMOTE
if [[ "$CLEAN_REMOTE" == "y" || "$CLEAN_REMOTE" == "Y" ]]; then
    if [[ -f "$KEY_PUB_PATH" ]]; then
        PUB_CONTENT=$(head -1 "$KEY_PUB_PATH" | tr -d '\n')
        ssh -p "$PORT" "${USER_NAME}@${HOST_NAME}" "sed -i '/${PUB_CONTENT//\//\\/}/d' ~/.ssh/authorized_keys 2>/dev/null" && \
            ok "已从远程服务器移除公钥" || \
            warn "远程操作失败，请手动编辑 ~/.ssh/authorized_keys"
    else
        warn "公钥文件已删除，无法精确匹配。"
        info "请手动登录 ${USER_NAME}@${HOST_NAME} -p ${PORT} 编辑 ~/.ssh/authorized_keys"
    fi
fi

# ── 总结 ──────────────────────────────────────────────────────
echo ""
echo -e "\033[35m=====================================\033[0m"
echo -e "\033[35m  删除完成\033[0m"
echo -e "\033[35m=====================================\033[0m"
for d in "${DELETED[@]}"; do ok "$d"; done
echo ""
