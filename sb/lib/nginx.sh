# ---------- [v2.6.0] nginx.conf / mime.types 备份只保留最近一份 ----------
_prune_nginx_backup() {
    local pattern="$1"   # 例如 /etc/nginx/nginx.conf.bak.sb.*
    # shellcheck disable=SC2086
    ls -1t ${pattern} 2>/dev/null | tail -n +2 | xargs -r rm -f
}

# Nginx：Argo 隧道路径分流 + /s/<token> 订阅；独立订阅见 sb-sub.conf
add_nginx_conf() {
    if ! command_exists nginx; then
        red "nginx 未安装，无法配置 Argo 隧道路径分流"
        return 1
    fi

    # 停止旧进程，避免占用端口
    manage_service "nginx" "stop" > /dev/null 2>&1
    pkill -x nginx > /dev/null 2>&1 || pkill nginx > /dev/null 2>&1
    sleep 0.5

    mkdir -p /etc/nginx/conf.d /var/log/nginx /run /var/lib/nginx /var/cache/nginx

    # 禁用可能冲突的默认站点
    if [ -L /etc/nginx/sites-enabled/default ]; then
        rm -f /etc/nginx/sites-enabled/default
        yellow "已禁用 sites-enabled/default"
    fi
    rm -f /etc/nginx/conf.d/sing-box.conf

    local vmess_ws_port=$((ARGO_PORT + 10))
    local vless_ws_port=$((ARGO_PORT + 11))
    local trojan_ws_port=$((ARGO_PORT + 12))
    local nginx_user
    nginx_user=$(_resolve_nginx_user)

    # ---------- 1. 始终覆盖写入已知可用的 mime.types（不信任系统残留文件）----------
    # 历史问题：系统 mime.types 可能缺失、截断、缺 }，导致 nginx -t 失败
    if [ -f /etc/nginx/mime.types ]; then
        cp -f /etc/nginx/mime.types "/etc/nginx/mime.types.bak.sb.$(date +%s)" 2>/dev/null || true
        # [v2.6.0] 只保留最近一份备份，避免反复重装后堆积
        _prune_nginx_backup "/etc/nginx/mime.types.bak.sb.*"
    fi
    cat > /etc/nginx/mime.types << 'MIMEOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/javascript                js;
    application/json                      json;
    application/octet-stream              bin exe dmg;
    application/pdf                       pdf;
    application/xhtml+xml                 xhtml;
    application/xml                       xsl;
    application/zip                       zip;
    image/png                             png;
    image/svg+xml                         svg svgz;
    image/webp                            webp;
    image/x-icon                          ico;
    text/plain                            txt;
    text/event-stream                     event-stream;
}
MIMEOF

    # ---------- 2. 始终覆盖写入完整可用的主配置（不依赖系统残缺 include）----------
    if [ -f /etc/nginx/nginx.conf ]; then
        cp -f /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.sb 2>/dev/null || true
    fi
    cat > /etc/nginx/nginx.conf << EOF
user ${nginx_user};
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    # 仅加载 conf.d，避免 sites-enabled 等冲突
    include /etc/nginx/conf.d/*.conf;
}
EOF

    # ---------- 3. Argo 路径分流 + HTTP 订阅 ----------
    ensure_sub_token
    local sub_tok="${SUB_TOKEN}"
    cat > /etc/nginx/conf.d/argo-ws.conf << EOF
server {
    listen ${ARGO_PORT};
    listen [::]:${ARGO_PORT};
    server_name _;

    location /vmess-argo {
        proxy_pass http://127.0.0.1:${vmess_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /vless-argo {
        proxy_pass http://127.0.0.1:${vless_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /trojan-argo {
        proxy_pass http://127.0.0.1:${trojan_ws_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # Base64 订阅（客户端导入）
    location = /s/${sub_tok} {
        default_type text/plain;
        charset utf-8;
        alias ${work_dir}/sub.txt;
        add_header Cache-Control "no-store";
        add_header Access-Control-Allow-Origin *;
    }
    # 明文节点列表
    location = /s/${sub_tok}/raw {
        default_type text/plain;
        charset utf-8;
        alias ${work_dir}/url.txt;
        add_header Cache-Control "no-store";
        add_header Access-Control-Allow-Origin *;
    }

    location / { return 404; }
}
EOF

    # 独立订阅端口配置
    write_sub_nginx_conf

    # ---------- 4. 检测并启动 ----------
    local nginx_test_out nginx_test_rc
    nginx_test_out=$(nginx -t 2>&1)
    nginx_test_rc=$?

    if [ $nginx_test_rc -ne 0 ]; then
        yellow "nginx -t 首次失败，尝试重装/修复 nginx 包依赖后重试..."
        echo "$nginx_test_out" | while IFS= read -r line; do red "  $line"; done
        # 尝试用包管理器补全 nginx 公共文件（不卸载配置）
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall nginx-common nginx 2>/dev/null || \
            DEBIAN_FRONTEND=noninteractive apt-get install -y nginx 2>/dev/null || true
        elif command_exists dnf; then
            dnf reinstall -y nginx 2>/dev/null || dnf install -y nginx 2>/dev/null || true
        elif command_exists yum; then
            yum reinstall -y nginx 2>/dev/null || yum install -y nginx 2>/dev/null || true
        elif command_exists apk; then
            apk add --no-cache nginx 2>/dev/null || true
        fi
        # 包重装可能覆盖我们的配置，再次写入
        cat > /etc/nginx/mime.types << 'MIMEOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/javascript                js;
    application/json                      json;
    application/octet-stream              bin exe dmg;
    application/pdf                       pdf;
    image/png                             png;
    image/svg+xml                         svg svgz;
    image/webp                            webp;
    image/x-icon                          ico;
    text/plain                            txt;
}
MIMEOF
        cat > /etc/nginx/nginx.conf << EOF
user ${nginx_user};
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    include /etc/nginx/conf.d/*.conf;
}
EOF
        # 确保 argo-ws.conf 仍在
        [ -f /etc/nginx/conf.d/argo-ws.conf ] || true
        nginx_test_out=$(nginx -t 2>&1)
        nginx_test_rc=$?
    fi

    if [ $nginx_test_rc -ne 0 ]; then
        red "nginx 配置检测仍失败："
        echo "$nginx_test_out" | while IFS= read -r line; do red "  $line"; done
        red "请手动执行并反馈完整输出: nginx -t ; ls -la /etc/nginx/ ; head -20 /etc/nginx/nginx.conf"
        return 1
    fi

    green "nginx -t 检测通过"

    if _nginx_start; then
        return 0
    fi
    red "nginx 启动失败。请执行: nginx -t ; ss -lntp | grep -E \":${ARGO_PORT:-8001} \" ; rc-service nginx status 2>/dev/null || systemctl status nginx"
    return 1
}

_resolve_nginx_user() {
    local u
    for u in nginx www-data www nobody; do
        if id "$u" >/dev/null 2>&1; then
            printf '%s' "$u"
            return 0
        fi
    done
    printf '%s' "root"
}

# 兼容旧调用名（其它位置可能仍引用）
_write_safe_mime_types() {
    cat > /etc/nginx/mime.types << 'MIMEOF'
types {
    text/html                             html htm shtml;
    text/css                              css;
    text/xml                              xml;
    image/gif                             gif;
    image/jpeg                            jpeg jpg;
    application/javascript                js;
    application/json                      json;
    application/octet-stream              bin exe dmg;
    application/pdf                       pdf;
    image/png                             png;
    image/svg+xml                         svg svgz;
    image/webp                            webp;
    image/x-icon                          ico;
    text/plain                            txt;
}
MIMEOF
}
_ensure_nginx_ready() {
    mkdir -p /etc/nginx/conf.d /var/log/nginx /run
    _write_safe_mime_types
}
_fix_nginx_user_directive() { :; }
_write_minimal_nginx_conf() { :; }

# 从已安装配置中获取UUID
# [优化] 原实现按 .type == "vless" 模糊匹配，若同时存在
# vless-reality / vless-ws(argo) / vless-ws-direct 三个 inbound，
# jq 会把三条 UUID 都选出来，最终靠 head -1 只取数组里排在前面的一条，
# 一旦某个 inbound 的 UUID 被单独改过就会取错。
# 这里改为按明确的 tag 优先级依次尝试，取不到才降级到按 type 兜底。
get_current_uuid() {
    local inbounds_file="${conf_dir}/inbounds.json"
    [ -f "$inbounds_file" ] || return 0
    local uuid tag
    for tag in vless-reality vmess-ws vless-ws vless-ws-direct trojan-ws; do
        uuid=$(jq -r --arg tag "$tag" \
            '.inbounds[] | select(.tag == $tag) | .users[0].uuid // .users[0].password // empty' \
            "$inbounds_file" 2>/dev/null | head -1)
        [ -n "$uuid" ] && { echo "$uuid"; return 0; }
    done
    # 兜底：按 type 模糊匹配（旧逻辑，仅在上面全部找不到时使用）
    uuid=$(jq -r '.inbounds[] | select(.type == "vless") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
    [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "vmess") | .users[0].uuid // empty' "$inbounds_file" 2>/dev/null | head -1)
    [ -z "$uuid" ] && uuid=$(jq -r '.inbounds[] | select(.type == "hysteria2") | .users[0].password // empty' "$inbounds_file" 2>/dev/null | head -1)
    echo "$uuid"
}

# 通用服务管理函数
# 通用服务管理函数（已修复状态检测 + 强制清理残留进程）

# ---------- Nginx 启停（Alpine OpenRC / systemd / 二进制统一）----------
_nginx_is_running() {
    # 以 master 进程为准，避免 pgrep 路径误匹配
    pgrep -f 'nginx: master process' >/dev/null 2>&1 && return 0
    pgrep -x nginx >/dev/null 2>&1 && return 0
    return 1
}

_nginx_stop_all() {
    # 先走服务管理器，再清理可能由「nginx 二进制直启」留下的进程
    if command_exists rc-service; then
        rc-service nginx stop >/dev/null 2>&1 || true
    elif command_exists systemctl; then
        systemctl stop nginx >/dev/null 2>&1 || true
    fi
    if command_exists nginx; then
        nginx -s stop >/dev/null 2>&1 || true
        nginx -s quit >/dev/null 2>&1 || true
    fi
    sleep 0.5
    if _nginx_is_running; then
        pkill -15 -f 'nginx: master process' 2>/dev/null || true
        pkill -15 -x nginx 2>/dev/null || true
        sleep 0.8
    fi
    if _nginx_is_running; then
        pkill -9 -f 'nginx: master process' 2>/dev/null || true
        pkill -9 -x nginx 2>/dev/null || true
        sleep 0.3
    fi
    # 不再用 return 码表示失败，由调用方检查
    return 0
}

_nginx_who_holds_port() {
    local p="${1:-}"
    [ -z "$p" ] && return 0
    if command_exists ss; then
        ss -lntp 2>/dev/null | grep -E ":${p}\\b" || true
    elif command_exists lsof; then
        lsof -i ":${p}" -sTCP:LISTEN 2>/dev/null || true
    fi
}

_nginx_start() {
    if ! command_exists nginx; then
        red "nginx 未安装"
        return 1
    fi
    if ! nginx -t >/dev/null 2>&1; then
        red "nginx -t 失败，拒绝启动"
        nginx -t
        return 1
    fi

    # 若已在跑且可响应，视为成功
    if _nginx_is_running; then
        if nginx -s reload >/dev/null 2>&1; then
            green "nginx 已在运行（已 reload）"
            return 0
        fi
        # reload 失败则彻底停掉再启
        _nginx_stop_all
    fi

    local port="${ARGO_PORT:-}"
    if [ -z "$port" ] && [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
        port=$(grep -oE 'listen[[:space:]]+[0-9]+' /etc/nginx/conf.d/argo-ws.conf 2>/dev/null | head -1 | awk '{print $2}')
    fi
    port="${port:-8001}"

    # 启动前确认端口空闲（排除将由本进程占用的情况：已无 nginx）
    if command_exists ss && ss -lntp 2>/dev/null | grep -qE ":${port}\\b"; then
        yellow "端口 ${port} 仍被占用，尝试释放 nginx 后重试..."
        _nginx_stop_all
        sleep 0.5
        if ss -lntp 2>/dev/null | grep -qE ":${port}\\b"; then
            red "端口 ${port} 仍被占用，占用进程如下："
            _nginx_who_holds_port "$port" | while IFS= read -r l; do red "  $l"; done
            return 1
        fi
    fi

    local started=0
    if command_exists rc-service; then
        # Alpine：优先 OpenRC，避免「二进制直启」与 rc-service 双实例抢端口
        rc-update add nginx default >/dev/null 2>&1 || true
        if rc-service nginx start >/tmp/sb-nginx-start.err 2>&1; then
            sleep 1
            if rc-service nginx status 2>/dev/null | grep -q started && _nginx_is_running; then
                started=1
                green "nginx 服务已启动 (OpenRC)"
            fi
        fi
    elif command_exists systemctl; then
        systemctl reset-failed nginx 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable nginx 2>/dev/null || true
        if systemctl start nginx >/tmp/sb-nginx-start.err 2>&1; then
            sleep 1
            if systemctl is-active --quiet nginx 2>/dev/null; then
                started=1
                green "nginx 服务已启动 (systemctl)"
            fi
        fi
    fi

    if [ "$started" -eq 0 ]; then
        # 回退二进制直启（仅当服务管理器不可用或失败且端口已空闲）
        _nginx_stop_all
        if nginx >/tmp/sb-nginx-bin.err 2>&1; then
            sleep 0.5
            if _nginx_is_running; then
                started=1
                green "nginx 已通过二进制直接启动"
            fi
        fi
        [ -s /tmp/sb-nginx-bin.err ] && grep -q . /tmp/sb-nginx-bin.err && \
            while IFS= read -r l; do [ -n "$l" ] && red "$l"; done < /tmp/sb-nginx-bin.err
    fi

    if [ "$started" -eq 1 ]; then
        return 0
    fi
    [ -s /tmp/sb-nginx-start.err ] && while IFS= read -r l; do [ -n "$l" ] && red "$l"; done < /tmp/sb-nginx-start.err
    return 1
}

manage_service() {
    local service_name="$1"
    local action="$2"

    if [ -z "$service_name" ] || [ -z "$action" ]; then
        red "缺少服务名或操作参数\n"
        return 1
    fi

    # 根据服务名确定检测文件
    local service_file=""
    case "$service_name" in
        "sing-box")
            service_file="${work_dir}/${server_name}"
            ;;
        "argo")
            service_file="${work_dir}/argo"
            ;;
        "nginx")
            service_file="$(command -v nginx 2>/dev/null)"
            ;;
        *)
            service_file=""
            ;;
    esac

    local status
    status=$(check_service "$service_name" "$service_file" 2>/dev/null)

    case "$action" in
        "start")
            if [[ "$status" == *"running"* ]]; then
                yellow "${service_name} 已在运行中\n"
                return 0
            fi
            if [[ "$status" == *"not installed"* ]]; then
                yellow "${service_name} 尚未安装！\n"
                return 1
            fi

            yellow "正在启动 ${service_name} 服务...\n"
            if [ "$service_name" = "nginx" ]; then
                if _nginx_start; then
                    return 0
                else
                    red "nginx 服务启动失败\n"
                    return 1
                fi
            fi
            if command_exists rc-service; then
                rc-service "$service_name" start
            elif command_exists systemctl; then
                systemctl reset-failed "$service_name" 2>/dev/null
                systemctl daemon-reload
                systemctl start "$service_name"
            fi

            sleep 1
            if [[ "$(check_service "$service_name" "$service_file" 2>/dev/null)" == *"running"* ]]; then
                green "${service_name} 服务已成功启动\n"
                return 0
            else
                red "${service_name} 服务启动失败\n"
                return 1
            fi
            ;;

        "stop")
            if [[ "$status" == *"not installed"* ]]; then
                yellow "${service_name} 尚未安装！\n"
                return 2
            fi
            if [[ "$status" == *"not running"* ]]; then
                yellow "${service_name} 当前未运行\n"
                return 1
            fi

            yellow "正在停止 ${service_name} 服务...\n"
            if [ "$service_name" = "nginx" ]; then
                _nginx_stop_all
                if _nginx_is_running; then
                    red "nginx 停止失败，仍有进程残留\n"
                    return 1
                fi
                green "nginx 服务已彻底停止\n"
                return 0
            fi

            if command_exists rc-service; then
                rc-service "$service_name" stop
            elif command_exists systemctl; then
                systemctl stop "$service_name"
            fi
            sleep 1

            local process_pattern=""
            case "$service_name" in
                "sing-box") process_pattern="${work_dir}/sing-box" ;;
                "argo")     process_pattern="${work_dir}/argo" ;;
            esac

            if [ -n "$process_pattern" ] && pgrep -f "$process_pattern" >/dev/null 2>&1; then
                yellow "检测到残留进程，正在强制终止...\n"
                pkill -15 -f "$process_pattern" 2>/dev/null
                sleep 1
                pkill -9 -f "$process_pattern" 2>/dev/null
                sleep 0.5
            fi

            if [ -n "$process_pattern" ] && pgrep -f "$process_pattern" >/dev/null 2>&1; then
                red "${service_name} 停止失败，仍有进程残留，请手动检查\n"
                return 1
            else
                green "${service_name} 服务已彻底停止\n"
                return 0
            fi
            ;;

        "restart")
            if [[ "$status" == *"not installed"* ]]; then
                yellow "${service_name} 尚未安装！\n"
                return 1
            fi

            yellow "正在重启 ${service_name} 服务...\n"
            if [ "$service_name" = "nginx" ]; then
                _nginx_stop_all
                sleep 0.5
                if _nginx_start; then
                    green "nginx 服务已成功重启\n"
                    return 0
                fi
                red "nginx 服务重启失败\n"
                yellow "请执行: nginx -t ; ss -lntp | head -30 ; rc-service nginx status 2>/dev/null || systemctl status nginx"
                return 1
            fi

            manage_service "$service_name" "stop" >/dev/null 2>&1
            sleep 1
            if command_exists rc-service; then
                rc-service "$service_name" start
            elif command_exists systemctl; then
                systemctl daemon-reload >/dev/null 2>&1
                systemctl start "$service_name" 2>/tmp/sb-svc-start.err
                if [ $? -ne 0 ] && [ -s /tmp/sb-svc-start.err ]; then
                    while IFS= read -r _eline; do
                        [ -n "$_eline" ] && red "$_eline"
                    done < /tmp/sb-svc-start.err
                fi
            fi
            sleep 1
            if [[ "$(check_service "$service_name" "$service_file" 2>/dev/null)" == *"running"* ]]; then
                green "${service_name} 服务已成功重启\n"
                return 0
            fi
            red "${service_name} 服务重启失败\n"
            return 1
            ;;

        *)
            red "无效的操作: $action\n"
            return 1
            ;;
    esac
}

start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop"; }
restart_singbox(){ manage_service "sing-box" "restart"; }
start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop"; }
restart_argo()   { manage_service "argo" "restart"; }
start_nginx()    { manage_service "nginx" "start"; }
restart_nginx()  { manage_service "nginx" "restart"; }

# 卸载 sing-box（交互式）
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    case "${choice}" in
        y|Y)
            yellow "正在卸载 sing-box"
            if command_exists rc-service; then
                rc-service sing-box stop; rc-service argo stop
                rm -f /etc/init.d/sing-box /etc/init.d/argo
                rc-update del sing-box default; rc-update del argo default
            else
                systemctl stop "${server_name}"; systemctl stop argo
                systemctl disable "${server_name}"; systemctl disable argo
                systemctl daemon-reload || true
            fi
            rm -rf "${work_dir}" || true
            rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
            rm -f /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/argo-ws.conf /etc/nginx/conf.d/sb-sub.conf

            reading "\n是否卸载 Nginx？${green}(卸载请输入 ${yellow}y${re} ${green}回车将跳过卸载Nginx) (y/n): ${re}" choice
            case "${choice}" in
                y|Y) manage_packages uninstall nginx ;;
                *)   yellow "取消卸载Nginx\n\n" ;;
            esac
            green "\nsing-box 卸载成功\n\n" && exit 0
            ;;
        *) purple "已取消卸载操作\n\n" ;;
    esac
}

# 创建快捷指令（优先运行本机已保存的脚本，避免 sb 拉到远程旧版）
create_shortcut() {
    # sb 始终从远程拉取执行（不保存、不优先本地副本）
    cat > "$work_dir/sb.sh" << 'EOF'
#!/usr/bin/env bash
REMOTE_URL="${SB_REMOTE_URL:-https://raw.githubusercontent.com/gxjxzgx/sing-box/refs/heads/main/sb.sh}"
exec bash <(curl -fsSL "$REMOTE_URL") "$@"
EOF
    chmod +x "$work_dir/sb.sh"
    ln -sf "$work_dir/sb.sh" /usr/bin/sb
    if [ -L /usr/bin/sb ] || [ -x /usr/bin/sb ]; then
        green "\n快捷指令 sb 创建成功（始终远程拉取: ${SB_REMOTE_URL:-https://raw.githubusercontent.com/gxjxzgx/sing-box/refs/heads/main/sb.sh}）\n"
    else
        red "\n快捷指令创建失败\n"
    fi
}


