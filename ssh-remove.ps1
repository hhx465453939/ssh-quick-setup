#Requires -Version 5.1
<#
.SYNOPSIS
    SSH 配置删除脚本 (Windows PowerShell)
.DESCRIPTION
    列出已配置的 SSH 快捷连接，交互式选择删除（密钥 + config 条目 + 远程公钥）
.EXAMPLE
    .\ssh-remove.ps1
#>

$ErrorActionPreference = "Stop"

# 定位 .ssh 目录（同 ssh-setup.ps1：MSYS 版 ssh 读 HOME，Windows 原生 OpenSSH 读 USERPROFILE）
if ($env:HOME -and ($env:HOME -match '^[A-Za-z]:[\\/]' -or $env:HOME -match '^\\\\')) {
    $SshHome = $env:HOME
} else {
    $SshHome = $env:USERPROFILE
}
$SshDir = "$SshHome\.ssh"
$ConfigFile = "$SshDir\config"

# ── 颜色辅助 ──────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "`n>>> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "  [X] $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Gray }

# 把 PowerShell 对原生命令 stderr 的包装文本清理成一句话
function Get-MeaningfulError {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $keep = @()
    foreach ($l in ($Text -split "`r?`n")) {
        $t = $l.Trim()
        if (-not $t) { continue }
        if ($t -match '^\+') { continue }
        if ($t -match '^(位置|At line|CategoryInfo|FullyQualifiedErrorId|ErrorRecord)') { continue }
        if ($t -match 'Permanently added') { continue }
        $keep += $t
    }
    $s = (($keep -join ' | ') -replace '^ssh(\.exe)?\s*:\s*', '').Trim()
    if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }
    return $s
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

# ── 解析 SSH config，提取所有 Host 段 ─────────────────────────
function Get-SshEntries {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return @() }

    $content = Get-Content $Path -ErrorAction SilentlyContinue
    $entries = @()
    $current = $null

    foreach ($line in $content) {
        if ($line -match '^\s*Host\s+(\S+)\s*$') {
            if ($null -ne $current) { $entries += $current }
            $current = @{
                Name     = $Matches[1]
                Lines    = @($line)
                HostName = ""
                Port     = ""
                User     = ""
                KeyFile  = ""
                Mode     = ""
                Fp       = ""
            }
        }
        elseif ($null -ne $current) {
            $current.Lines += $line
            if ($line -match '^\s*HostName\s+(\S+)')    { $current.HostName = $Matches[1] }
            if ($line -match '^\s*Port\s+(\S+)')        { $current.Port     = $Matches[1] }
            if ($line -match '^\s*User\s+(\S+)')        { $current.User     = $Matches[1] }
            if ($line -match '^\s*IdentityFile\s+(.+)') { $current.KeyFile  = $Matches[1].Trim() }
            # 由 ssh-setup 写入的标记行：记录该连接是哪种模式、密钥指纹
            if ($line -match 'ssh-quick-setup:.*mode=(\d)') { $current.Mode = $Matches[1] }
            if ($line -match 'ssh-quick-setup:.*fp=(\S+)')  { $current.Fp   = $Matches[1] }
        }
    }
    if ($null -ne $current) { $entries += $current }
    return $entries
}

# ── 从 config 中移除指定 Host 段 ──────────────────────────────
function Remove-SshConfigEntry {
    param([string]$Path, [string]$Alias)

    $content = Get-Content $Path -ErrorAction SilentlyContinue
    $newContent = [System.Collections.ArrayList]::new()
    $skip = $false
    $found = $false

    foreach ($line in $content) {
        if ($line -match "^\s*Host\s+$Alias\s*$") {
            $skip = $true
            $found = $true
            continue
        }
        if ($skip) {
            # 遇到下一个 Host 段或非缩进行时停止跳过
            if ($line -match "^\s*Host\s+\S+" -or ($line -match "\S" -and $line -notmatch "^\s")) {
                $skip = $false
                # 如果是新的 Host 行，保留
                if ($line -match "^\s*Host\s+\S+") {
                    [void]$newContent.Add($line)
                } else {
                    [void]$newContent.Add($line)
                }
            }
            continue
        }
        [void]$newContent.Add($line)
    }

    # 清理尾部空行，只保留一个
    $trimmed = $newContent | Where-Object { $_ -ne $null }
    $text = ($trimmed -join "`n").TrimEnd()
    $text += "`n"
    # 必须无 BOM 写入：带 BOM 的 config 会让 OpenSSH 拒绝解析整个文件
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))

    return $found
}

# ════════════════════════════════════════════════════════════════
# 主流程
# ════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "  SSH 配置管理 - 删除连接" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Magenta

# ── 检查 config 是否存在 ──────────────────────────────────────
if (-not (Test-Path $ConfigFile)) {
    Write-Err "未找到 SSH config: $ConfigFile"
    Write-Info "没有任何已配置的 SSH 快捷连接。"
    exit 0
}

# ── 列出已有配置 ──────────────────────────────────────────────
#  注意：必须用 @() 包裹。Get-SshEntries 返回单元素数组时 PowerShell 会
#  把它解包成一个 Hashtable，导致 $entries.Count 变成「哈希键个数」、
#  $entries[0] 变成按键取值（返回 $null），于是只有一个 Host 的配置会显示成一堆空行。
$entries = @(Get-SshEntries -Path $ConfigFile)

if ($entries.Count -eq 0) {
    Write-Warn "SSH config 中没有已配置的 Host。"
    exit 0
}

Write-Host "`n  当前已配置的 SSH 连接:" -ForegroundColor White
Write-Host "  -------------------------------" -ForegroundColor Gray
for ($i = 0; $i -lt $entries.Count; $i++) {
    $e = $entries[$i]
    Write-Host ("  [{0}] {1,-12} {2}@{3}:{4}" -f ($i+1), $e.Name, $e.User, $e.HostName, $(if ($e.Port) { $e.Port } else { '22' })) -ForegroundColor White
}
Write-Host "  -------------------------------" -ForegroundColor Gray

# ── 选择要删除的条目 ──────────────────────────────────────────
$choice = Read-Host "`n  输入编号选择要删除的连接 (直接回车取消)"
if ([string]::IsNullOrWhiteSpace($choice)) {
    Write-Info "已取消。"; exit 0
}

$idx = 0
if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $entries.Count) {
    Write-Err "无效的编号。"; exit 1
}

$target = $entries[$idx - 1]
$alias = $target.Name

Write-Host ""
Write-Host "  即将删除:" -ForegroundColor Yellow
Write-Host "  -------------------------------" -ForegroundColor Gray
Write-Host "  别名   : $alias" -ForegroundColor White
Write-Host "  地址   : $($target.HostName)" -ForegroundColor White
Write-Host "  端口   : $(if ($target.Port) { $target.Port } else { '22' })" -ForegroundColor White
Write-Host "  用户   : $($target.User)" -ForegroundColor White

# 检查密钥文件（优先用 config 里记录的 IdentityFile，兼容模式 2 导入的密钥）
$keyPath = ""
if ($target.KeyFile) {
    $kf = ($target.KeyFile.Trim() -replace '^~', $SshHome)
    if (-not [System.IO.Path]::IsPathRooted($kf)) { $kf = Join-Path $SshDir $kf }
    if (Test-Path $kf) { $keyPath = $kf }
}
if (-not $keyPath) {
    $fallback = "$SshDir\id_ed25519_$alias"
    if (Test-Path $fallback) { $keyPath = $fallback }
}
$keyPubPath = if ($keyPath) { "$keyPath.pub" } else { "$SshDir\id_ed25519_$alias.pub" }
$hasKey = [bool]$keyPath
$keyBasename = if ($hasKey) { [System.IO.Path]::GetFileName($keyPath) } else { "id_ed25519_$alias" }
if ($hasKey) {
    Write-Host "  密钥   : $keyPath" -ForegroundColor White
}
if (Test-Path $keyPubPath) {
    Write-Host "  公钥   : $keyPubPath" -ForegroundColor White
}

# ── 采集公钥指纹与公钥内容（必须在删除本地文件之前！） ────────
$port = if ($target.Port) { $target.Port } else { '22' }
$remoteTarget = "$($target.User)@$($target.HostName)"
$pubBlob = $null
$keyFp = $null

if ($keyPath -and (Test-Path $keyPath)) {
    $r = Invoke-Native 'ssh-keygen' @('-y', '-P', '""', '-f', $keyPath)
    if ($r.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Output)) {
        $p = ($r.Output.Trim() -split '\s+')
        if ($p.Count -ge 2) { $pubBlob = "$($p[0]) $($p[1])" }   # 去掉注释，只留可精确匹配的 type+base64
    }
    $r2 = Invoke-Native 'ssh-keygen' @('-lf', $keyPath)
    if ($r2.Output -match '(SHA256:[A-Za-z0-9+/=]+)') { $keyFp = $Matches[1] }
}
if (-not $pubBlob -and $keyPubPath -and (Test-Path $keyPubPath)) {
    $p = (((Get-Content $keyPubPath -TotalCount 1) -join '')).Trim() -split '\s+'
    if ($p.Count -ge 2) { $pubBlob = "$($p[0]) $($p[1])" }
}
if (-not $keyFp -and $target.Fp) { $keyFp = $target.Fp }   # 回退到 setup 写在 config 里的指纹

if ($keyFp) { Write-Host "  指纹   : $keyFp" -ForegroundColor White }

Write-Host "  -------------------------------" -ForegroundColor Gray

# ── 确认 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "  [!] 本地私钥删除后不可恢复" -ForegroundColor Red
$confirm = Read-Host "  确认删除? 请输入 yes 继续"
if ($confirm -ne 'yes') {
    Write-Info "已取消。"; exit 0
}

# ── 1. 远端清理（可选，但必须在删除本地私钥之前） ──────────────
$deleted = @()
$remoteState  = 'skipped'   # skipped | nofile | notfound | removed | failed | noblob | noconn
$remoteBackup = $null
$remoteTotal  = $null
$remoteCount  = 0
$remoteErr    = ""

Write-Host ""
Write-Host "  远端 authorized_keys 清理（可选）" -ForegroundColor White

if ($target.Mode -eq '2') {
    Write-Warn "这条连接用的是【服务端下发的私钥】(mode=2)：服务端通常已关闭密码认证。"
    Write-Warn "若远端条目由服务商预置、且你没有其它登录方式，删掉它可能让你【永久失联】。"
} elseif ($target.Mode -eq '1') {
    Write-Info "这条连接用的是【本地生成并上传】的密钥 (mode=1)：远端条目是你自己装的，可以安全移除。"
}
Write-Info "为什么现在做：本地私钥一旦删除就无法再用它登录，之后只能靠面板/其它密钥去改远端。"

$cleanRemote = Read-Host "  现在就从远端移除这条公钥? (y/N)"
if ($cleanRemote -eq 'y' -or $cleanRemote -eq 'Y') {
    if (-not $pubBlob) {
        Write-Warn "本地公钥内容不可得（私钥缺失/无 .pub），无法做精确匹配。"
        $remoteState = 'noblob'
    } elseif (-not $target.User -or -not $target.HostName) {
        Write-Warn "config 中信息不完整，无法自动清理。"
        $remoteState = 'noconn'
    } else {
        Write-Info "连接 ${remoteTarget}:${port} ..."
        # 远端脚本：先计数，再备份+删除，再计数回读（闭环验证）
        $remoteScript = @"
f="`$HOME/.ssh/authorized_keys"
if [ ! -f "`$f" ]; then echo "SQ_BEFORE=nofile"; exit 0; fi
b=`$(grep -cF '$pubBlob' "`$f" 2>/dev/null)
[ -n "`$b" ] || b=0
echo "SQ_BEFORE=`$b"
if [ "`$b" -gt 0 ]; then
  bk="`$f.bak.`$(date +%Y%m%d-%H%M%S)"
  cp -p "`$f" "`$bk" && echo "SQ_BACKUP=`$bk"
  grep -vF '$pubBlob' "`$f" > "`$f.sqnew"
  cat "`$f.sqnew" > "`$f"
  rm -f "`$f.sqnew"
  chmod 600 "`$f"
fi
a=`$(grep -cF '$pubBlob' "`$f" 2>/dev/null)
[ -n "`$a" ] || a=0
echo "SQ_AFTER=`$a"
echo "SQ_TOTAL=`$(grep -c . "`$f" 2>/dev/null)"
"@
        $remoteScript = ($remoteScript -replace "`r`n", "`n")

        $sshArgs = @()
        if ($keyPath -and (Test-Path $keyPath)) { $sshArgs += @('-i', $keyPath, '-o', 'IdentitiesOnly=yes') }
        $sshArgs += @('-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new', '-p', "$port", $remoteTarget, $remoteScript)
        $r = Invoke-Native 'ssh' $sshArgs

        if ($r.Output -match 'SQ_BEFORE=nofile') {
            $remoteState = 'nofile'
        } elseif ($r.Output -match 'SQ_BEFORE=(\d+)') {
            $remoteCount = [int]$Matches[1]
            if ($r.Output -match 'SQ_BACKUP=(\S+)') { $remoteBackup = $Matches[1] }
            if ($r.Output -match 'SQ_AFTER=(\d+)')  { $after = [int]$Matches[1] } else { $after = -1 }
            if ($r.Output -match 'SQ_TOTAL=(\d+)')  { $remoteTotal = [int]$Matches[1] }
            if ($remoteCount -eq 0) { $remoteState = 'notfound' }
            elseif ($after -eq 0)   { $remoteState = 'removed' }
            else                    { $remoteState = 'failed' }
        } elseif (($r.Error + $r.Output) -match 'Permission denied|publickey') {
            # 用这把私钥登不上远端 —— 通常就意味着远端已经没有它了
            $remoteState = 'denied'
            $remoteErr = Get-MeaningfulError -Text ($r.Error + "`n" + $r.Output)
        } else {
            $remoteState = 'failed'
            $remoteErr = Get-MeaningfulError -Text ($r.Error + "`n" + $r.Output)
        }

        switch ($remoteState) {
            'nofile'   { Write-Ok "远端没有 ~/.ssh/authorized_keys，无需清理。" }
            'notfound' { Write-Ok "远端 authorized_keys 里本来就没有这条公钥 → 无需清理（也没有误删任何条目）。" }
            'removed'  {
                Write-Ok "远端已移除 $remoteCount 条匹配公钥，现有公钥 $remoteTotal 条。"
                if ($remoteBackup) { Write-Info "远端备份: $remoteBackup" }
            }
            'denied'   {
                Write-Ok "用该私钥登录远端被拒（Permission denied）→ 远端大概率已经没有这条公钥。"
                Write-Info "可用下方核对命令确认（期望输出 0）。"
            }
            default    {
                Write-Err "远端清理未完成（可能：连不上 / 无权限 / 远端无 grep）。"
                if ($remoteErr) { Write-Info "远端返回: $remoteErr" }
                Write-Info "可手动执行（把 <公钥串> 换成上方检索字段）:"
                Write-Info "ssh -p $port $remoteTarget `"grep -vF '<公钥串>' ~/.ssh/authorized_keys > /tmp/ak && cat /tmp/ak > ~/.ssh/authorized_keys`""
            }
        }
    }
}

# ── 2. 删除本地密钥文件 ───────────────────────────────────────
if ($hasKey -or (Test-Path $keyPubPath)) {
    $removedAny = $false
    foreach ($f in @($keyPath, $keyPubPath)) {
        if ($f -and (Test-Path $f)) {
            Remove-Item $f -Force
            $removedAny = $true
        }
    }
    if ($removedAny) {
        Write-Ok "已删除本地密钥: $keyBasename / ${keyBasename}.pub"
        $deleted += "密钥文件"
    }
}

# ── 3. 从 SSH config 移除 ────────────────────────────────────
$removed = Remove-SshConfigEntry -Path $ConfigFile -Alias $alias
if ($removed) {
    Write-Ok "已从 SSH config 移除 Host $alias"
    $deleted += "SSH config 条目"
} else {
    Write-Warn "SSH config 中未找到 Host $alias (可能已被手动修改)"
}

# ── 总结 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "  删除完成" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Magenta
if ($deleted.Count -gt 0) {
    foreach ($d in $deleted) { Write-Ok $d }
} else {
    Write-Warn "没有实际删除任何内容。"
}

# ── 闭环核对：远端到底还有没有这条公钥 ──────────────────────
Write-Host ""
Write-Host "---------------------------------------------" -ForegroundColor Gray
Write-Host "  闭环核对（远端是否还留着这条公钥）" -ForegroundColor Cyan
Write-Host "---------------------------------------------" -ForegroundColor Gray
if ($keyFp)   { Write-Host "  公钥指纹 : $keyFp" -ForegroundColor White }
if ($pubBlob) {
    Write-Host "  检索字段（可完整复制，用作精确搜索）:" -ForegroundColor White
    Write-Host "  $pubBlob" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  # ① 列出远端全部公钥指纹（上面那把不应再出现）" -ForegroundColor Gray
Write-Host "  ssh -p $port $remoteTarget `"ssh-keygen -lf ~/.ssh/authorized_keys`"" -ForegroundColor White
Write-Host "  # ② 精确搜索（期望输出 0）" -ForegroundColor Gray
if ($pubBlob) {
    Write-Host "  ssh -p $port $remoteTarget `"grep -c -F '$pubBlob' ~/.ssh/authorized_keys`"" -ForegroundColor White
} else {
    Write-Host "  ssh -p $port $remoteTarget `"grep -n -E 'ssh-(rsa|ed25519|ecdsa)' ~/.ssh/authorized_keys`"" -ForegroundColor White
}
Write-Host "  # ③ 查看远端备份（上面清理若输出过备份路径）" -ForegroundColor Gray
Write-Host "  ssh -p $port $remoteTarget `"ls -l ~/.ssh/authorized_keys.bak.* 2>/dev/null`"" -ForegroundColor White
Write-Host ""
Write-Host "  [!] 本地私钥已删除，执行以上命令需要你还有其它登录方式（另一把密钥/密码/面板）" -ForegroundColor Yellow
Write-Host "      若已无其它入口，请在服务商控制台/面板里核对 ~/.ssh/authorized_keys" -ForegroundColor Gray
Write-Host ""
