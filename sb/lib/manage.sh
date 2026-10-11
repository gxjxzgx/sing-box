manage_singbox() {
    while true; do
        local singbox_status
        singbox_status=$(check_singbox 2>/dev/null)
        clear
        echo ""
        green "=== sing-box 管理 ===\n"
        green "当前状态: ${singbox_status}\n"
        green "1. 启动 sing-box 服务"
        skyblue "----------------"
        green "2. 停止 sing-box 服务"
        skyblue "----------------"
        green "3. 重启 sing-box 服务"
        skyblue "----------------"
        purple "0. 返回主菜单"
        skyblue "----------------"
        reading "请输入选择: " choice
        echo ""
        case "${choice}" in
            1) start_singbox ;;
            2) stop_singbox ;;
            3) restart_singbox ;;
            0) return ;;
            *) red "无效的选项，请重新输入"; sleep 1; continue ;;
        esac
        echo ""
        read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
    done
}

# Argo 管理
manage_argo() {
    local argo_status=$(check_argo 2>/dev/null)
    clear; echo ""
    green "=== Argo 隧道管理 ===\n"
    green "Argo当前状态: $argo_status\n"
    green "1. 启动Argo服务"
    skyblue "----------------"
    green "2. 停止Argo服务"
    skyblue "----------------"
    green "3. 重启Argo服务"
    skyblue "----------------"
    green "4. 添加Argo固定隧道"
    skyblue "----------------"
    green "5. 切换回Argo临时隧道"
    skyblue "----------------"
    green "6. 重新获取Argo临时域名"
    skyblue "----------------"
    purple "0. 返回主菜单"
    skyblue "----------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1) start_argo ;;
        2) stop_argo ;;
        3)
            clear
            # 通过 argo-start.sh 或配置文件判断是否为临时隧道
            if [ -f "${work_dir}/argo-start.sh" ] && grep -q -- '--url http://localhost' "${work_dir}/argo-start.sh" 2>/dev/null; then
                get_quick_tunnel && change_argo_domain
            elif [ ! -f "${work_dir}/argo_fixed.conf" ]; then
                get_quick_tunnel && change_argo_domain
            else
                green "\n当前使用固定隧道,无需获取临时域名"; sleep 2
            fi
            ;;
        4)
            clear
            yellow "\n固定隧道（JSON 或 Token）。Token 请在 Cloudflare 配置一致的 Public Hostname"
            yellow "JSON 参考: ${purple}https://fscarmen.cloudflare.now.cc${re}"
            yellow "架构: Cloudflare → Nginx(入口) → VMess/VLESS/Trojan 三个 WS 端口\n"

            load_argo_fixed_conf
            local current_argo_port="${ARGO_PORT:-8001}"
            reading "请输入 Argo 入口端口 (当前: ${current_argo_port}，回车保持): " input_port
            if [ -n "$input_port" ]; then
                if [[ "$input_port" =~ ^[0-9]+$ ]] && [ "$input_port" -ge 1 ] && [ "$input_port" -le 65535 ]; then
                    port_really_in_use "$input_port"
                    _rc=$?
                    if [ "$_rc" -eq 0 ]; then
                        red "端口 ${input_port} 已被占用，保持 ${current_argo_port}"
                        ARGO_PORT="$current_argo_port"
                    else
                        [ "$_rc" -eq 2 ] && yellow "端口 ${input_port} 检测曾报占用，但系统无实际监听进程，按空闲处理"
                        ARGO_PORT="$input_port"
                        export ARGO_PORT
                        if [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
                            sed -i "s/listen [0-9]\+;/listen ${ARGO_PORT};/g" /etc/nginx/conf.d/argo-ws.conf
                            sed -i "s/listen \[::\]:[0-9]\+;/listen [::]:${ARGO_PORT};/g" /etc/nginx/conf.d/argo-ws.conf
                            nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || restart_nginx >/dev/null 2>&1
                        fi
                        allow_port ${ARGO_PORT}/tcp >/dev/null 2>&1
                        green "Argo 入口端口已更新为: ${purple}${ARGO_PORT}${re}"
                    fi
                else
                    red "端口无效，保持 ${current_argo_port}"
                    ARGO_PORT="$current_argo_port"
                fi
            else
                ARGO_PORT="$current_argo_port"
            fi
            export ARGO_PORT

            reading "请输入固定隧道域名 (回车取消): " argo_domain
            [ -z "$argo_domain" ] && { yellow "已取消"; return; }

            yellow "可粘贴完整命令，将自动去除前缀仅保留 eyJ 令牌"
            reading "请输入隧道令牌/JSON (回车取消): " argo_auth
            argo_auth=$(clean_argo_token "$argo_auth")
            [ -z "$argo_auth" ] && { yellow "已取消"; return; }

            ARGO_DOMAIN="$argo_domain"
            ARGO_TOKEN="$argo_auth"
            ARGO_USE_FIXED=1
            ArgoDomain="$argo_domain"
            export ARGO_DOMAIN ARGO_TOKEN ARGO_USE_FIXED

            save_argo_fixed_conf
            rewrite_argo_service
            restart_argo
            sleep 1
            change_argo_domain
            ;;
        5)
            clear
            clear_argo_fixed_conf
            rewrite_argo_service
            restart_argo
            get_quick_tunnel
            change_argo_domain
            ;;
        6)
            if [ -f "${work_dir}/argo-start.sh" ] && grep -q -- '--url http://localhost' "${work_dir}/argo-start.sh" 2>/dev/null; then
                get_quick_tunnel && change_argo_domain
            elif [ ! -f "${work_dir}/argo_fixed.conf" ]; then
                get_quick_tunnel && change_argo_domain
            else
                yellow "当前使用固定隧道，无法获取临时隧道"; sleep 2
            fi
            ;;
        0) return ;;
        *)
            red "无效的选项！"; sleep 1; manage_argo; return
            ;;
    esac
}

# 获取argo临时隧道
get_quick_tunnel() {
    restart_argo
    yellow "获取临时argo域名中，请稍等...\n"
    sleep 3
    get_argodomain=""
    local i
    for i in $(seq 1 15); do
        purple "第 $i/15 次尝试获取 ArgoDomain..."
        if [ -f "${work_dir}/argo.log" ]; then
            get_argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | head -1)
            [ -z "$get_argodomain" ] && get_argodomain=$(grep -oE '[[:alnum:]+\.-]+\.trycloudflare\.com' "${work_dir}/argo.log" 2>/dev/null | head -1)
        fi
        [ -n "$get_argodomain" ] && break
        if [ "$i" -eq 5 ]; then
            yellow "仍未获取到，尝试再次重启 Argo..."
            restart_argo >/dev/null 2>&1 || true
        fi
        sleep 2
    done
    if [ -z "$get_argodomain" ]; then
        red "未能获取临时 Argo 域名，请稍后重试或改用固定隧道"
        ArgoDomain=""
        return 1
    fi
    green "ArgoDomain：${purple}$get_argodomain${re}\n"
    ArgoDomain=$get_argodomain
}

# 更新Argo域名到订阅（同步更新 vmess / vless-ws / trojan-ws）
change_argo_domain() {
    if [ -z "$ArgoDomain" ]; then
        red "ArgoDomain 为空，无法更新节点"
        return 1
    fi
    if [ ! -f "$client_dir" ]; then
        mkdir -p "$(dirname "$client_dir")"
        : > "$client_dir"
        yellow "节点文件不存在，已新建: $client_dir"
    fi

    # ---- 解析 uuid / 前缀 / 优选，用于缺失时补建 ----
    local _uuid _isp _prefix _cfip _cfport
    _uuid=$(jq -r '.inbounds[] | select(.users != null) | .users[]? | select(.uuid != null) | .uuid' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
    [ -z "$_uuid" ] && _uuid=$(jq -r '.inbounds[] | select(.users != null) | .users[]? | select(.password != null) | .password' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
    [ -z "$_uuid" ] && _uuid="${uuid:-}"
    _isp=$(get_isp "node" 2>/dev/null || echo "node")
    # 自定义前缀优先；有自定义时不输出服务商
    _prefix="${node_prefix:-$_isp}"
    _cfip="${CFIP:-cdns.doon.eu.org}"
    _cfport="$(printf '%s' "${CFPORT:-443}" | grep -E '^[0-9]+$' || echo 443)"

    # ---- 改前：备份 + 刷新直连缓存（直连行任何情况下都不允许丢）----
    cp -f "$client_dir" "${client_dir}.bak" 2>/dev/null || true
    save_direct_cache
    local _direct_before
    _direct_before=$(grep -cvE "$_ARGO_LINE_RE|^[[:space:]]*$" "$client_dir" 2>/dev/null || true)

    # ---- 逐行处理：只改 Argo 三类行，其余行（直连等）原样输出 ----
    local tmp line enc dec upd b64
    local has_vmess=0 has_vless=0 has_trojan=0
    tmp=$(mktemp) || { red "无法创建临时文件"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            vmess://*)
                enc="${line#vmess://}"
                dec=$(printf '%s' "$enc" | b64_decode)
                upd=$(printf '%s' "$dec" | jq -c --arg d "$ArgoDomain" '.host = $d | .sni = $d' 2>/dev/null)
                if [ -n "$upd" ]; then
                    b64=$(printf '%s' "$upd" | base64 -w0 2>/dev/null || printf '%s' "$upd" | base64 | tr -d '\n')
                    printf '%s\n' "vmess://${b64}" >> "$tmp"
                    has_vmess=1
                else
                    printf '%s\n' "$line" >> "$tmp"   # 解析失败：原样保留，不丢
                fi
                ;;
            vless://*path=%2Fvless-argo*|vless://*path=/vless-argo*)
                printf '%s\n' "$line" | sed -E "s|(sni=)[^&#[:space:]]+|\1${ArgoDomain}|; s|(host=)[^&#[:space:]]+|\1${ArgoDomain}|" >> "$tmp"
                has_vless=1
                ;;
            trojan://*path=%2Ftrojan-argo*|trojan://*path=/trojan-argo*)
                printf '%s\n' "$line" | sed -E "s|(sni=)[^&#[:space:]]+|\1${ArgoDomain}|; s|(host=)[^&#[:space:]]+|\1${ArgoDomain}|" >> "$tmp"
                has_trojan=1
                ;;
            *)
                printf '%s\n' "$line" >> "$tmp"
                ;;
        esac
    done < "$client_dir"
    [ "$has_vmess"  = "1" ] && green "vmess 节点已更新"
    [ "$has_vless"  = "1" ] && green "vless-argo 节点已更新"
    [ "$has_trojan" = "1" ] && green "trojan-argo 节点已更新"

    # ---- 缺失则补建（安装时域名超时跳过写入后的补救路径）----
    if [ -n "$_uuid" ]; then
        if [ "$has_vmess" != "1" ]; then
            local _vj
            _vj=$(jq -nc --arg ps "${_prefix}-argo-vmess" --arg add "$_cfip" --arg port "$_cfport" --arg id "$_uuid" --arg host "$ArgoDomain" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:"/vmess-argo?ed=2560",tls:"tls",sni:$host,alpn:"",fp:"firefox",allowInsecure:"false"}' 2>/dev/null)
            if [ -n "$_vj" ]; then
                printf '\n%s\n' "vmess://$(printf '%s' "$_vj" | base64 -w0 2>/dev/null || printf '%s' "$_vj" | base64 | tr -d '\n')" >> "$tmp"
                green "已补建 vmess-argo 节点"
            fi
        fi
        if [ "$has_vless" != "1" ]; then
            printf '\n%s\n' "vless://${_uuid}@${_cfip}:${_cfport}?encryption=none&security=tls&sni=${ArgoDomain}&fp=firefox&type=ws&host=${ArgoDomain}&path=%2Fvless-argo%3Fed%3D2560#${_prefix}-argo-vless" >> "$tmp"
            green "已补建 vless-argo 节点"
        fi
        if [ "$has_trojan" != "1" ]; then
            printf '\n%s\n' "trojan://${_uuid}@${_cfip}:${_cfport}?security=tls&sni=${ArgoDomain}&fp=firefox&type=ws&host=${ArgoDomain}&path=%2Ftrojan-argo%3Fed%3D2560#${_prefix}-argo-trojan" >> "$tmp"
            green "已补建 trojan-argo 节点"
        fi
    else
        yellow "未能从配置读取 UUID，若 Argo 节点仍缺失请重新安装或手动补全"
    fi

    # ---- 改后校验：直连行数减少（或原文件根本没有直连行）时，从缓存补回 ----
    local _direct_after _restored
    _direct_after=$(grep -cvE "$_ARGO_LINE_RE|^[[:space:]]*$" "$tmp" 2>/dev/null || true)
    if [ "${_direct_after:-0}" -lt "${_direct_before:-0}" ] || [ "${_direct_before:-0}" -eq 0 ]; then
        _restored=$(restore_direct_cache "$tmp")
        [ "${_restored:-0}" -gt 0 ] && yellow "已从缓存恢复 ${_restored} 条直连节点"
    fi

    # ---- 压缩多余空行，原子替换 ----
    sed '/^$/N;/^\n$/D' "$tmp" > "${tmp}.2" && mv -f "${tmp}.2" "$client_dir"
    rm -f "$tmp" "${tmp}.2"
    chmod 644 "$client_dir" 2>/dev/null || true
    save_direct_cache
    refresh_sub

    echo ""
    green "=== 更新后的节点信息 ===\n"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "${purple}${line}${re}"
    done < "$client_dir"
    echo ""

    send_tg_nodes 2>/dev/null || true
}

# 查看当前节点信息（节点链接 + 订阅 URL）


# 主菜单 7：管理节点订阅（含 Nginx）
menu_sub_manage() {
    while true; do
        clear; echo ""
        load_sub_conf
        ensure_sub_token
        local sub_st="已开启"
        [ "${SUB_ENABLED:-1}" != "1" ] && sub_st="已关闭"
        green "=== 管理节点订阅 ===\n"
        yellow "状态: ${purple}${sub_st}${re}  端口: ${purple}${SUB_PORT:-2096}${re}  令牌: ${purple}${SUB_TOKEN:0:8}...${re}\n"
        skyblue "----------------"
        green "1. 关闭节点订阅"
        skyblue "----------------"
        green "2. 开启节点订阅"
        skyblue "----------------"
        green "3. 更换订阅端口"
        skyblue "----------------"
        green "4. 重启订阅服务"
        skyblue "----------------"
        green "5. 生成新订阅链接"
        skyblue "----------------"
        green "6. Nginx管理"
        skyblue "----------------"
        purple "0. 返回主菜单"
        skyblue "----------------"
        reading "请输入选择: " sub_choice
        echo ""
        case "${sub_choice}" in
            1)
                SUB_ENABLED=0
                export SUB_ENABLED
                save_sub_conf
                write_sub_nginx_conf
                # 同步去掉 Argo 入口上的 /s/ 路径（重写 argo-ws 时会按 token 再写入；此处仅关独立端口）
                if command_exists nginx; then
                    nginx -t >/dev/null 2>&1 && restart_nginx >/dev/null 2>&1 || true
                fi
                green "节点订阅已关闭（独立端口不再对外提供）"
                sleep 1
                ;;
            2)
                ensure_sub_token
                SUB_ENABLED=1
                export SUB_ENABLED
                save_sub_conf
                allow_port ${SUB_PORT}/tcp >/dev/null 2>&1
                write_sub_nginx_conf
                if ! command_exists nginx; then
                    red "nginx 未安装，请先安装/生成配置"
                elif nginx -t >/dev/null 2>&1; then
                    restart_nginx >/dev/null 2>&1 || true
                    green "节点订阅已开启"
                    print_sub_urls
                else
                    red "nginx -t 失败，请到「Nginx管理」查看"
                    nginx -t 2>&1 | tail -5
                fi
                read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
                ;;
            3)
                ensure_sub_token
                reading "请输入新的订阅端口 (当前 ${SUB_PORT}，回车取消): " new_sp
                if [ -z "$new_sp" ]; then
                    yellow "已取消"; sleep 1; continue
                fi
                if ! [[ "$new_sp" =~ ^[0-9]+$ ]] || [ "$new_sp" -lt 1 ] || [ "$new_sp" -gt 65535 ]; then
                    red "端口无效"; sleep 1; continue
                fi
                port_really_in_use "$new_sp"
                _rc=$?
                if [ "$_rc" -eq 0 ]; then
                    # 若占用者是本机 nginx 监听旧 SUB_PORT，允许更换
                    if [ "$new_sp" = "${SUB_PORT}" ]; then
                        yellow "与当前端口相同"; sleep 1; continue
                    fi
                    red "端口 ${new_sp} 已被占用"; sleep 1; continue
                fi
                SUB_PORT="$new_sp"
                export SUB_PORT
                SUB_ENABLED=1
                export SUB_ENABLED
                save_sub_conf
                allow_port ${SUB_PORT}/tcp > /dev/null 2>&1
                write_sub_nginx_conf
                if command_exists nginx && nginx -t >/dev/null 2>&1; then
                    restart_nginx >/dev/null 2>&1 || true
                    green "订阅端口已改为: ${purple}${SUB_PORT}${re}"
                    print_sub_urls
                else
                    red "配置写入后 nginx -t 失败"
                    command_exists nginx && nginx -t
                fi
                read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
                ;;
            4)
                ensure_sub_token
                write_sub_nginx_conf
                if ! command_exists nginx; then
                    red "nginx 未安装"; sleep 1; continue
                fi
                if nginx -t >/dev/null 2>&1; then
                    restart_nginx && green "订阅服务(Nginx)已重启" || red "重启失败"
                    [ "${SUB_ENABLED:-1}" = "1" ] && print_sub_urls
                else
                    red "nginx -t 失败，无法重启"
                    nginx -t
                fi
                read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
                ;;
            5)
                yellow "将生成新的订阅令牌，旧订阅链接会立即失效"
                reading "确认生成？(y/N): " conf_gen
                if ! echo "$conf_gen" | grep -qiE '^y(es)?$'; then
                    yellow "已取消"; sleep 1; continue
                fi
                load_sub_conf
                local old_show="${SUB_TOKEN:-}"
                if regenerate_sub_token; then
                    green "已生成新订阅链接（旧令牌已失效）"
                    [ -n "$old_show" ] && yellow "旧令牌前缀: ${old_show:0:8}..."
                    print_sub_urls
                else
                    red "生成失败，请检查 Nginx 配置"
                fi
                read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
                ;;
            6)
                manage_nginx
                ;;
            0)
                return
                ;;
            *)
                red "无效选项"
                sleep 1
                ;;
        esac
    done
}

# ---------- Nginx 管理 ----------
_load_argo_port_for_nginx() {
    # 优先环境变量 → argo_fixed.conf → 现有 argo-ws.conf → 默认 8001
    if [ -n "${ARGO_PORT:-}" ] && [[ "$ARGO_PORT" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if [ -f "${work_dir}/argo_fixed.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/argo_fixed.conf" 2>/dev/null || true
    fi
    if [ -z "${ARGO_PORT:-}" ] || ! [[ "${ARGO_PORT}" =~ ^[0-9]+$ ]]; then
        if [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
            ARGO_PORT=$(grep -oE 'listen[[:space:]]+[0-9]+' /etc/nginx/conf.d/argo-ws.conf 2>/dev/null | head -1 | awk '{print $2}')
        fi
    fi
    ARGO_PORT="${ARGO_PORT:-8001}"
    export ARGO_PORT
}

manage_nginx() {
    while true; do
        clear; echo ""
        local ngx_st
        ngx_st=$(check_nginx 2>/dev/null)
        green "=== Nginx 管理 ===\n"
        green "当前状态: $ngx_st\n"
        if command_exists nginx; then
            yellow "配置检测: $(nginx -t 2>&1 | tail -1)\n"
        else
            red "系统未安装 nginx 命令\n"
        fi
        _load_argo_port_for_nginx
        yellow "当前 Argo 入口端口(ARGO_PORT): ${purple}${ARGO_PORT}${re}\n"

        green "1. 启动 Nginx"
        skyblue "----------------"
        green "2. 停止 Nginx"
        skyblue "----------------"
        green "3. 重启 Nginx"
        skyblue "----------------"
        green "4. 重新生成 Argo 路径配置 (argo-ws.conf + 主配置)"
        skyblue "----------------"
        green "5. 查看 nginx -t 完整输出"
        skyblue "----------------"
        green "6. 查看 argo-ws.conf"
        skyblue "----------------"
        green "7. 修改 Argo 入口监听端口并重载"
        skyblue "----------------"
        purple "0. 返回上一级"
        skyblue "----------------"
        reading "请输入选择: " ngx_choice
        echo ""
        case "${ngx_choice}" in
            1)
                if ! command_exists nginx; then
                    yellow "正在安装 nginx..."
                    manage_packages install nginx
                fi
                start_nginx
                ;;
            2)
                manage_service "nginx" "stop"
                ;;
            3)
                if ! command_exists nginx; then
                    red "nginx 未安装"
                else
                    restart_nginx
                fi
                ;;
            4)
                if ! command_exists nginx; then
                    manage_packages install nginx
                fi
                _load_argo_port_for_nginx
                if add_nginx_conf; then
                    green "Nginx Argo 配置已重新生成"
                else
                    red "配置生成失败，请查看上方错误信息"
                fi
                ;;
            5)
                if command_exists nginx; then
                    nginx -t
                else
                    red "nginx 未安装"
                fi
                ;;
            6)
                if [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
                    echo ""
                    cat /etc/nginx/conf.d/argo-ws.conf
                    echo ""
                else
                    red "文件不存在: /etc/nginx/conf.d/argo-ws.conf"
                    yellow "可选择 4 重新生成配置"
                fi
                ;;
            7)
                _load_argo_port_for_nginx
                reading "请输入新的 Argo 入口端口 (当前 ${ARGO_PORT}，回车取消): " new_ap
                if [ -z "$new_ap" ]; then
                    yellow "已取消"
                elif ! [[ "$new_ap" =~ ^[0-9]+$ ]] || [ "$new_ap" -lt 1 ] || [ "$new_ap" -gt 65535 ]; then
                    red "端口无效"
                else
                    port_really_in_use "$new_ap"
                    _rc=$?
                    if [ "$_rc" -eq 0 ]; then
                        red "端口 ${new_ap} 已被占用"
                    else
                        [ "$_rc" -eq 2 ] && yellow "端口 ${new_ap} 检测曾报占用，但系统无实际监听进程，按空闲处理"
                        ARGO_PORT="$new_ap"
                        export ARGO_PORT
                        if [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
                            sed -i "s/listen [0-9]\\+;/listen ${ARGO_PORT};/g" /etc/nginx/conf.d/argo-ws.conf
                            sed -i "s/listen \\[::\\]:[0-9]\\+;/listen [::]:${ARGO_PORT};/g" /etc/nginx/conf.d/argo-ws.conf
                        else
                            add_nginx_conf
                        fi
                        allow_port ${ARGO_PORT}/tcp >/dev/null 2>&1
                        if nginx -t 2>/dev/null; then
                            restart_nginx
                            # 持久化并同步 cloudflared 指向新端口（与 change_config 一致）
                            if [ -f "${work_dir}/argo_fixed.conf" ]; then
                                if grep -q '^ARGO_PORT=' "${work_dir}/argo_fixed.conf" 2>/dev/null; then
                                    sed -i "s/^ARGO_PORT=.*/ARGO_PORT=\"${ARGO_PORT}\"/" "${work_dir}/argo_fixed.conf"
                                else
                                    echo "ARGO_PORT=\"${ARGO_PORT}\"" >> "${work_dir}/argo_fixed.conf"
                                fi
                            fi
                            rewrite_argo_service
                            restart_argo
                            sleep 2
                            if [ -f "${work_dir}/argo-start.sh" ] && grep -q -- '--url http://localhost' "${work_dir}/argo-start.sh" 2>/dev/null; then
                                get_quick_tunnel && change_argo_domain
                            fi
                            green "Argo 入口端口已更新为 ${purple}${ARGO_PORT}${re}（Nginx + Argo 隧道已同步）"
                        else
                            red "配置检测失败"
                            nginx -t
                        fi
                    fi
                fi
                ;;
            0)
                return
                ;;
            *)
                red "无效选项"
                ;;
        esac
        echo ""
        read -n 1 -s -r -p $'\033[1;91m按任意键继续...\033[0m'
    done
}

check_nodes() {
    if [ ! -f "${work_dir}/url.txt" ]; then
        red "节点信息文件不存在，请先安装 sing-box"; return 1
    fi

    clear; echo ""
    green "=== 当前节点信息 ===\n"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "${purple}${line}${re}\n"
    done < "${work_dir}/url.txt"

    # 与安装结束、节点文件说明一致：始终展示订阅链接
    print_sub_urls

    yellow "温馨提醒: 若 hysteria2/tuic 不通，请将客户端「跳过证书验证」设为 true 或更换内核\n"
}

change_cfip() {
    clear
    yellow "修改vmess-argo优选域名\n"
    green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org  5: cf.zhetengsha.eu.org  6: time.is\n"
    reading "请输入你的优选域名或优选IP\n(请输入1至6选项,可输入域名:端口 或 IP:端口,直接回车默认使用1): " cfip_input

    case "$cfip_input" in
        ""|"1") cfip="cf.090227.xyz";          cfport="443" ;;
        "2")    cfip="cf.877774.xyz";           cfport="443" ;;
        "3")    cfip="cf.877771.xyz";           cfport="443" ;;
        "4")    cfip="cdns.doon.eu.org";        cfport="443" ;;
        "5")    cfip="cf.zhetengsha.eu.org";    cfport="443" ;;
        "6")    cfip="time.is";                 cfport="443" ;;
        *)
            if [[ "$cfip_input" =~ : ]]; then
                cfip=$(echo "$cfip_input" | cut -d':' -f1)
                cfport=$(echo "$cfip_input" | cut -d':' -f2)
            else
                cfip="$cfip_input"; cfport="443"
            fi
            ;;
    esac

    # 更新全部 vmess 的 add/port
    local _count
    _count=$(update_all_vmess --arg cfip "$cfip" --argjson cfport "$cfport" '.add = $cfip | .port = ($cfport|tonumber)')

    # 同步更新 argo 的 vless/trojan 节点中的 CFIP:CFPORT（仅 argo path 行）
    sed -i -E "/path=%2Fvless-argo|path=\/vless-argo/ s#@[^:?]+(:[0-9]+)?\?#@${cfip}:${cfport}?#" "$client_dir" 2>/dev/null || true
    sed -i -E "/path=%2Ftrojan-argo|path=\/trojan-argo/ s#@[^:?]+(:[0-9]+)?\?#@${cfip}:${cfport}?#" "$client_dir" 2>/dev/null || true

    export CFIP="$cfip" CFPORT="$cfport"
    refresh_sub
    green "\n优选域名已更新为：${purple}${cfip}:${cfport}${re}（vmess 更新 ${_count} 条）\n"
}

# WARP 分流管理
