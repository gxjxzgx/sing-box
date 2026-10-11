menu() {
    singbox_status=$(check_singbox 2>/dev/null)
    nginx_status=$(check_nginx 2>/dev/null)
    argo_status=$(check_argo 2>/dev/null)

    clear; echo ""
    green "Telegram群组: ${purple}https://t.me/eooceu${re}"
    green "YouTube频道: ${purple}https://youtube.com/@eooce${re}"
    green "Github地址: ${purple}https://github.com/eooce/sing-box${re}\n"
    purple "=== sing-box 多协议安装脚本（个人修改版） ===\n"
    purple "  Argo 状态: ${argo_status}"
    purple " Nginx 状态: ${nginx_status}"
    purple "sing-box 状态: ${singbox_status}\n"
    yellow "节点优先 IPv4 | 官方优先(Alpine→musl) | 独立订阅端口 | 固定隧道\n"
    skyblue "================"
    green "1. 安装 sing-box"
    red   "2. 卸载 sing-box"
    skyblue "================"
    green "3. sing-box 管理"
    green "4. Argo 隧道管理"
    skyblue "================"
    green "5. 查看节点信息 / 订阅链接"
    green "6. 修改节点配置"
    green "7. 管理节点订阅"
    green "8. WARP 分流管理"
    skyblue "================"
    green "9. 增加 / 删除协议"
    green "10. Telegram 通知设置"
    purple "11. SSH 综合工具箱"
    skyblue "================"
    red "0. 退出脚本"
    skyblue "================"
}

# 捕获 Ctrl+C
trap 'red "\n强制退出"; exit' INT

# ---- 参数解析入口 ----
case "$1" in
    -i | --install)
        if [ "${2:-}" = "--force" ] || [ "${2:-}" = "-f" ]; then
            auto_install 1
        else
            auto_install 0
        fi
        exit $?
        ;;
    -u | --uninstall)
        auto_uninstall
        exit 0
        ;;
    -c | --check)
        check_nodes
        exit 0
        ;;
    -r | --restart)
        get_quick_tunnel
        change_argo_domain
        exit 0
        ;;
    -h | --help)
        echo ""
        green "用法: [sb或脚本] [参数], 示例: sb -c"
        echo ""
        green "  -i, --install          无交互安装 sing-box（已安装则退出码 1）"
        green "  -i --force, -i -f     强制重装（先卸载再安装）"
        green "  -c, --check            查看节点信息（url.txt）"
        green "  -r, --restart          重新获取 Argo 临时隧道并更新节点"
        green "  -u, --uninstall        无交互卸载 sing-box（含 nginx）"
        green "  -h, --help             显示此帮助信息"
        echo ""
        green "  不带参数          进入交互式主菜单"
        echo ""
        yellow "修改版: 官方优先(Alpine→musl) | 节点优先 IPv4 | 独立订阅端口 SUB_PORT"
        yellow "支持环境变量: PORT / ARGO_PORT / ARGO_DOMAIN / ARGO_TOKEN / CFIP / CFPORT / uuid / node_prefix / BOT_TOKEN / CHAT_ID"
        yellow "安装时交互输入: 直连起始端口、Argo 入口端口、隧道类型、固定隧道域名、隧道令牌"
        echo ""
        exit 0
        ;;
    "")
        # 无参数：进入交互式主菜单
        while true; do
            menu
            reading "请输入选择(0-11): " choice
            echo ""
            need_pause=true
            case "${choice}" in
                1)
                    # 以二进制是否存在判断是否已安装（不依赖运行状态）
                    if [ -x "${work_dir}/sing-box" ]; then
                        yellow "sing-box 已经安装！如需重装请先卸载。\n"
                    else
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
                            echo "Unsupported init system"; exit 1
                        fi
                        sleep 3
                        get_info
                        add_nginx_conf
                        create_shortcut
                        # 安装完成后明确重启 Nginx
                        if command_exists nginx; then
                            if restart_nginx; then
                                green "Nginx 已重启完成"
                            else
                                red "Nginx 重启未成功，请执行: nginx -t && systemctl status nginx.service"
                            fi
                        fi
                    fi
                    ;;
                2)  uninstall_singbox;  need_pause=false ;;
                3)  manage_singbox;     need_pause=false ;;
                4)  manage_argo;        need_pause=true ;;
                5)
                    check_nodes
                    need_pause=true
                    ;;
                6)  change_config;      need_pause=true ;;
                7)
                    menu_sub_manage
                    need_pause=false
                    ;;
                8)  warp_manage;        need_pause=false ;;
                9)  manage_protocols;   need_pause=false ;;
                10) setup_telegram;     need_pause=false ;;
                11)
                    clear
                    bash <(curl -Ls ssh_tool.eooce.com)
                    need_pause=false
                    ;;
                0)  exit 0 ;;
                *)
                    red "无效的选项，请输入 0-11"
                    need_pause=true
                    ;;
            esac
            [ "$need_pause" = true ] && read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
        done
        ;;
    *)
        red "未知参数: $1"
        echo ""
        green "用法: sb [-i|-u|-c|-r|-h]，首次安装可用: bash 脚本 -i（可带环境变量）"
        exit 1
        ;;
esac
