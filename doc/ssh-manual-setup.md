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

## 〇.五、先判断走哪个场景

先看服务端允许哪些认证方式（本命令不会真正登录）：

```bash
ssh -v -o BatchMode=yes -o PreferredAuthentications=none -p <端口> <用户名>@<地址> true 2>&1 | grep "Authentications that can continue"
```

| 输出 | 含义 | 走哪个场景 |
|------|------|------------|
| 含 `password` | 服务端允许密码登录，你可以自己把公钥装上去 | **场景 A**（第一~六节） |
| 只有 `publickey` | 服务端已关闭密码登录；公钥通常由服务商/管理员预置，并下发了配套私钥 | **场景 B**（第五节之后） |

> 若你手里已经有一个服务商/管理员给的**私钥文件**（常见于 VPS 开通邮件、面板下载），
> 直接走场景 B：**不要**再生成新密钥，也**不要**尝试上传公钥（密码通道既然关了，上传必然失败）。

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

## 五、配置别名并登录（场景 A / B 通用）

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

## 五之二、场景 B：服务端已下发私钥（无密码登录）

> 适用于：服务商/管理员给你一个**私钥文件**，服务器上已预置配套公钥，密码登录已关闭。
> 你需要的只是把这份私钥规范化地放到本机并指定给 `ssh` 使用。

### 1. 归一化并落盘（关键：去掉 BOM、CRLF → LF）

从网页/面板复制保存的私钥常带 `CRLF` 行尾或 UTF-8 BOM，
新版 OpenSSH 会直接报 `invalid format` / `is not a key file` 而不加载。

**Windows (PowerShell)：**

```powershell
$src  = "$env:USERPROFILE\Desktop\私钥_xxx.txt"
$text = ([System.IO.File]::ReadAllText($src) -replace "`r`n", "`n") -replace "`r", "`n"
[System.IO.File]::WriteAllText("$env:USERPROFILE\.ssh\id_rsa_<别名>", $text, (New-Object System.Text.UTF8Encoding($false)))
icacls "$env:USERPROFILE\.ssh\id_rsa_<别名>" /inheritance:r /grant:r "$env:USERNAME:F"
ssh-keygen -lf "$env:USERPROFILE\.ssh\id_rsa_<别名>"    # 能打印指纹即成功
```

**Linux / macOS：**

```bash
tr -d '\r' < ~/私钥_xxx.txt > ~/.ssh/id_rsa_<别名>
chmod 600 ~/.ssh/id_rsa_<别名>
ssh-keygen -lf ~/.ssh/id_rsa_<别名>    # 能打印指纹即成功
```

### 2. 配置别名并登录

按第五节方式 B 写入 `~/.ssh/config`，`IdentityFile` 指向刚落盘的私钥，然后：

```bash
ssh <别名>
```

### 3. 注意事项

- **不需要**执行第一~三节（不生成新密钥、不需要管理员再授权）。
- 若私钥有口令，每次登录需输入；可用 `ssh-keygen -p -f ~/.ssh/id_rsa_<别名>` 改口令。
- `.ppk`（PuTTY）或 `BEGIN ENCRYPTED PRIVATE KEY`（加密 PKCS#8）需先转换：
  `puttygen in.ppk -O private-openssh -o out.key` / `openssl pkcs8 -in in.pem -out out.key`。
- 配置成功后，建议删除桌面/下载目录里的私钥原件（那里会被同步、备份、被其它程序可读）。

---

## 五之三、确认/清理远端 authorized_keys（闭环核对）

删完本地密钥后，怎么知道远端那条公钥到底删没删？用下面两步。

### 1. 核对（只读，不改任何东西）

```bash
# ① 列出远端所有公钥的指纹，并逐条对照（最直观）
ssh -p <端口> <用户名>@<地址> "ssh-keygen -lf ~/.ssh/authorized_keys"

# ② 在本机取出你要找的那把公钥的指纹，用于对照
ssh-keygen -lf ~/.ssh/id_rsa_<别名>

# ③ 精确搜索（固定字符串整串匹配）：输出 0 表示已不在
ssh -p <端口> <用户名>@<地址> "grep -c -F 'ssh-ed25519 AAAA...' ~/.ssh/authorized_keys"
```

### 2. 清理（先备份、再删、再回读验证）

```bash
ssh -p <端口> <用户名>@<地址> '
  f="$HOME/.ssh/authorized_keys"
  blob="ssh-ed25519 AAAA..."        # 要删的公钥：type + base64（注释之前的部分）
  before=$(grep -cF "$blob" "$f" 2>/dev/null || true); [ -n "$before" ] || before=0
  echo "BEFORE=$before"
  if [ "$before" -gt 0 ]; then
    cp -p "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"                    # 先备份
    grep -vF "$blob" "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
    chmod 600 "$f"
  fi
  echo "AFTER=$(grep -cF "$blob" "$f" 2>/dev/null || true)"
'
```

要点：

- 用 `grep -F`（固定字符串）而不是 `sed` 的正则：公钥里的 `/` `+` `=` 在正则里是元字符，容易误伤或根本删不掉。
- 必须删前备份 + 删后回读计数：`BEFORE=1` / `AFTER=0` 才算真的删掉。
- **顺序很重要：先确认/清理远端，再删本地私钥**。本地私钥删掉后就登不上去了，想改远端只能靠面板或另一把密钥。
- 服务端已关闭密码认证、且远端条目是你唯一入口时，删掉它就是永久失联。

> 自动化脚本（`ssh-remove.ps1` / `ssh-remove.sh`）已经把上面这套做成了交互流程，
> 并在结束时打印可直接复制的核对命令。

---

## 六、常见问题

| 现象 | 原因 / 处理 |
|------|-------------|
| `Permission denied (publickey)` | 公钥未正确写入 `authorized_keys`，或管理员侧权限不符合第三节清单 |
| 想输密码却直接 `Permission denied (publickey)`（根本没给输密码的机会） | 服务端已关闭密码认证（`Authentications that can continue:` 只有 `publickey`）→ 改用场景 B，或让管理员先把你的公钥装上去 |
| `Load key ...: invalid format` / `is not a key file` | 私钥带 `CRLF` 行尾或 UTF-8 BOM → 按场景 B 第 1 步归一化为 LF 并去掉 BOM |
| 原有别名全部失效，报 `no argument after keyword "\357\273\277"` | `config` 文件带 UTF-8 BOM（PS 5.1 的 `Add-Content/Set-Content -Encoding UTF8` 会加 BOM）→ 以无 BOM 重写该文件 |
| 删完本地密钥后，不确定远端那条公钥是否也删了 | 见第五之三节：先 `ssh-keygen -lf ~/.ssh/authorized_keys` 列指纹对照，再 `grep -c -F '<公钥串>'` 确认输出 0 |
| `UNPROTECTED PRIVATE KEY FILE` | 仅 Windows：执行第四节 `icacls` 命令 |
| 不确定哪一步出错 | 登录加 `-v` 调试：`ssh -v -i ~/.ssh/id_ed25519_<别名> <用户名>@<地址>`，观察是否出现 `Server accepts key` |

---

> **安全提示**：私钥文件（无 `.pub` 后缀）绝不外发；只需将 `.pub` 公钥交给管理员。
