# ============================================================
# 协议管理模块 - 增加/删除 socks5 / vless-ws直连(无TLS) / shadowsocks-2022
# ============================================================

# 检查指定 tag 是否已在 inbounds 中存在
proto_exists() {
    local tag="$1"
    jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "${conf_dir}/inbounds.json" > /dev/null 2>&1
}

# [v2.6.0] 只允许出现在协议标签里的字符（字母/数字/短横线），
# 防止 tag 被拼进 sed 正则时因为特殊字符（如 / . * [ ]）导致匹配错误甚至删错内容。
_safe_proto_tag() {
    local t="$1"
    [[ "$t" =~ ^[A-Za-z0-9_-]+$ ]]
}

# 更新订阅文件（[v2.6.0] 用 # 做 sed 定界符并显式校验 tag，避免特殊字符注入/语法出错）
remove_url_by_tag() {
    local tag="$1"
    if ! _safe_proto_tag "$tag"; then
        red "内部错误：非法的协议标签 '${tag}'，已跳过订阅清理"
        return 1
    fi
    sed -i "\\#^${tag}://#d" "$client_dir"
    sed -i '/^$/{N; /\n$/D}' "$client_dir"
}

update_sub() {
    refresh_sub "$client_dir"
}

# 通用：把新节点链接写入订阅文件并生效（供各 add_* 协议函数复用）
publish_node_url() {
    local url_line="$1"
    echo "" >> "${client_dir}"
    echo "${url_line}" >> "${client_dir}"
    update_sub
    restart_singbox
}

# 通用：按 tag 删除协议入站并从订阅中移除（供各 remove_* 协议函数复用）
remove_protocol() {
    local tag="$1" url_prefix="$2" label="$3"
    local inbounds_file="${conf_dir}/inbounds.json"

    if ! proto_exists "$tag"; then
        yellow "${label} 协议未添加，无需删除。"; sleep 1; return
    fi

    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' \
        "$inbounds_file" > "${inbounds_file}.tmp"
    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "删除${label}"; then
        sleep 1; return
    fi

    remove_url_by_tag "$url_prefix"
    update_sub
    restart_singbox
    green "\n${label} 协议已删除\n"
}

# ---- Socks5 入站 ----
add_socks5_inbound() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="socks5-in"

    if proto_exists "$tag"; then
        yellow "Socks5 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 获取当前UUID用于自动填充
    local current_uuid
    current_uuid=$(get_current_uuid | tr -d '\n\r')

    # 端口输入验证（含占用检测，复用通用端口选择函数）
    read_available_port "请输入 Socks5 监听端口 (回车随机生成): " sk_port
    green "socks5监听端口：${purple}${sk_port}${re}"

    reading "请输入 Socks5 用户名 (回车自动使用UUID前8位): " sk_user
    if [ -n "$sk_user" ]; then
        green "socks5用户名：${purple}${sk_user}${re}"
    else
        if [ -n "$current_uuid" ]; then
            sk_user=$(printf '%s' "${current_uuid:0:8}" | tr -d '\n\r')
            green "自动设置用户名: ${purple}${sk_user}${re}"
        else
            red "无法获取UUID，请手动输入用户名"
            reading "请输入 Socks5 用户名: " sk_user
            [ -z "$sk_user" ] && { red "用户名不能为空"; sleep 1; return; }
        fi
    fi

    reading "请输入 Socks5 密码 (回车自动使用UUID后12位): " sk_pass
    if [ -n "$sk_pass" ]; then
        green "socks5密码：${purple}${sk_pass}${re}"
    else
        if [ -n "$current_uuid" ]; then
            sk_pass=$(printf '%s' "${current_uuid: -12}" | tr -d '\n\r')
            green "自动设置密码: ${purple}${sk_pass}${re}"
        else
            red "无法获取UUID，请手动输入密码"
            reading "请输入 Socks5 密码: " sk_pass
            [ -z "$sk_pass" ] && { red "密码不能为空"; sleep 1; return; }
        fi
    fi

    jq --arg tag "$tag" \
       --argjson port "$sk_port" \
       --arg user "$sk_user" \
       --arg pass "$sk_pass" \
       '.inbounds += [{
           "type": "socks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"username": $user, "password": $pass}]
       }]' "$inbounds_file" > "${inbounds_file}.tmp"
    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "Socks5 入站"; then
        sleep 1; return
    fi

    allow_port ${sk_port}/tcp ${sk_port}/udp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    # [修复] 原来直接用裸 isp 命名，既不带 node_prefix 也没有协议后缀，
    # 和默认协议 ${prefix}-协议名 的命名风格不一致；这里对齐"改前缀"工具
    # (菜单6→9)已经假定的格式 ${prefix}-socks5。
    local prefix
    prefix=$(build_node_prefix "Socks5")

    local url_line="socks://$(printf '%s' "${sk_user}:${sk_pass}" | base64 -w0)@${server_ip}:${sk_port}#${prefix}-socks5"

    publish_node_url "$url_line"

    green "\nSocks5 协议已添加！"
    green "端口: ${purple}${sk_port}${re}"
    green "用户名: ${purple}${sk_user}${re}  ${green}密码:${re} ${purple}${sk_pass}${re}"
    green "节点链接: ${purple}${url_line}${re}\n"
}

remove_socks5_inbound() {
    remove_protocol "socks5-in" "socks" "Socks5"
}

# ---- VLESS-WS 直连（无 TLS）----
add_vless_ws_direct() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="vless-ws-direct"

    if proto_exists "$tag"; then
        yellow "VLESS-WS 直连（无 TLS）已存在，无需重复添加。"; sleep 1; return
    fi

    local current_uuid
    current_uuid=$(get_current_uuid)
    if [ -z "$current_uuid" ]; then
        red "无法获取当前UUID，请确认 sing-box 已正确安装并配置。"; sleep 2; return
    fi

    read_available_port "请输入 VLESS-WS 直连端口 (回车随机生成): " ws_port
    green "VLESS-WS 直连端口：${purple}${ws_port}${re}"

    jq --arg tag "$tag" \
       --argjson port "$ws_port" \
       --arg uid "$current_uuid" \
       '.inbounds += [{
           "type": "vless",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "users": [{"uuid": $uid}],
           "transport": {
               "type": "ws",
               "path": "/vless-ws"
           }
       }]' "$inbounds_file" > "${inbounds_file}.tmp"
    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "VLESS-WS 直连"; then
        sleep 1; return
    fi

    allow_port ${ws_port}/tcp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    # [修复] 对齐"改前缀"工具(菜单6→9)已假定的格式 ${prefix}-vless-ws
    local prefix
    prefix=$(build_node_prefix "VLESS-WS")

    local url_line="vless://${current_uuid}@${server_ip}:${ws_port}?encryption=none&security=none&type=ws&host=${server_ip}&path=%2Fvless-ws#${prefix}-vless-ws"

    publish_node_url "$url_line"

    green "\nVLESS-WS 直连（无 TLS）已添加！"
    green "UUID: ${purple}${current_uuid}${re}"
    green "端口: ${purple}${ws_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
}

remove_vless_ws_direct() {
    local tag="vless-ws-direct"
    local inbounds_file="${conf_dir}/inbounds.json"
    local label="VLESS-WS直连"

    if ! proto_exists "$tag"; then
        yellow "${label} 协议未添加，无需删除。"; sleep 1; return
    fi

    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' \
        "$inbounds_file" > "${inbounds_file}.tmp"
    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "删除${label}"; then
        sleep 1; return
    fi

    # 只删无 TLS 直连（path=/vless-ws），不动 Reality 与 Argo 的 vless://
    if [ -f "$client_dir" ]; then
        sed -i -E '/^vless:\/\// { /path=%2Fvless-ws|path=\/vless-ws/ d; }' "$client_dir"
        sed -i '/^$/{N; /\n$/D}' "$client_dir"
    fi
    update_sub
    restart_singbox
    green "\n${label} 协议已删除\n"
}

# ---- Shadowsocks-2022 ----
add_ss2022() {
    local inbounds_file="${conf_dir}/inbounds.json"
    local tag="shadowsocks-2022"

    if proto_exists "$tag"; then
        yellow "Shadowsocks-2022 协议已存在，无需重复添加。"; sleep 1; return
    fi

    # 端口输入验证（含占用检测，复用通用端口选择函数）
    read_available_port "请输入 Shadowsocks-2022 监听端口 (回车随机生成): " ss_port
    green "Shadowsocks-2022监听端口：${purple}${ss_port}${re}"

    echo ""
    green "请选择加密方式:"
    green "1. 2022-blake3-aes-128-gcm       (推荐，密钥16字节)"
    green "2. 2022-blake3-aes-256-gcm       (密钥32字节)"
    green "3. 2022-blake3-chacha20-poly1305 (密钥32字节)"
    reading "请输入选择 (默认1): " ss_method_choice
    local ss_method key_len
    case "${ss_method_choice}" in
        2) ss_method="2022-blake3-aes-256-gcm";        key_len=32 ;;
        3) ss_method="2022-blake3-chacha20-poly1305";   key_len=32 ;;
        *) ss_method="2022-blake3-aes-128-gcm";         key_len=16 ;;
    esac
    green "加密方式为：${purple}${ss_method}${re}"
    local ss_key
    ss_key=$(dd if=/dev/urandom bs=1 count=${key_len} 2>/dev/null | base64 -w0)

    jq --arg tag "$tag" \
       --argjson port "$ss_port" \
       --arg method "$ss_method" \
       --arg key "$ss_key" \
       '.inbounds += [{
           "type": "shadowsocks",
           "tag": $tag,
           "listen": "::",
           "listen_port": $port,
           "method": $method,
           "password": $key,
           "multiplex": {"enabled": true}
       }]' "$inbounds_file" > "${inbounds_file}.tmp"
    if ! safe_apply_conf "$inbounds_file" "${inbounds_file}.tmp" "Shadowsocks-2022"; then
        sleep 1; return
    fi

    allow_port ${ss_port}/tcp ${ss_port}/udp > /dev/null 2>&1

    local server_ip
    server_ip=$(get_realip)
    # [修复] 对齐"改前缀"工具(菜单6→9)已假定的格式 ${prefix}-ss2022
    local prefix
    prefix=$(build_node_prefix "SS2022")

    local ss_userinfo
    ss_userinfo=$(printf '%s:%s' "${ss_method}" "${ss_key}" | base64 -w0)
    local url_line="ss://${ss_userinfo}@${server_ip}:${ss_port}#${prefix}-ss2022"

    publish_node_url "$url_line"

    green "\nShadowsocks-2022 协议已添加！"
    green "加密方式: ${purple}${ss_method}${re}"
    green "密钥(base64): ${purple}${ss_key}${re}"
    green "端口: ${purple}${ss_port}${re}"
    green "节点链接:\n${purple}${url_line}${re}\n"
}

remove_ss2022() {
    remove_protocol "shadowsocks-2022" "ss" "Shadowsocks-2022"
}

# 显示当前已启用的额外协议状态

show_extra_proto_status() {
    local inbounds_file="${conf_dir}/inbounds.json"
    echo ""
    green "--- 额外协议状态 ---"

    # Socks5
    if jq -e '.inbounds[] | select(.tag == "socks5-in")' "$inbounds_file" > /dev/null 2>&1; then
        local sk_port sk_user
        sk_port=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .listen_port' "$inbounds_file")
        sk_user=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].username // "N/A"' "$inbounds_file")
        sk_pass=$(jq -r '.inbounds[] | select(.tag == "socks5-in") | .users[0].password // "N/A"' "$inbounds_file")
        echo -e " Socks5:           ${green}已启用${re} (端口: ${skyblue}${sk_port}${re}, 用户名: ${skyblue}${sk_user}${re}，密码：${skyblue}${sk_pass}${re})"
    else
        echo -e " Socks5:           ${yellow}未启用${re}"
    fi

    # VLESS-WS 直连（无 TLS）
    if jq -e '.inbounds[] | select(.tag == "vless-ws-direct")' "$inbounds_file" > /dev/null 2>&1; then
        ws_port=$(jq -r '.inbounds[] | select(.tag == "vless-ws-direct") | .listen_port' "$inbounds_file")
        ws_uuid=$(jq -r '.inbounds[] | select(.tag == "vless-ws-direct") | .users[0].uuid // "N/A"' "$inbounds_file")
        echo -e " VLESS-WS直连:     ${green}已启用${re} (端口: ${skyblue}${ws_port}${re}, UUID: ${skyblue}${ws_uuid}${re})"
    else
        echo -e " VLESS-WS直连:     ${yellow}未启用${re}"
    fi

    # Shadowsocks-2022
    if jq -e '.inbounds[] | select(.tag == "shadowsocks-2022")' "$inbounds_file" > /dev/null 2>&1; then
        local ss_port ss_method
        ss_port=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .listen_port' "$inbounds_file")
        ss_method=$(jq -r '.inbounds[] | select(.tag == "shadowsocks-2022") | .method' "$inbounds_file")
        echo -e " Shadowsocks-2022: ${green}已启用${re} (端口: ${skyblue}${ss_port}${re}, 加密: ${skyblue}${ss_method}${re})"
    else
        echo -e " Shadowsocks-2022: ${yellow}未启用${re}"
    fi

    echo ""
}

# 协议管理主菜单
manage_protocols() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; return
    fi

    clear; echo ""
    green "=== 协议管理 (增加/删除) ===\n"
    show_extra_proto_status

    green "--- Socks5 协议 ---"
    green "1. 添加 Socks5 协议"
    red   "2. 删除 Socks5 协议"
    skyblue "----------------"
    green "--- VLESS-WS 直连（无 TLS）---"
    green "3. 添加 VLESS-WS 直连（无 TLS）"
    red   "4. 删除 VLESS-WS 直连（无 TLS）"
    skyblue "----------------"
    green "--- Shadowsocks-2022 协议 ---"
    green "5. 添加 Shadowsocks-2022 协议"
    red   "6. 删除 Shadowsocks-2022 协议"
    skyblue "----------------"
    purple "0. 返回主菜单"
    skyblue "----------------"
    reading "请输入选择: " proto_choice
    echo ""
    case "${proto_choice}" in
        1) add_socks5_inbound ;;
        2) remove_socks5_inbound ;;
        3) add_vless_ws_direct ;;
        4) remove_vless_ws_direct ;;
        5) add_ss2022 ;;
        6) remove_ss2022 ;;
        0) return ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回协议管理菜单...\033[0m\n'
    manage_protocols
}

# 主菜单
