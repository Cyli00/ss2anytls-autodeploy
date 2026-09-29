#!/usr/bin/env bash

# ==========================================
# anytls-exit - 基于 anytls-go 的出口端一键部署脚本
# 仅部署服务端 (anytls-server)，不依赖 sing-box
# ==========================================

set -u

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- 全局变量 ---
REPO="anytls/anytls-go"
FALLBACK_VERSION="v0.0.13"
BIN_PATH="/usr/local/bin/anytls-server"
CONF_DIR="/etc/anytls"
CONF_FILE="$CONF_DIR/config.env"
SERVICE_NAME="anytls-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NODE_NAME="anytls-exit"

TMP_DIR=""
ARCH=""
RELEASE_TAG=""
DOWNLOAD_URL=""

# --- 辅助函数 ---

print_info()    { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }

cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT

show_banner() {
    echo -e "${CYAN}=========================================================="
    echo -e "${WHITE}   AnyTLS Exit Server 一键部署 (基于 anytls-go)"
    echo -e "${CYAN}==========================================================${NC}\n"
}

print_card() {
    local title="$1"
    shift
    echo -e "\n${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${WHITE} $title${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════╣${NC}"
    while [ $# -gt 0 ]; do
        echo -e "${GREEN}║${NC} $1"
        shift
    done
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}\n"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "请使用 root 权限运行：sudo bash $0"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl &>/dev/null || [[ ! -d /run/systemd/system ]]; then
        print_error "当前系统未使用 systemd，本脚本无法注册服务"
        exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) print_error "不支持的 CPU 架构：$(uname -m)（仅支持 amd64 / arm64）"; exit 1 ;;
    esac
}

install_dependencies() {
    local missing=0 dep
    for dep in curl unzip ss; do
        command -v "$dep" &>/dev/null || missing=1
    done
    if [[ $missing -eq 1 ]]; then
        print_info "安装依赖 (curl, unzip, iproute2)..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq curl unzip iproute2 ca-certificates >/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y -q curl unzip iproute ca-certificates >/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y -q curl unzip iproute ca-certificates >/dev/null
        fi
    fi
    for dep in curl unzip ss; do
        if ! command -v "$dep" &>/dev/null; then
            print_error "缺少依赖：$dep，请手动安装后重试"
            exit 1
        fi
    done
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

port_in_use() {
    [[ -n "$(ss -lntuH "sport = :$1" 2>/dev/null)" ]]
}

gen_password() {
    head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24
}

# 从已有配置中读取单个键值，避免直接 source 配置文件
read_conf() {
    [[ -f "$CONF_FILE" ]] || return 0
    grep -m1 "^$1=" "$CONF_FILE" | cut -d= -f2-
}

get_public_ipv4() {
    local endpoint ip
    for endpoint in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -4 -fsS --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

prompt_public_host() {
    local host
    if host=$(get_public_ipv4); then
        echo "$host"
        return 0
    fi
    print_warn "无法自动获取公网 IP"
    read -rp "   请手动输入公网 Host/IP: " host
    if [[ -z "$host" ]]; then
        print_error "公网地址为空，无法生成连接信息"
        exit 1
    fi
    echo "$host"
}

# 确定要安装的版本与下载地址：
# 优先通过 GitHub API 取得 release 中真实的资源链接；
# API 不可用（限流/网络问题）时，回退到按命名规则拼接的直链
resolve_release() {
    local endpoint json tag url
    if [[ -n "${ANYTLS_VERSION:-}" ]]; then
        tag="${ANYTLS_VERSION}"
        [[ "$tag" == v* ]] || tag="v$tag"
        endpoint="https://api.github.com/repos/${REPO}/releases/tags/${tag}"
    else
        endpoint="https://api.github.com/repos/${REPO}/releases/latest"
    fi

    json=$(curl -fsSL --max-time 15 "$endpoint" 2>/dev/null || true)
    if [[ -n "$json" ]]; then
        tag=$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
        url=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*"' \
            | grep "linux_${ARCH}\.zip" | head -n1 | sed -E 's/.*"(https[^"]+)"$/\1/')
    fi

    if [[ -z "${tag:-}" ]]; then
        print_warn "无法获取最新版本，回退到 ${FALLBACK_VERSION}"
        tag="$FALLBACK_VERSION"
    fi
    if [[ -z "${url:-}" ]]; then
        url="https://github.com/${REPO}/releases/download/${tag}/anytls_${tag#v}_linux_${ARCH}.zip"
    fi

    RELEASE_TAG="$tag"
    DOWNLOAD_URL="$url"
}

install_binary() {
    resolve_release
    print_info "下载 anytls-go ${RELEASE_TAG} (linux/${ARCH})..."

    TMP_DIR=$(mktemp -d) || { print_error "创建临时目录失败"; exit 1; }
    if ! curl -fsSL --retry 3 --max-time 120 -o "$TMP_DIR/anytls.zip" "$DOWNLOAD_URL"; then
        print_error "下载失败：$DOWNLOAD_URL"
        print_error "请检查网络，或通过 ANYTLS_VERSION=v0.0.xx 指定其他版本"
        exit 1
    fi

    if ! unzip -qo "$TMP_DIR/anytls.zip" -d "$TMP_DIR/pkg"; then
        print_error "解压失败，下载文件可能已损坏"
        exit 1
    fi

    local server_bin
    server_bin=$(find "$TMP_DIR/pkg" -type f -name 'anytls-server' | head -n1)
    if [[ -z "$server_bin" ]]; then
        print_error "压缩包内未找到 anytls-server"
        exit 1
    fi

    # 升级时需先停止服务，否则覆盖运行中的二进制会报 Text file busy
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    install -m 755 "$server_bin" "$BIN_PATH"
    print_success "anytls-server 已安装到 $BIN_PATH"
}

prompt_config() {
    local old_port old_pass
    old_port=$(read_conf LISTEN_PORT)
    old_pass=$(read_conf PASSWORD)

    LISTEN_PORT="${PORT:-}"
    PASSWORD="${PASSWORD:-}"

    if [[ -z "$LISTEN_PORT" ]]; then
        local def_port="${old_port:-8443}"
        while true; do
            read -rp "   监听端口 [默认 ${def_port}]: " LISTEN_PORT
            LISTEN_PORT="${LISTEN_PORT:-$def_port}"
            if ! valid_port "$LISTEN_PORT"; then
                print_error "端口无效：$LISTEN_PORT"
                continue
            fi
            # 重装时端口沿用旧值属于正常情况，此时不做占用检查
            if [[ "$LISTEN_PORT" != "$old_port" ]] && port_in_use "$LISTEN_PORT"; then
                print_error "端口 $LISTEN_PORT 已被占用，请更换"
                continue
            fi
            break
        done
    elif ! valid_port "$LISTEN_PORT"; then
        print_error "端口无效：$LISTEN_PORT"
        exit 1
    fi

    if [[ -z "$PASSWORD" ]]; then
        local def_pass="${old_pass:-$(gen_password)}"
        while true; do
            read -rp "   连接密码 [默认 ${def_pass}]: " PASSWORD
            PASSWORD="${PASSWORD:-$def_pass}"
            # 限制为 URL 非保留字符，保证 systemd 环境文件与 URI 中都无需转义
            if [[ ! "$PASSWORD" =~ ^[A-Za-z0-9._~-]{8,}$ ]]; then
                print_error "密码需 ≥8 位，且仅含字母、数字或 . _ ~ -"
                continue
            fi
            break
        done
    elif [[ ! "$PASSWORD" =~ ^[A-Za-z0-9._~-]{8,}$ ]]; then
        print_error "密码需 ≥8 位，且仅含字母、数字或 . _ ~ -"
        exit 1
    fi
}

write_config_and_service() {
    mkdir -p "$CONF_DIR"
    umask 077
    cat > "$CONF_FILE" <<EOF
LISTEN_PORT=${LISTEN_PORT}
PASSWORD=${PASSWORD}
EOF
    chmod 600 "$CONF_FILE"
    umask 022

    # 监听 ":端口" 即同时监听 IPv4/IPv6；DynamicUser 以低权限运行，
    # 并通过 AmbientCapabilities 保留绑定 443 等特权端口的能力
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Server (anytls-go)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONF_FILE}
ExecStart=${BIN_PATH} -l :\${LISTEN_PORT} -p \${PASSWORD}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

open_firewall() {
    local port="$1"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}/tcp" >/dev/null 2>&1 && print_info "已在 ufw 放行 ${port}/tcp"
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 \
            && firewall-cmd --reload >/dev/null 2>&1 \
            && print_info "已在 firewalld 放行 ${port}/tcp"
    fi
}

start_service() {
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 2

    if ! systemctl is-active --quiet "$SERVICE_NAME" || ! port_in_use "$LISTEN_PORT"; then
        print_error "服务启动失败，最近日志如下："
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2
        exit 1
    fi
}

show_info() {
    if [[ ! -f "$CONF_FILE" ]]; then
        print_error "未找到配置，请先执行安装"
        exit 1
    fi

    local port pass host uri
    port=$(read_conf LISTEN_PORT)
    pass=$(read_conf PASSWORD)
    host=$(prompt_public_host)
    uri="anytls://${pass}@${host}:${port}?insecure=1#${NODE_NAME}"

    print_card "Exit Server 信息 (复制到中转 B 端)" \
        "IP       : $host" \
        "Port     : $port" \
        "Password : $pass" \
        "证书     : 服务端自签，客户端需开启 insecure"

    echo -e "${CYAN}AnyTLS URI (一键导入链接):${NC}"
    echo -e "${GREEN}${uri}${NC}\n"

    echo -e "${CYAN}sing-box outbound 配置片段:${NC}"
    cat <<EOF
{
  "type": "anytls",
  "tag": "${NODE_NAME}",
  "server": "${host}",
  "server_port": ${port},
  "password": "${pass}",
  "tls": {
    "enabled": true,
    "insecure": true
  }
}
EOF
    echo ""
}

do_install() {
    show_banner
    check_root
    check_systemd
    detect_arch
    install_dependencies
    install_binary

    echo -e "\n${YELLOW}? 服务端配置${NC}"
    prompt_config
    write_config_and_service
    open_firewall "$LISTEN_PORT"
    start_service

    print_success "AnyTLS 出口服务已启动！"
    show_info
    print_warn "云厂商的安全组/防火墙也需放行 TCP ${LISTEN_PORT}"
    print_warn "管理命令：bash $0 {info|status|log|uninstall}"
}

do_uninstall() {
    check_root
    read -rp "确认卸载 anytls-server 及其配置? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        exit 0
    fi
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_FILE" "$BIN_PATH"
    rm -rf "$CONF_DIR"
    systemctl daemon-reload
    print_success "已卸载"
}

case "${1:-install}" in
    install)   do_install ;;
    info)      check_root; show_info ;;
    status)    systemctl status "$SERVICE_NAME" --no-pager ;;
    log)       shift; journalctl -u "$SERVICE_NAME" --no-pager "${@:--n50}" ;;
    uninstall) do_uninstall ;;
    *)         echo "用法: bash $0 {install|info|status|log|uninstall}"; exit 1 ;;
esac
