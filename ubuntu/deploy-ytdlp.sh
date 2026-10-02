#!/usr/bin/env bash
# ============================================================================
# deploy-ytdlp-ubuntu.sh - 无桌面 Ubuntu Server 一键部署 yt-dlp 下载环境
#   PO Token 服务器模式：本地部署（deno + systemd 用户服务）
#
# 用法:
#   bash deploy-ytdlp-ubuntu.sh [options]
# 选项:
#   -o, --output-dir DIR     下载输出目录          （默认: $HOME/Downloads）
#   -c, --cookies FILE       cookies.txt 路径      （默认: $HOME/.config/yt-dlp/cookies.txt）
#       --skip-pot           跳过 PO Token 服务器层
#       --npm-mirror         使用 npmmirror 镜像源（国内网络环境）
#   -V, --bgutil-ver VER     bgutil 发行版本号      （默认: 2.0.1）
#
# 幂等设计：可重复执行，已完成的步骤自动跳过。首次运行 apt 安装需要 sudo。
# 部署后：需将 cookies.txt（在有浏览器的机器上用 "Get cookies.txt LOCALLY"
# 扩展从已登录的 youtube.com 页面导出）放到指定路径，否则机房 IP 下载会 403。
# ============================================================================
set -euo pipefail

OUTPUT_DIR="$HOME/Downloads"
COOKIES_FILE="$HOME/.config/yt-dlp/cookies.txt"
SKIP_POT=0
NPM_MIRROR=0
BGUTIL_VER="2.0.1"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
        -c|--cookies)     COOKIES_FILE="$2"; shift 2 ;;
        --skip-pot)       SKIP_POT=1; shift ;;
        --npm-mirror)     NPM_MIRROR=1; shift ;;
        -V|--bgutil-ver)  BGUTIL_VER="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# 进度输出辅助函数：step=步骤标题，ok=成功，info=跳过说明，warn=警告
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()    { echo -e "    \033[1;32mOK: $*\033[0m"; }
info()  { echo -e "    \033[2m-- $*\033[0m"; }
warn()  { echo -e "    \033[1;33mWARNING: $*\033[0m"; }

# ---------------------------------------------------------------- 1. apt 依赖
step "1/7 安装 apt 包（ffmpeg、python3-venv、curl）"
# 注意：不能只查 ffmpeg/python3 是否存在——python3-venv 缺失时 venv 创建会在第 2 步失败
# （Debian/Ubuntu 把 ensurepip 拆进 python3-venv 包），所以这里要验证 venv 真正可用
if command -v ffmpeg >/dev/null && command -v python3 >/dev/null \
   && python3 -c "import ensurepip" >/dev/null 2>&1; then
    info "ffmpeg/python3/python3-venv 已存在"
else
    sudo apt-get update -y
    sudo apt-get install -y ffmpeg python3 python3-venv python3-pip curl ca-certificates
fi
ok "apt 包就绪"

# ---------------------------------------------------------------- 2. yt-dlp（venv + nightly）
step "2/7 在独立 venv 中安装 yt-dlp nightly（规避 PEP 668 系统限制）"
VENV="$HOME/.local/yt-dlp-venv"
BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -U pip
# --pre 拉取 nightly 预发布版——稳定版对 YouTube 改版滞后 1-3 周，是 403 的头号来源
"$VENV/bin/pip" install -q -U --pre "yt-dlp[default]"
ln -sf "$VENV/bin/yt-dlp" "$BIN_DIR/yt-dlp"

# 确保 ~/.local/bin 在 PATH 中（登录 shell 生效）
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    if ! grep -qs "$BIN_DIR" "$HOME/.profile"; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
    fi
    info "已通过 ~/.profile 将 $BIN_DIR 加入 PATH（重新登录或: source ~/.profile）"
fi
ok "yt-dlp $("$BIN_DIR/yt-dlp" --version)"

# ---------------------------------------------------------------- 3. 全局配置
step "3/7 写 ~/.config/yt-dlp/config"
CFG_DIR="$HOME/.config/yt-dlp"
mkdir -p "$CFG_DIR"
OUT_NORM="${OUTPUT_DIR/#\~/$HOME}"
mkdir -p "$OUT_NORM"
# 注意：配置文件内容必须保持 ASCII——yt-dlp 按系统代码页读取配置，非 ASCII 会解析失败
cat > "$CFG_DIR/config" <<EOF
-P $OUT_NORM
-o "%(title)s [%(id)s].%(ext)s"

-f bv*+ba/b
--merge-output-format mp4

--cookies $COOKIES_FILE

# 2026: default web client is SABR-locked to 360p; prefer token-capable clients first
--extractor-args youtube:player_client=web_embedded,android_vr,tv_downgraded
EOF
# cookies 等同登录凭证——收紧权限，防其他用户/进程读取
if [[ -f "$COOKIES_FILE" ]]; then
    chmod 600 "$COOKIES_FILE"
    ok "配置已写入；cookies 文件已就位"
else
    warn "配置已写入，但未找到 cookies 文件：$COOKIES_FILE"
    warn "请在有浏览器的机器上用 'Get cookies.txt LOCALLY' 扩展导出后放过来——没有它，机房 IP 下载必 403"
fi

# ---------------------------------------------------------------- 4. deno
if [[ $SKIP_POT -eq 1 ]]; then
    step "4/7 跳过 PO Token 层（--skip-pot）"
    DENO_BIN=""
else
    step "4/7 安装 deno"
    DENO_BIN="$HOME/.deno/bin/deno"
    if [[ -x "$DENO_BIN" ]]; then
        info "deno 已安装"
    else
        curl -fsSL https://deno.land/install.sh | sh -s -- -y
    fi
    ok "$("$DENO_BIN" --version | head -1)"
fi

# ---------------------------------------------------------------- 5+6. bgutil 服务器（本地）
if [[ $SKIP_POT -eq 0 ]]; then
    step "5/7 部署 bgutil-ytdlp-pot-provider v$BGUTIL_VER（服务器源码 + 插件）"
    SERVER_ROOT="$HOME/bgutil-ytdlp-pot-provider"
    SERVER_DIR="$SERVER_ROOT/server"

    if [[ -f "$SERVER_DIR/src/main.ts" ]]; then
        info "服务器源码已存在"
    else
        TMPD="$(mktemp -d)"
        curl -fsSL "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/archive/refs/tags/$BGUTIL_VER.tar.gz" -o "$TMPD/repo.tar.gz"
        tar -xzf "$TMPD/repo.tar.gz" -C "$TMPD"
        mkdir -p "$SERVER_ROOT"
        mv "$TMPD/bgutil-ytdlp-pot-provider-$BGUTIL_VER/server" "$SERVER_DIR"
        rm -rf "$TMPD"
        ok "服务器源码 -> $SERVER_DIR"
    fi

    # 插件（zip）-> ~/.config/yt-dlp/plugins/（yt-dlp 支持直接加载 zip 插件）
    PLUG_DIR="$CFG_DIR/plugins"
    mkdir -p "$PLUG_DIR"
    PLUG_ZIP="$PLUG_DIR/bgutil-ytdlp-pot-provider.zip"
    if [[ -f "$PLUG_ZIP" ]]; then
        info "插件 zip 已存在"
    else
        curl -fsSL "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/$BGUTIL_VER/bgutil-ytdlp-pot-provider.zip" -o "$PLUG_ZIP"
        ok "插件 zip 已安装 -> $PLUG_ZIP"
    fi

    # deno 依赖（npmjs 直连在国内网络常失败，npmmirror 为可靠备选）
    if [[ -f "$SERVER_DIR/node_modules/.deno" || -d "$SERVER_DIR/node_modules" && -n "$(ls -A "$SERVER_DIR/node_modules" 2>/dev/null)" ]]; then
        info "deno 依赖已安装"
    else
        (cd "$SERVER_DIR"
         if [[ $NPM_MIRROR -eq 1 ]]; then export NPM_CONFIG_REGISTRY="https://registry.npmmirror.com"; fi
         # 注意：不要加 --frozen——残缺锁文件状态下它会只装一部分包（实测踩坑）
         "$DENO_BIN" install --allow-scripts)
        ok "deno 依赖安装完成"
    fi
else
    step "5/7 跳过 bgutil 部署（--skip-pot）"
    SERVER_DIR=""
fi

# ---------------------------------------------------------------- 6. systemd 用户服务
if [[ $SKIP_POT -eq 0 ]]; then
    step "6/7 创建 systemd 用户服务（开机自启 + 崩溃自动重启）"
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"
    cat > "$SYSTEMD_DIR/bgutil-pot.service" <<EOF
[Unit]
Description=bgutil yt-dlp PO Token provider server (port 4416)
After=network.target

[Service]
WorkingDirectory=%h/bgutil-ytdlp-pot-provider/server
ExecStart=$DENO_BIN run --allow-env --allow-net --allow-ffi=. --allow-read=. src/main.ts
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now bgutil-pot.service
    # enable-linger：注销后用户服务继续运行（服务器场景必需）
    sudo loginctl enable-linger "$USER" 2>/dev/null || warn "无法启用 linger；服务仅在登录会话期间运行"
    sleep 3
    if curl -sf --max-time 5 http://127.0.0.1:4416/ping >/dev/null; then
        ok "PO Token 服务器已在 4416 端口就绪"
    else
        warn "服务器暂未响应（deno 冷启动约需 30s）；排查: systemctl --user status bgutil-pot"
    fi
else
    step "6/7 跳过 systemd 服务（--skip-pot）"
fi

# ---------------------------------------------------------------- 7. yt 包装命令
step "7/7 创建 'yt' 包装命令"
cat > "$BIN_DIR/yt" <<'EOF'
#!/usr/bin/env bash
# yt - yt-dlp 包装命令：PO Token 服务器（4416 端口）未监听时自动拉起
POT_URL="http://127.0.0.1:4416/ping"
YTDLP="$(command -v yt-dlp)" || { echo "yt-dlp not found in PATH" >&2; exit 1; }

pot_ok() { curl -sf --max-time 2 "$POT_URL" >/dev/null 2>&1; }

if ! pot_ok; then
    echo "[yt] PO Token 服务器未响应，正在启动 bgutil-pot.service ..."
    systemctl --user start bgutil-pot.service 2>/dev/null || true
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
echo " 1. 重新登录或执行: source ~/.profile   （使 ~/.local/bin 进入 PATH）"
echo " 2. 放置 cookies.txt 到: $COOKIES_FILE  （需 chmod 600）"
echo " 3. 用法:  yt <视频URL>     |  yt -x <视频URL>  （只取音频）"
echo " 4. 服务日志:  journalctl --user -u bgutil-pot -f"
echo " 5. 保持更新:  yt-dlp --update-to nightly（或重跑 pip -U --pre 命令）"
echo " 6. 输出目录:  $OUTPUT_DIR"
echo
