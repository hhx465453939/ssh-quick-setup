#!/usr/bin/env bash
# SSH 免密登录一键配置脚本 (Linux / macOS / WSL)
# 用法: bash ssh-setup.sh

set -euo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"

# ── 颜色 ──────────────────────────────────────────────────────
step()  { echo -e "\n\033[36m>>> $1\033[0m"; }
ok()    { echo -e "  \033[32m[OK]\033[0m $1"; }
warn()  { echo -e "  \033[33m[!]\033[0m $1"; }
info()  { echo -e "  \033[90m$1\033[0m"; }

# ── 确保 .ssh 目录 ─────────────────────────────────────────────
mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

# ── 第 1 步：收集信息 ─────────────────────────────────────────
echo ""
echo -e "\033[35m=====================================\033[0m"
echo -e "\033[35m  SSH 免密登录配置向导 (Linux/WSL)\033[0m"
echo -e "\033[35m=====================================\033[0m"

read -rp $'\n  [1/5] 请输入服务器别名 (如 xiyou, nas, dev): ' ALIAS
[[ -z "$ALIAS" ]] && { echo "别名不能为空，退出。"; exit 1; }
ALIAS=$(echo "$ALIAS" | tr '[:upper:]' '[:lower:]')

read -rp "  [2/5] 请输入服务器地址 (IP 或域名): " HOSTNAME_VAL
[[ -z "$HOSTNAME_VAL" ]] && { echo "地址不能为空，退出。"; exit 1; }

read -rp "  [3/5] 请输入 SSH 端口 (直接回车默认 22): " PORT
PORT=${PORT:-22}

read -rp "  [4/5] 请输入登录用户名: " USERNAME
[[ -z "$USERNAME" ]] && { echo "用户名不能为空，退出。"; exit 1; }

# ── 第 2 步：生成密钥 ─────────────────────────────────────────
step "生成 Ed25519 密钥对..."

KEY_FILE="$SSH_DIR/id_ed25519_$ALIAS"

if [[ -f "$KEY_FILE" ]]; then
    warn "密钥文件已存在: $KEY_FILE"
    read -rp "  是否覆盖重新生成? (y/N): " REGEN
    if [[ "$REGEN" == "y" || "$REGEN" == "Y" ]]; then
        rm -f "$KEY_FILE" "$KEY_FILE.pub"
        ssh-keygen -t ed25519 -C "${ALIAS}-ssh-key" -f "$KEY_FILE" -N ""
        ok "密钥已重新生成"
    else
        info "保留现有密钥，跳过生成。"
    fi
else
    ssh-keygen -t ed25519 -C "${ALIAS}-ssh-key" -f "$KEY_FILE" -N ""
fi

ok "私钥: $KEY_FILE"
ok "公钥: $KEY_FILE.pub"

# ── 第 3 步：上传公钥 ─────────────────────────────────────────
step "上传公钥到服务器 (需要输入一次密码)..."

read -rp "  现在上传公钥吗? (Y/n): " UPLOAD
UPLOAD=${UPLOAD:-Y}

if [[ "$UPLOAD" == "n" || "$UPLOAD" == "N" ]]; then
    warn "跳过上传。稍后可手动执行:"
    info "ssh-copy-id -i $KEY_FILE.pub -p $PORT ${USERNAME}@${HOSTNAME_VAL}"
else
    UPLOADED=false
    for i in 1 2 3; do
        info "第 $i 次尝试..."
        if ssh-copy-id -i "$KEY_FILE.pub" -p "$PORT" "${USERNAME}@${HOSTNAME_VAL}" 2>/dev/null; then
            ok "公钥上传成功!"
            UPLOADED=true
            break
        else
            # ssh-copy-id 失败时尝试 pipe 方式
            if cat "$KEY_FILE.pub" | ssh -p "$PORT" "${USERNAME}@${HOSTNAME_VAL}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null; then
                ok "公钥上传成功!"
                UPLOADED=true
                break
            fi
            warn "上传失败，请检查密码是否正确。"
            [[ $i -lt 3 ]] && read -rp "  按回车重试..." _
        fi
    done

    if [[ "$UPLOADED" == "false" ]]; then
        warn "自动上传失败。可手动执行:"
        info "ssh-copy-id -i $KEY_FILE.pub -p $PORT ${USERNAME}@${HOSTNAME_VAL}"
    fi
fi

# ── 第 4 步：写入 SSH config ──────────────────────────────────
step "配置 SSH config..."

touch "$CONFIG_FILE"

if grep -q "^Host $ALIAS$" "$CONFIG_FILE" 2>/dev/null; then
    warn "SSH config 中已存在 Host $ALIAS 配置，跳过写入。"
    info "如需修改，请手动编辑: $CONFIG_FILE"
else
    cat >> "$CONFIG_FILE" <<EOF

Host $ALIAS
    HostName $HOSTNAME_VAL
    Port $PORT
    User $USERNAME
    IdentityFile ~/.ssh/id_ed25519_$ALIAS
EOF
    ok "已添加 Host $ALIAS 到 SSH config"
fi

# ── 第 5 步：测试连接 ─────────────────────────────────────────
step "测试免密连接..."

read -rp "  现在测试 ssh $ALIAS 连接吗? (Y/n): " TEST_CONN
TEST_CONN=${TEST_CONN:-Y}

if [[ "$TEST_CONN" != "n" && "$TEST_CONN" != "N" ]]; then
    info "执行: ssh $ALIAS 'echo SSH 免密连接成功!'\n"
    if ssh "$ALIAS" "echo 'SSH 免密连接成功!'"; then
        ok "免密登录配置完成!"
    else
        warn "连接测试失败，请检查网络或服务器配置。"
    fi
fi

# ── 总结 ──────────────────────────────────────────────────────
echo ""
echo -e "\033[35m=====================================\033[0m"
echo -e "\033[35m  配置总结\033[0m"
echo -e "\033[35m=====================================\033[0m"
echo -e "  服务器别名 : $ALIAS"
echo -e "  地址       : $HOSTNAME_VAL"
echo -e "  端口       : $PORT"
echo -e "  用户       : $USERNAME"
echo -e "  私钥       : $KEY_FILE"
echo -e "  公钥       : $KEY_FILE.pub"
echo -e "  \033[32m快捷命令   : ssh $ALIAS\033[0m"
echo ""
echo -e "  \033[90m如需删除配置: 编辑 $CONFIG_FILE 移除 Host $ALIAS 段落\033[0m"
echo -e "\033[35m=====================================\033[0m"
echo ""
