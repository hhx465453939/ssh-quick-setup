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

# 修复历史遗留的 UTF-8 BOM（OpenSSH 遇到 BOM 会放弃解析整个 config）
function Repair-ConfigBom {
    if (-not (Test-Path $ConfigFile)) { return }
    $bytes = [System.IO.File]::ReadAllBytes($ConfigFile)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { return }
    $backup = "$ConfigFile.bak-bom"
    if (-not (Test-Path $backup)) { [System.IO.File]::WriteAllBytes($backup, $bytes) }
    [System.IO.File]::WriteAllText($ConfigFile, [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3), (New-Object System.Text.UTF8Encoding($false)))
    Write-Warn "检测到 config 带 UTF-8 BOM（OpenSSH 会拒绝解析整个 config），已自动修复"
    Write-Info "原始文件已备份: $backup"
}

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
        # 同 ssh-setup.ps1：Get-Content -Raw 属于 FileSystem provider 的动态参数，
        # 在受限语言模式或模块状态异常时会报「找不到参数 Raw」，统一改走 .NET
        try { $err = [System.IO.File]::ReadAllText($errFile) } catch { $err = $null }
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

    # 必须用 .NET 读取：PS 5.1 的 Get-Content 对「无 BOM 的 UTF-8」按 ANSI(GBK) 解码，
    # 中文注释会变乱码并吞掉换行符，紧随其后的 Host 行就不再独占一行，
    # 被下面的 ^\s*Host\s+(\S+)\s*$ 漏掉。
    # 实测（PS 5.1，config 首行是中文注释）：Get-Content 只能识别出后面几个 Host，
    # 第一个 Host 直接“消失”；换用 .NET ReadAllText 后全部条目正确。
    $content = @([System.IO.File]::ReadAllText($Path) -split "`r?`n")
    $entries = @()
    $current = $null

    foreach ($line in $content) {
        # Host 行可含多个别名（Host a b c）与行内注释，必须取全部 token：
        # 旧正则 ^\s*Host\s+(\S+)\s*$ 要求「单 token + 行尾」，对多别名行完全无法匹配，
        # 导致该行与其配置被丢弃或并入前一块（数据错乱），且该块无法被删除。
        if ($line -match '^\s*Host\s+(.+?)\s*$') {
            $namesRaw = @(($Matches[1] -replace '#.*$', '').Trim() -split '\s+') | Where-Object { $_ }
            if ($namesRaw.Count -gt 0) {
                if ($null -ne $current) { $entries += $current }
                $current = @{
                    Name      = ($namesRaw -join ', ')   # 展示：alpha, beta, gamma
                    NameRaw   = ($namesRaw -join ' ')     # 归一化别名串，删除时逐 token 精确比对
                    Aliases   = @($namesRaw)
                    Lines     = @($line)
                    HostName  = ""
                    Port      = ""
                    User      = ""
                    KeyFile   = ""
                    Mode      = ""
                    Fp        = ""
                    # 任一名含通配符即整块受保护（Host * / Host web1 web*.corp）：
                    # 只看首名会漏掉后置的通配模式，从而误删全局段
                    IsPattern = [bool](@($namesRaw | Where-Object { $_ -match '[*?!]' }).Count)
                }
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
    # $AliasTokens 为归一化后的别名串（如 "alpha beta gamma"）。
    # 用「归一化后逐 token 比对」而非正则：既避开正则元字符转义，也容忍原文多空格对齐。
    param([string]$Path, [string]$AliasTokens)

    $content = @([System.IO.File]::ReadAllText($Path) -split "`r?`n")
    $newContent = [System.Collections.ArrayList]::new()
    $skip = $false
    $found = $false

    $targetKey = ((@($AliasTokens.Trim() -split '\s+') | Where-Object { $_ }) -join ' ')

    foreach ($line in $content) {
        if ($line -match '^\s*Host\s+(.+?)\s*$') {
            $lineKey = ((@((($Matches[1]) -replace '#.*$', '').Trim() -split '\s+') | Where-Object { $_ }) -join ' ')
            if ($lineKey -eq $targetKey) {
                $skip = $true
                $found = $true
                continue
            }
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
    # 删除是不可逆操作：改写前留一份带时间戳备份，正则误判时能手工回滚
    $backup = "$Path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    try {
        [System.IO.File]::WriteAllText($backup, [System.IO.File]::ReadAllText($Path), (New-Object System.Text.UTF8Encoding($false)))
        Write-Info "config 已备份: $backup"
    } catch {
        Write-Warn "config 备份失败（$($_.Exception.Message)），仍继续删除。"
    }
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

# ── 修复 BOM（带 BOM 时 OpenSSH 不解析整个 config，且读写都会出偏差）──
Repair-ConfigBom

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
    $tag = if ($e.IsPattern) { '   <- 通配符/条件段，禁止删除' } else { '' }
    Write-Host ("  [{0}] {1,-12} {2}@{3}:{4}{5}" -f ($i+1), $e.Name, $e.User, $e.HostName, $(if ($e.Port) { $e.Port } else { '22' }), $tag) -ForegroundColor White
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

# Host * / Host *.corp 这类段是全局默认值（ServerAliveInterval / User / IdentityFile 等），
# 删掉会波及所有连接，必须拒绝（旧版会把它们当普通条目列出并可删）。
if ($target.IsPattern) {
    Write-Err "条目 [$($target.Name)] 是通配符/条件段（如 Host *），删除会破坏所有连接的默认配置，已拒绝。"
    Write-Info "如确实要清理，请手动编辑: $ConfigFile"
    exit 1
}

$alias = $target.Name                        # 展示用（多别名时为 "a, b, c"）
$aliasTokens = $target.NameRaw                # 删除匹配用（归一化 "a b c"）
$aliasFirst = @(@($target.Aliases)[0])[0]     # 密钥兜底文件名用首个别名

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
    $fallback = "$SshDir\id_ed25519_$aliasFirst"
    if (Test-Path $fallback) { $keyPath = $fallback }
}
$keyPubPath = if ($keyPath) { "$keyPath.pub" } else { "$SshDir\id_ed25519_$aliasFirst.pub" }
$hasKey = [bool]$keyPath
$keyBasename = if ($hasKey) { [System.IO.Path]::GetFileName($keyPath) } else { "id_ed25519_$aliasFirst" }
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
$removed = Remove-SshConfigEntry -Path $ConfigFile -AliasTokens $aliasTokens
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
