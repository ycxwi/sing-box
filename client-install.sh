#!/bin/sh
# sing-box 客户端安装器（OpenWrt / iStoreOS 软路由版）
#
# 用法：
#   sh client-install.sh <server> <port> <uuid> <password> <cert> <key> [socks-port]
#
# 参数：
#   server      服务端域名（同时作为 TLS serverName）
#   port        服务端 TUIC 端口（UDP）
#   uuid        服务端启动时打印的 uuid
#   password    服务端启动时打印的 password
#   cert        客户端证书路径（从服务端 /etc/sing-box/client.pem 拷来）
#   key         客户端私钥路径（/etc/sing-box/client.key）
#   socks-port  本地 socks5 监听端口，默认 1081
#
# 说明：客户端二进制用**静态编译版**（CGO_ENABLED=0），因为 OpenWrt 是 musl libc，
# glibc 动态链接的二进制无法运行。静态版与 glibc 版同时在 Release 里。
set -eu

SERVER="${1:-}"
PORT="${2:-}"
UUID="${3:-}"
PASSWORD="${4:-}"
CERT="${5:-}"
KEY="${6:-}"
SOCKS_PORT="${7:-1081}"

REPO="ycxwi/sing-box"
TAG="v1.14.4-quick"
BIN=/usr/bin/sbox-client
CONF_DIR=/etc/sbox-client

die() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -n "$SERVER" ] && [ -n "$PORT" ] && [ -n "$UUID" ] && [ -n "$PASSWORD" ] && [ -n "$CERT" ] && [ -n "$KEY" ] \
    || die "usage: client-install.sh <server> <port> <uuid> <password> <cert> <key> [socks-port]"
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$CERT" ] || die "client certificate not found: $CERT"
[ -f "$KEY" ] || die "client key not found: $KEY"

for cmd in curl gzip install; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ASSET="sing-box-linux-amd64-static.gz" ;;
    aarch64) ASSET="sing-box-linux-arm64-static.gz" ;;
    *)       die "unsupported architecture: $ARCH (only amd64/arm64 static builds are published)" ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

echo "[1/4] downloading $ASSET (static, musl-compatible)"
curl -fsSL -L "https://github.com/$REPO/releases/download/$TAG/$ASSET" -o "$TMP/sb.gz" \
    || die "download failed: $ASSET"

echo "[2/4] verifying and installing binary"
gzip -t "$TMP/sb.gz" || die "downloaded archive is corrupt"
gzip -dc "$TMP/sb.gz" > "$TMP/sb"
chmod 755 "$TMP/sb"
install -m 755 "$TMP/sb" "$BIN"
"$BIN" version >/dev/null 2>&1 || die "installed binary failed to run (arch/libc mismatch?)"

echo "[3/4] installing client certificate and config"
mkdir -p "$CONF_DIR"
install -m 644 "$CERT" "$CONF_DIR/client.pem"
install -m 600 "$KEY" "$CONF_DIR/client.key"

cat > "$CONF_DIR/client.json" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": $SOCKS_PORT
    }
  ],
  "outbounds": [
    {
      "type": "tuic",
      "tag": "tuic-out",
      "server": "$SERVER",
      "server_port": $PORT,
      "uuid": "$UUID",
      "password": "$PASSWORD",
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "$SERVER",
        "alpn": ["h3"],
        "client_certificate_path": "$CONF_DIR/client.pem",
        "client_key_path": "$CONF_DIR/client.key"
      }
    }
  ]
}
EOF

"$BIN" check -c "$CONF_DIR/client.json" || die "generated config failed validation"

echo "[4/4] installing procd service"
cat > /etc/init.d/sbox-client <<'INIT'
#!/bin/sh /etc/rc.common
# sbox-client —— sing-box 客户端（TUIC + mTLS），出 socks5 给 PassWall2
START=96
STOP=10
USE_PROCD=1

start_service() {
	if [ ! -f /etc/sbox-client/client.json ]; then
		echo "sbox-client: /etc/sbox-client/client.json missing, refusing to start" >&2
		return 1
	fi
	if [ ! -f /etc/sbox-client/client.pem ] || [ ! -f /etc/sbox-client/client.key ]; then
		echo "sbox-client: client cert/key missing, refusing to start" >&2
		return 1
	fi
	procd_open_instance
	procd_set_param command /usr/bin/sbox-client run -c /etc/sbox-client/client.json
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}

service_triggers() {
	procd_add_reload_trigger "sbox-client"
}
INIT
chmod 755 /etc/init.d/sbox-client
/etc/init.d/sbox-client enable
/etc/init.d/sbox-client restart

sleep 2
/etc/init.d/sbox-client status >/dev/null 2>&1 || true
ss -ltn 2>/dev/null | grep -q ":$SOCKS_PORT " || die "socks listener did not come up on port $SOCKS_PORT"

echo
echo "done. client running, socks5 = 127.0.0.1:$SOCKS_PORT"
echo
echo "接到 PassWall2："
echo "  节点类型：Socks"
echo "  地址：127.0.0.1    端口：$SOCKS_PORT"
echo "  在分流组里把该节点设为默认出口"
echo
echo "管理："
echo "  /etc/init.d/sbox-client status"
echo "  logread -f | grep sbox-client"
echo "  /etc/init.d/sbox-client restart"