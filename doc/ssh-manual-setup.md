# SSH 免密登录 · 手动配置指南（跨平台）

> 当自动化脚本不可用，**或服务器由独立管理员控制**（用户无权自行配置服务器登录授权）时，按本流程手动完成密钥认证。
> 本过程涉及权限交接，**必须人工执行，不可依赖 AI agent 自动化运维**。

---

## 〇、占位符约定

下文命令中以下占位符需按实际替换：

| 占位符 | 含义 | 示例 |
|--------|------|------|
| `<别名>` | 本地 SSH 连接别名 | `prod` |
| `<用户名>` | 服务器登录账号 | `appuser` |
| `<地址>` | 服务器 IP 或域名 | `10.0.0.5` |
| `<端口>` | SSH 端口（默认 22） | `22` |

---

## 一、生成密钥对（本地）

**Windows (PowerShell)：**

```powershell
ssh-keygen -t ed25519 -C "<别名>" -f "$env:USERPROFILE\.ssh\id_ed25519_<别名>"
```

**Linux / macOS：**

```bash
ssh-keygen -t ed25519 -C "<别名>" -f ~/.ssh/id_ed25519_<别名>
```

> 按提示设置 passphrase（免密登录则直接回车留空）。
> ⚠️ PowerShell 下若要在命令行直接设空密码，参数须写 `-N '""'`（单引号包双引号），写成 `-N ""` 会报错。

---

## 二、取出公钥内容

**Windows：**

```powershell
Get-Content "$env:USERPROFILE\.ssh\id_ed25519_<别名>.pub"
```

**Linux / macOS：**

```bash
cat ~/.ssh/id_ed25519_<别名>.pub
```

输出形如 `ssh-ed25519 AAAA... <别名>`，**完整复制这一整行**。

---

## 三、将公钥交给管理员（核心交接步骤）

1. 通过安全渠道（加密通讯 / 工单系统）把上一步的公钥**整行**发给服务器管理员。
2. 管理员在服务器上为该用户授权，执行：

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo '<粘贴用户公钥整行>' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**管理员侧权限检查清单**（任一不符即认证失败）：

- `~/.ssh` 目录权限 `700`，属主为目标用户
- `~/.ssh/authorized_keys` 权限 `600`，属主为目标用户
- 用户家目录权限不可对 group/other 可写（≤ `755`）

---

## 四、修复私钥权限（仅 Windows 必做）

Windows 下若私钥被其他用户/组可读，OpenSSH 会拒绝加载并报 `UNPROTECTED PRIVATE KEY FILE`。收紧权限：

```powershell
icacls "$env:USERPROFILE\.ssh\id_ed25519_<别名>" /inheritance:r /grant:r "$($env:USERNAME):F"
```

Linux/macOS 生成时已是 `600`，无需此步。

---

## 五、配置别名并登录

**方式 A：直接命令登录**

```bash
ssh -i ~/.ssh/id_ed25519_<别名> -p <端口> <用户名>@<地址>
```

**方式 B：写入 `~/.ssh/config`（推荐，长期复用）**

在 `~/.ssh/config`（Windows 为 `$env:USERPROFILE\.ssh\config`）末尾追加：

```sshconfig
Host <别名>
    HostName <地址>
    Port <端口>
    User <用户名>
    IdentityFile ~/.ssh/id_ed25519_<别名>
    IdentitiesOnly yes
    ServerAliveInterval 60
```

之后直接：

```bash
ssh <别名>
```

---

## 六、常见问题

| 现象 | 原因 / 处理 |
|------|-------------|
| `Permission denied (publickey)` | 公钥未正确写入 `authorized_keys`，或管理员侧权限不符合第三节清单 |
| `UNPROTECTED PRIVATE KEY FILE` | 仅 Windows：执行第四节 `icacls` 命令 |
| 不确定哪一步出错 | 登录加 `-v` 调试：`ssh -v -i ~/.ssh/id_ed25519_<别名> <用户名>@<地址>`，观察是否出现 `Server accepts key` |

---

> **安全提示**：私钥文件（无 `.pub` 后缀）绝不外发；只需将 `.pub` 公钥交给管理员。
