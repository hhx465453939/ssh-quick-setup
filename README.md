# SSH 免密登录快速配置工具

一键配置 / 删除 SSH 密钥认证，实现 `ssh <别名>` 免密登录远程服务器。

内置**两种密钥模式**，并会先探测服务端允许的认证方式，据此推荐模式。

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
[1/4] 输入服务器别名    → 如 xiyou、nas、dev
[2/4] 输入服务器地址    → IP 或域名
[3/4] 输入 SSH 端口     → 默认 22
[4/4] 输入登录用户名
      ↓
      探测服务端允许的认证方式（publickey / password）
      ↓
      选择密钥模式（脚本给出推荐值，直接回车即采用）
      ├── [1] 服务端有密码     → 本地生成 Ed25519 → 用密码上传公钥
      └── [2] 服务端已下发私钥 → 导入下发的私钥（不生成、不上传）
      ↓
      写入 ~/.ssh/config（UTF-8 无 BOM）
      ↓
      测试免密连接
```

### 两种模式怎么选

| 模式 | 适用场景 | 脚本做什么 |
|------|----------|------------|
| **[1] 服务端有密码** | 服务器是你自己装的 / 你能用密码登录 | 生成 `id_ed25519_<别名>`，把公钥追加进远程 `authorized_keys`（需输一次密码） |
| **[2] 服务端已下发私钥** | VPS / 服务商在开通时**给了你一个私钥文件**，且服务端关闭了密码登录 | 只把该私钥规范化后落到 `~/.ssh/`，**跳过生成与上传** |

> **怎么判断该用哪个？** 脚本会自动探测。若看到
> `Authentications that can continue: publickey`（里面**没有** `password`），
> 说明服务端已关闭密码认证 —— 此时模式 1 的上传步骤必然失败
> （`Permission denied (publickey)`），脚本会推荐模式 2。

### 模式 2：服务端下发的私钥

- **支持格式**：OpenSSH 私钥（`-----BEGIN OPENSSH PRIVATE KEY-----`）、PEM（RSA / EC / DSA）、PKCS#8
- **不支持**（脚本会给出转换命令）：PuTTY `.ppk`、加密的 PKCS#8（`BEGIN ENCRYPTED PRIVATE KEY`）
- **自动处理**：
  - 剥离 UTF-8 BOM
  - CRLF 行尾归一化为 LF（新版 OpenSSH 会以 `invalid format` 拒读 CRLF 私钥）
  - 校验私钥可解析并显示指纹（`ssh-keygen -lf`，无需口令）
  - Windows 下自动 `icacls` 收紧权限，Linux/macOS 下 `chmod 600`
  - 顺带导出 `.pub` 便于核对；若私钥带口令会提示
- **落地位置**：`~/.ssh/id_rsa_<别名>` / `id_ed25519_<别名>` / `id_ecdsa_<别名>`（按识别出的类型命名）

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
    显示详情（地址 / 用户 / 密钥 / 指纹），确认输入 yes
      ↓
[3] 询问是否清理远端 authorized_keys（默认 N）
    ├── 选 y → 现在就做（此时本地私钥还在，才能用它登录去改远端）
    │         计数 BEFORE → 备份 authorized_keys.bak.<时间戳> → 删除 → 计数 AFTER
    │         结果分四种：已移除 N 条 / 远端本来就没有 / 远端无该文件 / 清理失败(附原因)
    └── 选 N → 只提示后续手工命令，不动远端
      ↓
[4] 删除本地密钥文件（按 config 里的 IdentityFile 定位，含 .pub）
      ↓
[5] 从 SSH config 移除 Host 段落（无 BOM 写回）
      ↓
[6] 打印《闭环核对》区：公钥指纹 + 检索字段 + 三条可直接复制的核对命令
```

### 为什么顺序是「先远端、后本地」

本地私钥一旦删除，就再也不能用它登录，也就没机会再去远端改 `authorized_keys` 了。
所以脚本先做（可选的）远端清理，再删本地文件。

### 删除后如何确认远端真的没这条公钥了（闭环核对）

脚本结束时会把下面三条**已填好地址/端口/用户、可直接复制执行**的命令打印出来：

| 命令 | 期望结果 |
|------|----------|
| `ssh -p <端口> <用户>@<主机> "ssh-keygen -lf ~/.ssh/authorized_keys"` | 列出的指纹里**不再出现**上面给出的那把 |
| `ssh -p <端口> <用户>@<主机> "grep -c -F '<公钥串>' ~/.ssh/authorized_keys"` | 输出 `0` |
| `ssh -p <端口> <用户>@<主机> "ls -l ~/.ssh/authorized_keys.bak.*"` | 清理时自动生成的远端备份（可回滚） |

> 本地私钥已删除，执行这些命令需要你还有其它登录方式（另一把密钥 / 密码 / 服务商面板）。
> 若已没有任何其它入口，请在服务商控制台里核对。

### 删除内容说明

| 操作 | 说明 |
|------|------|
| 清理远程公钥（可选） | 精确匹配（`grep -F` 整串匹配，不做正则）→ 先备份再删除 → 删除后回读计数验证，并回显备份路径 |
| 删除密钥文件 | 路径取自 config 中的 `IdentityFile`，因此模式 2 导入的 `id_rsa_<别名>` 也能正确删除；找不到时回退 `id_ed25519_<别名>` |
| 清理 SSH config | 从 `~/.ssh/config` 中移除 `Host <别名>` 段落（无 BOM） |

### 多别名配置块（`Host a b c`）

OpenSSH 允许一行写多个别名，它们**共享同一份配置**。本脚本的处理：

| 情况 | 列表显示 | 删除行为 |
|------|----------|----------|
| `Host alpha beta gamma` | 一个条目，显示为 `alpha, beta, gamma` | 删除该条目 = 同时移除三个别名的配置（整块），其它 Host 段不受影响 |
| `Host *` | 标为 `<- 通配符/条件段，禁止删除` | **拒绝删除**（它是全局默认值，删了会波及所有连接） |
| `Host web1 web*.corp` | 同样标为禁止删除 | **拒绝删除** —— 只要块内**任一**别名含 `*`/`?`，整块即视为通配段 |

> 为什么删除粒度是整块：`alpha`/`beta`/`gamma` 共用同一段配置，单独删掉其中一个别名只能靠重写 `Host` 行，
> 容易破坏手写格式；因此列表按「块」展示，删除也按「块」执行，并让你在删除前看清全部受影响别名。

> 删除操作需输入 `yes` 二次确认，防止误删。改写 config 前还会自动生成 `config.bak-<时间戳>` 备份。

### 服务端下发的私钥（mode=2）会额外警告

`ssh-setup` 会在 config 里写一行注释，记录该连接是哪种模式、密钥与指纹（OpenSSH 忽略 `#` 行）：

```sshconfig
Host lavps
    # ssh-quick-setup: mode=2 key=id_rsa_lavps fp=SHA256:xxxx created=20261018-1048
    HostName 38.60.91.69
    ...
```

`ssh-remove` 读到 `mode=2` 时会提示：

```
[!] 这条连接用的是【服务端下发的私钥】(mode=2)：服务端通常已关闭密码认证。
[!] 若远端条目由服务商预置、且你没有其它登录方式，删掉它可能让你【永久失联】。
```

因为这类服务器往往没有密码兜底：删掉远端那条公钥就等于自己把门锁死。
如果只是想清理本地，远端清理那步回答 `N` 即可。

---

## 三、手动操作（补充）

如果脚本无法使用，可手动执行：

### 手动新建连接（模式 1：服务端有密码）

```powershell
# 生成密钥
ssh-keygen -t ed25519 -C "别名" -f "$env:USERPROFILE\.ssh\id_ed25519_别名"

# 上传公钥
type "$env:USERPROFILE\.ssh\id_ed25519_别名.pub" | ssh -p 端口 用户名@地址 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

### 手动导入连接（模式 2：服务端已下发私钥）

```powershell
# 1. 归一化行尾（CRLF → LF）并以无 BOM 写入 ~/.ssh（Windows 为例）
$src  = "$env:USERPROFILE\Desktop\私钥_xxx.txt"
$text = ([System.IO.File]::ReadAllText($src) -replace "`r`n", "`n") -replace "`r", "`n"
$dest = "$env:USERPROFILE\.ssh\id_rsa_别名"
[System.IO.File]::WriteAllText($dest, $text, (New-Object System.Text.UTF8Encoding($false)))

# 2. 收紧权限（否则可能报 UNPROTECTED PRIVATE KEY FILE）
icacls $dest /inheritance:r /grant:r "$env:USERNAME:F"

# 3. 校验（能打印指纹即正常）
ssh-keygen -lf $dest
```

```bash
# Linux / macOS / WSL
tr -d '\r' < ~/私钥_xxx.txt > ~/.ssh/id_rsa_别名
chmod 600 ~/.ssh/id_rsa_别名
ssh-keygen -lf ~/.ssh/id_rsa_别名
```

写入 `~/.ssh/config`（Windows 为 `$env:USERPROFILE\.ssh\config`）末尾追加：

```sshconfig
Host 别名
    HostName 地址
    Port 端口
    User 用户名
    IdentityFile ~/.ssh/id_rsa_别名
    IdentitiesOnly yes
    ServerAliveInterval 60
```

之后直接 `ssh 别名`。

### 手动删除连接

1. 编辑 `~/.ssh/config`，删除对应的 `Host <别名>` 段落
2. 删除密钥文件：按该段落里的 `IdentityFile` 删掉私钥与 `.pub`
3. 登录远程服务器，从 `~/.ssh/authorized_keys` 中删除对应公钥行

---

## 四、生成的文件位置

| 文件 | Windows | Linux/WSL |
|------|---------|-----------|
| 密钥对 | `%USERPROFILE%\.ssh\id_<类型>_<别名>` | `~/.ssh/id_<类型>_<别名>` |
| SSH 配置 | `%USERPROFILE%\.ssh\config` | `~/.ssh/config` |

`<类型>` 为 `ed25519`（模式 1 生成）或 `rsa` / `ecdsa`（模式 2 导入，按私钥实际类型）。

---

## 五、常见坑与注意事项

- 私钥文件（无 `.pub` 后缀）**绝对不要泄露或发送给任何人**；服务商下发的私钥请勿长期留在桌面/下载目录，配置完成后建议删除原件。
- 同一别名重复运行 setup 会询问是否覆盖密钥；SSH config 中已有同名 Host 会跳过不覆盖。
- 删除操作需输入 `yes` 确认，不会静默删除。

### 坑 1：config 文件带 BOM → 所有 Host 全部失效

PowerShell 5.1 的 `Add-Content / Set-Content -Encoding UTF8` 会写入 UTF-8 BOM，
而 OpenSSH 遇到 BOM 会**放弃解析整个 config**：

```
config line 1: no argument after keyword "\357\273\277"
config: terminating, 1 bad configuration options
```

症状是**已配置的所有服务器一起连不上**（不只是新加的那个）。
本工具已改为无 BOM 写入（`.NET UTF8Encoding($false)`），并会在启动时检测并修复历史遗留的 BOM
（原文件备份为 `config.bak-bom`）。

### 坑 2：私钥是 CRLF 行尾 → invalid format

从网页/面板复制保存的私钥常常是 CRLF 行尾，新版 OpenSSH 会以
`Load key ...: invalid format` / `is not a key file` 拒读（同一文件转成 LF 立刻可用）。
模式 2 导入时会自动归一化为 LF。

### 坑 3：私钥权限过宽 → UNPROTECTED PRIVATE KEY FILE

Windows 下私钥若对其它用户可读，OpenSSH 会拒绝加载。模式 2 导入时自动执行：

```powershell
icacls "$env:USERPROFILE\.ssh\id_rsa_<别名>" /inheritance:r /grant:r "$env:USERNAME:F"
```

### 其它

- 首次连接时脚本用 `StrictHostKeyChecking=accept-new` 自动记录服务器指纹到 `known_hosts`（不再交互询问 yes/no）。
- 探测认证方式时会临时使用一个空配置文件（`-F <空文件>` / `-F /dev/null`），避免本地旧配置干扰判断。
- 脚本写入的 config 使用 LF 行尾 + 无 BOM，OpenSSH 对两种行尾都能解析。
