# =========================
# Telegram 通知模块
# =========================
tg_conf_file="${work_dir}/tg.conf"

load_tg_config() {
    # 优先配置文件，未设置时再读取环境变量 BOT_TOKEN / CHAT_ID
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_ENABLED=""
    if [ -f "$tg_conf_file" ]; then
        # shellcheck source=/dev/null
        source "$tg_conf_file" 2>/dev/null || true
    fi
    # 配置文件未设置的项，回退到环境变量
    [ -z "$TG_BOT_TOKEN" ] && [ -n "${BOT_TOKEN:-}" ] && TG_BOT_TOKEN="$BOT_TOKEN"
    [ -z "$TG_CHAT_ID" ] && [ -n "${CHAT_ID:-}" ] && TG_CHAT_ID="$CHAT_ID"
    # TG_ENABLED：配置文件已写则尊重；未写且 Token+ChatID 齐全则默认启用
    if [ -z "$TG_ENABLED" ]; then
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            TG_ENABLED="1"
        else
            TG_ENABLED="0"
        fi
    fi
}

save_tg_config() {
    mkdir -p "$(dirname "$tg_conf_file")"
    cat > "$tg_conf_file" << TGEOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
TG_ENABLED="${TG_ENABLED}"
TGEOF
    chmod 600 "$tg_conf_file"
}

# HTML 转义（Telegram parse_mode=HTML）
tg_html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# 发送 Telegram 文本消息
# 用法: send_tg_msg "内容" [html]
# 第二参数为 html 时启用 parse_mode=HTML（用于 <pre> 代码块，客户端可一键复制）
send_tg_msg() {
    local msg="$1"
    local mode="${2:-}"
    load_tg_config
    if [ "$TG_ENABLED" != "1" ] || [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi
    # Telegram 消息最长约 4096，超长截断
    if [ ${#msg} -gt 4000 ]; then
        msg="${msg:0:4000}...(已截断)"
    fi
    if [ "$mode" = "html" ]; then
        curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${msg}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "disable_web_page_preview=true" \
            >/dev/null 2>&1
    else
        curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${msg}" \
            --data-urlencode "disable_web_page_preview=true" \
            >/dev/null 2>&1
    fi
}

# 获取服务纯文本状态（无颜色码，供 TG 推送使用）
get_plain_status() {
    local service_name="$1"
    local service_file="$2"
    if [ "$service_name" = "nginx" ]; then
        command_exists nginx || { echo "not installed"; return 2; }
    else
        [ -z "$service_file" ] || [ ! -f "$service_file" ] && { echo "not installed"; return 2; }
    fi
    if command_exists apk; then
        rc-service "${service_name}" status 2>/dev/null | grep -q "started" && echo "running" || echo "not running"
    else
        systemctl is-active "${service_name}" 2>/dev/null | grep -q "^active$" && echo "running" || echo "not running"
    fi
}

# 发送当前节点信息到 Telegram（含 sing-box / Argo / Nginx 状态）
send_tg_nodes() {
    load_tg_config
    if [ "$TG_ENABLED" != "1" ] || [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi
    if [ ! -f "$client_dir" ]; then
        return 1
    fi

    local server_ip hostname_info node_text node_escaped
    server_ip=$(get_realip 2>/dev/null || echo "unknown")
    hostname_info=$(hostname 2>/dev/null || echo "server")
    node_text=$(cat "$client_dir" 2>/dev/null)
    node_escaped=$(tg_html_escape "$node_text")

    local sb_status argo_status nginx_status
    sb_status=$(get_plain_status "sing-box" "${work_dir}/${server_name}")
    argo_status=$(get_plain_status "argo" "${work_dir}/argo")
    nginx_status=$(get_plain_status "nginx" "$(command -v nginx 2>/dev/null)")

    # 节点列表用 <pre> 代码块发送，Telegram 客户端可显示「复制代码」
    local msg
    msg="📡 <b>sing-box 节点通知</b>
主机: $(tg_html_escape "$hostname_info")
IP: $(tg_html_escape "$server_ip")
时间: $(date '+%Y-%m-%d %H:%M:%S')

—— 服务状态 ——
sing-box: ${sb_status}
Argo: ${argo_status}
Nginx: ${nginx_status}

—— 节点列表 ——
<pre>${node_escaped}</pre>"

    send_tg_msg "$msg" "html" && green "节点信息已推送到 Telegram" || yellow "Telegram 推送失败（请检查 Token/ChatID）"
}

# 配置 Telegram
setup_telegram() {
    load_tg_config
    clear
    echo ""
    green "=== Telegram 通知设置 ===\n"
    if [ "$TG_ENABLED" = "1" ] && [ -n "$TG_BOT_TOKEN" ]; then
        green "当前状态: ${green}已启用${re}"
        yellow "Bot Token: ${TG_BOT_TOKEN:0:10}********"
        yellow "Chat ID: ${TG_CHAT_ID}"
    else
        yellow "当前状态: 未启用"
    fi
    echo ""
    skyblue "----------------"
    green "1. 配置/修改 Bot Token 与 Chat ID"
    skyblue "----------------"
    green "2. 发送测试消息"
    skyblue "----------------"
    green "3. 推送当前节点信息"
    skyblue "----------------"
    green "4. 开启通知"
    skyblue "----------------"
    red   "5. 关闭通知"
    skyblue "----------------"
    green "6. 安装/更新离线监控 (可自定义间隔)"
    skyblue "----------------"
    red   "7. 卸载离线监控"
    skyblue "----------------"
    purple "0. 返回主菜单"
    skyblue "----------------"
    reading "请输入选择: " tg_choice
    case "$tg_choice" in
        1)
            yellow "配置优先写入 ${work_dir}/tg.conf；未配置时回退读取环境变量 BOT_TOKEN / CHAT_ID"
            reading "请输入 Telegram Bot Token (回车使用环境变量 BOT_TOKEN): " input_token
            reading "请输入 Telegram Chat ID (回车使用环境变量 CHAT_ID): " input_chat
            [ -z "$input_token" ] && input_token="${BOT_TOKEN:-}"
            [ -z "$input_chat" ] && input_chat="${CHAT_ID:-}"
            if [ -n "$input_token" ] && [ -n "$input_chat" ]; then
                TG_BOT_TOKEN="$input_token"
                TG_CHAT_ID="$input_chat"
                TG_ENABLED="1"
                save_tg_config
                green "已保存到配置文件并启用 Telegram 通知"
                send_tg_msg "✅ sing-box Telegram 通知已配置成功
主机: $(hostname)
时间: $(date '+%Y-%m-%d %H:%M:%S')"
            else
                red "Token 或 Chat ID 不能为空（可先 export BOT_TOKEN / CHAT_ID，或写入配置文件）"
            fi
            ;;
        2)
            load_tg_config
            if send_tg_msg "🔔 sing-box 测试消息
主机: $(hostname)
时间: $(date '+%Y-%m-%d %H:%M:%S')"; then
                green "测试消息已发送，请检查 Telegram"
            else
                red "发送失败，请先完成配置并开启通知"
            fi
            ;;
        3)
            send_tg_nodes
            ;;
        4)
            load_tg_config
            if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
                red "请先配置 Bot Token 与 Chat ID"
            else
                TG_ENABLED="1"
                save_tg_config
                green "已开启 Telegram 通知"
            fi
            ;;
        5)
            TG_ENABLED="0"
            save_tg_config
            yellow "已关闭 Telegram 通知"
            ;;
        6)
            install_tg_monitor
            ;;
        7)
            uninstall_tg_monitor
            ;;
        0) return ;;
        *) red "无效选项" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m'
    setup_telegram
}

# 确保系统有 crontab（Alpine 默认可能没有，需装 dcron）
ensure_crontab() {
    if command_exists crontab; then
        return 0
    fi
    yellow "未找到 crontab，尝试安装 cron 组件..."
    if command_exists apk; then
        # Alpine: dcron 提供 crontab；busybox 的 crond 不一定带 crontab 命令
        apk add --no-cache dcron 2>/dev/null || apk add --no-cache cronie 2>/dev/null || true
        if command_exists rc-service; then
            rc-update add dcron default 2>/dev/null || rc-update add crond default 2>/dev/null || true
            rc-service dcron start 2>/dev/null || rc-service crond start 2>/dev/null || true
        fi
    elif command_exists apt; then
        DEBIAN_FRONTEND=noninteractive apt install -y cron 2>/dev/null || true
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
    elif command_exists dnf; then
        dnf install -y cronie 2>/dev/null || true
        systemctl enable crond 2>/dev/null || true
        systemctl start crond 2>/dev/null || true
    elif command_exists yum; then
        yum install -y cronie 2>/dev/null || true
        systemctl enable crond 2>/dev/null || true
        systemctl start crond 2>/dev/null || true
    fi
    if command_exists crontab; then
        green "crontab 已就绪"
        return 0
    fi
    red "无法安装 crontab（Alpine 可手动: apk add dcron && rc-service dcron start）"
    return 1
}

# 离线监控脚本（供 cron 调用）
install_tg_monitor() {
    load_tg_config
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        red "请先配置 Bot Token 与 Chat ID"
        return 1
    fi
    TG_ENABLED="1"
    save_tg_config

    if ! ensure_crontab; then
        return 1
    fi

    reading "请输入检测间隔(分钟，回车默认2，最小1): " mon_min
    [ -z "$mon_min" ] && mon_min=2
    if ! [[ "$mon_min" =~ ^[0-9]+$ ]] || [ "$mon_min" -lt 1 ]; then
        mon_min=2
    fi
    green "离线检测间隔: ${purple}每 ${mon_min} 分钟${re}"

    cat > "${work_dir}/tg_monitor.sh" << 'MONEOF'
#!/bin/bash
work_dir="/etc/sing-box"
tg_conf_file="${work_dir}/tg.conf"
[ -f "$tg_conf_file" ] || exit 0
# shellcheck source=/dev/null
source "$tg_conf_file" 2>/dev/null || exit 0
[ "$TG_ENABLED" = "1" ] || exit 0
[ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || exit 0

send_msg() {
    curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=$1" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1
}

is_active() {
    local name="$1"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$name" && return 0
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$name" status 2>/dev/null | grep -q started && return 0
    fi
    return 1
}

host=$(hostname 2>/dev/null || echo server)
now=$(date '+%Y-%m-%d %H:%M:%S')
state_file="${work_dir}/tg_monitor.state"
prev_sb=1; prev_argo=1; prev_nginx=1
[ -f "$state_file" ] && . "$state_file" 2>/dev/null || true

check_svc() {
    local name="$1" prev="$2" var="$3"
    local cur=0
    is_active "$name" && cur=1
    if [ "$cur" -eq 0 ] && [ "$prev" -eq 1 ]; then
        send_msg "⚠️ 服务离线提醒
主机: ${host}
服务: ${name}
状态: 已停止/异常
时间: ${now}"
    elif [ "$cur" -eq 1 ] && [ "$prev" -eq 0 ]; then
        send_msg "✅ 服务恢复通知
主机: ${host}
服务: ${name}
状态: 已恢复运行
时间: ${now}"
    fi
    eval "$var=$cur"
}

check_svc sing-box "$prev_sb" cur_sb
check_svc argo "$prev_argo" cur_argo
check_svc nginx "$prev_nginx" cur_nginx

cat > "$state_file" << SEOF
prev_sb=${cur_sb:-1}
prev_argo=${cur_argo:-1}
prev_nginx=${cur_nginx:-1}
SEOF
MONEOF
    chmod +x "${work_dir}/tg_monitor.sh"

    # 写入 crontab（失败则明确报错，不假装成功）
    local cron_line="*/${mon_min} * * * * ${work_dir}/tg_monitor.sh >/dev/null 2>&1"
    if (crontab -l 2>/dev/null | grep -v "tg_monitor.sh"; echo "$cron_line") | crontab - 2>/dev/null; then
        green "离线监控已安装（每 ${mon_min} 分钟检测 sing-box / argo / nginx）"
        yellow "状态变化时会推送离线/恢复通知到 Telegram"
        # 确认 cron 守护进程在跑
        if command_exists rc-service; then
            rc-service dcron status 2>/dev/null | grep -q started || \
            rc-service crond status 2>/dev/null | grep -q started || \
            yellow "提示: 请确认 dcron/crond 服务已启动（rc-service dcron start）"
        elif command_exists systemctl; then
            systemctl is-active --quiet cron || systemctl is-active --quiet crond || \
            yellow "提示: 请确认 cron/crond 服务已启动"
        fi
    else
        red "写入 crontab 失败，离线监控未生效"
        return 1
    fi
}

uninstall_tg_monitor() {
    if command_exists crontab; then
        crontab -l 2>/dev/null | grep -v "tg_monitor.sh" | crontab - 2>/dev/null || true
    fi
    rm -f "${work_dir}/tg_monitor.sh" "${work_dir}/tg_monitor.state"
    green "离线监控已卸载"
}


# 适配alpine
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 非交互静默安装（-i 参数；仍走官方优先下载与 IPv4 逻辑）
auto_install() {
    local force_install="${1:-0}"
    if [ -x "${work_dir}/sing-box" ] && [ "$force_install" != "1" ]; then
        yellow "sing-box 已经安装。"
        yellow "如需重装请先执行: sb -u  或使用: sb -i --force"
        exit 1
    fi
    if [ -x "${work_dir}/sing-box" ] && [ "$force_install" = "1" ]; then
        yellow "检测到已安装，--force 将先卸载再安装..."
        auto_uninstall
    fi

    green "开始无交互式安装 sing-box..."
    manage_packages install nginx jq tar openssl lsof coreutils
    install_singbox

    if command_exists systemctl; then
        main_systemd_services
    elif command_exists rc-update; then
        alpine_openrc_services
        change_hosts
        rc-service sing-box restart
        rc-service argo restart
    else
        red "不支持的 init 系统，安装中止。"
        exit 1
    fi

    # 给 cloudflared 更多启动时间，再由 get_info 内轮询域名
    sleep 3
    get_info
    add_nginx_conf
    create_shortcut
    if command_exists nginx; then
        if restart_nginx; then
            green "Nginx 已重启完成"
        else
            red "Nginx 重启未成功，请执行: nginx -t && systemctl status nginx.service"
        fi
    fi
    green "\nsing-box 安装完成\n"
}

# 无交互静默卸载（-u 参数），含 nginx
auto_uninstall() {
    green "开始无交互式卸载sing-box..."

    if command_exists rc-service; then
        rc-service sing-box stop  > /dev/null 2>&1
        rc-service argo stop      > /dev/null 2>&1
        rc-update del sing-box default > /dev/null 2>&1
        rc-update del argo default     > /dev/null 2>&1
        rm -f /etc/init.d/sing-box /etc/init.d/argo
    elif command_exists systemctl; then
        systemctl stop    sing-box > /dev/null 2>&1
        systemctl stop    argo     > /dev/null 2>&1
        systemctl disable sing-box > /dev/null 2>&1
        systemctl disable argo     > /dev/null 2>&1
        systemctl daemon-reload    > /dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service \
              /etc/systemd/system/argo.service
    fi

    rm -rf "${work_dir}"
    rm -f /usr/bin/sb

    if command_exists nginx; then
        if command_exists rc-service; then
            rc-service nginx stop   > /dev/null 2>&1
            rc-update del nginx default > /dev/null 2>&1
        elif command_exists systemctl; then
            systemctl stop    nginx > /dev/null 2>&1
            systemctl disable nginx > /dev/null 2>&1
        fi
        rm -f /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/argo-ws.conf /etc/nginx/conf.d/sb-sub.conf
        manage_packages uninstall nginx
        [ -f /etc/nginx/nginx.conf.bak.sb ] && \
            mv /etc/nginx/nginx.conf.bak.sb /etc/nginx/nginx.conf > /dev/null 2>&1
    else
        yellow "nginx 未安装，跳过卸载 nginx。"
    fi

    green "\nsing-box 及 nginx 已完全卸载!\n"
}

# 变更配置
