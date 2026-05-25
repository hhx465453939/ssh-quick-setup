# SSH 免密登录快速配置工具

一键配置 / 删除 SSH 密钥认证，实现 `ssh <别名>` 免密登录远程服务器。

## 文件说明

| 文件 | 说明 |
|------|------|
| `ssh-setup.ps1` | 新建连接 - Windows PowerShell |
| `ssh-setup.sh` | 新建连接 - Linux/macOS/WSL |
| `ssh-remove.ps1` | 删除连接 - Windows PowerShell |
| `ssh-remove.sh` | 删除连接 - Linux/macOS/WSL |

---

## 一、新建 SSH 连接

### Windows PowerShell

右键 `ssh-setup.ps1` → 使用 PowerShell 运行，或：

```powershell
cd "$env:USERPROFILE\Desktop\ssh-quick-setup"
.\ssh-setup.ps1
```

> 如果提示执行策略限制，先执行一次：
> ```powershell
> Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
> ```

### Linux / macOS / WSL

```bash
cd ~/Desktop/ssh-quick-setup
bash ssh-setup.sh
```

### 引导流程

```
[1/5] 输入服务器别名    → 如 xiyou、nas、dev
[2/5] 输入服务器地址    → IP 或域名
[3/5] 输入 SSH 端口     → 默认 22
[4/5] 输入登录用户名
      ↓
      自动生成 Ed25519 密钥对 (id_ed25519_<别名>)
      ↓
[5/5] 上传公钥到服务器   → 输入一次密码
      ↓
      自动写入 ~/.ssh/config
      ↓
      测试免密连接
```

### 配置完成后

```bash
ssh xiyou    # 直接用别名登录，无需密码
```

---

## 二、删除 SSH 连接

### Windows PowerShell

```powershell
.\ssh-remove.ps1
```

### Linux / macOS / WSL

```bash
bash ssh-remove.sh
```

### 引导流程

```
[1] 列出所有已配置的 SSH 连接
      ↓
[2] 选择要删除的连接编号
      ↓
    显示详情，确认输入 yes
      ↓
[3] 自动删除：
    ├── 本地密钥文件 (id_ed25519_<别名> / .pub)
    ├── SSH config 中对应的 Host 段落
    └── 可选：远程服务器 authorized_keys 中的公钥
```

### 删除内容说明

| 操作 | 说明 |
|------|------|
| 删除密钥文件 | 移除 `~/.ssh/id_ed25519_<别名>` 及 `.pub` |
| 清理 SSH config | 从 `~/.ssh/config` 中移除 `Host <别名>` 段落 |
| 清理远程公钥 | 可选，从服务器 `~/.ssh/authorized_keys` 移除对应条目 |

> 删除操作需输入 `yes` 二次确认，防止误删。

---

## 三、手动操作（补充）

如果脚本无法使用，可手动执行：

### 手动新建连接

```powershell
# 生成密钥
ssh-keygen -t ed25519 -C "别名" -f "$env:USERPROFILE\.ssh\id_ed25519_别名"

# 上传公钥
type "$env:USERPROFILE\.ssh\id_ed25519_别名.pub" | ssh -p 端口 用户名@地址 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### 手动删除连接

1. 编辑 `~/.ssh/config`，删除对应的 `Host <别名>` 段落
2. 删除密钥文件：`id_ed25519_<别名>` 和 `id_ed25519_<别名>.pub`
3. 登录远程服务器，从 `~/.ssh/authorized_keys` 中删除对应公钥行

---

## 四、生成的文件位置

| 文件 | Windows | Linux/WSL |
|------|---------|-----------|
| 密钥对 | `C:\Users\<用户>\.ssh\id_ed25519_<别名>` | `~/.ssh/id_ed25519_<别名>` |
| SSH 配置 | `C:\Users\<用户>\.ssh\config` | `~/.ssh/config` |

## 五、注意事项

- 私钥文件（无 `.pub` 后缀）**绝对不要泄露或发送给任何人**
- 同一别名重复运行 setup 会询问是否覆盖密钥
- SSH config 中已有同名 Host 会跳过，不会覆盖
- 删除操作需输入 `yes` 确认，不会静默删除
- 远程公钥清理为可选项，跳过不影响本地配置删除
