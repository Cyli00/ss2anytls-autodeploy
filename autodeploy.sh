#!/bin/bash

# ==========================================
# ss2anytls-autodeploy - Sing-box AnyTLS 部署脚本
# ==========================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# --- 全局变量 ---
SB_CONFIG="/etc/sing-box/config.json"
SB_CERT_DIR="/etc/sing-box/certs"

# --- 辅助函数 ---

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "   _____ _                 ____            "
    echo "  / ____(_)               |  _ \           "
    echo " | (___  _ _ __   __ _    | |_) | _____  __"
    echo "  \___ \| | '_ \ / _\` |   |  _ < / _ \ \/ /"
    echo "  ____) | | | | | (_| |   | |_) | (_) >  < "
    echo " |_____/|_|_| |_|\__, |   |____/ \___/_/\_\\"
    echo "                  __/ |                    "
    echo "                 |___/                     "
    echo -e "${CYAN} ==========================================================${NC}"
    echo -e "${WHITE}      Sing-box Pure AnyTLS (No-Reality) Setup v2.3${NC}"
    echo -e "${CYAN} ==========================================================${NC}"
    echo ""
}

print_info() { echo -e "${CYAN}[INFO]${NC} $1" >&2; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }

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
        print_error "请使用 root 权限运行：sudo ./autodeploy.sh"
        exit 1
    fi
}

install_dependencies() {
    # 安装 jq, openssl, curl
    if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null || ! command -v curl &> /dev/null; then
        print_info "Installing dependencies (jq, openssl, curl)..."
        if [ -x "$(command -v apt)" ]; then
            apt update -qq && apt install -y jq openssl curl wget tar > /dev/null
        elif [ -x "$(command -v yum)" ]; then
            yum install -y epel-release > /dev/null
            yum install -y jq openssl curl wget tar > /dev/null
        fi
    fi

    for dep in jq openssl curl; do
        if ! command -v "$dep" &> /dev/null; then
            print_error "缺少依赖：$dep"
            exit 1
        fi
    done

    # 检查并安装 Sing-box
    if command -v sing-box &> /dev/null; then
        print_success "Sing-box 已安装 ($(sing-box version 2>/dev/null | head -n1))"
    else
        print_info "安装 Sing-box..."
        if curl -fsSL https://sing-box.app/install.sh | sh; then
            print_success "Sing-box 安装完成"
        else
            print_error "安装失败！请检查网络连接或手动安装"
            exit 1
        fi
    fi

    # 创建证书目录
    mkdir -p "$SB_CERT_DIR"
}

gen_ss2022_key() { openssl rand -base64 16; }
gen_anytls_pass() { openssl rand -base64 16; }

base64_no_wrap() { printf '%s' "$1" | base64 | tr -d '\n'; }

url_encode() {
    local value="$1"
    local encoded=""
    local char hex i
    local LC_ALL=C
    for (( i = 0; i < ${#value}; i++ )); do
        char="${value:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) encoded+="$char" ;;
            *) printf -v hex '%%%02X' "'$char"; encoded+="$hex" ;;
        esac
    done
    printf '%s' "$encoded"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

require_valid_port() {
    local port="$1"
    local label="$2"
    if ! valid_port "$port"; then
        print_error "${label}无效：$port"
        exit 1
    fi
}

normalize_tag() {
    local raw="$1"
    local fallback="$2"
    local normalized
    normalized=$(printf '%s' "$raw" | sed 's/[^a-zA-Z0-9-]//g')
    printf '%s' "${normalized:-$fallback}"
}

get_public_ipv4() {
    local endpoint public_ip
    for endpoint in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        public_ip=$(curl -4 -fsS --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]')
        if [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$public_ip"
            return 0
        fi
    done
    return 1
}

prompt_public_host() {
    local label="$1"
    local public_host
    if public_host=$(get_public_ipv4); then
        echo "$public_host"
        return 0
    fi

    print_warn "无法自动获取公网 IP"
    read -p "   ${label}公网 Host/IP: " public_host
    if [[ -z "$public_host" ]]; then
        print_error "公网地址为空，无法生成有效 URI"
        exit 1
    fi
    echo "$public_host"
}

apply_config_update() {
    local filter="$1"
    local tmp
    tmp=$(mktemp) || { print_error "创建临时配置文件失败"; exit 1; }

    if ! jq "$filter" "$SB_CONFIG" > "$tmp"; then
        rm -f "$tmp"
        print_error "写入 sing-box 配置失败"
        exit 1
    fi

    if ! mv "$tmp" "$SB_CONFIG"; then
        rm -f "$tmp"
        print_error "替换 sing-box 配置失败"
        exit 1
    fi
}

# 生成自签证书 (用于 C 端)
gen_self_signed_cert() {
    local cn_name="internal.anytls"
    local key_path="$SB_CERT_DIR/anytls.key"
    local crt_path="$SB_CERT_DIR/anytls.crt"

    print_info "Generating Self-Signed Cert..."
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
        -keyout "$key_path" -out "$crt_path" -days 3650 \
        -subj "/CN=$cn_name" >/dev/null 2>&1
    
    chmod 644 "$crt_path"
    chmod 600 "$key_path"
    echo "$crt_path|$key_path"
}

# 生成 Shadowsocks URI
gen_ss_uri() {
    local method="$1"
    local password="$2"
    local host="$3"
    local port="$4"
    local name="${5:-ss2anytls-SS}"

    # Base64编码 method:password
    local userinfo="${method}:${password}"
    local encoded
    encoded=$(base64_no_wrap "$userinfo")

    # URL编码节点名称
    local encoded_name
    encoded_name=$(url_encode "$name")

    # 生成完整URI
    echo "ss://${encoded}@${host}:${port}?udp=1#${encoded_name}"
}

# 生成 AnyTLS URI (用于 C 端导入)
gen_anytls_uri() {
    local password="$1"
    local host="$2"
    local port="$3"
    local name="${4:-ss2anytls-AnyTLS}"
    local sni="$5"

    local encoded_userinfo
    # AnyTLS URI 的 auth 是实际密码，base64 密码里的保留字符需要百分号编码
    encoded_userinfo=$(url_encode "$password")

    # URL编码节点名称
    local encoded_name
    encoded_name=$(url_encode "$name")

    # 生成完整URI
    if [[ -n "$sni" ]]; then
        local encoded_sni
        encoded_sni=$(url_encode "$sni")
        echo "anytls://${encoded_userinfo}@${host}:${port}?insecure=1&sni=${encoded_sni}#${encoded_name}"
    else
        echo "anytls://${encoded_userinfo}@${host}:${port}?insecure=1#${encoded_name}"
    fi
}

# 检查 tag 是否存在
check_tag_exists() {
    local tag="$1"
    if jq -e ".inbounds[]? | select(.tag == \"$tag\")" "$SB_CONFIG" >/dev/null 2>&1; then
        return 0  # 存在
    fi
    if jq -e ".outbounds[]? | select(.tag == \"$tag\")" "$SB_CONFIG" >/dev/null 2>&1; then
        return 0  # 存在
    fi
    return 1  # 不存在
}

# --- 逻辑 C: 出口端 (Pure AnyTLS Server) ---

logic_C() {
    echo -e "${WHITE}>>> Mode: ${CYAN}C. 出口机器 (Exit / Server C)${NC}"
    echo -e "${WHITE}    Role: Inbound (Pure AnyTLS + Self-Signed Cert)${NC}"
    echo -e "${YELLOW}    [Feature] Supports adding MULTIPLE inbounds.${NC}"
    
    install_dependencies

    # 初始化配置（如果不存在）
    if [ ! -f "$SB_CONFIG" ] || [ ! -s "$SB_CONFIG" ]; then
        echo '{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$SB_CONFIG"
    fi
    
    # 备份现有配置
    if [ -f "$SB_CONFIG" ]; then
        print_info "Config exists. Appending new inbound..."
        cp "$SB_CONFIG" "${SB_CONFIG}.bak"
    fi

    # 端口和Tag设置
    read -p "   Set Listen Port [Default 8443]: " listen_port
    listen_port=${listen_port:-8443}
    require_valid_port "$listen_port" "C 端监听端口"

    # SNI server_name 设置（可选）
    read -p "   SNI Server Name (留空则不添加): " sni_server_name
    sni_server_name=${sni_server_name:-""}
    
    # 检查端口冲突
    if jq -e ".inbounds[]? | select(.listen_port == $listen_port)" "$SB_CONFIG" >/dev/null 2>&1; then
        print_error "端口 $listen_port 已被占用！"
        jq -r '.inbounds[] | "  Port: \(.listen_port) - Tag: \(.tag)"' "$SB_CONFIG"
        exit 1
    fi
    
    # 让用户输入 tag 名称
    while true; do
        read -p "   Tag Name (英文/数字/短横线) [anytls-in]: " user_tag
        user_tag=${user_tag:-"anytls-in"}
        # 清理 tag，只保留字母数字和短横线
        user_tag=$(normalize_tag "$user_tag" "anytls-in")
        
        # 检查 tag 是否已存在
        if check_tag_exists "$user_tag"; then
            print_warn "Tag '$user_tag' 已存在！"
            read -p "   是否覆盖现有配置? [y/N]: " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
                # 删除旧的 inbound
                apply_config_update "del(.inbounds[] | select(.tag == \"$user_tag\"))"
                print_success "已删除旧配置"
                break
            else
                print_info "请重新输入不同的 Tag 名称"
                continue
            fi
        else
            break
        fi
    done

    # 1. 生成证书
    cert_paths=$(gen_self_signed_cert)
    crt_path=${cert_paths%%|*}
    key_path=${cert_paths#*|}

    # 2. 生成密码
    anytls_password=$(gen_anytls_pass)

    print_info "Appending AnyTLS Inbound via jq..."

    # 构造 Inbound (AnyTLS)
    if [[ -n "$sni_server_name" ]]; then
        json_ib=$(jq -n \
            --arg tag "$user_tag" \
            --arg port "$listen_port" \
            --arg pass "$anytls_password" \
            --arg crt "$crt_path" \
            --arg key "$key_path" \
            --arg sni "$sni_server_name" \
            '{
                type: "anytls",
                tag: $tag,
                listen: "::",
                listen_port: ($port|tonumber),
                users: [ { name: "user1", password: $pass } ],
                tls: {
                    enabled: true,
                    certificate_path: $crt,
                    key_path: $key,
                    server_name: $sni
                }
            }')
    else
        json_ib=$(jq -n \
            --arg tag "$user_tag" \
            --arg port "$listen_port" \
            --arg pass "$anytls_password" \
            --arg crt "$crt_path" \
            --arg key "$key_path" \
            '{
                type: "anytls",
                tag: $tag,
                listen: "::",
                listen_port: ($port|tonumber),
                users: [ { name: "user1", password: $pass } ],
                tls: {
                    enabled: true,
                    certificate_path: $crt,
                    key_path: $key
                }
            }')
    fi

    # 写入配置
    apply_config_update ".inbounds += [$json_ib]"
    
    # 确保有 direct outbound
    if ! jq -e '.outbounds[]? | select(.tag == "direct")' "$SB_CONFIG" >/dev/null 2>&1; then
        apply_config_update '.outbounds += [{"type":"direct","tag":"direct"}]'
    fi

    # 启用并重启服务
    systemctl enable sing-box.service >/dev/null 2>&1
    
    if systemctl restart sing-box.service; then
        public_ip=$(prompt_public_host "C 端")

        print_success "Server C Inbound Added!"

        # 生成 AnyTLS URI
        anytls_uri=$(gen_anytls_uri "$anytls_password" "$public_ip" "$listen_port" "$user_tag" "$sni_server_name")

        # 根据是否有 server_name 动态生成输出
        if [[ -n "$sni_server_name" ]]; then
            print_card "Copy to Server B" \
                "IP          : $public_ip" \
                "Port        : $listen_port" \
                "Password    : $anytls_password" \
                "SNI server name : $sni_server_name" \
                "Tag         : $user_tag"
        else
            print_card "Copy to Server B" \
                "IP       : $public_ip" \
                "Port     : $listen_port" \
                "Password : $anytls_password" \
                "Tag      : $user_tag"
        fi

        # 打印 AnyTLS URI
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${WHITE} AnyTLS URI (一键导入链接)${CYAN}                              ║${NC}"
        echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${GREEN}$anytls_uri${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"

        # 引导步骤
        echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║${WHITE}  下一步操作指引 (Next Steps)${YELLOW}              ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC}  1. 复制上方的 IP、Port、Password           ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  2. 登录到服务器 B (中转服务器)             ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  3. 运行本脚本并选择 [1] B (Relay)          ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  4. 粘贴上方信息以建立 B → C 隧道           ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  5. 可再次运行本脚本添加更多 C 端口         ${YELLOW}║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}\n"

        print_warn "若配置无法使用，可访问 /etc/sing-box/config.json.bak 退回之前配置"
    else
        print_error "服务启动失败！Restoring backup..."
        cp "${SB_CONFIG}.bak" "$SB_CONFIG" 2>/dev/null
        systemctl restart sing-box.service
        journalctl -u sing-box.service -n 20 --no-pager
    fi
}

# --- 逻辑 B: 中转端 (Incremental Relay) ---

logic_B() {
    echo -e "${WHITE}>>> Mode: ${CYAN}B. 中转机器 (Relay / Server B)${NC}"
    echo -e "${WHITE}    Role: SS-2022 -> AnyTLS Tunnel -> C${NC}"
    echo -e "${YELLOW}    [Feature] Supports adding MULTIPLE C-nodes.${NC}"
    
    install_dependencies

    # 初始化配置
    if [ ! -f "$SB_CONFIG" ] || [ ! -s "$SB_CONFIG" ]; then
        echo '{ "log": {"level":"warn"}, "inbounds":[], "outbounds":[{"type":"direct","tag":"direct"}], "route":{"rules":[]} }' > "$SB_CONFIG"
    fi
    
    # 备份现有配置
    if [ -f "$SB_CONFIG" ]; then
        print_info "Config exists. Appending new route..."
        cp "$SB_CONFIG" "${SB_CONFIG}.bak"
    fi

    # 1. 输入 C 端信息
    echo -e "\n${YELLOW}? Target Server C Info${NC}"
    read -p "   C Server IP: " c_ip
    read -p "   C Server Port: " c_port
    read -p "   C AnyTLS Password: " c_pass
    read -p "   C SNI Server Name (留空则不添加): " c_server_name
    c_server_name=${c_server_name:-""}

    if [[ -z "$c_ip" || -z "$c_pass" ]]; then print_error "Empty input!"; exit 1; fi
    require_valid_port "$c_port" "C 端端口"

    # 2. B 端入站设置
    echo -e "\n${YELLOW}? Local Inbound Settings${NC}"
    read -p "   Local Listen Port [Random]: " local_port
    local_port=${local_port:-$(shuf -i 20000-30000 -n 1)}
    require_valid_port "$local_port" "B 端本地监听端口"
    
    # 让用户输入 tag 名称（不再添加时间戳）
    while true; do
        read -p "   Tag Name (英文/数字/短横线) [ss-relay]: " user_tag
        user_tag=${user_tag:-"ss-relay"}
        # 清理 tag，只保留字母数字和短横线
        user_tag=$(normalize_tag "$user_tag" "ss-relay")
        
        ib_tag="${user_tag}-in"
        ob_tag="${user_tag}-out"
        
        # 检查 tag 是否已存在
        if check_tag_exists "$ib_tag" || check_tag_exists "$ob_tag"; then
            print_warn "Tag '$user_tag' 已存在！"
            read -p "   是否覆盖现有配置? [y/N]: " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
                # 删除旧的 inbound/outbound/route
                apply_config_update "del(.inbounds[] | select(.tag == \"$ib_tag\"))"
                apply_config_update "del(.outbounds[] | select(.tag == \"$ob_tag\"))"
                apply_config_update "del(.route.rules[] | select(.inbound == \"$ib_tag\"))"
                print_success "已删除旧配置"
                break
            else
                print_info "请重新输入不同的 Tag 名称"
                continue
            fi
        else
            break
        fi
    done
    
    read -p "   Node Display Name [ss2anytls-SS]: " node_name
    node_name=${node_name:-"ss2anytls-SS"}
    local_ss_pass=$(gen_ss2022_key)

    print_info "Appending Config via jq..."

    # --- 构造 Inbound (SS-2022) ---
    json_ib=$(jq -n \
        --arg tag "$ib_tag" \
        --arg port "$local_port" \
        --arg pass "$local_ss_pass" \
        '{
            type: "shadowsocks",
            tag: $tag,
            listen: "::",
            listen_port: ($port|tonumber),
            method: "2022-blake3-aes-128-gcm",
            password: $pass,
            multiplex: { enabled: false, padding: false }
        }')

    # --- 构造 Outbound (Pure AnyTLS) ---
    if [[ -n "$c_server_name" ]]; then
        json_ob=$(jq -n \
            --arg tag "$ob_tag" \
            --arg server "$c_ip" \
            --arg port "$c_port" \
            --arg pass "$c_pass" \
            --arg sni "$c_server_name" \
            '{
                type: "anytls",
                tag: $tag,
                server: $server,
                server_port: ($port|tonumber),
                password: $pass,
                tls: {
                    enabled: true,
                    insecure: true,
                    server_name: $sni
                }
            }')
    else
        json_ob=$(jq -n \
            --arg tag "$ob_tag" \
            --arg server "$c_ip" \
            --arg port "$c_port" \
            --arg pass "$c_pass" \
            '{
                type: "anytls",
                tag: $tag,
                server: $server,
                server_port: ($port|tonumber),
                password: $pass,
                tls: {
                    enabled: true,
                    insecure: true
                }
            }')
    fi

    # --- 构造 Route Rule ---
    json_rule=$(jq -n --arg ib "$ib_tag" --arg ob "$ob_tag" '{ inbound: $ib, outbound: $ob }')

    # --- 写入 ---
    apply_config_update ".inbounds += [$json_ib]"
    apply_config_update ".outbounds += [$json_ob]"
    apply_config_update ".route.rules += [$json_rule]"

    # 启用并重启服务
    systemctl enable sing-box.service >/dev/null 2>&1
    
    if systemctl restart sing-box.service; then
        pub_ip=$(prompt_public_host "B 端")
        
        # 生成 SS URI
        ss_uri=$(gen_ss_uri "2022-blake3-aes-128-gcm" "$local_ss_pass" "$pub_ip" "$local_port" "$node_name")
        
        print_success "Route Added! You can run this again to add another C."
        print_card "Client Config (Give to User)" \
            "B Host     : $pub_ip" \
            "B Port     : $local_port" \
            "Password   : $local_ss_pass" \
            "Method     : 2022-blake3-aes-128-gcm" \
            "Tag        : $ib_tag → $ob_tag"
        
        # 打印 SS URI
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${WHITE} Shadowsocks URI (一键导入链接)${CYAN}                           ║${NC}"
        echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${GREEN}$ss_uri${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
        
        print_warn "复制上方 URI 链接，在客户端使用一键导入功能即可使用"
        print_warn "若配置无法使用，可访问 /etc/sing-box/config.json.bak 退回之前配置"

        
    else
        print_error "Failed. Restoring backup..."
        cp "${SB_CONFIG}.bak" "$SB_CONFIG"
        systemctl restart sing-box.service
        journalctl -u sing-box.service -n 10 --no-pager
    fi
}

check_root
show_banner
echo -e "Select Mode:\n 1. (Relay) - Add Route\n 2. (Exit) - Setup AnyTLS"
read -p "Choice [1/2]: " choice
case "$choice" in 1) logic_B ;; 2) logic_C ;; *) exit 1 ;; esac
