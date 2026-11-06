#!/bin/sh
# sing-box quick mode 安装器
#
# 用法：
#   sh install.sh <domain> [port]
#   GH_TOKEN=<token> sh install.sh <domain> [port]   # 私有仓
#
# 行为：
#   1. 校验 root / 参数 / 依赖 / 架构
#   2. 从 GitHub Release 下载预编译二进制（私有仓用 GH_TOKEN）
#   3. 安装到 /usr/local/bin/sing-box
#   4. 跑一次 `sing-box <domain> [port]`：生成配置 + 安装并启用 systemd 服务
#
# 幂等：重复执行会覆盖二进制、复用已有 uuid/客户端 CA，服务保持单实例。
set -eu

DOMAIN="${1:-}"
PORT="${2:-443}"
REPO="ycxwi/sing-box"
TAG="v1.14.4-quick"

die() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -n "$DOMAIN" ] || die "usage: install.sh <domain> [port]"
[ "$(id -u)" -eq 0 ] || die "must run as root"

for cmd in curl gzip install systemctl uname; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ASSET="sing-box-linux-amd64.gz" ;;
    aarch64) ASSET="sing-box-linux-arm64.gz" ;;
    *)       die "unsupported architecture: $ARCH" ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
echo "[1/4] downloading $ASSET"

if [ -n "${GH_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: token $GH_TOKEN" -L "$URL" -o "$TMP/sing-box.gz" \
        || die "download failed (private repo requires GH_TOKEN with repo scope)"
else
    curl -fsSL -L "$URL" -o "$TMP/sing-box.gz" \
        || die "download failed (if the repo is private, set GH_TOKEN)"
fi

echo "[2/4] verifying archive"
gzip -t "$TMP/sing-box.gz" || die "downloaded archive is corrupt"

echo "[3/4] installing to /usr/local/bin/sing-box"
gzip -dc "$TMP/sing-box.gz" > "$TMP/sing-box"
chmod 755 "$TMP/sing-box"
install -m 755 "$TMP/sing-box" /usr/local/bin/sing-box
/usr/local/bin/sing-box version >/dev/null 2>&1 || die "installed binary failed to run"

echo "[4/4] configuring service for $DOMAIN:$PORT"
/usr/local/bin/sing-box "$DOMAIN" "$PORT"

echo
echo "done. service: sing-box-quick"
echo "  systemctl status sing-box-quick"
echo "  journalctl -u sing-box-quick -f"