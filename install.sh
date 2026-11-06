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

[ "$(id -u)" -eq 0 ] || die "must run as root"
# 无参数是合法用法：装完后把终端交给 sing-box，由它交互询问域名/端口。
# 注意 stdin 必须是终端——`curl | sh` 会拿管道当 stdin，那种用法必须带参数（见 README）。

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
    # 私有仓：github.com/releases/download 对匿名/仅有 token header 的请求都返 404，
    # 必须先经 API 拿 asset id，再带 Accept: application/octet-stream 取二进制。
    command -v python3 >/dev/null 2>&1 || die "GH_TOKEN path requires python3 to parse the API response"
    ASSET_ID=$(curl -fsSL -H "Authorization: token $GH_TOKEN" \
        "https://api.github.com/repos/$REPO/releases/tags/$TAG" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["assets"][0]["id"])') \
        || die "cannot resolve release asset id (check token scope: repo)"
    echo "      asset id: $ASSET_ID (private repo, via API)"
    curl -fsSL -H "Authorization: token $GH_TOKEN" -H "Accept: application/octet-stream" \
        "https://api.github.com/repos/$REPO/releases/assets/$ASSET_ID" -o "$TMP/sing-box.gz" \
        || die "download failed (private repo asset)"
else
    curl -fsSL -L "$URL" -o "$TMP/sing-box.gz" \
        || die "download failed (public repo path; set GH_TOKEN if the repo is private)"
fi

echo "[2/4] verifying archive"
gzip -t "$TMP/sing-box.gz" || die "downloaded archive is corrupt"

echo "[3/4] installing to /usr/local/bin/sing-box"
gzip -dc "$TMP/sing-box.gz" > "$TMP/sing-box"
chmod 755 "$TMP/sing-box"
install -m 755 "$TMP/sing-box" /usr/local/bin/sing-box
/usr/local/bin/sing-box version >/dev/null 2>&1 || die "installed binary failed to run"

echo "[4/4] configuring service"
if [ $# -eq 0 ]; then
    # 无参数：清理临时件，把终端交给 sing-box 交互询问域名/端口。
    # 不用 exec —— 后面要等 ACME 签下证书再打印安装链接。
    rm -rf "$TMP"
    trap - EXIT INT TERM
    /usr/local/bin/sing-box
else
    /usr/local/bin/sing-box "$DOMAIN" "$PORT"
fi

# 服务已交给 systemd；证书签下来后会自动生成一次性安装链接。
# 等它落盘（最多 60s）再打印——否则用户只看到“装完了”却不知道链接去哪了。
echo
echo "waiting for ACME certificate + install link (up to 60s)..."
i=0
while [ "$i" -lt 60 ]; do
    if [ -f /etc/sing-box/install-url.txt ]; then
        break
    fi
    i=$((i + 1))
    sleep 1
done
if [ -f /etc/sing-box/install-url.txt ]; then
    echo
    echo "install link (one-time, valid 30 min):"
    echo "  $(cat /etc/sing-box/install-url.txt)"
    echo "  paste it into the router page (service -> Sing-Box nodes)"
else
    echo
    echo "install link not ready yet (ACME may still be running)."
    echo "check later: cat /etc/sing-box/install-url.txt"
fi

echo
echo "done. service: sing-box-quick"
echo "  systemctl status sing-box-quick"
echo "  journalctl -u sing-box-quick -f"