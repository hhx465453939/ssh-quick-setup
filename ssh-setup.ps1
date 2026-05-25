#Requires -Version 5.1
<#
.SYNOPSIS
    SSH 免密登录一键配置脚本 (Windows PowerShell)
.DESCRIPTION
    交互式引导生成密钥对、上传公钥、配置 SSH config，实现 ssh <别名> 快速连接
.EXAMPLE
    .\ssh-setup.ps1
#>

$ErrorActionPreference = "Stop"
$SshDir = "$env:USERPROFILE\.ssh"
$ConfigFile = "$SshDir\config"

# ── 颜色辅助 ──────────────────────────────────────────────────
function Write-Step  { param([string]$Msg) Write-Host "`n>>> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Info  { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor Gray }

# ── 确保 .ssh 目录存在 ────────────────────────────────────────
if (-not (Test-Path $SshDir)) {
    New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
    Write-Ok "已创建目录 $SshDir"
}

# ── 第 1 步：收集服务器信息 ──────────────────────────────────
Write-Host ""
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "  SSH 免密登录配置向导" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Magenta

$Alias = Read-Host "`n  [1/5] 请输入服务器别名 (如 xiyou, nas, dev)"
if ([string]::IsNullOrWhiteSpace($Alias)) {
    Write-Host "别名不能为空，退出。" -ForegroundColor Red; exit 1
}
$Alias = $Alias.Trim().ToLower()

$HostName = Read-Host "  [2/5] 请输入服务器地址 (IP 或域名)"
if ([string]::IsNullOrWhiteSpace($HostName)) {
    Write-Host "地址不能为空，退出。" -ForegroundColor Red; exit 1
}

$Port = Read-Host "  [3/5] 请输入 SSH 端口 (直接回车默认 22)"
if ([string]::IsNullOrWhiteSpace($Port)) { $Port = "22" }

$UserName = Read-Host "  [4/5] 请输入登录用户名"
if ([string]::IsNullOrWhiteSpace($UserName)) {
    Write-Host "用户名不能为空，退出。" -ForegroundColor Red; exit 1
}

# ── 第 2 步：生成密钥对 ──────────────────────────────────────
Write-Step "生成 Ed25519 密钥对..."

$KeyFile = "$SshDir\id_ed25519_$Alias"

if (Test-Path $KeyFile) {
    Write-Warn "密钥文件已存在: $KeyFile"
    $Answer = Read-Host "  是否覆盖重新生成? (y/N)"
    if ($Answer -ne 'y' -and $Answer -ne 'Y') {
        Write-Info "保留现有密钥，跳过生成。"
    } else {
        Remove-Item "$KeyFile", "$KeyFile.pub" -Force -ErrorAction SilentlyContinue
        ssh-keygen -t ed25519 -C "$Alias-ssh-key" -f $KeyFile -N '""' 2>$null
        if ($LASTEXITCODE -ne 0) {
            # fallback: 交互式输入 passphrase
            ssh-keygen -t ed25519 -C "$Alias-ssh-key" -f $KeyFile
        }
    }
} else {
    # -N '""' 在某些版本不行，先尝试，失败则交互式
    ssh-keygen -t ed25519 -C "$Alias-ssh-key" -f $KeyFile -N '""' 2>$null
    if ($LASTEXITCODE -ne 0) {
        ssh-keygen -t ed25519 -C "$Alias-ssh-key" -f $KeyFile
    }
}

Write-Ok "私钥: $KeyFile"
Write-Ok "公钥: $KeyFile.pub"

# ── 第 3 步：上传公钥到服务器 ────────────────────────────────
Write-Step "上传公钥到服务器 (需要输入一次密码)..."

$Upload = Read-Host "  现在上传公钥吗? (Y/n)"
if ($Upload -eq 'n' -or $Upload -eq 'N') {
    Write-Warn "跳过上传。稍后可手动执行:"
    Write-Info "type `"$KeyFile.pub`" | ssh -p $Port ${UserName}@${HostName} `"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`""
} else {
    $MaxRetries = 3
    $Uploaded = $false
    for ($i = 1; $i -le $MaxRetries; $i++) {
        Write-Info "第 $i 次尝试..."
        Get-Content "$KeyFile.pub" | ssh -p $Port "${UserName}@${HostName}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "公钥上传成功!"
            $Uploaded = $true
            break
        } else {
            Write-Warn "上传失败，请检查密码是否正确。"
            if ($i -lt $MaxRetries) {
                Read-Host "  按回车重试..."
            }
        }
    }
    if (-not $Uploaded) {
        Write-Warn "自动上传失败。可手动执行:"
        Write-Info "type `"$KeyFile.pub`" | ssh -p $Port ${UserName}@${HostName} `"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`""
    }
}

# ── 第 4 步：写入 SSH config ─────────────────────────────────
Write-Step "配置 SSH config..."

if (-not (Test-Path $ConfigFile)) {
    New-Item -ItemType File -Path $ConfigFile -Force | Out-Null
}

# 检查是否已存在同名 Host 配置
$ConfigContent = Get-Content $ConfigFile -Raw -ErrorAction SilentlyContinue
if ($ConfigContent -match "(?m)^Host\s+$Alias\b") {
    Write-Warn "SSH config 中已存在 Host $Alias 配置，跳过写入。"
    Write-Info "如需修改，请手动编辑: $ConfigFile"
} else {
    $Entry = @"

Host $Alias
    HostName $HostName
    Port $Port
    User $UserName
    IdentityFile ~/.ssh/id_ed25519_$Alias
"@
    Add-Content -Path $ConfigFile -Value $Entry -Encoding UTF8
    Write-Ok "已添加 Host $Alias 到 SSH config"
}

# ── 第 5 步：测试连接 ────────────────────────────────────────
Write-Step "测试免密连接..."

$Test = Read-Host "  现在测试 ssh $Alias 连接吗? (Y/n)"
if ($Test -ne 'n' -and $Test -ne 'N') {
    Write-Info "执行: ssh $Alias `"echo 'SSH 免密连接成功!'`"`n"
    ssh $Alias "echo 'SSH 免密连接成功!'"
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "免密登录配置完成!"
    } else {
        Write-Warn "连接测试失败，请检查网络或服务器配置。"
    }
}

# ── 总结 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "  配置总结" -ForegroundColor Magenta
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host "  服务器别名 : $Alias" -ForegroundColor White
Write-Host "  地址       : $HostName" -ForegroundColor White
Write-Host "  端口       : $Port" -ForegroundColor White
Write-Host "  用户       : $UserName" -ForegroundColor White
Write-Host "  私钥       : $KeyFile" -ForegroundColor White
Write-Host "  公钥       : $KeyFile.pub" -ForegroundColor White
Write-Host "  快捷命令   : ssh $Alias" -ForegroundColor Green
Write-Host ""
Write-Host "  如需删除配置: 编辑 $ConfigFile 移除 Host $Alias 段落" -ForegroundColor Gray
Write-Host "=====================================" -ForegroundColor Magenta
Write-Host ""
