#!/usr/bin/env bash
# SSH 配置删除脚本 (Linux / macOS / WSL)
# 用法: bash ssh-remove.sh

set -euo pipefail

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"

# Windows 上 HOME 可能未指向真实用户目录，则回退 USERPROFILE
if [[ ! -d "$HOME" && -n "${USERPROFILE:-}" ]]; then
    SSH_DIR="$USERPROFILE/.ssh"
    CONFIG_FILE="$SSH_DIR/config"
fi

# 修复历史遗留的 UTF-8 BOM（OpenSSH 遇到 BOM 会放弃解析整个 config）
repair_config_bom() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    local head3
    head3=$(head -c 3 "$CONFIG_FILE" | od -An -tx1 | tr -d ' \n')
    [[ "$head3" == "efbbbf" ]] || return 0
    # 已存在的备份不覆盖：留住最原始那份（与 ssh-setup.sh / ssh-setup.ps1 一致）
    [[ -f "$CONFIG_FILE.bak-bom" ]] || cp "$CONFIG_FILE" "$CONFIG_FILE.bak-bom"
    tail -c +4 "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    warn "检测到 config 带 UTF-8 BOM（OpenSSH 会拒绝解析整个 config），已自动修复"
    info "原始文件已备份: $CONFIG_FILE.bak-bom"
}

# ── 颜色 ──────────────────────────────────────────────────────
step()  { echo -e "\n\033[36m>>> $1\033[0m"; }
ok()    { echo -e "  \033[32m[OK]\033[0m $1"; }
warn()  { echo -e "  \033[33m[!]\033[0m $1"; }
err()   { echo -e "  \033[31m[X]\033[0m $1"; }
info()  { echo -e "  \033[90m$1\033[0m"; }

repair_config_bom

# ── 解析 SSH config ───────────────────────────────────────────
# 输出字段：first_alias|host|port|user|key|mode|fp|label|raw
#   first_alias 保持旧行为（删除匹配用，末字兼容前 7 字段位置）
#   label 展示（a,b,c）；raw 归一化别名串（通配保护判定用）
parse_ssh_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then return; fi

    local entry_first="" entry_label="" entry_raw=""
    local entry_host="" entry_port="" entry_user="" entry_key="" entry_mode="" entry_fp=""
    local in_block=false

    while IFS= read -r line; do
        # 必须取得【全部】别名：旧写法 ([^#[:space:]]+) 只取首名，
        # 导致 Host web1 web*.corp 这类块的通配保护失效（会被当普通块删掉）
        if [[ "$line" =~ ^[[:space:]]*Host[[:space:]]+(.*)$ ]]; then
            # 输出上一个条目
            if [[ -n "$entry_first" ]]; then
                echo "$entry_first|$entry_host|${entry_port:-22}|$entry_user|$entry_key|$entry_mode|$entry_fp|$entry_label|$entry_raw"
            fi
            local _raw="${BASH_REMATCH[1]}"
            _raw="${_raw%%#*}"          # 剥离行内注释
            local -a _names=()
            local _t
            for _t in $_raw; do _names+=("$_t"); done
            if [[ ${#_names[@]} -eq 0 ]]; then continue; fi
            entry_first="${_names[0]}"
            entry_raw="${_names[*]}"
            entry_label="$(IFS=,; printf '%s' "${_names[*]}")"
            entry_host=""; entry_port=""; entry_user=""; entry_key=""; entry_mode=""; entry_fp=""
            in_block=true
        elif $in_block; then
            [[ "$line" =~ ^[[:space:]]*HostName[[:space:]]+([^#[:space:]]+) ]] && entry_host="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^[[:space:]]*Port[[:space:]]+([^#[:space:]]+) ]]     && entry_port="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^[[:space:]]*User[[:space:]]+([^#[:space:]]+) ]]      && entry_user="${BASH_REMATCH[1]}"
            [[ "$line" =~ ^[[:space:]]*IdentityFile[[:space:]]+([^#[:space:]]+) ]] && entry_key="${BASH_REMATCH[1]}"
            # 由 ssh-setup 写入的标记行：记录模式与密钥指纹
            [[ "$line" =~ ssh-quick-setup:.*mode=([0-9]) ]] && entry_mode="${BASH_REMATCH[1]}"
            [[ "$line" =~ ssh-quick-setup:.*fp=([^[:space:]]+) ]] && entry_fp="${BASH_REMATCH[1]}"
        fi
    done < "$CONFIG_FILE"

    # 输出最后一个条目
    if [[ -n "$entry_first" ]]; then
        echo "$entry_first|$entry_host|${entry_port:-22}|$entry_user|$entry_key|$entry_mode|$entry_fp|$entry_label|$entry_raw"
    fi
}

# ── 从 config 中删除指定 Host ─────────────────────────────────
remove_config_entry() {
    local alias="$1"
    local tmpfile backup alias_esc
    tmpfile=$(mktemp)

    # 删除是不可逆操作：改写前留一份带时间戳备份（旧版直接覆盖，误删无法回滚）
    backup="$CONFIG_FILE.bak-$(date +%Y%m%d-%H%M%S)"
    if cp "$CONFIG_FILE" "$backup" 2>/dev/null; then
        info "config 已备份: $backup"
    fi

    # 别名必须转义后再进正则：含 . * + 等元字符时未转义会误匹配到别的 Host
    alias_esc=$(printf '%s' "$alias" | sed 's/[][\.*^$+?(){}|]/\\&/g')

    local in_block=false skip=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*Host[[:space:]]+${alias_esc}([[:space:]]|$) ]]; then
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

    # 删除尾部空行，只保留一个结尾换行
    # （原来用 sed -e :a -e '/^\n*$/{$d;N;ba' 少了收尾的 -e '}'，在 GNU sed 下会报 unmatched '{' 并中断）
    awk 'NR>0 {l[NR]=$0} END {last=NR; while (last>0 && l[last]=="") last--; for (i=1;i<=last;i++) print l[i]}' "$tmpfile" > "$CONFIG_FILE"
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
# 不能用 mapfile/readarray：它们是 bash 4.0+ 才有的命令，
# 而 macOS 系统自带的 /bin/bash 是 3.2（2007 年版本），跑到这行会直接
# "mapfile: command not found" 把整个脚本干掉。改用 bash 3.2 也支持的 while read。
ENTRIES=()
while IFS= read -r _entry; do
    [[ -n "$_entry" ]] && ENTRIES+=("$_entry")
done < <(parse_ssh_config)

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
    warn "SSH config 中没有已配置的 Host。"
    exit 0
fi

echo ""
echo -e "  当前已配置的 SSH 连接:"
echo -e "  \033[90m-------------------------------\033[0m"
for i in "${!ENTRIES[@]}"; do
    IFS='|' read -r name host port user key _mode _fp label raw <<< "${ENTRIES[$i]}"
    [[ -n "${label:-}" ]] || label="$name"
    tag=""
    # 任一名含通配符即整块受保护（Host * / Host web1 web*.corp）
    [[ "${raw:-$name}" == *[*?]* ]] && tag="   <- 通配符/条件段，禁止删除"
    printf "  \033[97m[%d] %-20s %s@%s:%s%s\033[0m\n" "$((i+1))" "$label" "$user" "$host" "$port" "$tag"
done
echo -e "  \033[90m-------------------------------\033[0m"

# ── 选择 ───────────────────────────────────────────────────────
read -rp $'\n  输入编号选择要删除的连接 (直接回车取消): ' CHOICE
[[ -z "$CHOICE" ]] && { info "已取消。"; exit 0; }

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [[ "$CHOICE" -lt 1 ]] || [[ "$CHOICE" -gt ${#ENTRIES[@]} ]]; then
    err "无效的编号。"; exit 1
fi

IFS='|' read -r ALIAS HOST_NAME PORT USER_NAME KEY_FILE MODE FP ALIAS_LABEL ALIAS_RAW <<< "${ENTRIES[$((CHOICE-1))]}"
ALIAS_LABEL="${ALIAS_LABEL:-$ALIAS}"
ALIAS_RAW="${ALIAS_RAW:-$ALIAS}"

# 任一名含通配符即整块受保护。旧版只看首名，会把 Host web1 web*.corp 当普通块删掉。
if [[ "$ALIAS_RAW" == *[*?]* ]]; then
    err "条目 [$ALIAS_LABEL] 是通配符/条件段（如 Host *），删除会破坏所有连接的默认配置，已拒绝。"
    info "如确实要清理，请手动编辑: $CONFIG_FILE"
    exit 1
fi

# 密钥路径优先取自 config 里的 IdentityFile（兼容导入模式下的 id_rsa_<别名>）
KEY_PATH=""
if [[ -n "$KEY_FILE" ]]; then
    KEY_PATH="${KEY_FILE/#\~/$HOME}"
    KEY_PATH="${KEY_PATH/#\~/$SSH_DIR}"
    [[ "$KEY_PATH" == /* || "$KEY_PATH" == [A-Za-z]:* ]] || KEY_PATH="$SSH_DIR/$KEY_PATH"
    [[ -f "$KEY_PATH" ]] || KEY_PATH=""
fi
if [[ -z "$KEY_PATH" && -f "$SSH_DIR/id_ed25519_$ALIAS" ]]; then
    KEY_PATH="$SSH_DIR/id_ed25519_$ALIAS"
fi
KEY_BASENAME="$(basename "${KEY_PATH:-id_ed25519_$ALIAS}")"
KEY_PUB_PATH="${KEY_PATH:+$KEY_PATH.pub}"

echo ""
echo -e "  \033[33m即将删除:\033[0m"
echo -e "  \033[90m-------------------------------\033[0m"
echo -e "  别名   : $ALIAS_LABEL"
echo -e "  地址   : $HOST_NAME"
echo -e "  端口   : $PORT"
echo -e "  用户   : $USER_NAME"
[[ -n "$KEY_PATH" ]] && echo -e "  密钥   : $KEY_PATH"
[[ -n "$KEY_PUB_PATH" && -f "$KEY_PUB_PATH" ]] && echo -e "  公钥   : $KEY_PUB_PATH"

# ── 采集公钥指纹与公钥内容（必须在删除本地文件之前！） ────────
PUB_BLOB=""
KEY_FP=""
if [[ -n "$KEY_PATH" && -f "$KEY_PATH" ]]; then
    PUB_BLOB=$( { ssh-keygen -y -P "" -f "$KEY_PATH" 2>/dev/null | awk '{print $1" "$2}'; } || true)
    KEY_FP=$( { ssh-keygen -lf "$KEY_PATH" 2>/dev/null | sed -n 's/.*\(SHA256:[A-Za-z0-9+/=]*\).*/\1/p' | head -1; } || true)
fi
if [[ -z "$PUB_BLOB" && -n "$KEY_PUB_PATH" && -f "$KEY_PUB_PATH" ]]; then
    PUB_BLOB=$( { head -1 "$KEY_PUB_PATH" | awk '{print $1" "$2}'; } || true)
fi
[[ -z "$KEY_FP" && -n "$FP" ]] && KEY_FP="$FP"
[[ -n "$KEY_FP" ]] && echo -e "  指纹   : $KEY_FP"

echo -e "  \033[90m-------------------------------\033[0m"

# ── 确认 ───────────────────────────────────────────────────────
echo ""
echo -e "  \033[31m[!] 本地私钥删除后不可恢复\033[0m"
read -rp "  确认删除? 请输入 yes 继续: " CONFIRM
[[ "$CONFIRM" != "yes" ]] && { info "已取消。"; exit 0; }

DELETED=()
REMOTE_STATE="skipped"   # skipped|nofile|notfound|removed|failed|noblob
REMOTE_BACKUP=""
REMOTE_TOTAL=""
REMOTE_CNT=0
REMOTE_ERR=""

# ── 1. 远端清理（可选，但必须在删除本地私钥之前） ──────────────
echo ""
echo -e "  \033[97m远端 authorized_keys 清理（可选）\033[0m"
if [[ "$MODE" == "2" ]]; then
    warn "这条连接用的是【服务端下发的私钥】(mode=2)：服务端通常已关闭密码认证。"
    warn "若远端条目由服务商预置、且你没有其它登录方式，删掉它可能让你【永久失联】。"
elif [[ "$MODE" == "1" ]]; then
    info "这条连接用的是【本地生成并上传】的密钥 (mode=1)：远端条目是你自己装的，可以安全移除。"
fi
info "为什么现在做：本地私钥一旦删除就无法再用它登录，之后只能靠面板/其它密钥去改远端。"

read -rp "  现在就从远端移除这条公钥? (y/N): " CLEAN_REMOTE
if [[ "$CLEAN_REMOTE" == "y" || "$CLEAN_REMOTE" == "Y" ]]; then
    if [[ -z "$PUB_BLOB" ]]; then
        warn "本地公钥内容不可得（私钥缺失/无 .pub），无法做精确匹配。"
        REMOTE_STATE="noblob"
    elif [[ -z "$USER_NAME" || -z "$HOST_NAME" ]]; then
        warn "config 中信息不完整，无法自动清理。"
        REMOTE_STATE="noblob"
    else
        info "连接 ${USER_NAME}@${HOST_NAME}:${PORT} ..."
        # 远端脚本：先计数 → 备份+删除 → 再计数回读（闭环验证）
        REMOTE_SCRIPT=$(cat <<EOF
f="\$HOME/.ssh/authorized_keys"
if [ ! -f "\$f" ]; then echo "SQ_BEFORE=nofile"; exit 0; fi
b=\$(grep -cF '$PUB_BLOB' "\$f" 2>/dev/null)
[ -n "\$b" ] || b=0
echo "SQ_BEFORE=\$b"
if [ "\$b" -gt 0 ]; then
  bk="\$f.bak.\$(date +%Y%m%d-%H%M%S)"
  cp -p "\$f" "\$bk" && echo "SQ_BACKUP=\$bk"
  grep -vF '$PUB_BLOB' "\$f" > "\$f.sqnew"
  cat "\$f.sqnew" > "\$f"
  rm -f "\$f.sqnew"
  chmod 600 "\$f"
fi
a=\$(grep -cF '$PUB_BLOB' "\$f" 2>/dev/null)
[ -n "\$a" ] || a=0
echo "SQ_AFTER=\$a"
echo "SQ_TOTAL=\$(grep -c . "\$f" 2>/dev/null)"
EOF
)

        SSH_ARGS=(-o LogLevel=ERROR -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -p "$PORT")
        [[ -n "$KEY_PATH" && -f "$KEY_PATH" ]] && SSH_ARGS+=(-i "$KEY_PATH" -o IdentitiesOnly=yes)
        ROUT=$( { ssh "${SSH_ARGS[@]}" "${USER_NAME}@${HOST_NAME}" "$REMOTE_SCRIPT" 2>&1; } || true)

        if grep -q 'SQ_BEFORE=nofile' <<< "$ROUT"; then
            REMOTE_STATE="nofile"
        elif [[ "$ROUT" =~ SQ_BEFORE=([0-9]+) ]]; then
            REMOTE_CNT="${BASH_REMATCH[1]}"
            [[ "$ROUT" =~ SQ_BACKUP=([^[:space:]]+) ]] && REMOTE_BACKUP="${BASH_REMATCH[1]}"
            [[ "$ROUT" =~ SQ_TOTAL=([0-9]+) ]] && REMOTE_TOTAL="${BASH_REMATCH[1]}"
            after=-1
            [[ "$ROUT" =~ SQ_AFTER=([0-9]+) ]] && after="${BASH_REMATCH[1]}"
            if [[ "$REMOTE_CNT" -eq 0 ]]; then
                REMOTE_STATE="notfound"
            elif [[ "$after" -eq 0 ]]; then
                REMOTE_STATE="removed"
            else
                REMOTE_STATE="failed"
            fi
        else
            if grep -qE 'Permission denied|publickey' <<< "$ROUT"; then
                # 用这把私钥登不上远端 —— 通常就意味着远端已经没有它了
                REMOTE_STATE="denied"
            else
                REMOTE_STATE="failed"
            fi
            REMOTE_ERR=$(tr '\n' ' ' <<< "$ROUT" | cut -c1-300)
        fi

        case "$REMOTE_STATE" in
            nofile)   ok "远端没有 ~/.ssh/authorized_keys，无需清理。" ;;
            notfound) ok "远端 authorized_keys 里本来就没有这条公钥 → 无需清理（也没有误删任何条目）。" ;;
            removed)
                ok "远端已移除 $REMOTE_CNT 条匹配公钥，现有公钥 $REMOTE_TOTAL 条。"
                [[ -n "$REMOTE_BACKUP" ]] && info "远端备份: $REMOTE_BACKUP"
                ;;
            denied)
                ok "用该私钥登录远端被拒（Permission denied）→ 远端大概率已经没有这条公钥。"
                info "可用下方核对命令确认（期望输出 0）。"
                ;;
            *)
                err "远端清理未完成（可能：连不上 / 无权限 / 远端无 grep）。"
                [[ -n "$REMOTE_ERR" ]] && info "远端返回: $REMOTE_ERR"
                info "可手动执行（把 <公钥串> 换成上方检索字段）:"
                info "ssh -p $PORT ${USER_NAME}@${HOST_NAME} \"grep -vF '<公钥串>' ~/.ssh/authorized_keys > /tmp/ak && cat /tmp/ak > ~/.ssh/authorized_keys\""
                ;;
        esac
    fi
fi

# ── 2. 删除本地密钥 ──────────────────────────────────────────
if [[ -n "$KEY_PATH" ]] && { [[ -f "$KEY_PATH" ]] || [[ -f "$KEY_PUB_PATH" ]]; }; then
    rm -f "$KEY_PATH" "$KEY_PUB_PATH"
    ok "已删除本地密钥: $KEY_BASENAME / ${KEY_BASENAME}.pub"
    DELETED+=("密钥文件")
fi

# ── 3. 从 config 移除 ────────────────────────────────────────
remove_config_entry "$ALIAS"
ok "已从 SSH config 移除 Host $ALIAS"
DELETED+=("SSH config 条目")

# ── 总结 ──────────────────────────────────────────────────────
echo ""
echo -e "\033[35m=====================================\033[0m"
echo -e "\033[35m  删除完成\033[0m"
echo -e "\033[35m=====================================\033[0m"
if [[ ${#DELETED[@]} -gt 0 ]]; then
    for d in "${DELETED[@]}"; do ok "$d"; done
fi

# ── 闭环核对：远端到底还有没有这条公钥 ──────────────────────
echo ""
echo -e "\033[90m---------------------------------------------\033[0m"
echo -e "\033[36m  闭环核对（远端是否还留着这条公钥）\033[0m"
echo -e "\033[90m---------------------------------------------\033[0m"
[[ -n "$KEY_FP" ]] && echo -e "  \033[97m公钥指纹 : $KEY_FP\033[0m"
if [[ -n "$PUB_BLOB" ]]; then
    echo -e "  \033[97m检索字段（可完整复制，用作精确搜索）:\033[0m"
    echo -e "  \033[90m$PUB_BLOB\033[0m"
fi
echo ""
echo -e "  \033[90m# ① 列出远端全部公钥指纹（上面那把不应再出现）\033[0m"
echo -e "  \033[97mssh -p $PORT ${USER_NAME}@${HOST_NAME} \"ssh-keygen -lf ~/.ssh/authorized_keys\"\033[0m"
echo -e "  \033[90m# ② 精确搜索（期望输出 0）\033[0m"
echo -e "  \033[97mssh -p $PORT ${USER_NAME}@${HOST_NAME} \"grep -c -F '$PUB_BLOB' ~/.ssh/authorized_keys\"\033[0m"
echo -e "  \033[90m# ③ 查看远端备份（上面清理若输出过备份路径）\033[0m"
echo -e "  \033[97mssh -p $PORT ${USER_NAME}@${HOST_NAME} \"ls -l ~/.ssh/authorized_keys.bak.* 2>/dev/null\"\033[0m"
echo ""
echo -e "  \033[33m[!] 本地私钥已删除，执行以上命令需要你还有其它登录方式（另一把密钥/密码/面板）\033[0m"
echo -e "  \033[90m    若已无其它入口，请在服务商控制台/面板里核对 ~/.ssh/authorized_keys\033[0m"
echo ""
