get_info() {
    yellow "\nip检测中,请稍等...\n"
    server_ip=$(get_realip)
    clear
    isp=$(get_isp "node")

    # 优先使用固定隧道域名（若安装时已配置）
    argodomain=""
    load_argo_fixed_conf
    if [ "${ARGO_USE_FIXED:-0}" = "1" ] && [ -n "${ARGO_DOMAIN:-}" ]; then
        argodomain="$ARGO_DOMAIN"
        green "使用固定隧道域名: ${purple}${argodomain}${re}"
    fi

    # 若无固定域名，则从临时隧道日志解析（加长等待，cloudflared 常需 10–30 秒）
    if [ -z "$argodomain" ]; then
        if [ ! -f "${work_dir}/argo.log" ]; then
            restart_argo
            sleep 3
        fi
        local _argo_try
        for _argo_try in $(seq 1 15); do
            purple "第 ${_argo_try}/15 次尝试获取 ArgoDomain..."
            if [ -f "${work_dir}/argo.log" ]; then
                argodomain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" | head -1)
                [ -z "$argodomain" ] && argodomain=$(grep -oE '[[:alnum:]+\.-]+\.trycloudflare\.com' "${work_dir}/argo.log" 2>/dev/null | head -1)
            fi
            [ -n "$argodomain" ] && break
            # 中途重启一次 argo 提高成功率
            if [ "$_argo_try" -eq 5 ]; then
                yellow "仍未获取到域名，尝试重启 Argo 服务..."
                restart_argo >/dev/null 2>&1 || true
            fi
            sleep 2
        done
    fi

    local argo_domain_ok=1
    if [ -z "$argodomain" ]; then
        argo_domain_ok=0
        yellow "未能获取 Argo 临时域名（超时）。本次将跳过写入 Argo 节点，避免生成无效订阅。"
        yellow "请稍后在「Argo隧道管理」中重新获取临时域名，或配置固定隧道后再查看节点。"
        argodomain=""
    fi

    green "\nArgoDomain：${purple}$argodomain${re}\n"

    # 回读安装选项 / 密钥 / UUID（新 shell 调用 get_info 时内存变量为空）
    if [ -f "${work_dir}/install.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/install.conf" 2>/dev/null || true
    fi
    SKIP_DIRECT="${SKIP_DIRECT:-0}"
    if [ -z "$uuid" ]; then
        uuid=$(get_current_uuid | tr -d '\n\r')
    fi
    if [ -z "$public_key" ] && [ -f "${work_dir}/reality.keys" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/reality.keys" 2>/dev/null || true
        public_key="${PUBLIC_KEY:-$public_key}"
    fi
    if [ -z "$fingerprint" ] && [ -f "${work_dir}/cert.pem" ]; then
        fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" 2>/dev/null | cut -d'=' -f2 | sed 's/:/%3A/g')
    fi
    # 配置中无 Reality 入站则视为已跳过直连
    if [ -f "${conf_dir}/inbounds.json" ]; then
        if ! jq -e '.inbounds[] | select(.tag=="vless-reality")' "${conf_dir}/inbounds.json" >/dev/null 2>&1; then
            SKIP_DIRECT=1
        fi
    fi

    # 若未在安装流程中赋值，从配置读取端口
    if [ -z "$vless_port" ] || [ -z "$hy2_port" ] || [ -z "$tuic_port" ] || [ -z "$anytls_port" ]; then
        [ -z "$vless_port" ] && vless_port=$(jq -r '.inbounds[] | select(.tag=="vless-reality") | .listen_port // empty' "${conf_dir}/inbounds.json" 2>/dev/null)
        [ -z "$hy2_port" ] && hy2_port=$(jq -r '.inbounds[] | select(.tag=="hysteria2") | .listen_port // empty' "${conf_dir}/inbounds.json" 2>/dev/null)
        [ -z "$tuic_port" ] && tuic_port=$(jq -r '.inbounds[] | select(.tag=="tuic") | .listen_port // empty' "${conf_dir}/inbounds.json" 2>/dev/null)
        [ -z "$anytls_port" ] && anytls_port=$(jq -r '.inbounds[] | select(.tag=="anytls") | .listen_port // empty' "${conf_dir}/inbounds.json" 2>/dev/null)
    fi

    # Reality SNI 以配置为准（用户可能已修改伪装域名）
    reality_sni=$(jq -r '.inbounds[] | select(.tag=="vless-reality") | .tls.server_name // empty' "${conf_dir}/inbounds.json" 2>/dev/null)
    [ -z "$reality_sni" ] && reality_sni="www.iij.ad.jp"

    # 节点前缀处理
    # 自定义前缀优先；有自定义时不输出服务商
    prefix="${node_prefix:-$isp}"

    VMESS="{ \"v\": \"2\", \"ps\": \"${prefix}-argo-vmess\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": \"false\"}"

    extra_lines=""
    if [ -f "${client_dir}" ]; then
        # 只剔除本函数会重新生成的行；VLESS-WS 直连 / Socks5 / SS2022 等额外协议原样保留
        extra_lines=$(grep -vE '^(hysteria2|tuic|anytls|vmess|trojan)://|^vless://.*(flow=xtls-rprx-vision|path=(%2F|/)vless-argo)' "${client_dir}" | sed '/^[[:space:]]*$/d' || true)
    fi

    # 写入节点链接：直连协议按能力分别输出（无公钥时仍写 HY2/TUIC/WS）；Argo 三协议始终写入
    {
        if [ "${SKIP_DIRECT:-0}" != "1" ]; then
            if [ -n "$vless_port" ] && [ -n "$public_key" ]; then
                echo "vless://${uuid}@${server_ip}:${vless_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=firefox&pbk=${public_key}&type=tcp&headerType=none#${prefix}-vless-reality"
                echo ""
            elif [ -n "$vless_port" ] && [ -z "$public_key" ]; then
                yellow "缺少 Reality 公钥 (reality.keys)，已跳过 Reality 节点" >&2
            fi
            if [ -n "$hy2_port" ] && [ -n "$fingerprint" ]; then
                echo "hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none#${prefix}-hysteria2"
                echo ""
            fi
            if [ -n "$tuic_port" ]; then
                echo "tuic://${uuid}:${uuid}@${server_ip}:${tuic_port}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${prefix}-tuic"
                echo ""
            fi
            if [ -n "$anytls_port" ]; then
                echo "anytls://${uuid}@${server_ip}:${anytls_port}?insecure=1&sni=bing.com#${prefix}-anytls"
                echo ""
            fi
        fi
        if [ "${argo_domain_ok:-1}" = "1" ] && [ -n "$argodomain" ]; then
            echo "vmess://$(echo "$VMESS" | base64 -w0)"
            echo ""
            echo "vless://${uuid}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${argodomain}&fp=firefox&type=ws&host=${argodomain}&path=%2Fvless-argo%3Fed%3D2560#${prefix}-argo-vless"
            echo ""
            echo "trojan://${uuid}@${CFIP}:${CFPORT}?security=tls&sni=${argodomain}&fp=firefox&type=ws&host=${argodomain}&path=%2Ftrojan-argo%3Fed%3D2560#${prefix}-argo-trojan"
            echo ""
        else
            yellow "已跳过 Argo 节点写入（域名未就绪）" >&2
        fi
    } > "${work_dir}/url.txt"

    if [ -n "$extra_lines" ]; then
        echo "" >> "${work_dir}/url.txt"
        echo "$extra_lines" >> "${work_dir}/url.txt"
    fi

    save_direct_cache
    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < ${work_dir}/url.txt
    refresh_sub
    print_sub_urls
    yellow "\n温馨提醒:"
    yellow "节点默认优先 IPv4；若仍为 IPv6，可在「修改节点配置」中切换\n"
    red "若 hysteria2/tuic 不通，请将客户端「跳过证书验证」设为 true 或更换内核\n"
    yellow "节点已写入: ${work_dir}/url.txt  本地 base64: ${work_dir}/sub.txt\n"

    # 推送节点到 Telegram（若已启用）
    send_tg_nodes 2>/dev/null || true
}

