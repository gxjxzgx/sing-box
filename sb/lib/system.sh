manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    # 首次安装仅刷新软件源索引，不做全系统 upgrade（避免生产机被动升级内核等）
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在刷新软件源索引...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y
        elif command_exists dnf; then
            dnf check-update -y || true
        elif command_exists yum; then
            yum check-update -y || true
        elif command_exists apk; then
            apk update
        else
            yellow "Unknown system!\n"
        fi
        green "软件源索引已刷新\n"
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 获取ip
get_realip() {
    # 优先返回 IPv4（节点链接默认用 IPv4）
    # 仅当无可用 IPv4，或 IPv4 为 WARP/特殊线路不可直连时，才回退到 IPv6
    local ip v6 org
    ip=$(curl -4 -sm 2 ip.sb 2>/dev/null)
    ipv6() { curl -6 -sm 2 ip.sb 2>/dev/null; }

    if [ -n "$ip" ]; then
        # 检测 IPv4 是否为 Cloudflare WARP 等不可作直连地址的 IP
        org=$(curl -4 -sm 2 http://ipinfo.io/org 2>/dev/null)
        if echo "$org" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
            # IPv4 不可用，尝试 IPv6
            v6=$(ipv6)
            if [ -n "$v6" ]; then
                echo "[$v6]"
            else
                echo "$ip"   # 没有 IPv6 时仍返回 IPv4
            fi
        else
            echo "$ip"       # 正常 IPv4，优先使用
        fi
    else
        # 无 IPv4，使用 IPv6
        v6=$(ipv6)
        if [ -n "$v6" ]; then
            echo "[$v6]"
        else
            echo "127.0.0.1"
        fi
    fi
}


# 获取服务商名称（只返回服务商，如 Cloudflare / DigitalOcean，不带国家码、不带 ASN 号）
get_isp() {
    local fallback="${1:-node}"
    local result
    result=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null | tr -d '\n' | \
        awk -F\" '{i="";for(x=1;x<=NF;x++){if($x=="isp")i=$(x+2)};if(i)print i}')
    if [ -z "$result" ]; then
        result=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" 2>/dev/null | tr -d '\n' | \
            awk -F\" '{o="";for(x=1;x<=NF;x++){if($x=="org")o=$(x+2)};if(o)print o}')
    fi
    # 去掉可能带的 "AS12345 " 前缀；空格→下划线
    result=$(printf '%s' "$result" | sed -E 's/^AS[0-9]+[[:space:]]+//; s/,//g; s/[[:space:]]+/_/g')
    echo "${result:-$fallback}"
}

# [优化新增] 统一节点前缀计算
# 命名规则：有自定义前缀 → 自定义-协议；无自定义 → 服务商-协议
# 拼出前缀，但 manage_protocols 里手动新增的 Socks5 / VLESS-WS直连 / SS2022
# 三个协议此前各自单独取 isp 直接拼节点名，完全没带用户设置的 node_prefix，
# 也没有协议后缀，风格和默认协议不一致。这里抽成统一函数，谁调用都一样。
build_node_prefix() {
    local fallback="${1:-node}"
    # 自定义前缀优先；设置了自定义名称时不再输出服务商
    if [ -n "${node_prefix:-}" ]; then
        echo "$node_prefix"
    else
        get_isp "$fallback"
    fi
}

# 刷新本地 sub.txt（base64 节点列表，兼容 GNU / BusyBox base64；HTTP 由 Nginx /s/<token> 提供）
refresh_sub() {
    local src="${1:-$client_dir}"
    [ -f "$src" ] || return 1
    if base64 -w0 "$src" > "${work_dir}/sub.txt" 2>/dev/null; then
        :
    else
        base64 "$src" | tr -d '\n\r' > "${work_dir}/sub.txt"
    fi
    chmod 644 "${work_dir}/sub.txt" 2>/dev/null || true
}

# ---------- [v2.6.0新增] sing-box config 变更的统一"校验+回滚"封装 ----------
# 用法: apply_json_change <jq命令字符串数组...> 由调用方在外部完成 jq 写 tmp 文件，
# 这里只负责: 备份原文件 -> mv tmp 覆盖 -> sing-box check -> 失败则回滚并返回非0。
# 所有会修改 inbounds.json / route.json / outbounds.json 并且随后要 restart_singbox
# 的地方，统一改为调用这个函数，避免"改坏配置但没有回滚"的问题。
safe_apply_conf() {
    local target_file="$1"   # 要覆盖的正式配置文件，例如 ${conf_dir}/inbounds.json
    local tmp_file="$2"      # jq 已经写好的临时文件
    local label="${3:-配置}"

    if [ ! -s "$tmp_file" ]; then
        red "${label} 生成失败（临时文件为空），已取消本次修改"
        rm -f "$tmp_file"
        return 1
    fi

    # jq 输出必须是合法 JSON，防止半截写坏
    if command_exists jq && ! jq empty "$tmp_file" >/dev/null 2>&1; then
        red "${label} 生成的 JSON 不合法，已取消本次修改"
        rm -f "$tmp_file"
        return 1
    fi

    local backup_file="${target_file}.bak.safeapply"
    cp -f "$target_file" "$backup_file" 2>/dev/null || true
    mv -f "$tmp_file" "$target_file"

    if [ -x "${work_dir}/sing-box" ] && ! "${work_dir}/sing-box" check -C "${conf_dir}" >/dev/null 2>&1; then
        red "${label} 校验失败（sing-box check 未通过），已自动回滚"
        if [ -f "$backup_file" ]; then
            mv -f "$backup_file" "$target_file"
        fi
        return 1
    fi

    rm -f "$backup_file"
    return 0
}

# ---------- [v2.6.1-fix] 直连节点缓存 ----------
# url.txt 里「非 Argo」的行（Reality/HY2/TUIC/AnyTLS/VLESS-WS直连/Socks5/SS2022 等）
# 单独缓存一份。改隧道/改域名等只应该动 Argo 三行，直连行任何时候都不能丢。
DIRECT_CACHE="${work_dir}/direct_nodes.cache"
_ARGO_LINE_RE='^vmess://|path=(%2F|/)(vless|trojan)-argo'

# 从 url.txt 提取直连行写入缓存（url.txt 无直连行时不覆盖旧缓存）
save_direct_cache() {
    [ -s "$client_dir" ] || return 0
    local tmp
    tmp=$(mktemp 2>/dev/null) || return 0
    grep -vE "$_ARGO_LINE_RE" "$client_dir" 2>/dev/null | sed '/^[[:space:]]*$/d' > "$tmp"
    if [ -s "$tmp" ]; then
        mv -f "$tmp" "$DIRECT_CACHE"
        chmod 600 "$DIRECT_CACHE" 2>/dev/null || true
    else
        rm -f "$tmp"
    fi
}

# 把缓存里 target 缺失的直连行补回（追加）；输出补回条数
restore_direct_cache() {
    local target="${1:-$client_dir}" line n=0
    [ -s "$DIRECT_CACHE" ] || { echo 0; return 0; }
    touch "$target"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        if ! grep -qxF -- "$line" "$target" 2>/dev/null; then
            printf '\n%s\n' "$line" >> "$target"
            n=$((n + 1))
        fi
    done < "$DIRECT_CACHE"
    echo "$n"
}

# 订阅：令牌 + 独立端口 + 开关，写入 install.conf
load_sub_conf() {
    SKIP_DIRECT="${SKIP_DIRECT:-0}"
    SUB_TOKEN="${SUB_TOKEN:-}"
    SUB_PORT="${SUB_PORT:-}"
    SUB_ENABLED="${SUB_ENABLED:-1}"
    if [ -f "${work_dir}/install.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/install.conf" 2>/dev/null || true
    fi
    SUB_ENABLED="${SUB_ENABLED:-1}"
}

save_sub_conf() {
    # 只写入当前内存中的值，禁止再 source 文件以免覆盖刚改的令牌/端口
    {
        printf 'SKIP_DIRECT=%s\n' "${SKIP_DIRECT:-0}"
        printf 'SUB_TOKEN=%s\n' "${SUB_TOKEN:-}"
        printf 'SUB_PORT=%s\n' "${SUB_PORT:-2096}"
        printf 'SUB_ENABLED=%s\n' "${SUB_ENABLED:-1}"
    } > "${work_dir}/install.conf"
    chmod 644 "${work_dir}/install.conf" 2>/dev/null || true
}

ensure_sub_token() {
    load_sub_conf
    local tok="${SUB_TOKEN:-}"
    if [ -z "$tok" ] || ! echo "$tok" | grep -Eq '^[A-Za-z0-9_-]{8,64}$'; then
        if command_exists openssl; then
            tok=$(openssl rand -hex 12 2>/dev/null)
        fi
        [ -z "$tok" ] && tok=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 24)
        [ -z "$tok" ] && tok=$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 24)
        [ -z "$tok" ] && tok="sb$(date +%s)"
        SUB_TOKEN="$tok"
    fi
    export SUB_TOKEN
    # 默认订阅端口
    if [ -z "${SUB_PORT:-}" ] || ! [[ "${SUB_PORT}" =~ ^[0-9]+$ ]]; then
        SUB_PORT=2096
    fi
    export SUB_PORT
    SUB_ENABLED="${SUB_ENABLED:-1}"
    export SUB_ENABLED
    save_sub_conf
}

# 强制生成新订阅令牌（旧 /s/<token> 立即失效）；成功返回 0
regenerate_sub_token() {
    load_sub_conf
    local old_tok="${SUB_TOKEN:-}" tok=""
    if command_exists openssl; then
        tok=$(openssl rand -hex 12 2>/dev/null)
    fi
    [ -z "$tok" ] && tok=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 24)
    [ -z "$tok" ] && tok=$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 24)
    [ -z "$tok" ] && tok="sb$(date +%s)${RANDOM:-0}"
    [ -n "$old_tok" ] && [ "$tok" = "$old_tok" ] && tok="${tok}x"

    SUB_TOKEN="$tok"
    SUB_ENABLED=1
    [ -z "${SUB_PORT:-}" ] || ! [[ "${SUB_PORT}" =~ ^[0-9]+$ ]] && SUB_PORT=2096
    export SUB_TOKEN SUB_ENABLED SUB_PORT
    save_sub_conf
    allow_port ${SUB_PORT}/tcp >/dev/null 2>&1
    write_sub_nginx_conf

    local argo_conf="/etc/nginx/conf.d/argo-ws.conf"
    if [ -f "$argo_conf" ] && [ -n "$old_tok" ]; then
        sed -i "s|/s/${old_tok}|/s/${SUB_TOKEN}|g" "$argo_conf" 2>/dev/null || true
    elif [ -f "$argo_conf" ]; then
        _load_argo_port_for_nginx 2>/dev/null || true
        add_nginx_conf >/dev/null 2>&1 || true
    fi

    if command_exists nginx; then
        if nginx -t >/dev/null 2>&1; then
            restart_nginx >/dev/null 2>&1 || true
            return 0
        fi
        red "nginx -t 失败，新令牌已写入但可能未生效："
        nginx -t 2>&1 | tail -5
        return 1
    fi
    return 0
}

# 写入/更新独立订阅 Nginx 配置（sb-sub.conf）；关闭时删除
write_sub_nginx_conf() {
    ensure_sub_token
    local conf="/etc/nginx/conf.d/sb-sub.conf"
    if [ "${SUB_ENABLED:-1}" != "1" ]; then
        rm -f "$conf" 2>/dev/null || true
        return 0
    fi
    mkdir -p /etc/nginx/conf.d 2>/dev/null || true
    cat > "$conf" << EOF
server {
    listen ${SUB_PORT};
    listen [::]:${SUB_PORT};
    server_name _;

    location = /s/${SUB_TOKEN} {
        default_type text/plain;
        charset utf-8;
        alias ${work_dir}/sub.txt;
        add_header Cache-Control "no-store";
        add_header Access-Control-Allow-Origin *;
    }
    location = /s/${SUB_TOKEN}/raw {
        default_type text/plain;
        charset utf-8;
        alias ${work_dir}/url.txt;
        add_header Cache-Control "no-store";
        add_header Access-Control-Allow-Origin *;
    }
    location / { return 404; }
}
EOF
}

# 打印订阅链接（独立 SUB_PORT + Argo 域名）
print_sub_urls() {
    ensure_sub_token
    local ip domain argo_port host_for_url
    ip=$(get_realip 2>/dev/null || echo "服务器IP")
    host_for_url="$ip"
    if echo "$ip" | grep -q '^\[.*\]$'; then
        host_for_url="$ip"
    elif echo "$ip" | grep -q ':'; then
        host_for_url="[$ip]"
    fi

    argo_port="${ARGO_PORT:-}"
    if [ -z "$argo_port" ] && [ -f "${work_dir}/argo_fixed.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/argo_fixed.conf" 2>/dev/null || true
        argo_port="${ARGO_PORT:-}"
    fi
    if [ -z "$argo_port" ] && [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
        argo_port=$(grep -oE 'listen[[:space:]]+[0-9]+' /etc/nginx/conf.d/argo-ws.conf 2>/dev/null | head -1 | awk '{print $2}')
    fi
    argo_port="${argo_port:-8001}"

    domain=""
    if [ -f "${work_dir}/argo_fixed.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/argo_fixed.conf" 2>/dev/null || true
        [ "${ARGO_USE_FIXED:-0}" = "1" ] && [ -n "${ARGO_DOMAIN:-}" ] && domain="$ARGO_DOMAIN"
    fi
    if [ -z "$domain" ] && [ -f "${work_dir}/argo.log" ]; then
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -z "$domain" ] && domain=$(grep -oE '[[:alnum:]+.-]+\.trycloudflare\.com' "${work_dir}/argo.log" 2>/dev/null | head -1)
    fi

    echo ""
    green "=== 订阅链接（客户端直接导入） ==="
    if [ "${SUB_ENABLED:-1}" != "1" ]; then
        red "节点订阅当前已关闭（主菜单 7 → 开启节点订阅）"
        yellow "本地文件仍可用: ${work_dir}/sub.txt  |  ${work_dir}/url.txt"
        echo ""
        return 0
    fi
    yellow "令牌固定，改节点后无需换链接；勿泄露。订阅端口: ${SUB_PORT}"
    green "Base64 订阅(推荐·直连端口):"
    purple "  http://${host_for_url}:${SUB_PORT}/s/${SUB_TOKEN}"
    green "明文节点列表:"
    purple "  http://${host_for_url}:${SUB_PORT}/s/${SUB_TOKEN}/raw"
    if [ -n "$domain" ] && [ "$domain" != "未获取到域名" ]; then
        green "Argo/HTTPS 订阅(推荐外网):"
        purple "  https://${domain}/s/${SUB_TOKEN}"
        green "Argo 明文节点:"
        purple "  https://${domain}/s/${SUB_TOKEN}/raw"
    else
        yellow "Argo 域名未就绪时，仍可用上方直连端口订阅"
        green "备用(经 Argo 入口端口 ${argo_port}):"
        purple "  http://${host_for_url}:${argo_port}/s/${SUB_TOKEN}"
    fi
    yellow "本地文件: ${work_dir}/sub.txt  |  ${work_dir}/url.txt"
    echo ""
}

# 处理防火墙
