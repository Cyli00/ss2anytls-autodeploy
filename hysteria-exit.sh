#!/usr/bin/env bash

# ==========================================
# hysteria-exit - 基于 Hysteria 2 的出口端一键部署脚本
# 仅部署服务端 (hysteria server)，不依赖 sing-box
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
REPO="apernet/hysteria"
BIN_PATH="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria"
CONF_FILE="$CONF_DIR/exit.env"
YAML_FILE="$CONF_DIR/config.yaml"
CERT_FILE="$CONF_DIR/cert.pem"
KEY_FILE="$CONF_DIR/key.pem"
SYSCTL_FILE="/etc/sysctl.d/99-hysteria.conf"
SERVICE_NAME="hysteria-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
HOP_SERVICE="hysteria-hop"
HOP_FILE="/etc/systemd/system/${HOP_SERVICE}.service"
NODE_NAME="hysteria2-exit"

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
    echo -e "${WHITE}   Hysteria 2 Exit Server 一键部署 (基于 apernet/hysteria)"
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
    for dep in curl openssl ss; do
        command -v "$dep" &>/dev/null || missing=1
    done
    if [[ $missing -eq 1 ]]; then
        print_info "安装依赖 (curl, openssl, iproute2)..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq curl openssl iproute2 ca-certificates >/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y -q curl openssl iproute ca-certificates >/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y -q curl openssl iproute ca-certificates >/dev/null
        elif command -v apk &>/dev/null; then
            apk add -q curl openssl iproute2 ca-certificates >/dev/null
        fi
    fi
    for dep in curl openssl ss; do
        if ! command -v "$dep" &>/dev/null; then
            print_error "缺少依赖：$dep，请手动安装后重试"
            exit 1
        fi
    done
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Hysteria 2 基于 QUIC，只监听 UDP，因此只检查 UDP 端口占用
udp_port_in_use() {
    [[ -n "$(ss -lnuH "sport = :$1" 2>/dev/null)" ]]
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
# 指定 HYSTERIA_VERSION 时直接使用对应 release；
# 否则通过 GitHub API 取得最新 tag，API 不可用时回退到 releases/latest 直链
# Hysteria 的 release tag 形如 app/v2.x.y
resolve_release() {
    local json tag url

    if [[ -n "${HYSTERIA_VERSION:-}" ]]; then
        local ver="${HYSTERIA_VERSION#app/}"
        tag="app/v${ver#v}"
    else
        json=$(curl -fsSL --max-time 15 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)
        tag=$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    fi

    if [[ -n "${tag:-}" ]]; then
        url="https://github.com/${REPO}/releases/download/${tag}/hysteria-linux-${ARCH}"
    else
        print_warn "无法获取最新版本，改用 GitHub latest 直链"
        tag="latest"
        url="https://github.com/${REPO}/releases/latest/download/hysteria-linux-${ARCH}"
    fi

    RELEASE_TAG="$tag"
    DOWNLOAD_URL="$url"
}

install_binary() {
    resolve_release
    print_info "下载 Hysteria 2 ${RELEASE_TAG} (linux/${ARCH})..."

    TMP_DIR=$(mktemp -d) || { print_error "创建临时目录失败"; exit 1; }
    if ! curl -fsSL --retry 3 --max-time 180 -o "$TMP_DIR/hysteria" "$DOWNLOAD_URL"; then
        print_error "下载失败：$DOWNLOAD_URL"
        print_error "请检查网络，或通过 HYSTERIA_VERSION=app/v2.x.x 指定其他版本"
        exit 1
    fi

    chmod +x "$TMP_DIR/hysteria"
    if ! "$TMP_DIR/hysteria" version &>/dev/null; then
        print_error "下载的文件无法执行，可能与 CPU 架构不符或已损坏"
        exit 1
    fi

    # 升级时需先停止服务，否则覆盖运行中的二进制会报 Text file busy
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    install -m 755 "$TMP_DIR/hysteria" "$BIN_PATH"
    print_success "hysteria 已安装到 $BIN_PATH"
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
            read -rp "   监听端口 (UDP) [默认 ${def_port}]: " LISTEN_PORT
            LISTEN_PORT="${LISTEN_PORT:-$def_port}"
            if ! valid_port "$LISTEN_PORT"; then
                print_error "端口无效：$LISTEN_PORT"
                continue
            fi
            # 重装时端口沿用旧值属于正常情况，此时不做占用检查
            if [[ "$LISTEN_PORT" != "$old_port" ]] && udp_port_in_use "$LISTEN_PORT"; then
                print_error "UDP 端口 $LISTEN_PORT 已被占用，请更换"
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
            # 限制为 URL 与 YAML 都无需转义的字符
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

# 自签证书，有效期 10 年；已存在则沿用，避免重装后客户端指纹变化
ensure_cert() {
    [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]] && return 0
    print_info "生成自签 TLS 证书..."
    umask 077
    if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -days 3650 -subj "/CN=hysteria-exit" &>/dev/null; then
        umask 022
        print_error "生成证书失败"
        exit 1
    fi
    umask 022
}

# 端口跳跃：服务端仍只监听一个 UDP 端口，由 iptables 把跳跃范围内的 UDP 包重定向过来；
# 客户端在范围内切换端口，以规避针对单一端口的封锁
validate_hop_range() {
    local range="$1" lo hi busy
    if [[ ! "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
        print_error "格式应为「起始-结束」，如 20000-50000"
        return 1
    fi
    lo=${range%-*}
    hi=${range#*-}
    if ! valid_port "$lo" || ! valid_port "$hi" || (( 10#$lo >= 10#$hi )); then
        print_error "端口范围无效：$range（需在 1-65535 内且起始小于结束）"
        return 1
    fi
    if (( 10#$LISTEN_PORT >= 10#$lo && 10#$LISTEN_PORT <= 10#$hi )); then
        print_error "跳跃范围不能包含监听端口 $LISTEN_PORT"
        return 1
    fi
    # 范围内若已有其他 UDP 服务在监听，重定向会使其失效
    busy=$(ss -lnuH | awk '{print $4}' | grep -oE '[0-9]+$' \
        | awk -v l="$lo" -v h="$hi" '$1 >= l && $1 <= h' | head -n1)
    if [[ -n "$busy" ]]; then
        print_error "跳跃范围内的 UDP 端口 $busy 已被占用，请更换范围"
        return 1
    fi
}

prompt_hop() {
    local def
    def="$(read_conf HOP_RANGE)"
    def="${def:-0}"

    if [[ -z "${HOP_RANGE:-}" ]]; then
        while true; do
            read -rp "   端口跳跃范围 (UDP，如 20000-50000，输入 0 不启用) [默认 ${def}]: " HOP_RANGE
            HOP_RANGE="${HOP_RANGE:-$def}"
            [[ "$HOP_RANGE" == "0" ]] && break
            validate_hop_range "$HOP_RANGE" && break
        done
    elif [[ "$HOP_RANGE" != "0" ]]; then
        validate_hop_range "$HOP_RANGE" || exit 1
    fi
    [[ "$HOP_RANGE" == "0" ]] && HOP_RANGE=""
    return 0
}

ensure_iptables() {
    if ! command -v iptables &>/dev/null; then
        print_info "安装 iptables..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq iptables >/dev/null
        elif command -v dnf &>/dev/null; then
            dnf install -y -q iptables >/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y -q iptables >/dev/null
        elif command -v apk &>/dev/null; then
            apk add -q iptables >/dev/null
        fi
    fi
    if ! command -v iptables &>/dev/null; then
        print_error "缺少 iptables，无法启用端口跳跃"
        exit 1
    fi
}

# 用 systemd oneshot 单元维护 NAT 规则，开机自动生效、停止时自动清理
# 规则先删后加，重复启动不会叠加；IPv6 规则失败不影响 IPv4
apply_hop() {
    # 先停止旧单元，让它按旧范围执行 ExecStop 清理规则，再写入新单元
    systemctl stop "$HOP_SERVICE" 2>/dev/null || true
    if [[ -z "$HOP_RANGE" ]]; then
        systemctl disable "$HOP_SERVICE" >/dev/null 2>&1 || true
        rm -f "$HOP_FILE"
        systemctl daemon-reload
        return 0
    fi

    ensure_iptables
    local ipt ip6t lo hi match exec_block
    ipt=$(command -v iptables)
    ip6t=$(command -v ip6tables || true)
    lo=${HOP_RANGE%-*}
    hi=${HOP_RANGE#*-}
    match="-p udp --dport ${lo}:${hi} -j REDIRECT --to-ports ${LISTEN_PORT}"

    exec_block="ExecStartPre=-${ipt} -t nat -D PREROUTING ${match}
ExecStart=${ipt} -t nat -A PREROUTING ${match}
ExecStop=-${ipt} -t nat -D PREROUTING ${match}"
    if [[ -n "$ip6t" ]]; then
        exec_block+="
ExecStartPre=-${ip6t} -t nat -D PREROUTING ${match}
ExecStart=-${ip6t} -t nat -A PREROUTING ${match}
ExecStop=-${ip6t} -t nat -D PREROUTING ${match}"
    fi

    cat > "$HOP_FILE" <<EOF
[Unit]
Description=Hysteria 2 port hopping (UDP ${HOP_RANGE} -> ${LISTEN_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
${exec_block}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$HOP_SERVICE" >/dev/null 2>&1
    if ! systemctl is-active --quiet "$HOP_SERVICE"; then
        print_error "端口跳跃规则加载失败，最近日志如下："
        journalctl -u "$HOP_SERVICE" -n 20 --no-pager >&2
        exit 1
    fi
    print_success "端口跳跃已启用：UDP ${HOP_RANGE} -> ${LISTEN_PORT}"
}

write_config() {
    mkdir -p "$CONF_DIR"
    umask 077
    cat > "$CONF_FILE" <<EOF
LISTEN_PORT=${LISTEN_PORT}
PASSWORD=${PASSWORD}
HOP_RANGE=${HOP_RANGE}
EOF
    cat > "$YAML_FILE" <<EOF
listen: :${LISTEN_PORT}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: "${PASSWORD}"
EOF
    chmod 600 "$CONF_FILE"
    umask 022
}

# 服务以 nobody 运行时需要读取 YAML 与私钥：
# 仅把目录与这两个文件授予 nobody 的属组，其他用户无权读取
# 若授权失败，受限模式启动会失败，随后自动回退到 root 模式
prepare_files() {
    local grp
    grp=$(id -gn nobody 2>/dev/null || echo root)
    chgrp "$grp" "$CONF_DIR" "$YAML_FILE" "$KEY_FILE" 2>/dev/null || true
    chmod 750 "$CONF_DIR"
    chmod 640 "$YAML_FILE" "$KEY_FILE"
    chmod 644 "$CERT_FILE"
}

# mode=restricted: 以 nobody 运行，仅保留绑定特权端口的能力
# mode=root: 兜底方案，用于不支持能力/用户切换的容器环境
# 刻意不使用 DynamicUser / ProtectSystem / PrivateTmp 等指令，
# 它们依赖挂载命名空间，在 LXC/OpenVZ 容器中会以 226/NAMESPACE 失败
write_service() {
    local mode="$1" sec_block=""
    if [[ "$mode" == "restricted" ]]; then
        sec_block=$'User=nobody\nAmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\nNoNewPrivileges=yes'
    fi

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} server -c ${YAML_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
${sec_block}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# Hysteria 依赖较大的 UDP 收发缓冲区，否则吞吐会受限；
# 容器环境可能禁止修改 sysctl，失败时仅提示，不影响安装
tune_udp_buffers() {
    cat > "$SYSCTL_FILE" <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
    if ! sysctl -q -p "$SYSCTL_FILE" &>/dev/null; then
        print_warn "无法调整 UDP 缓冲区（容器环境可能不允许），速度可能受限"
    fi
}

open_firewall() {
    local port="$1"
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port//-/:}/udp" >/dev/null 2>&1 && print_info "已在 ufw 放行 ${port}/udp"
    fi
    if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 \
            && firewall-cmd --reload >/dev/null 2>&1 \
            && print_info "已在 firewalld 放行 ${port}/udp"
    fi
}

service_ok() {
    systemctl is-active --quiet "$SERVICE_NAME" && udp_port_in_use "$LISTEN_PORT"
}

start_service() {
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME" 2>/dev/null
    sleep 2

    if ! service_ok; then
        print_warn "受限模式启动失败（常见于容器类 VPS 或文件权限不符），改用 root 模式重试..."
        write_service root
        systemctl restart "$SERVICE_NAME" 2>/dev/null
        sleep 2
    fi

    if ! service_ok; then
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

    local port pass hop host uri port_desc sb_ports
    port=$(read_conf LISTEN_PORT)
    pass=$(read_conf PASSWORD)
    hop=$(read_conf HOP_RANGE)
    host=$(prompt_public_host)

    # 启用跳跃时，客户端直接连接跳跃范围，无需单一端口
    if [[ -n "$hop" ]]; then
        uri="hysteria2://${pass}@${host}:${hop}/?insecure=1#${NODE_NAME}"
        port_desc="${hop} (UDP 跳跃，服务端监听 ${port})"
        printf -v sb_ports '  "server_ports": ["%s"],\n  "hop_interval": "30s",\n' "${hop/-/:}"
    else
        uri="hysteria2://${pass}@${host}:${port}/?insecure=1#${NODE_NAME}"
        port_desc="${port} (UDP)"
        printf -v sb_ports '  "server_port": %s,\n' "$port"
    fi

    print_card "Exit Server 信息 (复制到中转 B 端)" \
        "IP       : $host" \
        "Port     : $port_desc" \
        "Password : $pass" \
        "证书     : 服务端自签，客户端需开启 insecure"

    echo -e "${CYAN}Hysteria 2 URI (一键导入链接):${NC}"
    echo -e "${GREEN}${uri}${NC}\n"

    echo -e "${CYAN}sing-box outbound 配置片段:${NC}"
    cat <<EOF
{
  "type": "hysteria2",
  "tag": "${NODE_NAME}",
  "server": "${host}",
${sb_ports}  "password": "${pass}",
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
    prompt_hop
    write_config
    ensure_cert
    prepare_files
    write_service restricted
    tune_udp_buffers
    open_firewall "$LISTEN_PORT"
    start_service
    apply_hop

    print_success "Hysteria 2 出口服务已启动！"
    show_info
    print_warn "Hysteria 2 基于 QUIC（UDP），云厂商的安全组/防火墙需放行 UDP ${LISTEN_PORT}${HOP_RANGE:+ 及跳跃范围 ${HOP_RANGE}}"
    print_warn "管理命令：bash $0 {info|status|log|uninstall}"
}

do_uninstall() {
    check_root
    read -rp "确认卸载 Hysteria 2 服务及其配置? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "已取消"
        exit 0
    fi
    systemctl disable --now "$HOP_SERVICE" >/dev/null 2>&1
    rm -f "$HOP_FILE"
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1
    rm -f "$SERVICE_FILE" "$BIN_PATH" "$SYSCTL_FILE"
    rm -f "$CONF_FILE" "$YAML_FILE" "$CERT_FILE" "$KEY_FILE"
    rmdir "$CONF_DIR" 2>/dev/null || true
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
