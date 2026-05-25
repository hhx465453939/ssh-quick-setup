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
$SshDir = "$env:USERPROFILE\.ssh"
$ConfigFile = "$SshDir\config"

# ── 颜色辅助 ──────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "`n>>> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "  [X] $Msg" -ForegroundColor Red }
function Write-Info  { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Gray }

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
            }
        }
        elseif ($null -ne $current) {
            $current.Lines += $line
            if ($line -match '^\s*HostName\s+(\S+)')    { $current.HostName = $Matches[1] }
            if ($line -match '^\s*Port\s+(\S+)')        { $current.Port     = $Matches[1] }
            if ($line -match '^\s*User\s+(\S+)')        { $current.User     = $Matches[1] }
            if ($line -match '^\s*IdentityFile\s+(.+)') { $current.KeyFile  = $Matches[1].Trim() }
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
    Set-Content -Path $Path -Value $text -Encoding UTF8 -NoNewline

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
$entries = Get-SshEntries -Path $ConfigFile

if ($entries.Count -eq 0) {
    Write-Warn "SSH config 中没有已配置的 Host。"
    exit 0
}

Write-Host "`n  当前已配置的 SSH 连接:" -ForegroundColor White
Write-Host "  -------------------------------" -ForegroundColor Gray
for ($i = 0; $i -lt $entries.Count; $i++) {
    $e = $entries[$i]
    Write-Host ("  [{0}] {1,-12} {2}@{3}:{4}" -f ($i+1), $e.Name, $e.User, $e.HostName, $e.Port) -ForegroundColor White
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
Write-Host "  端口   : $($target.Port)" -ForegroundColor White
Write-Host "  用户   : $($target.User)" -ForegroundColor White

# 检查密钥文件
$keyBasename = "id_ed25519_$alias"
$keyPath = "$SshDir\$keyBasename"
$keyPubPath = "$keyPath.pub"
$hasKey = Test-Path $keyPath
if ($hasKey) {
    Write-Host "  密钥   : $keyPath" -ForegroundColor White
}

Write-Host "  -------------------------------" -ForegroundColor Gray

# ── 确认 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "  [!] 此操作不可自动撤销" -ForegroundColor Red
$confirm = Read-Host "  确认删除? 请输入 yes 继续"
if ($confirm -ne 'yes') {
    Write-Info "已取消。"; exit 0
}

# ── 执行删除 ──────────────────────────────────────────────────
$deleted = @()

# 1. 删除密钥文件
if ($hasKey) {
    $removedAny = $false
    foreach ($f in @($keyPath, $keyPubPath)) {
        if (Test-Path $f) {
            Remove-Item $f -Force
            $removedAny = $true
        }
    }
    if ($removedAny) {
        Write-Ok "已删除密钥: $keyBasename / ${keyBasename}.pub"
        $deleted += "密钥文件"
    }
}

# 2. 从 SSH config 移除
$removed = Remove-SshConfigEntry -Path $ConfigFile -Alias $alias
if ($removed) {
    Write-Ok "已从 SSH config 移除 Host $alias"
    $deleted += "SSH config 条目"
} else {
    Write-Warn "SSH config 中未找到 Host $alias (可能已被手动修改)"
}

# 3. 可选：清理远程 authorized_keys
$cleanRemote = Read-Host "`n  是否同时从远程服务器移除公钥? (y/N)"
if ($cleanRemote -eq 'y' -or $cleanRemote -eq 'Y') {
    if ($hasKey -and (Test-Path $keyPubPath)) {
        # 密钥已删，无法获取公钥指纹
        Write-Warn "本地公钥已删除，无法精确匹配远程条目。"
        Write-Info "如需清理，请手动登录远程服务器编辑 ~/.ssh/authorized_keys"
    } else {
        # 密钥文件还在（可能之前没配这个密钥）
        Write-Info "将登录远程服务器移除对应公钥..."
    }

    # 尝试用 config 中的信息连接
    $port = if ($target.Port) { $target.Port } else { "22" }
    $user = $target.User
    $remoteHost = $target.HostName

    if ($user -and $remoteHost) {
        # 获取公钥内容用于匹配（如果还存在的话）
        $pubContent = $null
        if (Test-Path $keyPubPath) {
            $pubContent = (Get-Content $keyPubPath -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
        }

        if ($pubContent) {
            # 精确删除匹配行
            $escapedKey = $pubContent -replace '/', '\/' -replace '\+', '\+' -replace '\=', '\='
            ssh -p $port "${user}@${remoteHost}" "sed -i '/$(echo $pubContent | sed 's/[\/&]/\\&/g')/d' ~/.ssh/authorized_keys 2>/dev/null && echo '已移除远程公钥' || echo '远程操作失败'"
        } else {
            Write-Warn "公钥文件已删除，无法精确匹配。"
            Write-Info "请手动登录 ${user}@${remoteHost} -p ${port} 编辑 ~/.ssh/authorized_keys"
        }
    } else {
        Write-Warn "config 中信息不完整，无法自动清理远程公钥。"
    }
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
Write-Host ""
