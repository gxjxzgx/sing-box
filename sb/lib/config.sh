change_config() {
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?

    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi

    clear; echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box当前状态: $singbox_status\n"
    green "1. 修改端口"
    skyblue "----------------"
    green "2. 修改UUID"
    skyblue "----------------"
    green "3. 修改Reality伪装域名"
    skyblue "----------------"
    green "4. 添加hysteria2端口跳跃"
    skyblue "----------------"
    green "5. 删除hysteria2端口跳跃"
    skyblue "----------------"
    green "6. 修改vmess-argo优选域名"
    skyblue "----------------"
    green "7. 修改节点ip为ipv4"
    skyblue "----------------"
    green "8. 修改节点ip为ipv6"
    skyblue "----------------"
    green "9. 修改节点前缀名称"
    skyblue "----------------"
    purple "0. 返回主菜单"
    skyblue "----------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)
            echo ""
            green "1. 修改vless-reality端口"
            skyblue "----------------"
            green "2. 修改hysteria2端口"
            skyblue "----------------"
            green "3. 修改tuic端口"
            skyblue "----------------"
            green "4. 修改Argo对外端口（Nginx入口，三协议共用）"
            skyblue "----------------"
            green "5. 修改 AnyTLS 端口"
            skyblue "----------------"
            purple "0. 返回上一级"
            skyblue "----------------"
            reading "请输入选择: " choice
            local inbounds_file="${conf_dir}/inbounds.json"
            # [优化] 下面 1/2/3/5 四个端口修改分支，原来各自手写了一遍
            # "输入→随机兜底→范围校验→port_really_in_use占用检测→重试"的循环，
            # 脚本自己已经定义了完全等价的通用函数 read_available_port，这里改
            # 为直接复用。注意：read_available_port 的随机端口范围是
            # 10000-65000（原手写循环是 2000-65000），范围收窄但依然是安全的
            # 非特权高位端口，不影响功能。
            case "${choice}" in
                1)
                    read_available_port "\n请输入vless-reality端口 (回车跳过将使用随机端口): " new_port
                    # 仅修改 tag=vless-reality，避免误改 vless-ws
                    jq --argjson port "$new_port" \
                        '(.inbounds[] | select(.tag == "vless-reality")).listen_port = $port' \
                        "$inbounds_file" > "${inbounds_file}.tmp"
                    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "vless-reality 端口"; then
                        return 1
                    fi
                    allow_port $new_port/tcp > /dev/null 2>&1
                    restart_singbox
                    # 仅更新 reality 直连节点端口（排除 argo 的 vless-ws）；用端口后紧跟 ? 定位，兼容 IPv6 主机地址
                    sed -i -E "/vless:\/\/.*flow=xtls-rprx-vision/ s/:[0-9]+\?/:${new_port}?/" "$client_dir"
                    refresh_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nvless-reality端口已修改成：${purple}$new_port${re}\n"
                    ;;
                2)
                    read_available_port "\n请输入hysteria2端口 (回车跳过将使用随机端口): " new_port
                    jq --argjson port "$new_port" \
                        '(.inbounds[] | select(.tag == "hysteria2")).listen_port = $port' \
                        "$inbounds_file" > "${inbounds_file}.tmp"
                    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "hysteria2 端口"; then
                        return 1
                    fi
                    allow_port $new_port/udp > /dev/null 2>&1
                    restart_singbox
                    # 用端口后紧跟 /? 定位，兼容 IPv6 主机地址
                    sed -i -E "/hysteria2:\/\// s#:[0-9]+/\?#:${new_port}/?#" "$client_dir"
                    refresh_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nhysteria2端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                3)
                    read_available_port "\n请输入tuic端口 (回车跳过将使用随机端口): " new_port
                    jq --argjson port "$new_port" \
                        '(.inbounds[] | select(.tag == "tuic")).listen_port = $port' \
                        "$inbounds_file" > "${inbounds_file}.tmp"
                    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "tuic 端口"; then
                        return 1
                    fi
                    allow_port $new_port/udp > /dev/null 2>&1
                    restart_singbox
                    # 用端口后紧跟 ? 定位，兼容 IPv6 主机地址
                    sed -i -E "/tuic:\/\// s/:[0-9]+\?/:${new_port}?/" "$client_dir"
                    refresh_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\ntuic端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                4)
                    # Argo 对外端口 = Nginx 监听端口（内部三个协议端口不变）
                    read_available_port "\n请输入Argo对外端口 (当前Nginx入口, 回车跳过将使用随机端口): " new_port
                    allow_port $new_port/tcp > /dev/null 2>&1
                    if [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
                        sed -i "s/listen [0-9]\+;/listen ${new_port};/g" /etc/nginx/conf.d/argo-ws.conf
                        sed -i "s/listen \[::\]:[0-9]\+;/listen [::]:${new_port};/g" /etc/nginx/conf.d/argo-ws.conf
                        nginx -t >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || restart_nginx >/dev/null 2>&1
                    fi
                    export ARGO_PORT=$new_port
                    # 同步到固定配置（若有）并重写 argo 启动脚本
                    if [ -f "${work_dir}/argo_fixed.conf" ]; then
                        sed -i "s/^ARGO_PORT=.*/ARGO_PORT=\"${new_port}\"/" "${work_dir}/argo_fixed.conf"
                    fi
                    rewrite_argo_service
                    restart_argo
                    sleep 2
                    # 仅临时隧道需要重新拉取域名
                    if [ -f "${work_dir}/argo-start.sh" ] && grep -q -- '--url http://localhost' "${work_dir}/argo-start.sh" 2>/dev/null; then
                        get_quick_tunnel && change_argo_domain
                    fi
                    green "\nArgo对外端口已修改为：${purple}${new_port}${re}（三个协议仍共用此入口）\n"
                    ;;
                5)
                    # AnyTLS
                    if ! jq -e '.inbounds[] | select(.tag=="anytls")' "$inbounds_file" >/dev/null 2>&1; then
                        red "当前未安装 AnyTLS 协议（可能已选择跳过直连）"
                        break
                    fi
                    read_available_port "\n请输入 AnyTLS 端口 (回车随机): " new_port
                    jq --argjson port "$new_port" \
                        '(.inbounds[] | select(.tag == "anytls")).listen_port = $port' \
                        "$inbounds_file" > "${inbounds_file}.tmp"
                    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "AnyTLS 端口"; then
                        return 1
                    fi
                    allow_port $new_port/tcp > /dev/null 2>&1
                    restart_singbox
                    # 仅更新 anytls 节点，兼容 IPv6
                    sed -i -E "/^anytls:\/\// s/:[0-9]+\?/:${new_port}?/" "$client_dir"
                    refresh_sub
                    while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
                    green "\nAnyTLS 端口已修改为：${purple}${new_port}${re}\n"
                    ;;
                0) change_config ;;
                *) red "无效的选项，请输入 1 到 5" ;;
            esac
            ;;
        2)
            reading "\n请输入新的UUID(直接回车随机生成UUID): " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            if ! echo "$new_uuid" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
                red "UUID 格式无效"; return 1
            fi
            # Socks5 用户名/密码保持与添加时一致：前8位 / 后12位，避免整段 UUID 污染密码
            local sk_user sk_pass
            sk_user=$(printf '%s' "${new_uuid:0:8}")
            sk_pass=$(printf '%s' "${new_uuid: -12}")
            jq --arg uuid "$new_uuid" --arg sk_user "$sk_user" --arg sk_pass "$sk_pass" '
                (.inbounds[] | select(.users != null) | .users[] | select(.uuid != null).uuid) = $uuid |
                (.inbounds[] | select(.tag != "socks5-in" and .users != null) | .users[] | select(.password != null).password) = $uuid |
                (.inbounds[] | select(.tag == "socks5-in") | .users[0].username) = $sk_user |
                (.inbounds[] | select(.tag == "socks5-in") | .users[0].password) = $sk_pass
            ' "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.json.tmp"
            if ! safe_apply_conf "${conf_dir}/inbounds.json" "${conf_dir}/inbounds.json.tmp" "UUID"; then
                return 1
            fi
            restart_singbox
            sed -i -E 's/(vless:\/\/|hysteria2:\/\/|anytls:\/\/|trojan:\/\/)[^@]*(@.*)/\1'"$new_uuid"'\2/' $client_dir
            sed -i -E "s#tuic://[0-9a-f-]{36}:[0-9a-f-]{36}@#tuic://$new_uuid:$new_uuid@#g" $client_dir
            # 同步更新 socks:// 订阅链接中的账号密码（base64(user:pass)）
            if grep -q '^socks://' "$client_dir" 2>/dev/null; then
                local sk_auth sk_b64
                sk_auth=$(printf '%s:%s' "$sk_user" "$sk_pass")
                sk_b64=$(printf '%s' "$sk_auth" | base64 -w0 2>/dev/null || printf '%s' "$sk_auth" | base64 | tr -d '\n')
                sed -i -E "s#socks://[^@]+@#socks://${sk_b64}@#g" "$client_dir"
            fi
            # 更新全部 vmess 的 id，保留 ps/add/port/host/sni 等
            update_all_vmess --arg id "$new_uuid" '.id = $id' >/dev/null
            refresh_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nUUID已修改为：${purple}${new_uuid}${re}\n"
            if jq -e '.inbounds[] | select(.tag == "socks5-in")' "${conf_dir}/inbounds.json" >/dev/null 2>&1; then
                green "Socks5 用户名/密码已同步为 UUID 前8位/后12位，并已更新订阅链接\n"
            fi
            ;;
        3)
            clear
            green "\n1. www.joom.com\n\n2. www.stengg.com\n\n3. www.wedgehr.com\n\n4. www.cerebrium.ai\n\n5. www.nazhumi.com\n"
            reading "\n请输入新的Reality伪装域名(可自定义输入,回车留空将使用默认1): " new_sni
            case "$new_sni" in
                ""|"1") new_sni="www.joom.com" ;;
                "2") new_sni="www.stengg.com" ;;
                "3") new_sni="www.wedgehr.com" ;;
                "4") new_sni="www.cerebrium.ai" ;;
                "5") new_sni="www.nazhumi.com" ;;
            esac
            jq --arg sni "$new_sni" \
               '(.inbounds[] | select(.tag == "vless-reality") | .tls.server_name) = $sni |
                (.inbounds[] | select(.tag == "vless-reality") | .tls.reality.handshake.server) = $sni' \
               "${conf_dir}/inbounds.json" > "${conf_dir}/inbounds.json.tmp"
            if ! safe_apply_conf "${conf_dir}/inbounds.json" "${conf_dir}/inbounds.json.tmp" "Reality SNI"; then
                return 1
            fi
            restart_singbox
            # 仅更新 Reality 节点的 sni
            sed -i -E "/flow=xtls-rprx-vision/s/(sni=)[^&]*/\1${new_sni}/" $client_dir
            refresh_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nReality sni已修改为：${purple}${new_sni}${re}\n"
            ;;
        4)
            purple "端口跳跃需确保跳跃区间的端口没有被占用\n"
            reading "请输入跳跃起始端口 (回车跳过将使用随机端口): " min_port
            [ -z "$min_port" ] && min_port=$(shuf -i 50000-65000 -n 1)
            yellow "你的起始端口为：$min_port"
            reading "\n请输入跳跃结束端口 (需大于起始端口): " max_port
            [ -z "$max_port" ] && max_port=$(($min_port + 100))
            yellow "你的结束端口为：$max_port\n"
            listen_port=$(jq -r '.inbounds[] | select(.type == "hysteria2").listen_port' "${conf_dir}/inbounds.json")
            iptables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            command -v ip6tables &> /dev/null && ip6tables -t nat -A PREROUTING -p udp --dport $min_port:$max_port -j DNAT --to-destination :$listen_port > /dev/null
            if command_exists rc-service 2>/dev/null; then
                iptables-save > /etc/iptables/rules.v4
                command -v ip6tables &> /dev/null && ip6tables-save > /etc/iptables/rules.v6
                cat << 'IEOF' > /etc/init.d/iptables
#!/sbin/openrc-run
depend() { need net; }
start() {
    [ -f /etc/iptables/rules.v4 ] && iptables-restore < /etc/iptables/rules.v4
    command -v ip6tables &> /dev/null && [ -f /etc/iptables/rules.v6 ] && ip6tables-restore < /etc/iptables/rules.v6
}
IEOF
                chmod +x /etc/init.d/iptables && rc-update add iptables default && /etc/init.d/iptables start
            elif [ -f /etc/debian_version ]; then
                DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent > /dev/null 2>&1 && netfilter-persistent save > /dev/null 2>&1
                systemctl enable netfilter-persistent > /dev/null 2>&1 && systemctl start netfilter-persistent > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                manage_packages install iptables-services > /dev/null 2>&1 && service iptables save > /dev/null 2>&1
                systemctl enable iptables > /dev/null 2>&1 && systemctl start iptables > /dev/null 2>&1
                command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
                systemctl enable ip6tables > /dev/null 2>&1 && systemctl start ip6tables > /dev/null 2>&1
            fi
            restart_singbox
            ip=$(get_realip)
            fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')
            uuid=$(sed -n 's/.*hysteria2:\/\/\([^@]*\)@.*/\1/p' $client_dir)
            isp=$(build_node_prefix "node")
            # [修复] 原实现在删除旧 hysteria2 行之前先记下它的行号，
            # 但 sed 删除后文件整体少了一行，再按旧行号插入会导致新行
            # 比预期位置晚插入一行（off-by-one，纯展示顺序问题，不影响功能）。
            # 改为直接删除后追加到文件末尾，不依赖行号计算。
            sed -i.bak "/hysteria2:/d" $client_dir
            echo "hysteria2://$uuid@$ip:$listen_port?peer=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none&mport=$listen_port,$min_port-$max_port#${isp}-hysteria2" >> $client_dir
            refresh_sub
            while IFS= read -r line; do yellow "$line"; done < ${work_dir}/url.txt
            green "\nhysteria2端口跳跃已开启：${purple}$min_port-$max_port${re}\n"
            ;;
        5)
            iptables -t nat -F PREROUTING > /dev/null 2>&1
            command -v ip6tables &> /dev/null && ip6tables -t nat -F PREROUTING > /dev/null 2>&1
            if command_exists rc-service 2>/dev/null; then
                rc-update del iptables default && rm -rf /etc/init.d/iptables
            elif [ -f /etc/debian_version ]; then
                netfilter-persistent save > /dev/null 2>&1
            elif [ -f /etc/redhat-release ]; then
                service iptables save > /dev/null 2>&1
                command -v ip6tables &> /dev/null && service ip6tables save > /dev/null 2>&1
            fi
            sed -i '/hysteria2/s/&mport=[^#&]*//g' /etc/sing-box/url.txt
            refresh_sub
            green "\n端口跳跃已删除\n"
            ;;
        6) change_cfip ;;
        7)
            local new_ipv4
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            new_ipv4=$(curl -4 -sm 2 ip.sb)
            if ! printf '%s' "$new_ipv4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
                red "\n错误: 获取 IPv4 失败: $new_ipv4\n"
                return 1
            fi
            if curl -4 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                red "\n当前服务器的ipv4: $new_ipv4 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@\[[0-9a-fA-F:]+\]' "$client_dir"; then
                # 替换 @ 后的 IPv6 主机
                sed -i -E "/^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@\[[0-9a-fA-F:]+\]#@${new_ipv4}#g" "$client_dir"
                # 同步直连节点 host=（可选 vless-ws 依赖 Host 头；仅改 path=/vless-ws 行，不动 argo）
                sed -i -E "/path=%2Fvless-ws|path=\/vless-ws/ s#(host=)\[[0-9a-fA-F:]+\]#\1${new_ipv4}#g" "$client_dir"
                green "\n已将 IPv6 修改为 IPv4: $new_ipv4 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv4, 无需切换\n" && return 0
            fi
            refresh_sub
           ;;
        8)
            local new_ipv6
            [ -f "$client_dir" ] || {
                red "\n错误: $client_dir 不存在\n"
                return 1
            }
            new_ipv6=$(curl -6 -sm 3 ip.sb)
            if ! printf '%s' "$new_ipv6" | grep -Eq '^[0-9a-fA-F:]+$'; then
                red "\n当前服务器没有可用的ipv6\n"
                return 1
            fi
            if curl -6 -sm 2 http://ipinfo.io/org | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
                red "\n当前服务器的ipv6 $new_ipv6 为warp ip,无法作为直连节点使用\n"
                return 1
            fi
            if grep -Eq '^(vless|hysteria2|tuic|anytls|socks|ss)://[^@]+@([0-9]{1,3}\.){3}[0-9]{1,3}' "$client_dir"; then
                sed -i -E "/^(vless|hysteria2|tuic|anytls|socks|ss):\/\// s#@(([0-9]{1,3}\.){3}[0-9]{1,3})#@[${new_ipv6}]#g" "$client_dir"
                # 同步直连 vless-ws 的 host= 为 [ipv6]
                sed -i -E "/path=%2Fvless-ws|path=\/vless-ws/ s#(host=)([0-9]{1,3}\.){3}[0-9]{1,3}#\1[${new_ipv6}]#g" "$client_dir"
                sed -i -E "/path=%2Fvless-ws|path=\/vless-ws/ s#(host=)\[[0-9a-fA-F:]+\]#\1[${new_ipv6}]#g" "$client_dir"
                green "\n已将 IPv4 修改为 IPv6: [${new_ipv6}] 可复制以下节点或更新订阅\n"
                check_nodes
            else
                yellow "\n当前已是ipv6, 无需切换\n" && return 0
            fi
            refresh_sub
           ;;
        9)
            # 修改节点前缀名称
            reading "\n请输入新的节点前缀名称 (回车清空前缀，改用服务商名称): " new_prefix
            export node_prefix="$new_prefix"

            if [ -z "$new_prefix" ]; then
                prefix_display="(使用服务商名称)"
            else
                prefix_display="$new_prefix"
            fi
            green "节点前缀已设置为: ${purple}${prefix_display}${re}"

            # 重新生成节点名称
            if [ ! -f "$client_dir" ]; then
                red "节点文件不存在"
                return 1
            fi

            isp=$(get_isp "node")

            # 自定义前缀优先；有自定义时不输出服务商
            prefix="${node_prefix:-$isp}"

            # 更新各协议节点备注（顺序：先区分 argo / 直连 ws，再处理 reality，避免互相覆盖）
            sed -i -E "s|(hysteria2://[^#]+)#.*|\1#${prefix}-hysteria2|" "$client_dir"
            sed -i -E "s|(tuic://[^#]+)#.*|\1#${prefix}-tuic|" "$client_dir"
            sed -i -E "s|(trojan://[^#]+)#.*|\1#${prefix}-argo-trojan|" "$client_dir"
            sed -i -E "s|(anytls://[^#]+)#.*|\1#${prefix}-anytls|" "$client_dir"
            sed -i -E "s|(socks://[^#]+)#.*|\1#${prefix}-socks5|" "$client_dir"
            sed -i -E "s|(ss://[^#]+)#.*|\1#${prefix}-ss2022|" "$client_dir"

            # vless-ws argo 隧道
            sed -i -E "s|(vless://[^#]*path=%2Fvless-argo[^#]*)#.*|\1#${prefix}-argo-vless|" "$client_dir"
            sed -i -E "s|(vless://[^#]*path=/vless-argo[^#]*)#.*|\1#${prefix}-argo-vless|" "$client_dir"

            # vless-ws 直连（无 TLS，path 为 /vless-ws，非 argo）
            sed -i -E "s|(vless://[^#]*path=%2Fvless-ws[^#]*)#.*|\1#${prefix}-vless-ws|" "$client_dir"
            sed -i -E "s|(vless://[^#]*path=/vless-ws[^#]*)#.*|\1#${prefix}-vless-ws|" "$client_dir"

            # Reality（含 flow=xtls-rprx-vision）
            sed -i -E "s|(vless://[^#]*flow=xtls-rprx-vision[^#]*)#.*|\1#${prefix}-vless-reality|" "$client_dir"

            # 更新全部 vmess 的 ps 字段
            update_all_vmess --arg ps "${prefix}-argo-vmess" '.ps = $ps' >/dev/null

            refresh_sub
            green "\n节点前缀已更新，可复制以下节点或更新订阅\n"
            while IFS= read -r line; do yellow "$line"; done < "$client_dir"
            ;;
        0) return ;;
        *)
            # [修复] 原来这里什么都不做，case结束后函数静默返回，
            # 主循环会 pause 然后重画主菜单——等于"输入错误直接跳回主菜单"，
            # 和 setup_telegram/manage_protocols 等"输入错误留在本菜单重试"
            # 的行为不一致。这里改为重新显示本菜单，保持一致。
            red "无效的选项！\n"; sleep 1; change_config; return
            ;;
    esac
}

# singbox 管理（优化版：循环 + 状态刷新）
