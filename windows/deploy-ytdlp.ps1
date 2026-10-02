<#
.SYNOPSIS
    yt-dlp Windows 一键部署脚本。
.DESCRIPTION
    在全新 Windows 机器上部署完整的 yt-dlp 下载环境：
      1. winget 安装 yt-dlp + ffmpeg（+ deno，如缺失）
      2. 升级 yt-dlp 到 nightly（稳定版对 YouTube 改版滞后 1-3 周，是 403 的头号来源）
      3. 确保 WinGet Links 目录在用户 PATH 中（写注册表并广播生效，免注销）
      4. 写全局配置  %APPDATA%\yt-dlp\config   （必须纯 ASCII —— GBK 系统下中文注释会导致解析失败）
      5. 写 'yt' 包装命令  %LOCALAPPDATA%\Microsoft\WinGet\Links\yt.ps1
         （按需自动拉起 bgutil PO Token 服务器，监听 4416）
      6. 部署 bgutil PO Token provider：
         插件 zip -> %APPDATA%\yt-dlp\plugins\
         服务器   -> %USERPROFILE%\bgutil-ytdlp-pot-provider\server\  （deno 依赖）
         启动器   -> start-pot-server.cmd
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy-ytdlp.ps1
    powershell -ExecutionPolicy Bypass -File .\deploy-ytdlp.ps1 -CookiesBrowser chrome -OutputDir "D:\YT"
.NOTES
    幂等设计：可重复执行，已完成的步骤自动跳过。
    依赖：Windows 10/11 且装有 winget；需联网（GitHub + npm 镜像源）。
#>
param(
    # 下载输出目录
    [string]$OutputDir = "$env:USERPROFILE\Downloads",
    # cookies 来源浏览器：firefox（推荐，Chrome/Edge 新版的 app-bound 加密让提取必然失败）或 'none'
    [ValidateSet('firefox', 'chrome', 'edge', 'brave', 'none')]
    [string]$CookiesBrowser = 'firefox',
    # 跳过 PO Token 层（建议先装最简版跑通，遇到 403/bot 校验再补装）
    [switch]$SkipPotServer,
    # bgutil 发行版本号
    [string]$BgutilVersion = '2.0.1'
)

$ErrorActionPreference = 'Stop'
$Links    = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
$CfgDir   = Join-Path $env:APPDATA 'yt-dlp'
$PlugDir  = Join-Path $CfgDir 'plugins'
$ServerRoot = Join-Path $env:USERPROFILE 'bgutil-ytdlp-pot-provider'
$Temp     = Join-Path $env:TEMP "ytdlp-deploy-$(Get-Random)"

# 进度输出辅助函数：step=步骤标题，ok=成功，info=跳过说明，warn=警告
function Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok([string]$msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Info([string]$msg) { Write-Host "    -- $msg" -ForegroundColor DarkGray }

New-Item -ItemType Directory -Force -Path $Links, $CfgDir, $PlugDir, $Temp | Out-Null

# ---------------------------------------------------------------- 1. winget 安装
Step '1/6 通过 winget 安装 yt-dlp / ffmpeg / deno'

$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) { throw '未找到 winget，请先从 Microsoft Store 安装"应用安装程序"' }

# 不用 winget list 判断（输出随系统语言变化），直接探测可执行文件更可靠
$needYtDlp  = -not (Test-Path (Join-Path $Links 'yt-dlp.exe'))
$needFfmpeg = -not (Get-Command ffmpeg -ErrorAction SilentlyContinue) -and -not (Test-Path (Join-Path $Links 'ffmpeg.exe'))
$needDeno   = -not (Test-Path (Join-Path $Links 'deno.exe'))

$pkgs = @()
if ($needYtDlp)  { $pkgs += 'yt-dlp.yt-dlp' }
if ($needFfmpeg) { $pkgs += 'Gyan.FFmpeg' }
if ($needDeno)   { $pkgs += 'DenoLand.Deno' }

if ($pkgs.Count -eq 0) {
    Info '三个组件均已安装，跳过'
} else {
    foreach ($p in $pkgs) {
        Info "installing $p ..."
        winget install --id $p --accept-source-agreements --accept-package-agreements --silent
        # -1978335189 (0x8A15002B) = winget 的"已安装"错误码，不算失败
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
            Write-Warning "winget install $p 返回退出码 $LASTEXITCODE（继续执行）"
        }
    }
    Ok "已安装: $($pkgs -join ', ')"
}

# ---------------------------------------------------------------- 2. 升级 nightly
Step '2/6 升级 yt-dlp 到 nightly'
$ytDlp = Join-Path $Links 'yt-dlp.exe'
if (-not (Test-Path $ytDlp)) { throw "yt-dlp.exe 未找到：$ytDlp" }

& $ytDlp --update-to nightly
if ($LASTEXITCODE -eq 0) { Ok (& $ytDlp --version) } else { Write-Warning 'nightly 升级失败，稳定版仍可能可用' }

# ---------------------------------------------------------------- 3. 用户 PATH
Step '3/6 确保 WinGet Links 目录在用户 PATH 中'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -split ';' -notcontains $Links) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $Links), 'User')
    # 广播 WM_SETTINGCHANGE：让新开的进程立即拿到新 PATH，无需注销重登
    Add-Type -Namespace Win32 -Name Native -MemberDefinition `
        '[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'
    [UIntPtr]$result = [UIntPtr]::Zero
    [Win32.Native]::SendMessageTimeout([IntPtr]0xFFFF, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
    Ok "已写入用户 PATH 并广播生效：$Links（需新开终端才可见）"
} else {
    Info '已在 PATH 中'
}

# ---------------------------------------------------------------- 4. 全局配置
Step '4/6 写全局配置 %APPDATA%\yt-dlp\config'
$outNorm = ($OutputDir -replace '\\', '/').TrimEnd('/')
$cfg = @"
-P $outNorm
-o "%(title)s [%(id)s].%(ext)s"

-f bv*+ba/b
--merge-output-format mp4
"@
if ($CookiesBrowser -ne 'none') {
    $cfg += "`n`n# cookies are the key to pass datacenter-IP 403 on googlevideo`n--cookies-from-browser $CookiesBrowser"
}
# 注意：配置文件内容必须保持 ASCII——yt-dlp 按系统代码页（GBK）读取配置，非 ASCII 会直接报错
$cfg += "`n`n# 2026: default web client is SABR-locked to 360p; prefer token-capable clients first`n--extractor-args youtube:player_client=web_embedded,android_vr,tv_downgraded`n"
Set-Content -Path (Join-Path $CfgDir 'config') -Value $cfg -Encoding Ascii
Ok "配置已写入（输出目录=$outNorm, cookies=$CookiesBrowser）"

# ---------------------------------------------------------------- 5. yt 包装命令
Step '5/6 写 yt.ps1 包装命令（按需自动拉起 PO Token 服务器）'
$ytPs1 = @'
# yt.ps1 - yt-dlp wrapper: auto-start bgutil PO Token server (port 4416) when not listening
$ErrorActionPreference = 'Continue'
$YtDlpPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\yt-dlp.exe'
$ServerCmd = Join-Path $env:USERPROFILE 'bgutil-ytdlp-pot-provider\server\start-pot-server.cmd'
$Port      = 4416

# 用 Get-NetTCPConnection 精确探测监听状态（比 netstat+findstr 可靠，不会误匹配字符串）
function Test-PortListening {
    param([int]$Port)
    return $null -ne (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

if (-not (Test-PortListening -Port $Port)) {
    Write-Host "[yt] PO Token 服务器未运行（端口 $Port），最小化窗口启动中..." -ForegroundColor Cyan
    if (Test-Path $ServerCmd) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "`"$ServerCmd`"" -WindowStyle Minimized
    } else {
        Write-Warning "[yt] 未找到 $ServerCmd - 无 PO Token 继续执行"
    }
    # 最长等待 60 秒（deno 冷启动加载 canvas/jsdom 约需 30-40 秒）
    $tries = 0
    while (-not (Test-PortListening -Port $Port)) {
        Start-Sleep -Seconds 3
        $tries++
        if ($tries -ge 20) { Write-Warning '[yt] 等待 60s 服务器仍未就绪，继续执行'; break }
    }
    if (Test-PortListening -Port $Port) { Write-Host '[yt] PO Token 服务器就绪。' -ForegroundColor Green }
}

if (-not (Test-Path $YtDlpPath)) { Write-Error "yt-dlp.exe 未找到：$YtDlpPath"; exit 1 }
# @args 原样透传所有参数，无字符串拼接执行，规避注入面
& $YtDlpPath @args
exit $LASTEXITCODE
'@
Set-Content -Path (Join-Path $Links 'yt.ps1') -Value $ytPs1 -Encoding UTF8
Ok 'yt.ps1 已写入'

# ---------------------------------------------------------------- 6. PO Token 层
if (-not $SkipPotServer) {
    Step "6/6 部署 bgutil PO Token provider v$BgutilVersion"

    # 6a. 插件 zip -> %APPDATA%\yt-dlp\plugins\（yt-dlp 支持直接加载 zip 形式插件）
    $plugZip = Join-Path $PlugDir 'bgutil-ytdlp-pot-provider.zip'
    if (Test-Path $plugZip) {
        Info '插件 zip 已存在'
    } else {
        $url = "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/$BgutilVersion/bgutil-ytdlp-pot-provider.zip"
        Info "下载插件: $url"
        Invoke-WebRequest -Uri $url -OutFile $plugZip -UseBasicParsing
        Ok '插件 zip 下载完成'
    }

    # 6b. 服务器源码 -> %USERPROFILE%\bgutil-ytdlp-pot-provider\server\（插件默认查找路径，零配置）
    $serverSrc = Join-Path $ServerRoot 'server'
    if ((Test-Path $serverSrc) -and (Test-Path (Join-Path $serverSrc 'src'))) {
        Info '服务器源码已存在'
    } else {
        $repoZip = Join-Path $Temp "bgutil-repo-$BgutilVersion.zip"
        $url = "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/archive/refs/tags/$BgutilVersion.zip"
        Info "下载服务器源码: $url"
        Invoke-WebRequest -Uri $url -OutFile $repoZip -UseBasicParsing
        Expand-Archive -Path $repoZip -DestinationPath $Temp -Force
        $extracted = Join-Path $Temp "bgutil-ytdlp-pot-provider-$BgutilVersion\server"
        if (-not (Test-Path $extracted)) { throw "zip 结构异常：未找到 $extracted" }
        New-Item -ItemType Directory -Force -Path $ServerRoot | Out-Null
        Move-Item -Path $extracted -Destination $serverSrc
        Ok "服务器源码已部署到 $serverSrc"
    }

    # 6c. deno 依赖（npmjs 直连在国内网络常失败；npmmirror 是可靠备选）
    $deno = Join-Path $Links 'deno.exe'
    if (-not (Test-Path $deno)) { Write-Warning "未找到 deno.exe，跳过 PO Token 服务器依赖安装"; }
    elseif (Test-Path (Join-Path $serverSrc 'node_modules\.package-lock.json')) {
        Info 'deno 依赖已安装'
    } else {
        Info '安装 deno 依赖（可能需要几分钟）...'
        Push-Location $serverSrc
        try {
            $env:NPM_CONFIG_REGISTRY = 'https://registry.npmmirror.com'
            # 注意：不要加 --frozen——残缺锁文件状态下它会只装一部分包（实测踩坑）
            & $deno install --allow-scripts
            if ($LASTEXITCODE -ne 0) { throw "deno install 失败，退出码 $LASTEXITCODE" }
        } finally { Pop-Location }
        Ok 'deno 依赖安装完成'
    }

    # 6d. 服务器启动器（yt.ps1 按需拉起的就是它）
    $startCmd = @'
@echo off
rem bgutil-ytdlp-pot-provider HTTP server (port 4416). Close this window to stop it.
cd /d "%USERPROFILE%\bgutil-ytdlp-pot-provider\server\node_modules"
"%LOCALAPPDATA%\Microsoft\WinGet\Links\deno.exe" run --allow-env --allow-net --allow-ffi=. --allow-read=. ../src/main.ts
pause
'@
    Set-Content -Path (Join-Path $serverSrc 'start-pot-server.cmd') -Value $startCmd -Encoding Ascii
    Ok 'start-pot-server.cmd 已写入'
} else {
    Step '6/6 跳过 PO Token 层（-SkipPotServer）'
}

# ---------------------------------------------------------------- 收尾提示
Remove-Item -Recurse -Force $Temp -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '=========================================' -ForegroundColor Yellow
Write-Host ' 部署完成。部署后注意事项：' -ForegroundColor Yellow
Write-Host '=========================================' -ForegroundColor Yellow
Write-Host " 1. 新开一个终端（PATH/配置需重载）。"
if ($CookiesBrowser -ne 'none') {
Write-Host " 2. 在 $CookiesBrowser 中登录一次 youtube.com，下载前完全退出浏览器"
Write-Host "    （cookie 库被占用会导致 --cookies-from-browser 失败）。"
}
Write-Host " 3. 用法:   yt <视频URL>        需要时自动拉起 PO Token 服务器"
Write-Host "            yt -x <视频URL>    只提取音频"
Write-Host " 4. 保持更新: yt-dlp --update-to nightly（YouTube 改版导致解析失败时先跑这条）"
Write-Host " 5. 输出目录: $OutputDir"
Write-Host ''
