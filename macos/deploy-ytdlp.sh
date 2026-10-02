#!/usr/bin/env bash
# ============================================================================
# deploy-ytdlp-macos.sh - macOS 一键部署 yt-dlp 下载环境
#   同时支持 Apple Silicon (arm64) 与 Intel (x86_64)，macOS 12+，无需 Rosetta。
#
#   ffmpeg 安装策略按系统版本分流（Homebrew 自 2024-10 起只为最近三个大版本
#   提供 bottle；macOS 13 上 ffmpeg 走源码编译需数小时，不实用）：
#     - macOS 14+  : Homebrew（已有 brew 则直接用；否则提示安装）
#     - macOS 13-  : 静态二进制（ffmpeg + ffprobe，按 uname -m 选架构）
#
# 用法:
#   bash deploy-ytdlp-macos.sh [options]
# 选项:
#   -o, --output-dir DIR     下载输出目录  （默认: ~/Downloads）
#   -b, --browser NAME       firefox|chrome|edge|brave|none  （默认: firefox；
#                            macOS 上 chrome/edge 走钥匙串解密，可用——
#                            Windows 上的 app-bound 加密问题不存在）
#       --skip-pot           跳过 PO Token 服务器层
#       --npm-mirror         使用 npmmirror 镜像源（国内网络环境）
#   -V, --bgutil-ver VER     bgutil 发行版本号（默认: 2.0.1）
#
# 幂等设计：可重复执行。新机首次运行会触发 Xcode CLT 安装对话框，装完重跑即可。
# ============================================================================
set -euo pipefail

OUTPUT_DIR="$HOME/Downloads"
BROWSER="firefox"
SKIP_POT=0
NPM_MIRROR=0
BGUTIL_VER="2.0.1"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -b|--browser)    BROWSER="$2";    shift 2 ;;
        --skip-pot)      SKIP_POT=1;      shift ;;
        --npm-mirror)    NPM_MIRROR=1;    shift ;;
        -V|--bgutil-ver) BGUTIL_VER="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# 架构（arm64 / x86_64）与大版本号——后续所有二选一分流都基于这两个值
ARCH="$(uname -m)"
MAC_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()    { echo -e "    \033[1;32mOK: $*\033[0m"; }
info()  { echo -e "    \033[2m-- $*\033[0m"; }
warn()  { echo -e "    \033[1;33mWARNING: $*\033[0m"; }

# 带路径报错的 mkdir：set -e 下裸 mkdir 失败会静默退出且不带路径，
# 排障时完全猜不到挂在哪个目录（真实教训：-o /data/downloads 挂在 root 属主的 /data）
mk_dir() {
    mkdir -p "$1" || {
        echo "错误：无法创建目录 $1" >&2
        echo "  - 检查该路径的属主与权限；系统目录请先 sudo mkdir 并 chown 给当前用户；" >&2
        echo "  - 或改用 -o 指定一个当前用户可写的目录。" >&2
        exit 1
    }
}

echo "Detected: macOS $MAC_MAJOR on $ARCH"

# ---------------------------------------------------------------- 1. 前置依赖
step "1/7 检查前置依赖（Xcode CLT / python3）"
# python3 由 Xcode Command Line Tools 提供，新 Mac 往往没装
if ! xcode-select -p >/dev/null 2>&1; then
    warn "未安装 Xcode Command Line Tools（python3 依赖它）"
    xcode-select --install || true
    echo "    => 系统已弹出安装对话框，点击'安装'，完成后重新运行本脚本。"
    exit 1
fi
if ! command -v python3 >/dev/null; then
    echo "装有 CLT 但找不到 python3，请从 python.org 安装 3.9+"; exit 1
fi
ok "python3 $(python3 --version | cut -d' ' -f2)"

# ---------------------------------------------------------------- 2. yt-dlp（venv + nightly）
step "2/7 在独立 venv 中安装 yt-dlp nightly"
VENV="$HOME/.local/yt-dlp-venv"
BIN_DIR="$HOME/.local/bin"
mk_dir "$BIN_DIR"
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -U pip
# --pre 拉取 nightly 预发布版——稳定版对 YouTube 改版滞后 1-3 周，是 403 的头号来源
"$VENV/bin/pip" install -q -U --pre "yt-dlp[default]"
ln -sf "$VENV/bin/yt-dlp" "$BIN_DIR/yt-dlp"

# PATH：macOS 默认 shell 为 zsh -> 写 ~/.zprofile（bash 用户兼容写 ~/.profile）
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    for RC in "$HOME/.zprofile" "$HOME/.profile"; do
        grep -qs "$BIN_DIR" "$RC" || echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$RC"
    done
    info "已通过 ~/.zprofile 将 $BIN_DIR 加入 PATH（新开终端或: source ~/.zprofile）"
fi
ok "yt-dlp $("$BIN_DIR/yt-dlp" --version)"

# ---------------------------------------------------------------- 3. ffmpeg
step "3/7 安装 ffmpeg（策略取决于 macOS 版本）"
have_ffmpeg() { command -v ffmpeg >/dev/null || [[ -x "$BIN_DIR/ffmpeg" ]]; }
if have_ffmpeg; then
    info "ffmpeg 已存在: $(command -v ffmpeg || echo "$BIN_DIR/ffmpeg")"
elif command -v brew >/dev/null 2>&1 && [[ "$MAC_MAJOR" -ge 14 ]]; then
    # macOS 14+ 有官方 bottle，brew 是首选渠道
    brew install ffmpeg
    ok "已通过 Homebrew 安装"
else
    if [[ "$MAC_MAJOR" -lt 14 ]] && command -v brew >/dev/null 2>&1; then
        warn "macOS $MAC_MAJOR 无 ffmpeg bottle（源码编译需数小时），改用静态二进制"
    fi
    # 静态二进制按架构匹配（ffmpeg-static 与 ffprobe-static 为同作者项目）
    for TOOL in ffmpeg ffprobe; do
        REPO="$TOOL-static"
        [[ "$TOOL" == "ffprobe" ]] && REPO="ffprobe-static"
        URL="https://github.com/eugeneware/$REPO/releases/latest/download/$TOOL-darwin-$ARCH"
        info "downloading $TOOL ($ARCH) ..."
        curl -fsSL "$URL" -o "$BIN_DIR/$TOOL"
        chmod +x "$BIN_DIR/$TOOL"
        # 清除 Gatekeeper 隔离属性，否则首次运行被"无法验证开发者"拦截
        xattr -d com.apple.quarantine "$BIN_DIR/$TOOL" 2>/dev/null || true
    done
    ok "静态 ffmpeg + ffprobe -> $BIN_DIR（按 $ARCH 匹配，无需 Rosetta）"
fi

# ---------------------------------------------------------------- 4. 全局配置
step "4/7 写 ~/.config/yt-dlp/config"
CFG_DIR="$HOME/.config/yt-dlp"
mk_dir "$CFG_DIR"
mk_dir "$OUTPUT_DIR"
# 注意：配置文件内容必须保持 ASCII——yt-dlp 按系统代码页读取配置，非 ASCII 会解析失败
{
    echo "-P $OUTPUT_DIR"
    echo '-o "%(title)s [%(id)s].%(ext)s"'
    echo ""
    echo "-f bv*+ba/b"
    echo "--merge-output-format mp4"
    if [[ "$BROWSER" != "none" ]]; then
        echo ""
        echo "# cookies pass the datacenter-IP 403; on macOS chrome/edge also work (Keychain)"
        echo "--cookies-from-browser $BROWSER"
    fi
    echo ""
    echo "# 2026: default web client is SABR-locked to 360p; prefer token-capable clients first"
    echo "--extractor-args youtube:player_client=web_embedded,android_vr,tv_downgraded"
} > "$CFG_DIR/config"
ok "配置已写入（输出目录=$OUTPUT_DIR, cookies=$BROWSER）"

# ---------------------------------------------------------------- 5. deno（EJS 挑战求解必需，与 PO Token 层无关）
# 不能放进 --skip-pot 分支：即使不部署 bgutil，yt-dlp 自身的 n-challenge /
# 签名解算同样需要 JS 运行时，缺了会报 "n challenge solving failed" +
# "The page needs to be reloaded"
step "5/7 安装 deno（yt-dlp EJS 挑战求解必需）"
DENO_BIN="$HOME/.deno/bin/deno"
if [[ -x "$DENO_BIN" ]] || command -v deno >/dev/null; then
    info "deno 已安装"
else
    # 官方安装器自动匹配 arm64/x86_64 构建版本
    curl -fsSL https://deno.land/install.sh | sh -s -- -y >/dev/null
fi
ok "$("$DENO_BIN" --version 2>/dev/null | head -1 || deno --version | head -1)"

if [[ $SKIP_POT -eq 1 ]]; then
    step "5b/7 跳过 bgutil PO Token 层（--skip-pot）"
else
    step "5b/7 部署 bgutil PO Token provider v$BGUTIL_VER"

    SERVER_DIR="$HOME/bgutil-ytdlp-pot-provider/server"
    if [[ -f "$SERVER_DIR/src/main.ts" ]]; then
        info "服务器源码已存在"
    else
        TMPD="$(mktemp -d)"
        curl -fsSL "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/archive/refs/tags/$BGUTIL_VER.tar.gz" -o "$TMPD/repo.tar.gz"
        tar -xzf "$TMPD/repo.tar.gz" -C "$TMPD"
        mk_dir "$(dirname "$SERVER_DIR")"
        mv "$TMPD/bgutil-ytdlp-pot-provider-$BGUTIL_VER/server" "$SERVER_DIR"
        rm -rf "$TMPD"
        ok "服务器源码 -> $SERVER_DIR"
    fi

    PLUG_DIR="$CFG_DIR/plugins"
    mk_dir "$PLUG_DIR"
    PLUG_ZIP="$PLUG_DIR/bgutil-ytdlp-pot-provider.zip"
    if [[ -f "$PLUG_ZIP" ]]; then
        info "插件 zip 已存在"
    else
        curl -fsSL "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/$BGUTIL_VER/bgutil-ytdlp-pot-provider.zip" -o "$PLUG_ZIP"
        ok "插件 zip 已安装"
    fi

    if [[ -d "$SERVER_DIR/node_modules" && -n "$(ls -A "$SERVER_DIR/node_modules" 2>/dev/null)" ]]; then
        info "deno 依赖已安装"
    else
        (cd "$SERVER_DIR"
         if [[ $NPM_MIRROR -eq 1 ]]; then export NPM_CONFIG_REGISTRY="https://registry.npmmirror.com"; fi
         # 注意：不要加 --frozen——残缺锁文件状态下它会只装一部分包（实测踩坑）
         "$DENO_BIN" install --allow-scripts)
        ok "deno 依赖安装完成"
    fi
fi

# ---------------------------------------------------------------- 6. launchd 自启服务
if [[ $SKIP_POT -eq 0 ]]; then
    step "6/7 创建 launchd LaunchAgent（开机自启 + 崩溃自动拉起）"
    PLIST="$HOME/Library/LaunchAgents/com.bgutil.pot.plist"
    mk_dir "$HOME/Library/LaunchAgents"
    # RunAtLoad=登录时启动；KeepAlive=进程退出即重启（等效 systemd Restart=always）
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.bgutil.pot</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DENO_BIN</string>
        <string>run</string>
        <string>--allow-env</string>
        <string>--allow-net</string>
        <string>--allow-ffi=.</string>
        <string>--allow-read=.</string>
        <string>src/main.ts</string>
    </array>
    <key>WorkingDirectory</key><string>$SERVER_DIR</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
    # bootout 清掉可能存在的旧实例，再 bootstrap 加载新版
    launchctl bootout "gui/$(id -u)/com.bgutil.pot" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    sleep 3
    if curl -sf --max-time 5 http://127.0.0.1:4416/ping >/dev/null; then
        ok "PO Token 服务器已在 4416 端口就绪（KeepAlive：崩溃与重启后自动恢复）"
    else
        warn "暂未响应（deno 冷启动约需 30s）；排查: launchctl print gui/\$(id -u)/com.bgutil.pot"
    fi
else
    step "6/7 跳过 launchd 服务（--skip-pot）"
fi

# ---------------------------------------------------------------- 7. yt 包装命令
step "7/7 创建 'yt' 包装命令"
cat > "$BIN_DIR/yt" <<'EOF'
#!/usr/bin/env bash
# yt - yt-dlp 包装命令：PO Token 服务器（launchd 管理）未监听时自动拉起
POT_URL="http://127.0.0.1:4416/ping"
YTDLP="$(command -v yt-dlp)" || YTDLP="$HOME/.local/bin/yt-dlp"
[[ -x "$YTDLP" ]] || { echo "yt-dlp not found" >&2; exit 1; }

pot_ok() { curl -sf --max-time 2 "$POT_URL" >/dev/null 2>&1; }

if ! pot_ok; then
    echo "[yt] PO Token 服务器未响应，正在通过 launchctl 启动 ..."
    launchctl kickstart "gui/$(id -u)/com.bgutil.pot" 2>/dev/null || true
    for _ in $(seq 1 20); do
        sleep 3
        pot_ok && break
    done
    if pot_ok; then echo "[yt] PO Token 服务器就绪。"
    else echo "[yt] WARNING: 等待 60s 仍未就绪，继续执行" >&2; fi
fi

# exec + "$@" 原样透传参数，无字符串拼接执行，规避注入面
exec "$YTDLP" "$@"
EOF
chmod +x "$BIN_DIR/yt"
ok "yt 命令 -> $BIN_DIR/yt"

# ---------------------------------------------------------------- 收尾提示
echo
echo "========================================="
echo " 部署完成。部署后注意事项："
echo "========================================="
echo " 1. 新开终端（或: source ~/.zprofile）使 PATH 生效"
echo " 2. 在 $BROWSER 中登录一次 youtube.com；下载前完全退出浏览器"
echo " 3. 用法:  yt <视频URL>   |   yt -x <视频URL>  （只取音频）"
echo " 4. 服务状态:  launchctl print gui/\$(id -u)/com.bgutil.pot"
echo " 5. 保持更新:  yt-dlp --update-to nightly（或重跑 pip -U --pre 命令）"
echo " 6. 输出目录:  $OUTPUT_DIR"
echo
