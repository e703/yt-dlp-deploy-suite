#!/usr/bin/env bash
# ============================================================================
# deploy-ytdlp-ubuntu-docker.sh - 无桌面 Ubuntu Server 一键部署 yt-dlp 下载环境
#   PO Token 服务器模式：DOCKER COMPOSE（官方镜像 brainicism/bgutil-ytdlp-pot-provider）
#
# 用法:
#   bash deploy-ytdlp-ubuntu-docker.sh [options]
# 选项:
#   -o, --output-dir DIR     下载输出目录          （默认: $HOME/Downloads）
#   -c, --cookies FILE       cookies.txt 路径      （默认: $HOME/.config/yt-dlp/cookies.txt）
#       --skip-pot           跳过 PO Token 服务器层
#   -d, --compose-dir DIR    docker-compose.yml 存放目录（默认: $HOME/bgutil-pot）
#   -V, --bgutil-ver VER     bgutil 插件发行版本号  （默认: 2.0.1）
#
# 幂等设计：可重复执行。首次运行 apt 安装需要 sudo。
# 关键点：容器只负责计算 PO Token，**插件 zip 仍须装在宿主机**——
# yt-dlp 在宿主机运行，通过 HTTP (127.0.0.1:4416) 与容器通信。
# ============================================================================
set -euo pipefail

OUTPUT_DIR="$HOME/Downloads"
COOKIES_FILE="$HOME/.config/yt-dlp/cookies.txt"
SKIP_POT=0
COMPOSE_DIR="$HOME/bgutil-pot"
BGUTIL_VER="2.0.1"

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        -c|--cookies)      COOKIES_FILE="$2"; shift 2 ;;
        --skip-pot)        SKIP_POT=1; shift ;;
        -d|--compose-dir)  COMPOSE_DIR="$2"; shift 2 ;;
        -V|--bgutil-ver)   BGUTIL_VER="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# 进度输出辅助函数：step=步骤标题，ok=成功，info=跳过说明，warn=警告
step()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
ok()    { echo -e "    \033[1;32mOK: $*\033[0m"; }
info()  { echo -e "    \033[2m-- $*\033[0m"; }
warn()  { echo -e "    \033[1;33mWARNING: $*\033[0m"; }

# 辅助函数：当前用户不在 docker 组时自动回退 sudo（避免强行要求重新登录）
docker_cmd() {
    if docker info >/dev/null 2>&1; then docker "$@"
    else sudo docker "$@"; fi
}

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

# ---------------------------------------------------------------- 4. docker + compose
if [[ $SKIP_POT -eq 1 ]]; then
    step "4/7 跳过 PO Token 层（--skip-pot）"
else
    step "4/7 检查 Docker + Compose 插件"
    if ! command -v docker >/dev/null; then
        info "安装 Docker Engine + compose 插件..."
        sudo apt-get update -y
        sudo apt-get install -y docker.io docker-compose-v2 || sudo apt-get install -y docker.io docker-compose
        sudo systemctl enable --now docker
    fi
    docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1 || {
        echo "Docker Compose 不可用（需要 docker-compose-v2 插件）"; exit 1; }
    # 尽力把用户加入 docker 组（免 sudo）；本会话内仍用 docker_cmd 的 sudo 回退
    docker info >/dev/null 2>&1 || sudo usermod -aG docker "$USER" 2>/dev/null || true
    ok "docker 就绪"
fi

# ---------------------------------------------------------------- 5+6. bgutil（Compose 部署）
if [[ $SKIP_POT -eq 0 ]]; then
    step "5/7 通过 Docker Compose 部署 bgutil PO Token 服务器 -> $COMPOSE_DIR"

    # 5a. 插件 zip 装在宿主机（yt-dlp 经 HTTP 与容器通信，容器不含插件）
    PLUG_DIR="$CFG_DIR/plugins"
    mkdir -p "$PLUG_DIR"
    PLUG_ZIP="$PLUG_DIR/bgutil-ytdlp-pot-provider.zip"
    if [[ -f "$PLUG_ZIP" ]]; then
        info "插件 zip 已存在"
    else
        curl -fsSL "https://github.com/Brainicism/bgutil-ytdlp-pot-provider/releases/download/$BGUTIL_VER/bgutil-ytdlp-pot-provider.zip" -o "$PLUG_ZIP"
        ok "插件 zip 已安装 -> $PLUG_ZIP"
    fi

    # 5b. compose 文件（端口仅绑 127.0.0.1——本地辅助服务，不对局域网暴露）
    mkdir -p "$COMPOSE_DIR"
    cat > "$COMPOSE_DIR/docker-compose.yml" <<'EOF'
services:
  bgutil-ytdlp-pot-provider:
    image: brainicism/bgutil-ytdlp-pot-provider:latest
    container_name: bgutil-pot
    restart: unless-stopped
    # bind to loopback only: local helper for yt-dlp, not a public service
    ports:
      - "127.0.0.1:4416:4416"
EOF

    # 6a. 启动容器
    step "6/7 启动容器"
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
        docker_cmd compose -f "$COMPOSE_DIR/docker-compose.yml" up -d
    else
        sudo docker-compose -f "$COMPOSE_DIR/docker-compose.yml" up -d
    fi

    # 等待就绪（容器内冷启动约需 30s）
    pot_ok() { curl -sf --max-time 3 http://127.0.0.1:4416/ping >/dev/null 2>&1; }
    for _ in $(seq 1 20); do
        pot_ok && break
        sleep 3
    done
    if pot_ok; then
        ok "PO Token 服务器已在 4416 端口就绪（restart=unless-stopped：重启后自动拉起）"
    else
        warn "容器暂未响应；查看日志: docker logs bgutil-pot"
    fi
else
    step "5/7 + 6/7 跳过 bgutil（--skip-pot）"
fi

# ---------------------------------------------------------------- 7. yt 包装命令
step "7/7 创建 'yt' 包装命令"
cat > "$BIN_DIR/yt" <<EOF
#!/usr/bin/env bash
# yt - yt-dlp 包装命令：PO Token 服务器（docker）未监听时自动拉起
POT_URL="http://127.0.0.1:4416/ping"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
YTDLP="\$(command -v yt-dlp)" || { echo "yt-dlp not found in PATH" >&2; exit 1; }

pot_ok() { curl -sf --max-time 2 "\$POT_URL" >/dev/null 2>&1; }

dc() {
    if docker compose version >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then docker compose -f "\$COMPOSE_FILE" up -d
        else sudo docker compose -f "\$COMPOSE_FILE" up -d; fi
    else
        sudo docker-compose -f "\$COMPOSE_FILE" up -d
    fi
}

if ! pot_ok; then
    echo "[yt] PO Token 服务器未响应，正在通过 docker compose 启动 ..."
    dc 2>/dev/null || true
    for _ in \$(seq 1 20); do
        sleep 3
        pot_ok && break
    done
    if pot_ok; then echo "[yt] PO Token 服务器就绪。"
    else echo "[yt] WARNING: 等待 60s 仍未就绪，继续执行" >&2; fi
fi

# exec + "\$@" 原样透传参数，无字符串拼接执行，规避注入面
exec "\$YTDLP" "\$@"
EOF
chmod +x "$BIN_DIR/yt"
ok "yt 命令 -> $BIN_DIR/yt"

# ---------------------------------------------------------------- 收尾提示
echo
echo "========================================="
echo " 部署完成。部署后注意事项："
echo "========================================="
echo " 1. 重新登录或执行: source ~/.profile   （使 ~/.local/bin 与 docker 组生效）"
echo " 2. 放置 cookies.txt 到: $COOKIES_FILE  （需 chmod 600）"
echo " 3. 用法:  yt <视频URL>     |  yt -x <视频URL>  （只取音频）"
echo " 4. 容器日志:  docker logs -f bgutil-pot"
echo " 5. 保持更新:  yt-dlp --update-to nightly（或重跑 pip -U --pre 命令）"
echo " 6. 输出目录:  $OUTPUT_DIR"
echo
