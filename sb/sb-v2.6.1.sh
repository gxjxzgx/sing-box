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

# 模块列表（按依赖顺序）
_SB_MODS="common port system firewall install argo nodes nginx telegram config manage warp protocols menu_entry"

# 远程模块地址（脚本放在仓库的哪个目录，这里就写哪个目录；可用环境变量 SB_BASE_URL 覆盖）
_SB_BASE_URL="${SB_BASE_URL:-https://raw.githubusercontent.com/gxjxzgx/sing-box/refs/heads/main/sb}"

# 脚本所在目录（支持软链）
# 通过 bash <(curl ...) 运行时，BASH_SOURCE 是 /dev/fd/NN 管道，旁边没有 lib/，
# 此时自动把 lib/*.sh 下载到临时目录，加载完立即删除。
_SB_SRC="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
_SB_CLEAN=0
if [ -f "$_SB_SRC" ] && [ -d "$(dirname "$_SB_SRC")/lib" ]; then
    _SB_ROOT="$(dirname "$_SB_SRC")"
    _SB_LIB="${_SB_ROOT}/lib"
else
    if ! command -v curl >/dev/null 2>&1; then
        echo -e "\e[1;91m错误: 未找到 curl，无法在线获取模块\033[0m" >&2
        echo "请安装 curl，或下载完整压缩包后保持 sb-v2.6.1.sh 与 lib/ 同级目录运行。" >&2
        exit 1
    fi
    _SB_LIB="$(mktemp -d 2>/dev/null)" || { echo "错误: 无法创建临时目录" >&2; exit 1; }
    _SB_CLEAN=1
    for _mod in $_SB_MODS; do
        if ! curl -fsSL --retry 2 -m 30 "${_SB_BASE_URL}/lib/${_mod}.sh" -o "${_SB_LIB}/${_mod}.sh"; then
            echo -e "\e[1;91m错误: 下载模块失败 ${_SB_BASE_URL}/lib/${_mod}.sh\033[0m" >&2
            echo "请确认仓库里 lib/ 与本脚本同目录，或用 SB_BASE_URL=... 指定模块所在目录。" >&2
            rm -rf "$_SB_LIB"
            exit 1
        fi
    done
fi

# 在线模式下，无论脚本如何退出（菜单 exit / 参数执行完 / Ctrl+C）都清理临时模块目录
if [ "$_SB_CLEAN" = 1 ]; then
    trap 'rm -rf "$_SB_LIB"' EXIT
fi

# 按依赖顺序加载
for _mod in $_SB_MODS
do
    _f="${_SB_LIB}/${_mod}.sh"
    if [ ! -f "$_f" ]; then
        echo -e "\e[1;91m错误: 缺少模块 ${_f}\033[0m" >&2
        [ "$_SB_CLEAN" = 1 ] && rm -rf "$_SB_LIB"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$_f"
done
unset _mod _f _SB_SRC
