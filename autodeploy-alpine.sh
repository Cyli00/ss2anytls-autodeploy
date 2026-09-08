#!/bin/sh

set -eu

VERSION="0.0.13"
BASE_DIR="/opt/anytls"
BIN="/usr/local/bin/anytls-server"
CONF="${BASE_DIR}/config"
SERVICE="/etc/init.d/anytls"

# GitHub Release
DOWNLOAD_URL="https://github.com/anytls/anytls-go/releases/download/v${VERSION}/anytls_${VERSION}_linux_arm64.zip"

# --------------------------------------------------
# basic
# --------------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行"
    exit 1
fi

ARCH="$(uname -m)"

case "$ARCH" in
    aarch64|arm64)
        ;;
    *)
        echo "错误：这个脚本只适用于 ARM64"
        echo "当前架构：$ARCH"
        exit 1
        ;;
esac

mkdir -p "$BASE_DIR"

echo "=========================================="
echo " AnyTLS Alpine ARM64 Exit Deploy"
echo " Version: v${VERSION}"
echo "=========================================="
echo

# --------------------------------------------------
# dependencies
# --------------------------------------------------

echo "[1/6] 检查依赖..."

if ! command -v wget >/dev/null 2>&1; then
    echo "安装 wget..."
    apk add --no-cache wget
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo "安装 unzip..."
    apk add --no-cache unzip
fi

echo "依赖 OK"
echo

# --------------------------------------------------
# download
# --------------------------------------------------

echo "[2/6] 安装 anytls-server..."

TMP="/tmp/anytls-${VERSION}.zip"

if [ ! -x "$BIN" ]; then

    rm -f "$TMP"

    echo "下载："
    echo "$DOWNLOAD_URL"
    echo

    wget -O "$TMP" "$DOWNLOAD_URL"

    rm -rf /tmp/anytls-extract
    mkdir -p /tmp/anytls-extract

    unzip -o "$TMP" -d /tmp/anytls-extract >/dev/null

    SERVER_BIN="$(find /tmp/anytls-extract -type f -name 'anytls-server' | head -n 1)"

    if [ -z "$SERVER_BIN" ]; then
        echo "错误：压缩包中没有找到 anytls-server"
        exit 1
    fi

    install -m 755 "$SERVER_BIN" "$BIN"

    rm -rf /tmp/anytls-extract
    rm -f "$TMP"

else
    echo "已安装：$BIN"
fi

echo

# --------------------------------------------------
# version
# --------------------------------------------------

echo "[3/6] 检查版本..."

"$BIN" --help >/dev/null 2>&1 || true

echo "Binary: $BIN"
echo

# --------------------------------------------------
# password
# --------------------------------------------------

echo "[4/6] 配置 AnyTLS..."

if [ -f "$CONF" ]; then
    . "$CONF"
else
    PASSWORD=""
    LISTEN_PORT="8443"
fi

printf "监听端口 [%s]: " "${LISTEN_PORT:-8443}"
read NEW_PORT || true

if [ -n "${NEW_PORT:-}" ]; then
    LISTEN_PORT="$NEW_PORT"
fi

case "$LISTEN_PORT" in
    ''|*[!0-9]*)
        echo "端口无效"
        exit 1
        ;;
esac

if [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
    echo "端口必须在 1-65535"
    exit 1
fi

if [ -z "${PASSWORD:-}" ]; then

    if command -v openssl >/dev/null 2>&1; then
        PASSWORD="$(openssl rand -base64 24 | tr -d '\n')"
    else
        # Alpine busybox 自带 /dev/urandom
        PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '\n')"
    fi

    echo "已生成随机密码"
else
    echo "保留已有密码"
fi

cat > "$CONF" <<EOF
PASSWORD='$PASSWORD'
LISTEN_PORT='$LISTEN_PORT'
EOF

chmod 600 "$CONF"

echo

# --------------------------------------------------
# service
# --------------------------------------------------

echo "[5/6] 配置服务..."

# 如果环境存在 OpenRC，则创建 OpenRC service
if command -v rc-service >/dev/null 2>&1 || [ -d /etc/init.d ]; then

    cat > "$SERVICE" <<EOF
#!/sbin/openrc-run

name="anytls"
description="AnyTLS Server"

command="$BIN"
command_args="-l 0.0.0.0:\${LISTEN_PORT} -p \${PASSWORD}"

command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

output_log="/var/log/anytls.log"
error_log="/var/log/anytls.err"

depend() {
    need net
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    . "$CONF"
}
EOF

    chmod +x "$SERVICE"

    . "$CONF"

    # 停旧进程
    rc-service anytls stop >/dev/null 2>&1 || true

    # 启动
    rc-service anytls start

    # 开机启动
    rc-update add anytls default >/dev/null 2>&1 || true

else

    echo "检测不到 OpenRC"
    echo "使用后台进程方式启动"

    if [ -f "$BASE_DIR/anytls.pid" ]; then
        OLD_PID="$(cat "$BASE_DIR/anytls.pid" 2>/dev/null || true)"

        if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
            kill "$OLD_PID" 2>/dev/null || true
            sleep 1
        fi
    fi

    . "$CONF"

    nohup "$BIN" \
        -l "0.0.0.0:${LISTEN_PORT}" \
        -p "$PASSWORD" \
        > "$BASE_DIR/anytls.log" 2>&1 &

    PID=$!

    echo "$PID" > "$BASE_DIR/anytls.pid"

    sleep 1

    if ! kill -0 "$PID" 2>/dev/null; then
        echo
        echo "启动失败"
        cat "$BASE_DIR/anytls.log" || true
        exit 1
    fi
fi

echo

# --------------------------------------------------
# result
# --------------------------------------------------

PUBLIC_IP=""

for URL in \
    "https://api.ipify.org" \
    "https://ifconfig.me" \
    "https://icanhazip.com"
do
    if command -v wget >/dev/null 2>&1; then
        PUBLIC_IP="$(wget -qO- --timeout=5 "$URL" 2>/dev/null | tr -d '[:space:]' || true)"
    fi

    case "$PUBLIC_IP" in
        *.*)
            break
            ;;
        *)
            PUBLIC_IP=""
            ;;
    esac
done

if [ -z "$PUBLIC_IP" ]; then
    printf "请输入服务器公网 IP: "
    read PUBLIC_IP
fi

echo
echo "=========================================="
echo " AnyTLS 部署完成"
echo "=========================================="
echo
echo "地址     : $PUBLIC_IP"
echo "端口     : $LISTEN_PORT"
echo "密码     : $PASSWORD"
echo
echo "AnyTLS URI:"
echo
echo "anytls://${PASSWORD}@${PUBLIC_IP}:${LISTEN_PORT}?insecure=1"
echo
echo "------------------------------------------"

if command -v rc-service >/dev/null 2>&1; then
    echo "服务状态:"
    rc-service anytls status || true
    echo
    echo "日志:"
    echo "  tail -f /var/log/anytls.log"
    echo
    echo "管理:"
    echo "  rc-service anytls restart"
    echo "  rc-service anytls stop"
else
    echo "PID:"
    cat "$BASE_DIR/anytls.pid" 2>/dev/null || true
    echo
    echo "日志:"
    echo "  tail -f $BASE_DIR/anytls.log"
fi

echo
echo "配置:"
echo "  $CONF"
echo "二进制:"
echo "  $BIN"
echo
echo "=========================================="
