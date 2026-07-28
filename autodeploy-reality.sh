#!/bin/bash

# ==========================================
# ss2anytls-autodeploy - Sing-box VLESS+Reality+Vision 部署脚本
# Exit 端使用 VLESS + Reality + Vision（基于 sing-box），中转端使用 SS-2022 入站
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
    echo -e "${WHITE}  Sing-box VLESS + Reality + Vision Setup v1.0${NC}"
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
        print_error "请使用 root 权限运行：sudo ./autodeploy-reality.sh"
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
}

gen_ss2022_key() { openssl rand -base64 16; }

# 生成 UUID（优先使用 sing-box，回退到 /proc）
gen_uuid() {
    if command -v sing-box &> /dev/null; then
        sing-box generate uuid 2>/dev/null
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        uuidgen 2>/dev/null || openssl rand -hex 16
    fi
}

# 生成 Reality 密钥对，输出 "private|public"
gen_reality_keypair() {
    local keypair priv pub
    if command -v sing-box &> /dev/null; then
        keypair=$(sing-box generate reality-keypair 2>/dev/null)
        priv=$(printf '%s' "$keypair" | awk '/PrivateKey/ {print $2}')
        pub=$(printf '%s' "$keypair" | awk '/PublicKey/ {print $2}')
    fi
    # 回退：使用 openssl 生成 X25519 密钥对（base64 raw）
    if [[ -z "$priv" || -z "$pub" ]]; then
        priv=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
        pub=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
    fi
    printf '%s|%s' "$priv" "$pub"
}

# 生成 short_id（8 位十六进制）
gen_short_id() { openssl rand -hex 4; }

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

# 生成 Shadowsocks URI
gen_ss_uri() {
    local method="$1"
    local password="$2"
    local host="$3"
    local port="$4"
    local name="${5:-ss2reality-SS}"

    local userinfo="${method}:${password}"
    local encoded
    encoded=$(base64_no_wrap "$userinfo")

    local encoded_name
    encoded_name=$(url_encode "$name")

    echo "ss://${encoded}@${host}:${port}?udp=1#${encoded_name}"
}

# 生成 VLESS + Reality + Vision URI（用于客户端导入）
gen_vless_reality_uri() {
    local uuid="$1"
    local host="$2"
    local port="$3"
    local sni="$4"
    local pbk="$5"
    local sid="$6"
    local fp="$7"
    local name="${8:-ss2reality-VLESS}"

    local encoded_name
    encoded_name=$(url_encode "$name")

    # 标准共享链接格式：vless://uuid@host:port?参数#name
    echo "vless://${uuid}@${host}:${port}?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}#${encoded_name}"
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

# --- 逻辑 C: 出口端 (VLESS + Reality + Vision Server) ---

logic_C() {
    echo -e "${WHITE}>>> Mode: ${CYAN}C. 出口机器 (Exit / Server C)${NC}"
    echo -e "${WHITE}    Role: Inbound (VLESS + Reality + Vision)${NC}"
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
    read -p "   Set Listen Port [Default 443]: " listen_port
    listen_port=${listen_port:-443}
    require_valid_port "$listen_port" "C 端监听端口"

    # Reality 必须的 SNI/目标域名（用于握手转发，通常是真实存在的 TLS 网站）
    echo -e "${YELLOW}   Reality 握手目标（handshake server）需要是一个真实可访问的 TLS 网站${NC}"
    echo -e "${YELLOW}   常见选择：www.cloudflare.com / www.microsoft.com / gateway.icloud.com${NC}"
    read -p "   Reality SNI / Handshake Server [www.microsoft.com]: " sni_server_name
    sni_server_name=${sni_server_name:-"www.microsoft.com"}

    # uTLS 指纹（客户端伪装）
    read -p "   uTLS Fingerprint [chrome]: " utls_fp
    utls_fp=${utls_fp:-"chrome"}

    # 检查端口冲突
    if jq -e ".inbounds[]? | select(.listen_port == $listen_port)" "$SB_CONFIG" >/dev/null 2>&1; then
        print_error "端口 $listen_port 已被占用！"
        jq -r '.inbounds[] | "  Port: \(.listen_port) - Tag: \(.tag)"' "$SB_CONFIG"
        exit 1
    fi

    # 让用户输入 tag 名称
    while true; do
        read -p "   Tag Name (英文/数字/短横线) [vless-reality-in]: " user_tag
        user_tag=${user_tag:-"vless-reality-in"}
        user_tag=$(normalize_tag "$user_tag" "vless-reality-in")

        if check_tag_exists "$user_tag"; then
            print_warn "Tag '$user_tag' 已存在！"
            read -p "   是否覆盖现有配置? [y/N]: " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
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

    # 1. 生成 Reality 密钥对
    print_info "Generating Reality Keypair..."
    keypair=$(gen_reality_keypair)
    private_key=${keypair%%|*}
    public_key=${keypair#*|}
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        print_error "生成 Reality 密钥对失败"
        exit 1
    fi

    # 2. 生成 UUID 与 short_id
    vless_uuid=$(gen_uuid)
    short_id=$(gen_short_id)

    print_info "Appending VLESS+Reality Inbound via jq..."

    # 构造 Inbound (VLESS + Reality + Vision)
    json_ib=$(jq -n \
        --arg tag "$user_tag" \
        --arg port "$listen_port" \
        --arg uuid "$vless_uuid" \
        --arg sni "$sni_server_name" \
        --arg priv "$private_key" \
        --arg sid "$short_id" \
        '{
            type: "vless",
            tag: $tag,
            listen: "::",
            listen_port: ($port|tonumber),
            users: [ { name: "user1", uuid: $uuid, flow: "xtls-rprx-vision" } ],
            tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                    enabled: true,
                    handshake: {
                        server: $sni,
                        server_port: 443
                    },
                    private_key: $priv,
                    short_id: [ $sid ]
                }
            }
        }')

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

        # 生成 VLESS URI
        vless_uri=$(gen_vless_reality_uri "$vless_uuid" "$public_ip" "$listen_port" "$sni_server_name" "$public_key" "$short_id" "$utls_fp" "$user_tag")

        print_card "Copy to Server B / Client" \
            "IP             : $public_ip" \
            "Port           : $listen_port" \
            "UUID           : $vless_uuid" \
            "SNI            : $sni_server_name" \
            "Public Key     : $public_key" \
            "Short ID       : $short_id" \
            "Fingerprint    : $utls_fp" \
            "Flow           : xtls-rprx-vision" \
            "Tag            : $user_tag"

        # 打印 VLESS URI
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${WHITE} VLESS Reality URI (一键导入链接)${CYAN}                         ║${NC}"
        echo -e "${CYAN}╠════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC} ${GREEN}$vless_uri${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"

        # 引导步骤
        echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║${WHITE}  下一步操作指引 (Next Steps)${YELLOW}              ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC}  1. 复制上方的 IP/Port/UUID/SNI/公钥/ShortID ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  2. 登录到服务器 B (中转服务器)             ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  3. 运行本脚本并选择 [1] B (Relay)          ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  4. 粘贴上方信息以建立 B → C 隧道           ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  5. 或直接用 VLESS URI 导入客户端            ${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  6. 可再次运行本脚本添加更多 C 端口         ${YELLOW}║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}\n"

        print_warn "若配置无法使用，可访问 /etc/sing-box/config.json.bak 退回之前配置"
    else
        print_error "服务启动失败！Restoring backup..."
        cp "${SB_CONFIG}.bak" "$SB_CONFIG" 2>/dev/null
        systemctl restart sing-box.service
        journalctl -u sing-box.service -n 20 --no-pager
    fi
}

# --- 逻辑 B: 中转端 (Incremental Relay, SS-2022 -> VLESS Reality) ---

logic_B() {
    echo -e "${WHITE}>>> Mode: ${CYAN}B. 中转机器 (Relay / Server B)${NC}"
    echo -e "${WHITE}    Role: SS-2022 -> VLESS+Reality+Vision Tunnel -> C${NC}"
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
    read -p "   C VLESS UUID: " c_uuid
    read -p "   C Reality SNI: " c_sni
    read -p "   C Reality Public Key: " c_public_key
    read -p "   C Reality Short ID: " c_short_id
    read -p "   C uTLS Fingerprint [chrome]: " c_fp
    c_fp=${c_fp:-"chrome"}

    if [[ -z "$c_ip" || -z "$c_uuid" || -z "$c_sni" || -z "$c_public_key" || -z "$c_short_id" ]]; then
        print_error "Empty input!"
        exit 1
    fi
    require_valid_port "$c_port" "C 端端口"

    # 2. B 端入站设置
    echo -e "\n${YELLOW}? Local Inbound Settings${NC}"
    read -p "   Local Listen Port [Random]: " local_port
    local_port=${local_port:-$(shuf -i 20000-30000 -n 1)}
    require_valid_port "$local_port" "B 端本地监听端口"

    # 让用户输入 tag 名称
    while true; do
        read -p "   Tag Name (英文/数字/短横线) [ss-relay]: " user_tag
        user_tag=${user_tag:-"ss-relay"}
        user_tag=$(normalize_tag "$user_tag" "ss-relay")

        ib_tag="${user_tag}-in"
        ob_tag="${user_tag}-out"

        if check_tag_exists "$ib_tag" || check_tag_exists "$ob_tag"; then
            print_warn "Tag '$user_tag' 已存在！"
            read -p "   是否覆盖现有配置? [y/N]: " overwrite
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
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

    read -p "   Node Display Name [ss2reality-SS]: " node_name
    node_name=${node_name:-"ss2reality-SS"}
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

    # --- 构造 Outbound (VLESS + Reality + Vision) ---
    json_ob=$(jq -n \
        --arg tag "$ob_tag" \
        --arg server "$c_ip" \
        --arg port "$c_port" \
        --arg uuid "$c_uuid" \
        --arg sni "$c_sni" \
        --arg pbk "$c_public_key" \
        --arg sid "$c_short_id" \
        --arg fp "$c_fp" \
        '{
            type: "vless",
            tag: $tag,
            server: $server,
            server_port: ($port|tonumber),
            uuid: $uuid,
            flow: "xtls-rprx-vision",
            tls: {
                enabled: true,
                server_name: $sni,
                utls: { enabled: true, fingerprint: $fp },
                reality: {
                    enabled: true,
                    public_key: $pbk,
                    short_id: $sid
                }
            }
        }')

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
echo -e "Select Mode:\n 1. (Relay) - Add Route\n 2. (Exit) - Setup VLESS+Reality"
read -p "Choice [1/2]: " choice
case "$choice" in 1) logic_B ;; 2) logic_C ;; *) exit 1 ;; esac