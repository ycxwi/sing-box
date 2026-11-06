#!/bin/sh
# sing-box 客户端安装器（OpenWrt / iStoreOS 软路由版）
#
# 用法（两种）：
#   无参： sh client-install.sh
#          当前目录需有 client.json / client.pem / client.key（一次性 bundle 解包后）
#   有参： sh client-install.sh <server> <port> <uuid> <password> <cert> <key> [socks-port] [server-name]
#
# 多节点：每执行一次 = 添加或更新一个节点。
#   - 每个节点一份配置：/etc/sbox-client/nodes/<name>.json（同名即更新，不动其它节点）
#   - 每个节点一个独立 socks5 端口，默认从 1081 起取首个空闲
#   - 节点名 = 域名里的非字母数字换成下划线（tok.example.com -> tok_example_com）
#   - PassWall2 侧把每个 socks 端口各配成一个节点即可
#
# 参数：
#   server      服务端域名（同时作为 TLS serverName）
#   port        服务端 TUIC 端口（UDP）
#   uuid        服务端启动时打印的 uuid
#   password    服务端启动时打印的 password
#   cert        客户端证书路径（从服务端 /etc/sing-box/client.pem 拷来）
#   key         客户端私钥路径（/etc/sing-box/client.key）
#   socks-port  本节点 socks5 端口；省略 = 自动分配（同名节点已存在则沿用原端口）
#   server-name TLS SNI / 证书校验名，默认 = server。
#               服务端证书签给域名时，server 可填 IP，但这里必须填域名。
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
SOCKS_PORT="${7:-}"
SERVER_NAME="${8:-}"

REPO="ycxwi/sing-box"
TAG="v1.14.4-quick"
BIN=/usr/bin/sbox-client
CONF_DIR=/etc/sbox-client
NODES_DIR=$CONF_DIR/nodes
INIT_SCRIPT=/etc/init.d/sbox-client

die() {
    echo "FAIL: $*" >&2
    exit 1
}

# 两种模式：
#   无参  = 从当前目录的 client.json/client.pem/client.key 直接安装（配合一次性 tar.gz 下载件）
#   有参  = 传统方式，参数传入 + 证书路径
if [ $# -eq 0 ]; then
    MODE=fromdir
    [ -f ./client.json ] || die "no args and ./client.json not found — cd into the extracted bundle dir, or pass the 6 params"
    [ -f ./client.pem ] || die "client.pem missing beside client.json"
    [ -f ./client.key ] || die "client.key missing beside client.json"
else
    MODE=params
    [ -n "$SERVER" ] && [ -n "$PORT" ] && [ -n "$UUID" ] && [ -n "$PASSWORD" ] && [ -n "$CERT" ] && [ -n "$KEY" ] \
        || die "usage: client-install.sh [<server> <port> <uuid> <password> <cert> <key> [socks-port] [server-name]]"
    [ -f "$CERT" ] || die "client certificate not found: $CERT"
    [ -f "$KEY" ] || die "client key not found: $KEY"
fi
[ "$(id -u)" -eq 0 ] || die "must run as root"

# 平台判定：服务托管依赖 procd + /etc/rc.common，只有 OpenWrt/iStoreOS 具备。
# 非 OpenWrt（Debian/Ubuntu 等）不写第二套 service 定义：装完二进制与配置后
# 显式跳过托管，给出手动启动命令。
if [ -f /etc/rc.common ] && command -v procd >/dev/null 2>&1; then
    HAS_PROCD=1
else
    HAS_PROCD=0
fi

# 离线安装（SB_BINARY）不需要 curl；默认路径才要
if [ -z "${SB_BINARY:-}" ]; then
    command -v curl >/dev/null 2>&1 || die "missing curl (set SB_BINARY for offline install)"
fi
for cmd in gzip uname mktemp; do
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

if [ -n "${SB_BINARY:-}" ]; then
    # 离线路径：直接用本机已有的静态二进制（不联网）
    [ -f "$SB_BINARY" ] || die "SB_BINARY not found: $SB_BINARY"
    echo "[1/4] using local binary: $SB_BINARY"
    cp "$SB_BINARY" "$TMP/sb"
else
    echo "[1/4] downloading $ASSET (static, musl-compatible)"
    curl -fsSL -L "https://github.com/$REPO/releases/download/$TAG/$ASSET" -o "$TMP/sb.gz" \
        || die "download failed: $ASSET"
    gzip -t "$TMP/sb.gz" || die "downloaded archive is corrupt"
    gzip -dc "$TMP/sb.gz" > "$TMP/sb"
fi

chmod 755 "$TMP/sb"
echo "[2/4] installing binary"
# busybox 没有 coreutils 的 install，用 cp + chmod
cp "$TMP/sb" "$BIN"
chmod 755 "$BIN"
"$BIN" version >/dev/null 2>&1 || die "installed binary failed to run (arch/libc mismatch?)"

echo "[3/4] installing client certificate and config"
mkdir -p "$NODES_DIR"

# 旧单节点布局（三件平铺在 $CONF_DIR）不再支持。
# 不做自动迁移：自动搬家会与本次安装的证书互相覆盖（源文件可能正是本次的输入），
# 检测到即停，给出确切命令，迁移完再跑。
if [ -f "$CONF_DIR/client.json" ]; then
    echo "FAIL: legacy single-node layout detected: $CONF_DIR/client.json" >&2
    echo "" >&2
    echo "This installer stores every node under $NODES_DIR/." >&2
    echo "Migrate the existing node once, then re-run:" >&2
    echo "" >&2
    echo "  name=<node-name>        # e.g. tok_example_com" >&2
    echo "  mkdir -p $NODES_DIR" >&2
    echo "  mv $CONF_DIR/client.json $NODES_DIR/\$name.json" >&2
    echo "  mv $CONF_DIR/client.pem  $NODES_DIR/\$name.pem" >&2
    echo "  mv $CONF_DIR/client.key  $NODES_DIR/\$name.key" >&2
    echo "  sed -i \"s#$CONF_DIR/client\.#$NODES_DIR/\$name.#g\" $NODES_DIR/\$name.json" >&2
    exit 1
fi

# 参数来源：无参模式从 bundle 的 client.json 回读；有参模式用命令行
if [ "$MODE" = fromdir ]; then
    SERVER=$(sed -n 's/.*"server": *"\([^"]*\)".*/\1/p' ./client.json | head -1)
    PORT=$(sed -n 's/.*"server_port": *\([0-9]*\).*/\1/p' ./client.json | head -1)
    UUID=$(sed -n 's/.*"uuid": *"\([^"]*\)".*/\1/p' ./client.json | head -1)
    PASSWORD=$(sed -n 's/.*"password": *"\([^"]*\)".*/\1/p' ./client.json | head -1)
    [ -n "$SERVER" ] || die "cannot read server from ./client.json"
    [ -n "$PORT" ] || die "cannot read server_port from ./client.json"
    [ -n "$UUID" ] || die "cannot read uuid from ./client.json"
    CERT_SRC=./client.pem
    KEY_SRC=./client.key
    # SNI 以 bundle 里的 server_name 为准（服务端证书签给域名，server 可能是 IP）
    if [ -z "$SERVER_NAME" ]; then
        SERVER_NAME=$(sed -n 's/.*"server_name": *"\([^"]*\)".*/\1/p' ./client.json | head -1)
    fi
else
    CERT_SRC=$CERT
    KEY_SRC=$KEY
fi
if [ -z "$SERVER_NAME" ]; then
    SERVER_NAME=$SERVER
fi

NODE_NAME=$(echo "$SERVER" | sed 's/[^A-Za-z0-9]/_/g')
[ -n "$NODE_NAME" ] || die "cannot derive node name from server: $SERVER"
NODE_JSON="$NODES_DIR/$NODE_NAME.json"

# 端口：显式指定则校验冲突；未指定则沿用同名节点旧端口，否则取首个空闲
if [ -n "$SOCKS_PORT" ]; then
    for f in "$NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        if [ "$f" = "$NODE_JSON" ]; then
            continue
        fi
        if sed -n 's/.*"listen_port": *\([0-9]*\).*/\1/p' "$f" | grep -qx "$SOCKS_PORT"; then
            die "socks port $SOCKS_PORT is already used by $f"
        fi
    done
else
    if [ -f "$NODE_JSON" ]; then
        SOCKS_PORT=$(sed -n 's/.*"listen_port": *\([0-9]*\).*/\1/p' "$NODE_JSON" | head -1)
    fi
    if [ -z "$SOCKS_PORT" ]; then
        p=1081
        while : ; do
            taken=0
            for f in "$NODES_DIR"/*.json; do
                [ -f "$f" ] || continue
                if sed -n 's/.*"listen_port": *\([0-9]*\).*/\1/p' "$f" | grep -qx "$p"; then
                    taken=1
                    break
                fi
            done
            if [ "$taken" -eq 0 ]; then
                h=$(printf '%04X' "$p")
                if grep -q ":$h " /proc/net/tcp 2>/dev/null; then
                    taken=1
                fi
            fi
            if [ "$taken" -eq 0 ]; then
                break
            fi
            p=$((p + 1))
            if [ "$p" -gt 1100 ]; then
                die "no free socks port in 1081-1100"
            fi
        done
        SOCKS_PORT=$p
    fi
fi

cat > "$NODE_JSON" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    { "type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": $SOCKS_PORT }
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
      "udp_relay_mode": "native",
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_NAME",
        "alpn": ["h3"],
        "client_certificate_path": "$NODES_DIR/$NODE_NAME.pem",
        "client_key_path": "$NODES_DIR/$NODE_NAME.key"
      }
    }
  ]
}
EOF
chmod 600 "$NODE_JSON"

# 同内容不重复写：更新同名节点时源路径可能就是已装路径，cp 会报 same file
if [ -f "$NODES_DIR/$NODE_NAME.pem" ] && cmp -s "$CERT_SRC" "$NODES_DIR/$NODE_NAME.pem"; then
    echo "      client cert unchanged"
else
    cp "$CERT_SRC" "$NODES_DIR/$NODE_NAME.pem"
fi
if [ -f "$NODES_DIR/$NODE_NAME.key" ] && cmp -s "$KEY_SRC" "$NODES_DIR/$NODE_NAME.key"; then
    echo "      client key unchanged"
else
    cp "$KEY_SRC" "$NODES_DIR/$NODE_NAME.key"
fi
chmod 644 "$NODES_DIR/$NODE_NAME.pem"
chmod 600 "$NODES_DIR/$NODE_NAME.key"

"$BIN" check -c "$NODE_JSON" || die "generated config failed validation"

if [ "$HAS_PROCD" -eq 1 ]; then
echo "[4/4] installing procd service (one instance per node)"
# 服务脚本固定扫描 nodes/*.json，节点增删只需增删文件 + restart
cat > "$INIT_SCRIPT" <<'INIT'
#!/bin/sh /etc/rc.common
# sbox-client —— sing-box 客户端（TUIC + mTLS），每个节点一个 socks5 端口
# 节点 = /etc/sbox-client/nodes/<name>.json（同名 .pem/.key 为它的客户端证书）
START=96
STOP=10
USE_PROCD=1

start_service() {
	nodes=0
	for cfg in /etc/sbox-client/nodes/*.json; do
		[ -f "$cfg" ] || continue
		base="${cfg%.json}"
		name="${base##*/}"
		# 手动禁用标记（/etc/sbox-client/disabled/<name>）——存在即不拉起该节点
		if [ -f "/etc/sbox-client/disabled/$name" ]; then
			echo "sbox-client: node $name is disabled, skipping" >&2
			continue
		fi
		if [ ! -f "$base.pem" ] || [ ! -f "$base.key" ]; then
			echo "sbox-client: node $name has no cert/key, skipping it" >&2
			continue
		fi
		procd_open_instance "$name"
		procd_set_param command /usr/bin/sbox-client run -c "$cfg"
		procd_set_param respawn 3600 5 5
		procd_set_param stdout 1
		procd_set_param stderr 1
		procd_close_instance
		nodes=$((nodes + 1))
	done
	if [ "$nodes" -eq 0 ]; then
		echo "sbox-client: no usable node under /etc/sbox-client/nodes, refusing to start" >&2
		return 1
	fi
}

service_triggers() {
	procd_add_reload_trigger "sbox-client"
}
INIT
chmod 755 "$INIT_SCRIPT"
"$INIT_SCRIPT" enable
"$INIT_SCRIPT" restart

# 轮询等本节点端口起来（最长 10s），不固定 sleep
i=0
while [ "$i" -lt 10 ]; do
    PORT_HEX=$(printf '%04X' "$SOCKS_PORT")
    if grep -q ":${PORT_HEX} " /proc/net/tcp 2>/dev/null; then
        break
    fi
    i=$((i + 1))
    sleep 1
done
PORT_HEX=$(printf '%04X' "$SOCKS_PORT")
grep -q ":${PORT_HEX} " /proc/net/tcp 2>/dev/null \
    || die "socks listener did not come up on port $SOCKS_PORT (checked /proc/net/tcp)"
SERVICE_STATE="running, managed by procd"
else
echo "[4/4] skipped service setup: not OpenWrt/iStoreOS"
echo "      reason: procd and /etc/rc.common not found on this system"
echo "      binary + config are installed; start a node manually:"
echo "        $BIN run -c $NODE_JSON"
SERVICE_STATE="installed, not started"
fi

echo
echo "done. client $SERVICE_STATE"
echo
echo "this node:"
echo "  name     = $NODE_NAME"
echo "  server   = $SERVER"
echo "  sni      = $SERVER_NAME"
echo "  port     = $PORT"
echo "  uuid     = $UUID"
echo "  password = $PASSWORD"
echo "  socks    = 127.0.0.1:$SOCKS_PORT"
echo
echo "all nodes on this device:"
for f in "$NODES_DIR"/*.json; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    n="${n%.json}"
    np=$(sed -n 's/.*"listen_port": *\([0-9]*\).*/\1/p' "$f" | head -1)
    echo "  socks 127.0.0.1:$np   ($n)"
done
echo
echo "接到 PassWall2：每个 socks 端口单独建一个节点"
echo "  节点类型：Socks"
echo "  地址：127.0.0.1    端口：上面列出的端口"
echo "  在分流组里按需把某个节点设为默认出口"
echo
if [ "$HAS_PROCD" -eq 1 ]; then
echo "管理："
echo "  /etc/init.d/sbox-client status"
echo "  logread -f | grep sbox-client"
echo "  /etc/init.d/sbox-client restart"
echo
echo "增删节点：再跑一次本脚本（加节点），或删掉 nodes/<name>.* 后 restart"
fi