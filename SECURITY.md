# 安全说明与安全审计 (Security Policy & Audit)

本项目是一组**部署脚本**：它们会安装软件、写入系统配置、生成常驻服务。本文档记录安全审计结论、
已知风险点与缓解措施。发现安全问题请优先通过 Issue 私密描述联系维护者，**不要直接公开细节**。

## 审计范围与结论（2026-10-03，v1.0）

| 风险域 | 评估 | 缓解措施（已内置） |
|---|---|---|
| 凭证处理（cookies） | **高风险面，重点管控** | Ubuntu/macOS 版：cookies.txt 由用户放置，脚本自动 `chmod 600`；Windows 版走 `--cookies-from-browser`，不落盘；`.gitignore` 显式排除 `cookies.txt` / `*.cookies`；文档反复提示"等同登录凭证，勿提交勿外传" |
| 网络暴露面 | 低 | PO Token 服务器仅监听 `127.0.0.1:4416`（systemd / launchd / Docker Compose 三处一致）；Docker 端口映射绑回环，不对局域网开放 |
| 注入面（参数透传） | 低 | `yt` 包装命令统一用 `exec "$YTDLP" "$@"`（bash）/ `& $YtDlpPath @args`（PowerShell）透传，无 `eval`、无字符串拼接执行；URL 由用户自身输入 |
| 特权提升 | 中（仅安装期） | 仅 apt/brew/winget 安装阶段需要 sudo/管理员；服务与文件全部落在用户目录（`~/.local`、`%LOCALAPPDATA%`），不写系统级配置 |
| 供应链依赖 | **中——最需要关注** | 见下节"第三方二进制与依赖清单" |
| 敏感信息泄露 | 低 | 脚本全程使用 `$HOME` / `$env:USERPROFILE` 等环境变量，无硬编码个人路径；输出文件名取自视频标题，与用户身份无关 |

## 第三方二进制与依赖清单

| 依赖 | 来源 | 信任边界 | 说明 |
|---|---|---|---|
| yt-dlp | PyPI 官方包（venv 内 `pip -U --pre`）/ winget | 高 | nightly 含未发布代码，属项目官方渠道 |
| ffmpeg | apt / brew / winget；**macOS ≤13 走 ffmpeg-static** | 高 / **中** | 系统包管理器渠道可信；ffmpeg-static 为第三方预编译 |
| ffprobe（macOS ≤13） | `eugeneware/ffprobe-static` GitHub Release | **中** | 同 ffmpeg-static |
| deno | deno.land 官方安装脚本 | 高 | 自动匹配 arm64/x86_64 |
| bgutil 插件与服务器源码 | `Brainicism/bgutil-ytdlp-pot-provider` GitHub Release / 源码 | 高 | 上游开源项目 |
| npm 依赖（deno install） | npmjs；可选 `registry.npmmirror.com` 镜像 | 中 | 镜像仅在中国网络环境下由用户显式以 `--npm-mirror` 启用 |

**macOS ≤13 静态二进制的建议校验**：下载后可执行
`shasum -a 256 ~/.local/bin/ffmpeg` 与上游 Release 页面公布的校验和比对；
本脚本的长期目标是在 Release 中固化校验和清单（见 TODO）。

## 已知设计取舍

1. **nightly 优先于稳定版**：yt-dlp 稳定版对 YouTube 改版滞后 1–3 周，是 403 的头号来源；
   nightly 为官方预发布渠道，风险可接受且可随时回退。
2. **`--pre` 安装语义**：venv 隔离安装，不污染系统 Python（同时规避 Ubuntu PEP 668）。
3. **launchd/systemd 用户级服务**：PO Token 服务器以当前用户身份常驻，权限收敛于用户目录。
4. **PO Token 服务器"按需拉起"**：Windows `yt.cmd`/`yt.ps1` 会在 4416 未监听时自动启动服务器——
   启动的最小化窗口是**正常组件，不是弹窗广告**，关闭它只影响需要 PO Token 的场景。

## 用户侧安全清单（部署后建议自查）

```bash
# 1. cookies 权限（Ubuntu/macOS）
stat -c "%a %n" ~/.config/yt-dlp/cookies.txt     # 应为 600

# 2. 确认 PO Token 服务器未暴露到局域网
ss -tlnp | grep 4416                              # 地址应为 127.0.0.1:4416

# 3. 提交前确认凭证不入库
git check-ignore ~/.config/yt-dlp/cookies.txt && echo "已忽略"
```
