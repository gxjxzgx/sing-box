# ---------- Argo 配置辅助（统一入口，避免多处重复写 conf / 服务单元）----------
# 架构固定：cloudflared → Nginx(ARGO_PORT) → 三个本机 WS 端口

# 保存固定隧道配置（Token 用 printf %q 转义，避免含引号时 source 失败）
save_argo_fixed_conf() {
    mkdir -p "${work_dir}"
    {
        echo "ARGO_USE_FIXED=1"
        printf 'ARGO_DOMAIN=%q\n' "${ARGO_DOMAIN}"
        printf 'ARGO_TOKEN=%q\n' "${ARGO_TOKEN}"
        printf 'ARGO_PORT=%q\n' "${ARGO_PORT}"
    } > "${work_dir}/argo_fixed.conf"
    chmod 600 "${work_dir}/argo_fixed.conf"
}

# 清除固定隧道配置（切回临时隧道时调用）
clear_argo_fixed_conf() {
    ARGO_USE_FIXED=0
    ARGO_DOMAIN=""
    ARGO_TOKEN=""
    export ARGO_USE_FIXED ARGO_DOMAIN ARGO_TOKEN
    rm -f "${work_dir}/argo_fixed.conf" "${work_dir}/tunnel.json" "${work_dir}/tunnel.yml" 2>/dev/null || true
}

# 加载已保存的固定隧道配置（若存在）
load_argo_fixed_conf() {
    if [ -f "${work_dir}/argo_fixed.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/argo_fixed.conf" 2>/dev/null || true
    fi
    ARGO_USE_FIXED="${ARGO_USE_FIXED:-0}"
    ARGO_PORT="${ARGO_PORT:-8001}"
}

# 根据当前 ARGO_USE_FIXED / ARGO_TOKEN 生成 argo 启动命令
# 输出：全局变量 _ARGO_EXEC_CMD（始终指向 Nginx 入口 ARGO_PORT）
_prepare_argo_exec() {
    load_argo_fixed_conf

    if [ "$ARGO_USE_FIXED" = "1" ] && [ -n "${ARGO_TOKEN:-}" ]; then
        if echo "$ARGO_TOKEN" | grep -q 'TunnelSecret'; then
            echo "$ARGO_TOKEN" > "${work_dir}/tunnel.json"
            local tunnel_id
            tunnel_id=$(echo "$ARGO_TOKEN" | grep -o '"TunnelID":"[^"]*"' | head -1 | cut -d'"' -f4)
            [ -z "$tunnel_id" ] && tunnel_id=$(cut -d\" -f12 <<< "$ARGO_TOKEN" 2>/dev/null || true)
            if [ -z "$tunnel_id" ]; then
                yellow "无法从 JSON 中解析 TunnelID，已回退为临时隧道"
                clear_argo_fixed_conf
                _ARGO_EXEC_CMD="/etc/sing-box/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
            else
                cat > "${work_dir}/tunnel.yml" << YMLEOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
YMLEOF
                _ARGO_EXEC_CMD="/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run"
                green "Argo 服务将使用固定隧道 (JSON) → ${ARGO_DOMAIN} → Nginx:${ARGO_PORT}"
            fi
        else
            local safe_token
            safe_token=$(printf '%s' "$ARGO_TOKEN" | sed "s/'/'\\\\''/g")
            _ARGO_EXEC_CMD="/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token '${safe_token}'"
            green "Argo 服务将使用固定隧道 (Token) → ${ARGO_DOMAIN:-未指定域名} → Nginx:${ARGO_PORT}"
        fi
    else
        if [ "$ARGO_USE_FIXED" = "1" ]; then
            yellow "固定隧道配置不完整，已回退为临时隧道"
            clear_argo_fixed_conf
        fi
        _ARGO_EXEC_CMD="/etc/sing-box/argo tunnel --url http://localhost:${ARGO_PORT} --no-autoupdate --edge-ip-version auto --protocol http2"
        green "Argo 服务将使用临时隧道 → Nginx:${ARGO_PORT}"
    fi
}

# 写入 argo 启动脚本（避免服务单元中嵌套引号问题），再重写服务单元
rewrite_argo_service() {
    _prepare_argo_exec
    # 启动脚本：单一入口，systemd/openrc 均调用此文件
    cat > "${work_dir}/argo-start.sh" << 'STARTEOF'
#!/bin/sh
exec >> /etc/sing-box/argo.log 2>&1
STARTEOF
    # 将实际命令追加（不经过 shell 二次解析服务单元）
    printf '%s\n' "exec ${_ARGO_EXEC_CMD}" >> "${work_dir}/argo-start.sh"
    chmod +x "${work_dir}/argo-start.sh"

    if command_exists rc-service 2>/dev/null; then
        cat > /etc/init.d/argo << 'EOF'
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="/etc/sing-box/argo-start.sh"
command_background=true
pidfile="/var/run/argo.pid"
EOF
        chmod +x /etc/init.d/argo
        rc-update add argo default >/dev/null 2>&1 || true
    else
        cat > /etc/systemd/system/argo.service << 'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo-start.sh
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable argo >/dev/null 2>&1 || true
    fi
}

# debian/ubuntu/centos 守护进程
main_systemd_services() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    rewrite_argo_service
    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd
        systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    systemctl enable argo
    systemctl start argo
}

# 适配alpine 守护进程
alpine_openrc_services() {
    # 使用与原版兼容的 OpenRC 写法（Alpine 通用，不依赖 supervise-daemon）
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"

depend() {
    need net
}

start_pre() {
    # 清理陈旧 pid，避免「already started」但进程已死
    if [ -f "$pidfile" ]; then
        oldpid=$(cat "$pidfile" 2>/dev/null)
        if [ -n "$oldpid" ] && ! kill -0 "$oldpid" 2>/dev/null; then
            rm -f "$pidfile"
        fi
    fi
    if [ ! -x /etc/sing-box/sing-box ]; then
        eerror "找不到 /etc/sing-box/sing-box"
        return 1
    fi
}
EOF

    rewrite_argo_service
    chmod +x /etc/init.d/sing-box
    # 确保 argo init 可执行
    [ -f /etc/init.d/argo ] && chmod +x /etc/init.d/argo
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-update add argo default >/dev/null 2>&1 || true
}

# 生成节点链接并写入 url.txt / sub.txt，并打印 HTTP 订阅地址
