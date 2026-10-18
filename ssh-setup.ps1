#Requires -Version 5.1
<#
.SYNOPSIS
    SSH 免密登录一键配置脚本 (Windows PowerShell)
.DESCRIPTION
    交互式引导完成 SSH 密钥认证配置，实现 ssh <别名> 快速连接。
    支持两种模式：
      [1] 服务端有密码     —— 本地生成密钥对，用密码上传公钥（传统流程）
      [2] 服务端已下发私钥 —— 直接导入服务端下发的私钥，跳过生成与上传
    脚本会先探测服务端允许的认证方式，并据此推荐模式。
.EXAMPLE
    .\ssh-setup.ps1
#>

$ErrorActionPreference = "Stop"

# 定位 .ssh 目录。Git for Windows 附带的 MSYS 版 ssh 读 $env:HOME/.ssh/config，
# Windows 原生 OpenSSH 读 %USERPROFILE%\.ssh\config；不一致时以 HOME 为准（PATH 里通常是 Git 版 ssh），
# 仅在 HOME 不是 Windows 路径时回退 USERPROFILE。
if ($env:HOME -and ($env:HOME -match '^[A-Za-z]:[\\/]' -or $env:HOME -match '^\\\\')) {
    $SshHome = $env:HOME
} else {
    $SshHome = $env:USERPROFILE
}
$SshDir = "$SshHome\.ssh"
$ConfigFile = "$SshDir\config"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ── 颜色辅助 ──────────────────────────────────────────────────
function Write-Step { param([string]$Msg) Write-Host "`n>>> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "  [X] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Gray }

# ════════════════════════════════════════════════════════════════
# 工具函数
# ════════════════════════════════════════════════════════════════

function Convert-ToLf {
    param([string]$Text)
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n")
}

# UTF-8 无 BOM 写入。
# PS 5.1 的 Add-Content/Set-Content -Encoding UTF8 会写入 BOM，
# 而 OpenSSH 遇到 BOM 会放弃解析【整个】config（报 no argument after keyword），
# 症状是所有 Host 全部失效，因此这里必须手工写无 BOM 文本。
function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, (Convert-ToLf $Text), $Utf8NoBom)
}

function Add-TextNoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::AppendAllText($Path, (Convert-ToLf $Text), $Utf8NoBom)
}

# 修复历史遗留的 BOM（修复前该 config 对 OpenSSH 完全不可解析）
function Repair-ConfigBom {
    if (-not (Test-Path $ConfigFile)) { return }
    $bytes = [System.IO.File]::ReadAllBytes($ConfigFile)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { return }

    $backup = "$ConfigFile.bak-bom"
    if (-not (Test-Path $backup)) { [System.IO.File]::WriteAllBytes($backup, $bytes) }
    Write-TextNoBom -Path $ConfigFile -Text ([System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3))
    Write-Warn "检测到 config 带 UTF-8 BOM（OpenSSH 会拒绝解析整个 config），已自动修复"
    Write-Info "原始文件已备份: $backup"
}

# 安全执行原生命令（$ErrorActionPreference = Stop 下 PS 5.1 会把 stderr 当异常抛出）
function Invoke-Native {
    param([string]$File, [string[]]$Arguments)
    $errFile = [System.IO.Path]::GetTempFileName()
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $File @Arguments 2> $errFile
        $code = $LASTEXITCODE
        $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    } finally {
        $ErrorActionPreference = $old
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $out) { $out = @() }
    return @{
        ExitCode = $code
        Output   = ((@($out)) -join "`n")
        Error    = ([string]$err)
    }
}

# Windows 私钥权限收紧（权限过宽时 OpenSSH 报 UNPROTECTED PRIVATE KEY FILE）
function Set-KeyAcl {
    param([string]$Path)
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $r = Invoke-Native 'icacls' @($Path, '/inheritance:r', '/grant:r', "${user}:(F)")
    if ($r.ExitCode -ne 0) {
        $r = Invoke-Native 'icacls' @($Path, '/inheritance:r', '/grant:r', "${user}:F")
    }
    if ($r.ExitCode -ne 0) {
        Write-Warn "权限收紧失败，如登录报 UNPROTECTED PRIVATE KEY FILE，请手动执行:"
        Write-Info "icacls `"$Path`" /inheritance:r /grant:r `"${user}:F`""
    }
}

# 读私钥指纹，失败返回 $null（-lf 只读公钥部分，无需口令，可安全用于校验）
function Get-KeyFingerprint {
    param([string]$Path)
    $r = Invoke-Native 'ssh-keygen' @('-lf', $Path)
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) { return $null }
    return (($r.Output -split "`n")[0]).Trim()
}

# 私钥格式识别
function Get-KeyFormat {
    param([string]$Text)
    if ($Text -match 'PuTTY-User-Key-File-[23]')              { return 'ppk' }
    if ($Text -match '-----BEGIN OPENSSH PRIVATE KEY-----')   { return 'openssh' }
    if ($Text -match '-----BEGIN RSA PRIVATE KEY-----')       { return 'pem-rsa' }
    if ($Text -match '-----BEGIN EC PRIVATE KEY-----')        { return 'pem-ec' }
    if ($Text -match '-----BEGIN DSA PRIVATE KEY-----')       { return 'pem-dsa' }
    if ($Text -match '-----BEGIN ENCRYPTED PRIVATE KEY-----') { return 'pkcs8-enc' }
    if ($Text -match '-----BEGIN PRIVATE KEY-----')           { return 'pkcs8' }
    return 'unknown'
}

# 探测服务端允许的认证方式，返回如 "publickey" / "publickey,password"，失败返回 $null
function Get-AuthMethods {
    param([string]$TargetHost, [string]$Port, [string]$User, [int]$Timeout = 8)

    # -F <空文件>：忽略本地 config，避免别名/旧密钥干扰。
    # 注意：Windows 原生 ssh 可用 -F NUL，但 Git 自带的 MSYS 版 ssh 不认 NUL，故用空临时文件。
    $emptyConf = [System.IO.Path]::GetTempFileName()
    try {
        $r = Invoke-Native 'ssh' @(
            '-F', $emptyConf, '-v',
            '-o', 'BatchMode=yes',
            '-o', "ConnectTimeout=$Timeout",
            '-o', 'PreferredAuthentications=none',
            '-o', 'StrictHostKeyChecking=accept-new',
            '-p', "$Port", "$User@$TargetHost", 'true'
        )
    } finally {
        Remove-Item $emptyConf -Force -ErrorAction SilentlyContinue
    }
    if ($r.Error -match 'Authentications that can continue:\s*([^\r\n]+)') {
        return (($Matches[1].Trim() -split ',') | ForEach-Object { $_.Trim() }) -join ','
    }
    return $null
}

# 校验 config 是否可被 OpenSSH 解析
function Test-ConfigParses {
    param([string]$Alias)
    $r = Invoke-Native 'ssh' @('-G', $Alias)
    return $r.ExitCode -eq 0
}

# ── 模式 1：本地生成密钥对 ────────────────────────────────────
function New-LocalKey {
    param([string]$Alias)

    Write-Step "生成 Ed25519 密钥对..."

    $keyFile = "$SshDir\id_ed25519_$Alias"

    if (Test-Path $keyFile) {
        Write-Warn "密钥文件已存在: $keyFile"
        $ans = Read-Host "  是否覆盖重新生成? (y/N)"
        if ($ans -notmatch '^[yY]$') {
            Write-Info "保留现有密钥，跳过生成。"
            return $keyFile
        }
        Remove-Item $keyFile, "$keyFile.pub" -Force -ErrorAction SilentlyContinue
    }

    # -N '""' 是 PowerShell 下传空口令的正确写法（写成 -N "" 会被吞掉参数）
    $r = Invoke-Native 'ssh-keygen' @('-t', 'ed25519', '-C', "$Alias-ssh-key", '-f', $keyFile, '-N', '""')
    if ($r.ExitCode -ne 0 -or -not (Test-Path $keyFile)) {
        Write-Warn "非交互生成失败，改用交互式生成（口令处直接回车即为免密）..."
        & ssh-keygen -t ed25519 -C "$Alias-ssh-key" -f $keyFile
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $keyFile)) {
            Write-Err "密钥生成失败。"
            return $null
        }
    }

    Set-KeyAcl -Path $keyFile

    $chk = Invoke-Native 'ssh-keygen' @('-y', '-P', '""', '-f', $keyFile)
    if ($chk.ExitCode -ne 0) {
        Write-Warn "该私钥带口令，每次登录需输入口令（可执行 ssh-keygen -p -f `"$keyFile`" 修改）。"
    }

    Write-Ok "私钥: $keyFile"
    Write-Ok "公钥: $keyFile.pub"
    return $keyFile
}

# ── 模式 2：导入服务端下发的私钥 ──────────────────────────────
function Import-ServerKey {
    param([string]$Alias)

    Write-Step "导入服务端下发的私钥..."
    Write-Info "服务端已预置对应公钥，此模式不生成新密钥、也不上传任何东西。"

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $src = Read-Host "  请输入私钥文件路径 (可直接把文件拖进终端)"
        if ($null -eq $src) { $src = "" }
        $src = $src.Trim().Trim('"').Trim("'").Trim()
        if ([string]::IsNullOrWhiteSpace($src)) {
            Write-Err "路径不能为空。"
            continue
        }
        $src = $src -replace '^~', $env:USERPROFILE
        if (-not (Test-Path $src)) {
            Write-Err "文件不存在: $src"
            continue
        }

        # -Raw 读取：自动识别并剥离 UTF-8 BOM
        $text = [System.IO.File]::ReadAllText($src)
        $fmt = Get-KeyFormat -Text $text

        if ($fmt -eq 'ppk') {
            Write-Err "这是 PuTTY 专用格式 (.ppk)，OpenSSH 无法直接使用。"
            Write-Info "请先转换: puttygen `"$src`" -O private-openssh -o `"$SshDir\id_rsa_$Alias`""
            return $null
        }
        if ($fmt -eq 'unknown') {
            Write-Err "无法识别的私钥格式（未找到 -----BEGIN ... PRIVATE KEY----- 标记）。"
            Write-Info "请确认文件内容是完整私钥，而不是公钥或账号说明。"
            continue
        }
        if ($fmt -eq 'pkcs8-enc') {
            Write-Err "这是加密的 PKCS#8 私钥（BEGIN ENCRYPTED PRIVATE KEY），需先解密。"
            Write-Info "请执行: openssl pkcs8 -in `"$src`" -out `"$SshDir\id_rsa_$Alias`""
            return $null
        }

        # 归一化：BOM 已剥离；CRLF → LF（新版 OpenSSH 会以 invalid format 拒读 CRLF 私钥）
        $norm = Convert-ToLf $text
        if (-not $norm.EndsWith("`n")) { $norm += "`n" }

        # 先落到临时文件做校验（校验通过才动 $SshDir）
        $tmp = [System.IO.Path]::GetTempFileName()
        $fp = $null
        try {
            [System.IO.File]::WriteAllText($tmp, $norm, $Utf8NoBom)
            Set-KeyAcl -Path $tmp
            $fp = Get-KeyFingerprint -Path $tmp
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }

        if (-not $fp) {
            Write-Err "私钥无法解析。"
            Write-Info "常见原因: ① 从网页复制时漏行/串行；② 文件被换行符或 BOM 破坏；③ 需要口令。"
            if ($attempt -lt 3) { Write-Info "请重新提供文件路径（剩余 $((3 - $attempt)) 次）。" }
            continue
        }

        if ($fp -match '\(([A-Za-z0-9]+)\)') { $type = $Matches[1].ToLower() } else { $type = 'rsa' }
        $prefix = switch ($type) {
            'ed25519' { 'id_ed25519' }
            'ecdsa'   { 'id_ecdsa' }
            'dsa'     { 'id_dsa' }
            default   { 'id_rsa' }
        }
        $dest = "$SshDir\${prefix}_$Alias"

        $srcFull = (Resolve-Path -LiteralPath $src).Path
        if ($srcFull -eq $dest) {
            Write-Info "私钥已在目标位置，跳过复制。"
        } elseif (Test-Path $dest) {
            Write-Warn "目标已存在: $dest"
            $ans = Read-Host "  是否覆盖? (y/N)"
            if ($ans -notmatch '^[yY]$') {
                Write-Info "已取消导入。"
                return $null
            }
            Write-TextNoBom -Path $dest -Text $norm
        } else {
            Write-TextNoBom -Path $dest -Text $norm
        }

        Set-KeyAcl -Path $dest

        # 顺带导出公钥便于核对；失败说明该私钥带口令
        $y = Invoke-Native 'ssh-keygen' @('-y', '-P', '""', '-f', $dest)
        if ($y.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($y.Output)) {
            # 去掉 ssh-keygen -y 自动附加的文件路径注释，换成可读注释
            $parts = ($y.Output.Trim() -split '\s+')
            $pubLine = "$($parts[0]) $($parts[1]) $Alias-ssh-key"
            Write-TextNoBom -Path "$dest.pub" -Text ($pubLine + "`n")
        } else {
            Write-Warn "该私钥带口令，每次登录需输入口令（可执行 ssh-keygen -p -f `"$dest`" 修改）。"
        }

        Write-Ok "已导入私钥: $dest"
        Write-Info "指纹: $fp"
        return $dest
    }

    Write-Err "导入失败（已尝试 3 次）。"
    return $null
}

# ── 模式 1 的收尾：上传公钥 ───────────────────────────────────
function Send-PublicKey {
    param([string]$KeyFile, [string]$TargetHost, [string]$Port, [string]$User, [string]$AuthMethods)

    Write-Step "上传公钥到服务器 (需要输入一次密码)..."

    if ($AuthMethods -and ($AuthMethods -notmatch 'password')) {
        Write-Warn "探测到服务端只允许 publickey 认证，本步骤大概率失败。"
        Write-Info "若这台服务器属于『服务端下发私钥』类型，请改用模式 [2] 导入。"
    }

    $remoteCmd = 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys'

    $ans = Read-Host "  现在上传公钥吗? (Y/n)"
    if ($ans -eq 'n' -or $ans -eq 'N') {
        Write-Warn "跳过上传。稍后可手动执行:"
        Write-Info "type `"$KeyFile.pub`" | ssh -p $Port ${User}@${TargetHost} `"$remoteCmd`""
        return $false
    }

    $MaxRetries = 3
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Info "第 $i 次尝试..."
        Get-Content "$KeyFile.pub" -Raw | & ssh -p $Port "${User}@${TargetHost}" $remoteCmd
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "公钥上传成功!"
            return $true
        }
        Write-Warn "上传失败，请检查密码是否正确。"
        if ($i -lt $MaxRetries) { Read-Host "  按回车重试..." | Out-Null }
    }

    Write-Warn "自动上传失败。"
    if ($AuthMethods -and ($AuthMethods -notmatch 'password')) {
        Write-Info "服务端认证方式为 [$AuthMethods]，不含 password —— 无法用密码上传公钥。"
        Write-Info "请改用模式 [2] 导入服务端下发的私钥。"
    }
    Write-Info "也可手动执行:"
    Write-Info "type `"$KeyFile.pub`" | ssh -p $Port ${User}@${TargetHost} `"$remoteCmd`""
    return $false
}

# ════════════════════════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "  SSH 免密登录配置向导" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Magenta

foreach ($tool in @('ssh', 'ssh-keygen')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Err "未找到 $tool，请先安装 OpenSSH 客户端。"
        exit 1
    }
}

# ── 确保 .ssh 目录存在 ────────────────────────────────────────
if (-not (Test-Path $SshDir)) {
    New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
    Write-Ok "已创建目录 $SshDir"
}
Repair-ConfigBom

# ── 第 1 步：收集服务器信息 ──────────────────────────────────
$Alias = Read-Host "`n  [1/4] 请输入服务器别名 (如 xiyou, nas, dev)"
if ([string]::IsNullOrWhiteSpace($Alias)) {
    Write-Host "别名不能为空，退出。" -ForegroundColor Red; exit 1
}
$Alias = $Alias.Trim().ToLower()

$HostName = Read-Host "  [2/4] 请输入服务器地址 (IP 或域名)"
if ([string]::IsNullOrWhiteSpace($HostName)) {
    Write-Host "地址不能为空，退出。" -ForegroundColor Red; exit 1
}
$HostName = $HostName.Trim()

$Port = Read-Host "  [3/4] 请输入 SSH 端口 (直接回车默认 22)"
if ([string]::IsNullOrWhiteSpace($Port)) { $Port = "22" } else { $Port = $Port.Trim() }

$UserName = Read-Host "  [4/4] 请输入登录用户名"
if ([string]::IsNullOrWhiteSpace($UserName)) {
    Write-Host "用户名不能为空，退出。" -ForegroundColor Red; exit 1
}
$UserName = $UserName.Trim()

# ── 第 2 步：探测认证方式并选择模式 ───────────────────────────
Write-Step "探测服务端允许的认证方式..."

$AuthMethods = Get-AuthMethods -TargetHost $HostName -Port $Port -User $UserName
$RecMode = 1

if ($AuthMethods) {
    Write-Info "服务端允许: $AuthMethods"
    if ($AuthMethods -notmatch 'password') {
        $RecMode = 2
        Write-Warn "服务端已关闭密码认证，只能用公钥登录 → 推荐模式 [2]"
    }
} else {
    Write-Warn "未探测到认证方式（网络不可达 / 服务端未响应），按默认模式 [1] 继续。"
}

Write-Step "请选择密钥模式"
if ($AuthMethods) { Write-Info "探测结果: 服务端允许的认证方式 = $AuthMethods" } else { Write-Info "探测结果: 未知" }
Write-Info "[1] 服务端有密码      —— 本地生成新密钥对，用密码上传公钥"
Write-Info "[2] 服务端已下发私钥  —— 导入下发的私钥，跳过生成与上传"

$modeInput = Read-Host "`n  请选择 (1/2，回车采用推荐 [$RecMode])"
if ([string]::IsNullOrWhiteSpace($modeInput)) { $Mode = $RecMode }
elseif ($modeInput.Trim() -eq '1') { $Mode = 1 }
elseif ($modeInput.Trim() -eq '2') { $Mode = 2 }
else { Write-Host "无效输入，退出。" -ForegroundColor Red; exit 1 }

# ── 第 3 步：准备私钥 ────────────────────────────────────────
$KeyFile = $null
if ($Mode -eq 1) {
    $KeyFile = New-LocalKey -Alias $Alias
} else {
    $KeyFile = Import-ServerKey -Alias $Alias
}
if (-not $KeyFile) {
    Write-Err "私钥准备失败，退出。"
    exit 1
}

# ── 第 4 步：上传公钥（仅模式 1） ─────────────────────────────
if ($Mode -eq 1) {
    Send-PublicKey -KeyFile $KeyFile -TargetHost $HostName -Port $Port -User $UserName -AuthMethods $AuthMethods | Out-Null
} else {
    Write-Step "跳过公钥上传"
    Write-Info "模式 [2]：公钥已由服务端预置，无需上传。"
}

# ── 第 5 步：写入 SSH config ─────────────────────────────────
Write-Step "配置 SSH config..."

$keyName = [System.IO.Path]::GetFileName($KeyFile)
$alreadyConfigured = $false
if (Test-Path $ConfigFile) {
    $configText = [System.IO.File]::ReadAllText($ConfigFile)
    if ($configText -match "(?m)^\s*Host\s+$([regex]::Escape($Alias))\s*$") { $alreadyConfigured = $true }
}

if ($alreadyConfigured) {
    Write-Warn "SSH config 中已存在 Host $Alias 配置，跳过写入。"
    Write-Info "如需修改，请手动编辑: $ConfigFile"
} else {
    $entry = @"

Host $Alias
    HostName $HostName
    Port $Port
    User $UserName
    IdentityFile ~/.ssh/$keyName
    IdentitiesOnly yes
    ServerAliveInterval 60

"@
    Add-TextNoBom -Path $ConfigFile -Text $entry
    Write-Ok "已添加 Host $Alias 到 SSH config"
}

if (Test-ConfigParses -Alias $Alias) {
    Write-Ok "config 语法校验通过"
} else {
    Write-Warn "config 解析异常，请检查 $ConfigFile"
}

# ── 第 6 步：测试连接 ────────────────────────────────────────
Write-Step "测试免密连接..."

$Test = Read-Host "  现在测试 ssh $Alias 连接吗? (Y/n)"
if ($Test -ne 'n' -and $Test -ne 'N') {
    Write-Info "执行: ssh $Alias `"echo 'SSH 免密连接成功!'`"`n"
    & ssh -o BatchMode=yes -o ConnectTimeout=15 $Alias "echo 'SSH 免密连接成功!'"
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "免密登录配置完成!"
    } else {
        Write-Warn "连接测试失败，请检查网络或服务器配置。"
        Write-Info "排查命令: ssh -v -i `"$KeyFile`" -p $Port ${UserName}@${HostName}"
    }
}

# ── 总结 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "  配置总结" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "  模式       : $(if ($Mode -eq 1) { '[1] 生成新密钥并上传公钥' } else { '[2] 导入服务端下发私钥' })" -ForegroundColor White
Write-Host "  服务器别名 : $Alias" -ForegroundColor White
Write-Host "  地址       : $HostName" -ForegroundColor White
Write-Host "  端口       : $Port" -ForegroundColor White
Write-Host "  用户       : $UserName" -ForegroundColor White
Write-Host "  私钥       : $KeyFile" -ForegroundColor White
Write-Host "  快捷命令   : ssh $Alias" -ForegroundColor Green
Write-Host ""
Write-Host "  如需删除配置: .\ssh-remove.ps1" -ForegroundColor Gray
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host ""
