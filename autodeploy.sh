#!/bin/bash

# ==========================================
# LeiKwan Host - Sing-box Pure AnyTLS Setup
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
    echo -e "${WHITE}           利 群 主 機  -  L e i K w a n   H o s t${NC}"
    echo -e "${CYAN} ==========================================================${NC}"
    echo -e "${WHITE}      Sing-box Pure AnyTLS (No-Reality) Setup v2.2${NC}"
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
        print_error "Please run as root: sudo ./auto-anytls-pure.sh"
        exit 1
    fi
}

install_dependencies() {
    # 安装 jq, openssl, curl
    if ! command -v jq &> /dev/null || ! command -v openssl &> /dev/null; then
        print_info "Installing dependencies (jq, openssl)..."
        if [ -x "$(command -v apt)" ]; then
            apt update -qq && apt install -y jq openssl curl wget tar > /dev/null
        elif [ -x "$(command -v yum)" ]; then
            yum install -y epel-release > /dev/null
            yum install -y jq openssl curl wget tar > /dev/null
        fi
    fi

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

    mkdir -p /etc/sing-box
    mkdir -p $SB_CERT_DIR
    
    # 清理默认配置
    if [ -f "$SB_CONFIG" ]; then
        # 检查是否是默认配置（包含dns或默认8080端口）
        if jq -e '.dns or (.inbounds[]? | select(.listen_port == 8080))' "$SB_CONFIG" >/dev/null 2>&1; then
            print_info "检测到默认配置，正在清理..."
            cp "$SB_CONFIG" "${SB_CONFIG}.original.bak" 2>/dev/null
            
            # 删除 dns 和默认 inbound，保留基础结构
            tmp=$(mktemp)
            jq 'del(.dns) | .inbounds = [] | .outbounds = [{"type":"direct","tag":"direct"}] | .route = {"rules":[]}' "$SB_CONFIG" > "$tmp" 2>/dev/null && mv "$tmp" "$SB_CONFIG"
            
            print_success "已清理默认模板"
        fi
    else
        # 创建空白配置
        echo '{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[]}}' > "$SB_CONFIG"
    fi
}

gen_ss2022_key() { openssl rand -base64 16; }
gen_anytls_pass() { openssl rand -base64 16; }

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
    local name="${5:-LeiKwan-SS}"
    
    # Base64编码 method:password
    local userinfo="${method}:${password}"
    local encoded=$(echo -n "$userinfo" | base64 -w 0 2>/dev/null || echo -n "$userinfo" | base64)
    
    # URL编码节点名称
    local encoded_name=$(echo -n "$name" | xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g')
    
    # 生成完整URI
    echo "ss://${encoded}@${host}:${port}?udp=1#${encoded_name}"
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
    
    install_dependencies

    read -p "   Set Listen Port [Default 8443]: " listen_port
    listen_port=${listen_port:-8443}

    # 1. 生成证书
    cert_paths=$(gen_self_signed_cert)
    crt_path=$(echo $cert_paths | cut -d'|' -f1)
    key_path=$(echo $cert_paths | cut -d'|' -f2)

    # 2. 生成密码
    anytls_password=$(gen_anytls_pass)

    print_info "Writing Config..."

    # C端配置：Inbound 使用 anytls 类型，开启 TLS 并指向本地证书
    cat > $SB_CONFIG <<EOF
{
  "log": { "level": "warn"},
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $listen_port,
      "users": [ { "name": "user1", "password": "$anytls_password" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "$crt_path",
        "key_path": "$key_path"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

    # 启用并重启服务
    systemctl enable sing-box.service >/dev/null 2>&1
    systemctl restart sing-box.service
    
    if ! systemctl is-active --quiet sing-box.service; then
        print_error "服务启动失败！"
        journalctl -u sing-box.service -n 20 --no-pager
        exit 1
    fi
    
    public_ip=$(curl -4 -s --max-time 3 ifconfig.me)

    print_success "Server C Deployed!"
    print_card "Copy to Server B" \
        "IP       : $public_ip" \
        "Port     : $listen_port" \
        "Password : $anytls_password"
    
    # 引导步骤
    echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${WHITE}  下一步操作指引 (Next Steps)${YELLOW}              ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  1. 复制上方的 IP、Port、Password           ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  2. 登录到服务器 B (中转服务器)             ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  3. 运行本脚本并选择 [1] B (Relay)          ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  4. 粘贴上方信息以建立 B → C 隧道           ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}\n"
}

# --- 逻辑 B: 中转端 (Incremental Relay) ---

logic_B() {
    echo -e "${WHITE}>>> Mode: ${CYAN}B. 中转机器 (Relay / Server B)${NC}"
    echo -e "${WHITE}    Role: SS-2022 -> AnyTLS Tunnel -> C${NC}"
    echo -e "${YELLOW}    [Feature] Supports adding MULTIPLE C-nodes.${NC}"
    
    install_dependencies

    # 初始化配置
    if [ ! -f "$SB_CONFIG" ] || [ ! -s "$SB_CONFIG" ]; then
        echo '{ "log": {"level":"warn"}, "inbounds":[], "outbounds":[{"type":"direct","tag":"direct"}], "route":{"rules":[]} }' > $SB_CONFIG
    else
        print_info "Config exists. Appending new route..."
        cp $SB_CONFIG "${SB_CONFIG}.bak"
    fi

    # 1. 输入 C 端信息
    echo -e "\n${YELLOW}? Target Server C Info${NC}"
    read -p "   C Server IP: " c_ip
    read -p "   C Server Port: " c_port
    read -p "   C AnyTLS Password: " c_pass
    
    if [[ -z "$c_ip" || -z "$c_pass" ]]; then print_error "Empty input!"; exit 1; fi

    # 2. B 端入站设置
    echo -e "\n${YELLOW}? Local Inbound Settings${NC}"
    read -p "   Local Listen Port [Random]: " local_port
    local_port=${local_port:-$(shuf -i 20000-30000 -n 1)}
    
    # 让用户输入 tag 名称（不再添加时间戳）
    while true; do
        read -p "   Tag Name (英文/数字/短横线) [ss-relay]: " user_tag
        user_tag=${user_tag:-"ss-relay"}
        # 清理 tag，只保留字母数字和短横线
        user_tag=$(echo "$user_tag" | sed 's/[^a-zA-Z0-9-]//g')
        
        ib_tag="${user_tag}-in"
        ob_tag="${user_tag}-out"
        
        # 检查 tag 是否已存在
        if check_tag_exists "$ib_tag" || check_tag_exists "$ob_tag"; then
            print_warn "Tag '$user_tag' 已存在！"
            read -p "   是否覆盖现有配置? [y/N]: " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
                # 删除旧的 inbound/outbound/route
                tmp=$(mktemp)
                jq "del(.inbounds[] | select(.tag == \"$ib_tag\"))" "$SB_CONFIG" > "$tmp" && mv "$tmp" "$SB_CONFIG"
                jq "del(.outbounds[] | select(.tag == \"$ob_tag\"))" "$SB_CONFIG" > "$tmp" && mv "$tmp" "$SB_CONFIG"
                jq "del(.route.rules[] | select(.inbound == \"$ib_tag\"))" "$SB_CONFIG" > "$tmp" && mv "$tmp" "$SB_CONFIG"
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
    
    read -p "   Node Display Name [LeiKwan-SS]: " node_name
    node_name=${node_name:-"LeiKwan-SS"}
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

    # --- 构造 Route Rule ---
    json_rule=$(jq -n --arg ib "$ib_tag" --arg ob "$ob_tag" '{ inbound: $ib, outbound: $ob }')

    # --- 写入 ---
    tmp=$(mktemp)
    jq ".inbounds += [$json_ib]" $SB_CONFIG > "$tmp" && mv "$tmp" $SB_CONFIG
    jq ".outbounds += [$json_ob]" $SB_CONFIG > "$tmp" && mv "$tmp" $SB_CONFIG
    jq ".route.rules += [$json_rule]" $SB_CONFIG > "$tmp" && mv "$tmp" $SB_CONFIG

    # 启用并重启服务
    systemctl enable sing-box.service >/dev/null 2>&1
    
    if systemctl restart sing-box.service; then
        pub_ip=$(curl -4 -s --max-time 3 ifconfig.me)
        
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
        
    else
        print_error "Failed. Restoring backup..."
        cp "${SB_CONFIG}.bak" $SB_CONFIG
        systemctl restart sing-box.service
        journalctl -u sing-box.service -n 10 --no-pager
    fi
}

check_root
show_banner
echo -e "Select Mode:\n 1. (Relay) - Add Route\n 2. (Exit) - Setup AnyTLS"
read -p "Choice [1/2]: " choice
case "$choice" in 1) logic_B ;; 2) logic_C ;; *) exit 1 ;; esac
