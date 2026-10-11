warp_manage() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; return
    fi

    clear
    route_file="${conf_dir}/route.json"
    outbound_file="${conf_dir}/outbounds.json"

    echo ""
    green "=== WARP 分流管理 ===\n"
    green "当前已启用的分流规则集:"
    jq -r '.route.rules[] | select(.rule_set != null) | .rule_set[]?' "$route_file" 2>/dev/null | sort -u | while read tag; do
        echo -e " - ${skyblue}$tag${re}"
    done || echo "  无"
    green "\n已添加的socks/http代理出站:"
    jq -r '.outbounds[] | select(.tag != "direct") | " - \(.tag) [\(.type)]"' "$outbound_file" 2>/dev/null || echo "  无"

    echo ""
    green "1. 设置分流服务 (未添加socks/http直接设置则使用WARP)"
    skyblue "----------------"
    red "2. 删除分流服务"
    skyblue "----------------"
    green "3. 添加 Socks5/HTTP 出站"
    skyblue "----------------"
    red "4. 删除 Socks5/HTTP 出站"
    skyblue "----------------"
    purple "0. 返回主菜单"
    skyblue "----------------"
    purple "00. 退出脚本"
    skyblue "----------------"
    reading "请输入选择: " choice
    case "${choice}" in
        1)  add_rule_menu ;;
        2)  delete_rule_menu ;;
        3)  add_socks5_proxy ;;
        4)  delete_socks5_proxy ;;
        0)  return ;;
        00) exit 0 ;;
        *)  red "无效选项"; sleep 1; warp_manage ;;
    esac
}

add_rule_menu() {
    clear
    green "选择要分流的服务:\n"
    green "1.  OpenAI"
    green "2.  Claude"
    green "3.  Gemini"
    green "4.  Google"
    green "5.  Tiktok"
    green "6.  Twitter"
    green "7.  YouTube"
    green "8.  Netflix"
    green "9.  Telegram"
    skyblue "----------------"
    green "10. 设置全局代理出站 (所有流量走指定代理)"
    green "11. 恢复服务器原IP出站 (所有流量走服务器ip)"
    skyblue "----------------"
    purple "0.  返回上级菜单"
    skyblue "----------------"
    reading "请输入选择: " add_choice
    case "$add_choice" in
        1)  rule_tag="openai"   ;;
        2)  rule_tag="claude"   ;;
        3)  rule_tag="gemini"   ;;
        4)  rule_tag="google"   ;;
        5)  rule_tag="tiktok"   ;;
        6)  rule_tag="twitter"  ;;
        7)  rule_tag="youtube"  ;;
        8)  rule_tag="netflix"  ;;
        9)  rule_tag="telegram" ;;
        10) set_global_outbound; return ;;
        11) restore_direct_outbound; return ;;
        0)  warp_manage; return ;;
        *)  red "无效选项"; sleep 1; add_rule_menu; return ;;
    esac

    if jq -e --arg tag "$rule_tag" \
        '.route.rules[] | select(.rule_set != null) | .rule_set[]? | select(. == $tag)' \
        "$route_file" > /dev/null 2>&1; then
        yellow "规则集 '${rule_tag}' 已启用。"; sleep 1; warp_manage; return
    fi

    jq 'if (.route.rules | length) == 1 and (.route.rules[0].rule_set | length) == 0
        then .route.rules = []
        else . end' \
        "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"

    local out_tags=($(jq -r '.outbounds[] | select(.tag != "direct") | .tag' "$outbound_file" 2>/dev/null))
    if [ ${#out_tags[@]} -eq 0 ]; then
        selected_out="wireguard-out"
        yellow "未找到其他出站，将自动使用 wireguard-out。"
    else
        echo ""
        green "请选择分流流量要走的出站:"
        for i in "${!out_tags[@]}"; do
            echo -e "  ${green}$((i+1)). ${skyblue}${out_tags[$i]}${re}"
        done
        reading "请输入编号: " out_choice
        if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
           [ "$out_choice" -lt 1 ] || \
           [ "$out_choice" -gt "${#out_tags[@]}" ]; then
            red "无效选择"; sleep 1; warp_manage; return
        fi
        selected_out="${out_tags[$((out_choice-1))]}"
    fi

    # 复用已有出站时：仅原地追加 rule_set，其它出站规则必须保留
    jq --arg tag "$rule_tag" --arg out "$selected_out" '
        if (.route.rules | length) == 0 then
            .route.rules = [{"rule_set": [$tag], "outbound": $out}]
        elif any(.route.rules[]; .outbound == $out) then
            .route.rules = [
                .route.rules[] |
                if .outbound == $out then
                    .rule_set = ((.rule_set // []) + [$tag] | unique)
                else
                    .
                end
            ]
        else
            .route.rules += [{"rule_set": [$tag], "outbound": $out}]
        end
    ' "$route_file" > "${route_file}.tmp"
    if ! safe_apply_conf "$route_file" "${route_file}.tmp" "分流规则(${rule_tag})"; then
        warp_manage; return
    fi

    restart_singbox
    green "'${rule_tag}' 已分流至出站 '${selected_out}'"
    sleep 1; warp_manage
}

# 设置全局代理出站
set_global_outbound() {
    # 检查是否存在 socks5/http 代理出站（排除 direct 和 wireguard-out）
    local proxy_tags
    proxy_tags=($(jq -r '.outbounds[] | select(.tag != "direct" and .tag != "wireguard-out") | .tag' \
        "$outbound_file" 2>/dev/null))

    if [ ${#proxy_tags[@]} -eq 0 ]; then
        yellow "\n当前没有可用的 socks5/http 代理出站。"
        yellow "请先返回 → 设置分流服务 → 添加 Socks5/HTTP 出站，再设置全局代理。\n"
        sleep 3; add_rule_menu; return
    fi

    echo ""
    green "请选择全局代理出站:"
    for i in "${!proxy_tags[@]}"; do
        echo -e "  ${green}$((i+1)). ${skyblue}${proxy_tags[$i]}${re}"
    done
    echo ""
    reading "请输入编号: " out_choice
    if [[ ! "$out_choice" =~ ^[0-9]+$ ]] || \
       [ "$out_choice" -lt 1 ] || \
       [ "$out_choice" -gt "${#proxy_tags[@]}" ]; then
        red "无效选择"; sleep 1; add_rule_menu; return
    fi
    local selected_out="${proxy_tags[$((out_choice-1))]}"

    # [修复] 原实现先 `del direct` 再校验，但 route.json 里每条 rule_set 都写死了
    # "download_detour":"direct"，direct 一旦被删掉，sing-box check 会因为
    # route 引用了不存在的 outbound 而失败，safe_apply_conf 随即自动回滚——
    # 也就是说这个"全局代理"功能此前大概率从未真正生效过，只是静默失败退出。
    #
    # 修复思路：不删除 direct（它仍要留着给 rule_set 下载用，属于控制面而非
    # 用户数据面），只把 route.final 指向所选代理，即可让所有未被其它规则
    # 匹配到的流量走全局代理，效果等价且不会破坏 rule_set 下载。
    if [ -f "$route_file" ]; then
        jq --arg out "$selected_out" '.route.final = $out' \
            "$route_file" > "${route_file}.tmp"
        if ! safe_apply_conf "$route_file" "${route_file}.tmp" "全局代理出站(route)"; then
            warp_manage; return
        fi
    else
        # 若 route 已不存在，写入最小可用配置
        cat > "$route_file" << EOF
{
  "route": {
    "rules": [],
    "final": "${selected_out}"
  }
}
EOF
    fi
    restart_singbox
    green "\n已设置全局代理出站：${purple}${selected_out}${re}"
    yellow "所有流量将通过 ${selected_out} 转发，如需恢复请选择「恢复服务器原IP出站」\n"
    sleep 2; warp_manage
}

# 恢复服务器原IP出站（恢复默认 route.json）
restore_direct_outbound() {
    yellow "\n正在恢复默认路由配置...\n"

    # 恢复 outbounds.json 中的 direct 出站（不存在则插入到数组最前面）
    if ! jq -e '.outbounds[] | select(.tag == "direct")' "$outbound_file" > /dev/null 2>&1; then
        jq '.outbounds = [{"type": "direct", "tag": "direct"}] + .outbounds' \
            "$outbound_file" > "${outbound_file}.tmp"
        if ! safe_apply_conf "$outbound_file" "${outbound_file}.tmp" "恢复 direct 出站"; then
            warp_manage; return
        fi
    fi

    # [修复] 原实现直接 `cat >` 覆盖 route.json / endpoints.json，没有走脚本
    # 自己定义的"备份→改→check→失败回滚"(safe_apply_conf)流程，一旦这段
    # 静态内容以后被改动引入变量插值出错，就没有校验和回滚兜底。
    # 这里改为先写临时文件，再统一走 safe_apply_conf 校验落地。

    # 恢复默认 route.json
    cat > "${route_file}.tmp" << 'EOF'
{
  "route": {
    "rule_set": [
      {"tag":"gemini","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/gemini.srs","download_detour":"direct"},
      {"tag":"claude","type":"remote","format":"binary","url":"https://main.ssss.nyc.mn/claude.srs","download_detour":"direct"},
      {"tag":"openai","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/openai.srs","download_detour":"direct"},
      {"tag":"tiktok","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/tiktok.srs","download_detour":"direct"},
      {"tag":"twitter","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/twitter.srs","download_detour":"direct"},
      {"tag":"google","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/google.srs","download_detour":"direct"},
      {"tag":"telegram","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/telegram.srs","download_detour":"direct"},
      {"tag":"youtube","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/youtube.srs","download_detour":"direct"},
      {"tag":"netflix","type":"remote","format":"binary","url":"https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo-lite/geosite/netflix.srs","download_detour":"direct"}
    ],
    "rules": [{"rule_set": []}],
    "final": "direct"
  }
}
EOF
    if ! safe_apply_conf "$route_file" "${route_file}.tmp" "恢复默认路由(route.json)"; then
        warp_manage; return
    fi

    # 恢复默认 endpoints.json
    cat > "${conf_dir}/endpoints.json.tmp" << EOF
{
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "wireguard-out",
      "mtu": 1280,
      "address": [
        "172.16.0.2/32",
        "2606:4700:110:8dfe:d141:69bb:6b80:925/128"
      ],
      "private_key": "YFYOAdbw1bKTHlNNi+aEjBM3BO7unuFC5rOkMRAz9XY=",
      "peers": [
        {
          "address": "engage.cloudflareclient.com",
          "port": 2408,
          "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [78, 135, 76]
        }
      ]
    }
  ]
}
EOF
    if ! safe_apply_conf "${conf_dir}/endpoints.json" "${conf_dir}/endpoints.json.tmp" "恢复默认出站端点(endpoints.json)"; then
        warp_manage; return
    fi

    restart_singbox
    green "\n已恢复服务器原IP出站，所有流量走 direct。\n"
    sleep 2; warp_manage
}

delete_rule_menu() {
    clear
    green "当前已启用的分流规则集:"
    jq -r '.route.rules[] | select(.rule_set != null) | .rule_set[]?' "$route_file" | nl -w2 -s'. '
    reading "\n输入要删除的规则名称或序号: " del_input
    if [[ "$del_input" =~ ^[0-9]+$ ]]; then
        tag=$(jq -r --arg idx "$del_input" '[.route.rules[] | select(.rule_set != null) | .rule_set[]] | .[(($idx | tonumber) - 1)]' "$route_file")
    else
        tag="$del_input"
    fi
    if [ -z "$tag" ] || [ "$tag" == "null" ]; then
        red "无效的选择"; sleep 1; warp_manage; return
    fi
    jq --arg tag "$tag" \
       'del(.route.rules[] | select(.rule_set != null) | .rule_set[] | select(. == $tag)) |
        .route.rules = [.route.rules[] | select(.rule_set != null and (.rule_set | length) > 0)]' \
       "$route_file" > "${route_file}.tmp"
    if ! safe_apply_conf "$route_file" "${route_file}.tmp" "删除分流规则(${tag})"; then
        warp_manage; return
    fi
    restart_singbox
    green "规则集 '${tag}' 已禁用。"
    sleep 1; warp_manage
}

add_socks5_proxy() {
    clear
    reading "请输入代理URL (支持socks://,socks5://,http:// 支持v2rayN导出的节点链接): " proxy_url
    [ -z "$proxy_url" ] && { red "输入为空！"; sleep 1; return; }

    # [v2.6.0] 原来用 grep -oP，busybox grep（Alpine 默认）不支持 -P，这里改为
    # sed 提取 "://" 之前的协议名，纯 POSIX 正则，Alpine/Debian/CentOS 通用。
    proto=$(printf '%s' "$proxy_url" | sed -n 's#^\([a-zA-Z0-9]*\)://.*#\1#p')
    [[ ! "$proto" =~ ^(socks5|socks|http)$ ]] && { red "不支持的协议"; sleep 2; return; }
    case "$proto" in
        socks|socks5) outbound_type="socks" ;;
        http)         outbound_type="http" ;;
    esac

    after_proto="${proxy_url#*://}"
    if [[ "$after_proto" == *"#"* ]]; then
        tag_from_url="${after_proto##*#}"; after_proto="${after_proto%%#*}"
    else
        tag_from_url=""
    fi

    if [[ "$after_proto" == *"@"* ]]; then
        user_pass="${after_proto%%@*}"; host_port="${after_proto##*@}"
    else
        user_pass=""; host_port="$after_proto"
    fi

    user=""; password=""
    if [ -n "$user_pass" ]; then
        decoded=$(echo "$user_pass" | base64 -d 2>/dev/null)
        if [ -n "$decoded" ] && [[ "$decoded" != "$user_pass" ]] && [[ "$decoded" == *":"* ]]; then
            user="${decoded%%:*}"; password="${decoded#*:}"
        elif [[ "$user_pass" == *":"* ]]; then
            user="${user_pass%%:*}"; password="${user_pass#*:}"
        else
            user="$user_pass"
        fi
    fi

    server="${host_port%%:*}"; port="${host_port##*:}"
    [ -z "$server" ] || [ -z "$port" ] && { red "格式错误：缺少ip或端口"; sleep 2; return; }

    [[ "$proto" == "socks" || "$proto" == "socks5" ]] && check_proto="socks5" || check_proto="$proto"

    # 判断是否为本地地址，本地地址跳过外部 API 检测，直接用 curl 测试
    local is_local=false
    if [[ "$server" == "127.0.0.1" || "$server" == "::1" || "$server" == "localhost" ]]; then
        is_local=true
    fi

    local proxy_auth=""
    [ -n "$user" ] && [ -n "$password" ] && proxy_auth="${user}:${password}@" || \
        { [ -n "$user" ] && proxy_auth="${user}@"; }

    if [ "$is_local" = true ]; then
        # 本地代理：直接用 curl 通过代理访问外网测试连通性
        yellow "检测到本地代理 ${check_proto}://${server}:${port}，跳过外部API检测，正在用curl测试连通性..."
        local curl_proxy_url="${check_proto}://${proxy_auth}${server}:${port}"
        local test_result
        test_result=$(curl -s --max-time 8 --proxy "$curl_proxy_url" "https://api.ip.sb/ip" 2>/dev/null)
        if [ -z "$test_result" ]; then
            yellow "警告：通过本地代理访问外网失败，请确认代理服务正在运行。"
            reading "是否仍然添加此代理？(y/n): " force_add
            [[ ! "$force_add" =~ ^[yY]$ ]] && { yellow "已取消"; sleep 1; return; }
        else
            green "本地代理可用，出口IP: $test_result"
        fi
    else
        # 远程代理：调用外部 API 检测
        yellow "正在测试代理 ${check_proto}://${server}:${port} ..."
        local api_response
        api_response=$(curl -s --max-time 8 -G \
            --data-urlencode "proxy=${check_proto}://${proxy_auth}${server}:${port}" \
            "https://check.socks5.cmliussss.net/check" 2>/dev/null)
        [ -z "$api_response" ] && { red "API 请求失败"; sleep 2; return; }

        success=$(echo "$api_response" | jq -r '.success')
        if [ "$success" != "true" ]; then
            error_msg=$(echo "$api_response" | jq -r '.error // "未知错误"')
            red "代理不可用: $error_msg"; sleep 2; return
        fi
        exit_ip=$(echo "$api_response" | jq -r '.exit.ip // empty')
        green "代理可用"
        [ -n "$exit_ip" ] && green "出口 IP: $exit_ip"
    fi

    [ -n "$tag_from_url" ] && tag="$tag_from_url" || tag="${outbound_type}-${server}-${port}"
    jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" >/dev/null 2>&1 \
        && { red "出站标签 '${tag}' 已存在"; sleep 2; return; }

    # 根据是否有账号密码，决定写入字段，避免空字符串导致 sing-box 报错
    if [ -n "$user" ] && [ -n "$password" ]; then
        jq --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
           --arg port "$port" --arg user "$user" --arg password "$password" \
           '.outbounds += [{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber),"username":$user,"password":$password}]' \
           "$outbound_file" > "${outbound_file}.tmp"
    else
        # 无账号密码：不写 username/password 字段
        jq --arg type "$outbound_type" --arg tag "$tag" --arg server "$server" \
           --arg port "$port" \
           '.outbounds += [{"type":$type,"tag":$tag,"server":$server,"server_port":($port|tonumber)}]' \
           "$outbound_file" > "${outbound_file}.tmp"
    fi
    if ! safe_apply_conf "$outbound_file" "${outbound_file}.tmp" "Socks5/HTTP出站(${tag})"; then
        sleep 2; return
    fi

    if jq -e '.route.rules | length > 0' "$route_file" >/dev/null 2>&1; then
        jq --arg tag "$tag" '.route.rules[].outbound = $tag' "$route_file" > "${route_file}.tmp"
        if safe_apply_conf "$route_file" "${route_file}.tmp" "切换分流出站为${tag}"; then
            yellow "已将现有分流规则出站切换为 '${tag}'。"
        fi
    fi

    restart_singbox
    green "\n${tag} 代理出站已添加\n"
    sleep 2; warp_manage
}

delete_socks5_proxy() {
    clear
    green "当前可用出站列表:"
    local out_list=$(jq -r '[.outbounds[] | select(.tag != "direct")] | to_entries | .[] | "\(.key+1). \(.value.tag) [\(.value.type)]"' "$outbound_file" 2>/dev/null)
    [ -z "$out_list" ] && { yellow "没有可删除的出站。"; sleep 2; return; }
    echo "$out_list"

    reading "输入要删除的出站编号或标签: " del_input
    if [[ "$del_input" =~ ^[0-9]+$ ]]; then
        tag=$(jq -r --arg idx "$del_input" '.outbounds | map(select(.tag != "direct")) | .[($idx | tonumber)-1].tag // empty' "$outbound_file")
        [ -z "$tag" ] && { red "编号无效！"; sleep 1; return; }
    else
        tag="$del_input"
        jq -e --arg tag "$tag" '.outbounds[] | select(.tag == $tag)' "$outbound_file" > /dev/null 2>&1 || { red "标签 '${tag}' 不存在！"; sleep 1; return; }
    fi
    [ "$tag" == "wireguard-out" ] && { red "wireguard-out 为系统内置，不可删除！"; sleep 2; return; }

    jq --arg tag "$tag" 'del(.outbounds[] | select(.tag == $tag))' "$outbound_file" > "${outbound_file}.tmp"
    if ! safe_apply_conf "$outbound_file" "${outbound_file}.tmp" "删除出站(${tag})"; then
        sleep 1; return
    fi
    jq --arg tag "$tag" '.route.rules = [.route.rules[] | select(.outbound != $tag)]' "$route_file" > "${route_file}.tmp"
    safe_apply_conf "$route_file" "${route_file}.tmp" "清理分流规则(${tag})" || true

    restart_singbox
    green "${tag} 代理出站已删除。"
    sleep 1
}

