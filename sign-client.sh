#!/bin/sh
# 签发一张新的客户端证书（无参数，直接运行）
#
# 用法：sign-client.sh
#
# 用服务端的客户端 CA（/etc/sing-box/client-ca.pem + client-ca.key）签一张新证书，
# 自动命名、自动落到 /etc/sing-box/clients/，最后打印拷到设备的命令。
#
# 无参数设计理由：证书内容只依赖 CA 与当前时间，人工输入名字只会引入拼写错误。
set -eu

BASE=/etc/sing-box
CA="$BASE/client-ca.pem"
CAKEY="$BASE/client-ca.key"
OUTDIR="$BASE/clients"

die() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$CA" ] || die "client CA not found: $CA (run install.sh first)"
[ -f "$CAKEY" ] || die "client CA key not found: $CAKEY"

for cmd in openssl date; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

mkdir -p "$OUTDIR"

NAME="client-$(date +%Y%m%d-%H%M%S)"
PEM="$OUTDIR/$NAME.pem"
KEY="$OUTDIR/$NAME.key"
CSR="$OUTDIR/.$NAME.csr"

# 同名已存在就拒绝——同一秒内重复执行会覆盖已分发证书，属于危险操作
[ -e "$PEM" ] && die "$PEM already exists, retry in a second"

echo "[1/3] generating key + CSR for CN=$NAME"
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$KEY" -subj "/CN=$NAME" -out "$CSR" 2>/dev/null \
    || die "failed to generate key/CSR"

echo "[2/3] signing with client CA (10 years)"
openssl x509 -req -in "$CSR" -CA "$CA" -CAkey "$CAKEY" -CAcreateserial \
    -out "$PEM" -days 3650 -sha256 2>/dev/null \
    || die "failed to sign certificate"
rm -f "$CSR"
chmod 600 "$KEY"
chmod 644 "$PEM"

echo "[3/3] verifying against CA"
openssl verify -CAfile "$CA" "$PEM" >/dev/null 2>&1 \
    || die "issued certificate failed CA verification"

openssl x509 -in "$PEM" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/      /'

echo
echo "issued:"
echo "  $PEM"
echo "  $KEY"
echo
echo "deploy to device:"
echo "  scp $PEM root@<device>:/tmp/client.pem"
echo "  scp $KEY root@<device>:/tmp/client.key"