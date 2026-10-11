#!/bin/bash
# =========================
# 老王 sing-box 多协议安装脚本（个人修改版）— 模块化拆分入口
#
# 协议:
#   直连: vless-reality | hysteria2 | tuic | anytls
#   Argo: vmess-ws | vless-ws | trojan-ws（经 Nginx + cloudflared）
#   可选: vless-ws（无 TLS）| socks5 | shadowsocks-2022
#
# 版本: v2.6.1（模块化拆分）
# 基于单文件 sb.sh v2.6.1，按功能拆到 lib/
#
# 目录结构:
#   sb-v2.6.1.sh          本入口（source 全部 lib 后进入菜单/参数解析）
#   lib/common.sh         颜色、常量、b64、Alpine bash、Token 清理
#   lib/port.sh           端口占用检测、服务状态检查
#   lib/system.sh         包管理、IP/ISP、前缀、订阅令牌、safe_apply_conf
#   lib/firewall.sh       防火墙放行
#   lib/install.sh        安装 sing-box / 生成配置
#   lib/argo.sh           Argo 固定/临时隧道与服务单元
#   lib/nodes.sh          生成节点链接 get_info
#   lib/nginx.sh          Nginx 配置、启停、卸载、快捷方式
#   lib/telegram.sh       Telegram 推送与监控、自动安装/卸载
#   lib/config.sh         修改节点配置（端口/UUID/SNI/前缀等）
#   lib/manage.sh         sing-box/Argo/订阅/Nginx 管理菜单
#   lib/warp.sh           WARP 分流
#   lib/protocols.sh      额外协议增删（Socks5 / VLESS-WS / SS2022）
#   lib/menu_entry.sh     主菜单与 CLI 参数解析
# =========================

export LANG=en_US.UTF-8

# 脚本所在目录（支持软链）
_SB_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && pwd)"
_SB_LIB="${_SB_ROOT}/lib"

if [ ! -d "$_SB_LIB" ]; then
    echo -e "\e[1;91m错误: 找不到模块目录 ${_SB_LIB}\033[0m" >&2
    echo "请保持 sb-v2.6.1.sh 与 lib/ 同级目录。" >&2
    exit 1
fi

# 按依赖顺序加载
for _mod in \
    common \
    port \
    system \
    firewall \
    install \
    argo \
    nodes \
    nginx \
    telegram \
    config \
    manage \
    warp \
    protocols \
    menu_entry
do
    _f="${_SB_LIB}/${_mod}.sh"
    if [ ! -f "$_f" ]; then
        echo -e "\e[1;91m错误: 缺少模块 ${_f}\033[0m" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$_f"
done
unset _mod _f
