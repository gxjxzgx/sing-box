#!/bin/bash

# =========================
# 老王 sing-box 多协议安装脚本（个人修改版）
#
# 协议:
#   直连: vless-reality | hysteria2 | tuic | anytls
#   Argo: vmess-ws | vless-ws | trojan-ws（经 Nginx + cloudflared）
#   可选: vless-ws（无 TLS）| socks5 | shadowsocks-2022
#
# 端口规划:
#   直连  Reality=vless_port  HY2=+1  TUIC=+2  AnyTLS=+3
#   Argo  ARGO_PORT 为 Nginx 对外入口；内部 WS 为 ARGO_PORT+10~+12（仅本机）
#   订阅  独立端口 SUB_PORT（默认可改）+ Argo 入口路径 /s/<token>
#         直连: http://IP:SUB_PORT/s/<token>
#         Argo: https://域名/s/<token>
#
# 主要特性:
#   1. sing-box / cloudflared 优先官方下载，失败回退镜像
#      Alpine/musl 优先官方 -musl 构建
#   2. 节点地址优先 IPv4；支持菜单切换 IPv4/IPv6（同步 host=）
#   3. 端口占用用 port_really_in_use 判定，减少 TIME_WAIT 误报
#   4. Argo 固定隧道 / 临时隧道；Token 自动剥离 cloudflared 安装前缀
#   5. 安装可选跳过直连协议（仅 Argo）；SKIP_DIRECT / 密钥持久化
#   6. HTTP 订阅：独立端口 SUB_PORT + Argo 路径 /s/<token>；主菜单5查看、7管理
#   7. 支持 WARP 分流、Telegram 推送、额外协议增删
#
# 基于: eooce/sing-box
# 修改日期: 2026.9.27
# 版本: v2.6.0（全面优化版）
#   v2.5.9~19 功能累积（端口/订阅/小磁盘/菜单/直连第4协议等）
#   v2.6.0   1) 协议增删/WARP分流类函数统一走"备份→改配置→sing-box check→失败回滚"
#            2) add_socks5_proxy 的协议解析改用纯 POSIX 正则，去掉 grep -P（Alpine busybox 兼容）
#            3) Alpine 下自动 apk add bash（脚本自身用到大量 bash 专属语法，不能假设已装）
#            4) remove_url_by_tag 的 sed 定界符改为 # 并对 tag 做安全校验，避免特殊字符注入
#            5) nginx.conf / mime.types 备份文件只保留最近一份，不再无限堆积
#            6) sing-box 最新版本获取增加 GitHub API 限流提示与本地缓存版本号 fallback
# =========================
export LANG=en_US.UTF-8
# 定义颜色
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue() { echo -e "\e[1;36m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

# 定义常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
# 仅当环境变量 PORT 存在时预设，否则留给交互输入
if [ -n "$PORT" ]; then
    export vless_port="$PORT"
else
    export vless_port=""
fi
export CFIP=${CFIP:-'cdns.doon.eu.org'}
export ARGO_PORT=${ARGO_PORT:-'8001'}
export CFPORT=${CFPORT:-'443'}

# 检查是否为root下运行
[[ $EUID -ne 0 ]] && red "请在root用户下运行脚本，可输入 sudo -i 回车切换到root用户" && exit 1

# 检查命令是否存在函数
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ---------- [优化新增] 跨平台 base64 解码封装 ----------
# GNU coreutils 的 base64 支持长选项 --decode；Alpine 默认的 busybox base64
# 只认短选项 -d，不认 --decode（--decode 在 busybox 下会解析失败/静默无输出）。
# 脚本此前在改 UUID / 改 Argo 域名 / 改优选IP 三处都只写了 --decode，
# 导致 Alpine 上这几个操作会让 vmess 节点悄悄更新失败而不报错。
# 统一用这个函数：优先 -d（两种实现都支持标准短选项），失败再退回 --decode。
b64_decode() {
    base64 -d 2>/dev/null || base64 --decode 2>/dev/null
}

# ---------- [v2.6.0新增] Alpine 下确保 bash 已安装 ----------
# 脚本大量使用数组、local、printf %q 等 bash 专属语法，busybox ash 无法解释。
# 若通过 `apk add bash` 之前的裸 Alpine 直接跑本脚本，这里补装一次。
ensure_bash_on_alpine() {
    if command_exists apk && [ -z "${BASH_VERSION:-}" ]; then
        # 理论上走到这里说明当前解释器不是 bash，但脚本已声明 #!/bin/bash，
        # 正常情况下不会发生；此判断主要防御被 sh 强行调用的场景。
        apk add --no-cache bash >/dev/null 2>&1 || true
    elif command_exists apk && ! command_exists bash; then
        yellow "检测到 Alpine 且未安装 bash，正在安装..."
        apk add --no-cache bash >/dev/null 2>&1
        if command_exists bash; then
            green "bash 安装成功"
        else
            red "bash 安装失败，脚本后续可能无法正常运行，请手动执行: apk add bash"
        fi
    fi
}
ensure_bash_on_alpine

# 自动清理 Argo 隧道令牌：去除常见前缀，仅保留有效 Token（通常以 eyJ 开头）
# 支持粘贴完整命令，例如：
#   sudo cloudflared service install eyJhbGciOi...
#   cloudflared.exe service install eyJhbGciOi...
#   cloudflared tunnel run --token eyJhbGciOi...
clean_argo_token() {
    local raw="$1"
    [ -z "$raw" ] && { echo ""; return; }

    # 若为 JSON 凭证（含 TunnelSecret），原样返回
    if echo "$raw" | grep -q 'TunnelSecret'; then
        printf '%s' "$raw"
        return
    fi

    # 优先提取以 eyJ 开头的 JWT/Token 片段
    local token
    token=$(printf '%s' "$raw" | grep -oE 'eyJ[A-Za-z0-9+/=._-]+' | head -1)

    if [ -n "$token" ]; then
        # 若提取结果与原始输入不同，说明发生了前缀剥离
        if [ "$token" != "$raw" ]; then
            yellow "已自动去除命令前缀，仅保留有效令牌 (eyJ...)" >&2
        fi
        printf '%s' "$token"
        return
    fi

    # 未匹配到 eyJ：尝试去掉常见 cloudflared install 前缀后返回剩余部分
    token=$(printf '%s' "$raw" | sed -E \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//' \
        -e 's/.*(cloudflared(\.exe)?[[:space:]]+service[[:space:]]+install[[:space:]]+)//' \
        -e 's/.*(cloudflared(\.exe)?[[:space:]]+tunnel[[:space:]]+run[[:space:]]+--token[[:space:]]+)//' \
        -e 's/^sudo[[:space:]]+//' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//')
    printf '%s' "$token"
}

# 检测端口是否已被占用（tcp/udp 监听）
# 检测端口是否已被占用
# 以实际 bind 为准；可用 SKIP_PORT_CHECK=1 跳过检测（应急）
port_in_use() {
    local port="$1"
    [ -z "$port" ] && return 1
    # 应急：跳过检测（确认无冲突时使用）
    [ "${SKIP_PORT_CHECK:-0}" = "1" ] && return 1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi

    local py=""
    command_exists python3 && py=python3
    [ -z "$py" ] && command_exists python && py=python

    # 方法1：TCP + UDP 实际 bind。仅 EADDRINUSE 视为占用
    if [ -n "$py" ]; then
        $py -c "
import socket, sys, errno
p = int(sys.argv[1])
in_use = False
eaddr = (getattr(errno, 'EADDRINUSE', 98), getattr(errno, 'WSAEADDRINUSE', 10048))
for fam, addr in ((socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')):
    for sock_type in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        try:
            s = socket.socket(fam, sock_type)
            try:
                if fam == socket.AF_INET6:
                    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            except Exception:
                pass
            s.bind((addr, p))
            s.close()
        except OSError as e:
            if e.errno in eaddr:
                in_use = True
                break
        except Exception:
            pass
    if in_use:
        break
sys.exit(0 if in_use else 1)
" "$port" 2>/dev/null
        local py_rc=$?
        if [ "$py_rc" -eq 0 ]; then
            return 0
        elif [ "$py_rc" -eq 1 ]; then
            return 1
        fi
    fi

    # 方法2：/proc/net — TCP 仅 LISTEN(0A)；UDP 有记录即占用（无 LISTEN 状态位）
    local hex
    hex=$(printf '%04X' "$port" 2>/dev/null) || hex=""
    if [ -n "$hex" ] && [ -r /proc/net/tcp ]; then
        if awk -v h="$hex" '
            NR > 1 {
                n = split($2, a, ":")
                if (n >= 2 && toupper(a[n]) == h && toupper($4) == "0A") exit 0
            }
            END { exit 1 }
        ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
            return 0
        fi
        if [ -r /proc/net/udp ] || [ -r /proc/net/udp6 ]; then
            if awk -v h="$hex" '
                NR > 1 {
                    n = split($2, a, ":")
                    if (n >= 2 && toupper(a[n]) == h) exit 0
                }
                END { exit 1 }
            ' /proc/net/udp /proc/net/udp6 2>/dev/null; then
                return 0
            fi
        fi
        return 1
    fi

    # 方法3：ss 查 TCP LISTEN + UDP
    if command_exists ss; then
        if ss -tln 2>/dev/null | grep LISTEN | grep -qE "[:.]${port}([^0-9]|$)"; then
            return 0
        fi
        if ss -uln 2>/dev/null | grep -qE "[:.]${port}([^0-9]|$)"; then
            return 0
        fi
    fi

    return 1
}

port_holder_info() {
    local port="$1"
    [ -z "$port" ] && return 0
    if command_exists ss; then
        ss -lntp 2>/dev/null | grep -E ":${port}\\b" || true
        ss -lnup 2>/dev/null | grep -E ":${port}\\b" || true
    elif command_exists lsof; then
        lsof -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
        lsof -iUDP:"${port}" 2>/dev/null || true
    fi
}

# 统一的"真实冲突"判断：port_in_use 为真时，再用 ss/lsof 交叉验证是否有实际监听进程。
# 有实际监听进程才算真冲突；查不到则视为 TIME_WAIT 等误报，不阻断安装。
# 脚本内所有端口冲突检测（直连端口、Argo端口等）统一走此函数，避免检测标准不一致。
# 返回: 0=真实冲突  1=空闲  2=误报（port_in_use为真但查无实际监听进程）
port_really_in_use() {
    local port="$1"
    port_in_use "$port" || return 1
    local holder
    holder=$(port_holder_info "$port" 2>/dev/null || true)
    if [ -n "$holder" ]; then
        return 0
    else
        return 2
    fi
}

# 交互获取可用端口；参数: 提示语 默认空则随机
# 返回值写入变量名（第三个参数，默认 new_port）
read_available_port() {
    local prompt="$1"
    local varname="${2:-new_port}"
    local port=""
    while true; do
        reading "$prompt" port
        if [ -z "$port" ]; then
            port=$(shuf -i 10000-65000 -n 1)
        fi
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            red "端口必须为 1-65535 的数字"
            continue
        fi
        port_really_in_use "$port"
        local _rc=$?
        if [ "$_rc" -eq 0 ]; then
            red "端口 ${port} 已被占用，请重新输入"
            continue
        elif [ "$_rc" -eq 2 ]; then
            yellow "端口 ${port} 检测曾报占用，但系统无实际监听进程，按空闲处理"
        fi
        green "端口 ${purple}${port}${re} 可用"
        eval "$varname=\"$port\""
        break
    done
}

# 检查服务状态通用函数
check_service() {
    local service_name=$1
    local service_file=$2

    [[ ! -f "${service_file}" ]] && { red "not installed"; return 2; }

    if command_exists apk; then
        if rc-service "${service_name}" status 2>/dev/null | grep -q "started"; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    else
        if systemctl is-active "${service_name}" 2>/dev/null | grep -q "^active$"; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    fi
}

# 检查sing-box状态
check_singbox() {
    check_service "sing-box" "${work_dir}/${server_name}"
}

# 检查argo状态
check_argo() {
    check_service "argo" "${work_dir}/argo"
}

# 检查nginx状态
check_nginx() {
    command_exists nginx || { red "not installed"; return 2; }
    # OpenRC/systemd 状态 + 二进制直启的 master 均视为 running
    if command_exists rc-service && rc-service nginx status 2>/dev/null | grep -q started; then
        green "running"; return 0
    fi
    if command_exists systemctl && systemctl is-active --quiet nginx 2>/dev/null; then
        green "running"; return 0
    fi
    if pgrep -f 'nginx: master process' >/dev/null 2>&1 || pgrep -x nginx >/dev/null 2>&1; then
        green "running"; return 0
    fi
    yellow "not running"; return 1
}

# 根据系统类型安装、卸载依赖
manage_packages() {
    if [ $# -lt 2 ]; then
        red "Unspecified package name or action"
        return 1
    fi

    action=$1
    shift

    # 首次安装仅刷新软件源索引，不做全系统 upgrade（避免生产机被动升级内核等）
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在刷新软件源索引...\n"
        if command_exists apt; then
            DEBIAN_FRONTEND=noninteractive apt update -y
        elif command_exists dnf; then
            dnf check-update -y || true
        elif command_exists yum; then
            yum check-update -y || true
        elif command_exists apk; then
            apk update
        else
            yellow "Unknown system!\n"
        fi
        green "软件源索引已刷新\n"
    fi

    for package in "$@"; do
        if [ "$action" == "install" ]; then
            if command_exists "$package"; then
                green "${package} already installed"
                continue
            fi
            yellow "正在安装 ${package}..."
            if command_exists apt; then
                DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then
                dnf install -y "$package"
            elif command_exists yum; then
                yum install -y "$package"
            elif command_exists apk; then
                apk add "$package"
            else
                red "Unknown system!"
                return 1
            fi
        elif [ "$action" == "uninstall" ]; then
            if ! command_exists "$package"; then
                yellow "${package} is not installed"
                continue
            fi
            yellow "正在卸载 ${package}..."
            if command_exists apt; then
                apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then
                dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then
                yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then
                apk del "$package"
            else
                red "Unknown system!"
                return 1
            fi
        else
            red "Unknown action: $action"
            return 1
        fi
    done

    return 0
}

# 获取ip
get_realip() {
    # 优先返回 IPv4（节点链接默认用 IPv4）
    # 仅当无可用 IPv4，或 IPv4 为 WARP/特殊线路不可直连时，才回退到 IPv6
    local ip v6 org
    ip=$(curl -4 -sm 2 ip.sb 2>/dev/null)
    ipv6() { curl -6 -sm 2 ip.sb 2>/dev/null; }

    if [ -n "$ip" ]; then
        # 检测 IPv4 是否为 Cloudflare WARP 等不可作直连地址的 IP
        org=$(curl -4 -sm 2 http://ipinfo.io/org 2>/dev/null)
        if echo "$org" | grep -qE 'Cloudflare|UnReal|AEZA|Andrei'; then
            # IPv4 不可用，尝试 IPv6
            v6=$(ipv6)
            if [ -n "$v6" ]; then
                echo "[$v6]"
            else
                echo "$ip"   # 没有 IPv6 时仍返回 IPv4
            fi
        else
            echo "$ip"       # 正常 IPv4，优先使用
        fi
    else
        # 无 IPv4，使用 IPv6
        v6=$(ipv6)
        if [ -n "$v6" ]; then
            echo "[$v6]"
        else
            echo "127.0.0.1"
        fi
    fi
}


# 获取 ISP 信息（国家-运营商）
get_isp() {
    local fallback="${1:-node}"
    local result
    result=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" 2>/dev/null | tr -d '\n' | \
        awk -F\" '{c="";i="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="isp")i=$(x+2)};if(c&&i)print c"-"i}' | \
        sed 's/ /_/g')
    if [ -z "$result" ]; then
        result=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://ipapi.co/json" 2>/dev/null | tr -d '\n' | \
            awk -F\" '{c="";o="";for(x=1;x<=NF;x++){if($x=="country_code")c=$(x+2);if($x=="org")o=$(x+2)};if(c&&o)print c"-"o}' | \
            sed 's/ /_/g')
    fi
    echo "${result:-$fallback}"
}

# [优化新增] 统一节点前缀计算
# 默认安装的协议（Reality/HY2/TUIC/AnyTLS/Argo三协议）都用 ${node_prefix}-${isp}
# 拼出前缀，但 manage_protocols 里手动新增的 Socks5 / VLESS-WS直连 / SS2022
# 三个协议此前各自单独取 isp 直接拼节点名，完全没带用户设置的 node_prefix，
# 也没有协议后缀，风格和默认协议不一致。这里抽成统一函数，谁调用都一样。
build_node_prefix() {
    local fallback="${1:-node}"
    local isp
    isp=$(get_isp "$fallback")
    if [ -z "${node_prefix:-}" ]; then
        echo "$isp"
    else
        echo "${node_prefix}-${isp}"
    fi
}

# 刷新本地 sub.txt（base64 节点列表，兼容 GNU / BusyBox base64；HTTP 由 Nginx /s/<token> 提供）
refresh_sub() {
    local src="${1:-$client_dir}"
    [ -f "$src" ] || return 1
    if base64 -w0 "$src" > "${work_dir}/sub.txt" 2>/dev/null; then
        :
    else
        base64 "$src" | tr -d '\n\r' > "${work_dir}/sub.txt"
    fi
    chmod 644 "${work_dir}/sub.txt" 2>/dev/null || true
}

# ---------- [v2.6.0新增] sing-box config 变更的统一"校验+回滚"封装 ----------
# 用法: apply_json_change <jq命令字符串数组...> 由调用方在外部完成 jq 写 tmp 文件，
# 这里只负责: 备份原文件 -> mv tmp 覆盖 -> sing-box check -> 失败则回滚并返回非0。
# 所有会修改 inbounds.json / route.json / outbounds.json 并且随后要 restart_singbox
# 的地方，统一改为调用这个函数，避免"改坏配置但没有回滚"的问题。
safe_apply_conf() {
    local target_file="$1"   # 要覆盖的正式配置文件，例如 ${conf_dir}/inbounds.json
    local tmp_file="$2"      # jq 已经写好的临时文件
    local label="${3:-配置}"

    if [ ! -s "$tmp_file" ]; then
        red "${label} 生成失败（临时文件为空），已取消本次修改"
        rm -f "$tmp_file"
        return 1
    fi

    # jq 输出必须是合法 JSON，防止半截写坏
    if command_exists jq && ! jq empty "$tmp_file" >/dev/null 2>&1; then
        red "${label} 生成的 JSON 不合法，已取消本次修改"
        rm -f "$tmp_file"
        return 1
    fi

    local backup_file="${target_file}.bak.safeapply"
    cp -f "$target_file" "$backup_file" 2>/dev/null || true
    mv -f "$tmp_file" "$target_file"

    if [ -x "${work_dir}/sing-box" ] && ! "${work_dir}/sing-box" check -C "${conf_dir}" >/dev/null 2>&1; then
        red "${label} 校验失败（sing-box check 未通过），已自动回滚"
        if [ -f "$backup_file" ]; then
            mv -f "$backup_file" "$target_file"
        fi
        return 1
    fi

    rm -f "$backup_file"
    return 0
}

# 订阅：令牌 + 独立端口 + 开关，写入 install.conf
load_sub_conf() {
    SKIP_DIRECT="${SKIP_DIRECT:-0}"
    SUB_TOKEN="${SUB_TOKEN:-}"
    SUB_PORT="${SUB_PORT:-}"
    SUB_ENABLED="${SUB_ENABLED:-1}"
    if [ -f "${work_dir}/install.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/install.conf" 2>/dev/null || true
    fi
    SUB_ENABLED="${SUB_ENABLED:-1}"
}

save_sub_conf() {
    # 只写入当前内存中的值，禁止再 source 文件以免覆盖刚改的令牌/端口
    {
        printf 'SKIP_DIRECT=%s\n' "${SKIP_DIRECT:-0}"
        printf 'SUB_TOKEN=%s\n' "${SUB_TOKEN:-}"
        printf 'SUB_PORT=%s\n' "${SUB_PORT:-2096}"
        printf 'SUB_ENABLED=%s\n' "${SUB_ENABLED:-1}"
    } > "${work_dir}/install.conf"
    chmod 644 "${work_dir}/install.conf" 2>/dev/null || true
}

ensure_sub_token() {
    load_sub_conf
    local tok="${SUB_TOKEN:-}"
    if [ -z "$tok" ] || ! echo "$tok" | grep -Eq '^[A-Za-z0-9_-]{8,64}$'; then
        if command_exists openssl; then
            tok=$(openssl rand -hex 12 2>/dev/null)
        fi
        [ -z "$tok" ] && tok=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 24)
        [ -z "$tok" ] && tok=$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 24)
        [ -z "$tok" ] && tok="sb$(date +%s)"
        SUB_TOKEN="$tok"
    fi
    export SUB_TOKEN
    # 默认订阅端口
    if [ -z "${SUB_PORT:-}" ] || ! [[ "${SUB_PORT}" =~ ^[0-9]+$ ]]; then
        SUB_PORT=2096
    fi
    export SUB_PORT
    SUB_ENABLED="${SUB_ENABLED:-1}"
    export SUB_ENABLED
    save_sub_conf
}

# 强制生成新订阅令牌（旧 /s/<token> 立即失效）；成功返回 0
regenerate_sub_token() {
    load_sub_conf
    local old_tok="${SUB_TOKEN:-}" tok=""
    if command_exists openssl; then
        tok=$(openssl rand -hex 12 2>/dev/null)
    fi
    [ -z "$tok" ] && tok=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 24)
    [ -z "$tok" ] && tok=$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 24)
    [ -z "$tok" ] && tok="sb$(date +%s)${RANDOM:-0}"
    [ -n "$old_tok" ] && [ "$tok" = "$old_tok" ] && tok="${tok}x"

    SUB_TOKEN="$tok"
    SUB_ENABLED=1
    [ -z "${SUB_PORT:-}" ] || ! [[ "${SUB_PORT}" =~ ^[0-9]+$ ]] && SUB_PORT=2096
    export SUB_TOKEN SUB_ENABLED SUB_PORT
    save_sub_conf
    allow_port ${SUB_PORT}/tcp >/dev/null 2>&1
    write_sub_nginx_conf

    local argo_conf="/etc/nginx/conf.d/argo-ws.conf"
    if [ -f "$argo_conf" ] && [ -n "$old_tok" ]; then
        sed -i "s|/s/${old_tok}|/s/${SUB_TOKEN}|g" "$argo_conf" 2>/dev/null || true
    elif [ -f "$argo_conf" ]; then
        _load_argo_port_for_nginx 2>/dev/null || true
        add_nginx_conf >/dev/null 2>&1 || true
    fi

    if command_exists nginx; then
        if nginx -t >/dev/null 2>&1; then
            restart_nginx >/dev/null 2>&1 || true
            return 0
        fi
        red "nginx -t 失败，新令牌已写入但可能未生效："
        nginx -t 2>&1 | tail -5
        return 1
    fi
    return 0
}

# 写入/更新独立订阅 Nginx 配置（sb-sub.conf）；关闭时删除
write_sub_nginx_conf() {
    ensure_sub_token
    local conf="/etc/nginx/conf.d/sb-sub.conf"
    if [ "${SUB_ENABLED:-1}" != "1" ]; then
        rm -f "$conf" 2>/dev/null || true
        return 0
    fi
    mkdir -p /etc/nginx/conf.d 2>/dev/null || true
    cat > "$conf" << EOF
server {
    listen ${SUB_PORT};
    listen [::]:${SUB_PORT};
    server_name _;

    location = /s/${SUB_TOKEN} {
        default_type text/plain;
        charset utf-8;
        alias ${work_dir}/sub.txt;
        add_header Cache-Control "no-store";
        add_header Access-Control-Allow-Origin *;
    }
    location = /s/${SUB_TOKEN}/raw {
        default_type text/plain;
        charset utf-8;
        alias ${work_dir}/url.txt;
        add_header Cache-Control "no-store";
        add_header Access-Control-Allow-Origin *;
    }
    location / { return 404; }
}
EOF
}

# 打印订阅链接（独立 SUB_PORT + Argo 域名）
print_sub_urls() {
    ensure_sub_token
    local ip domain argo_port host_for_url
    ip=$(get_realip 2>/dev/null || echo "服务器IP")
    host_for_url="$ip"
    if echo "$ip" | grep -q '^\[.*\]$'; then
        host_for_url="$ip"
    elif echo "$ip" | grep -q ':'; then
        host_for_url="[$ip]"
    fi

    argo_port="${ARGO_PORT:-}"
    if [ -z "$argo_port" ] && [ -f "${work_dir}/argo_fixed.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/argo_fixed.conf" 2>/dev/null || true
        argo_port="${ARGO_PORT:-}"
    fi
    if [ -z "$argo_port" ] && [ -f /etc/nginx/conf.d/argo-ws.conf ]; then
        argo_port=$(grep -oE 'listen[[:space:]]+[0-9]+' /etc/nginx/conf.d/argo-ws.conf 2>/dev/null | head -1 | awk '{print $2}')
    fi
    argo_port="${argo_port:-8001}"

    domain=""
    if [ -f "${work_dir}/argo_fixed.conf" ]; then
        # shellcheck source=/dev/null
        source "${work_dir}/argo_fixed.conf" 2>/dev/null || true
        [ "${ARGO_USE_FIXED:-0}" = "1" ] && [ -n "${ARGO_DOMAIN:-}" ] && domain="$ARGO_DOMAIN"
    fi
    if [ -z "$domain" ] && [ -f "${work_dir}/argo.log" ]; then
        domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${work_dir}/argo.log" 2>/dev/null | head -1)
        [ -z "$domain" ] && domain=$(grep -oE '[[:alnum:]+.-]+\.trycloudflare\.com' "${work_dir}/argo.log" 2>/dev/null | head -1)
    fi

    echo ""
    green "=== 订阅链接（客户端直接导入） ==="
    if [ "${SUB_ENABLED:-1}" != "1" ]; then
        red "节点订阅当前已关闭（主菜单 7 → 开启节点订阅）"
        yellow "本地文件仍可用: ${work_dir}/sub.txt  |  ${work_dir}/url.txt"
        echo ""
        return 0
    fi
    yellow "令牌固定，改节点后无需换链接；勿泄露。订阅端口: ${SUB_PORT}"
    green "Base64 订阅(推荐·直连端口):"
    purple "  http://${host_for_url}:${SUB_PORT}/s/${SUB_TOKEN}"
    green "明文节点列表:"
    purple "  http://${host_for_url}:${SUB_PORT}/s/${SUB_TOKEN}/raw"
    if [ -n "$domain" ] && [ "$domain" != "未获取到域名" ]; then
        green "Argo/HTTPS 订阅(推荐外网):"
        purple "  https://${domain}/s/${SUB_TOKEN}"
        green "Argo 明文节点:"
        purple "  https://${domain}/s/${SUB_TOKEN}/raw"
    else
        yellow "Argo 域名未就绪时，仍可用上方直连端口订阅"
        green "备用(经 Argo 入口端口 ${argo_port}):"
        purple "  http://${host_for_url}:${argo_port}/s/${SUB_TOKEN}"
    fi
    yellow "本地文件: ${work_dir}/sub.txt  |  ${work_dir}/url.txt"
    echo ""
}

# 处理防火墙
allow_port() {
    has_ufw=0
    has_firewalld=0
    has_iptables=0
    has_ip6tables=0

    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1
    [ "$has_iptables" -eq 1 ] && {
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i lo -j ACCEPT
        iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p icmp -j ACCEPT
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    }
    [ "$has_ip6tables" -eq 1 ] && {
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT 3 -i lo -j ACCEPT
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p icmp -j ACCEPT
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    }

    for rule in "$@"; do
        port=${rule%/*}
        proto=${rule#*/}
        [ "$has_ufw" -eq 1 ] && ufw allow in ${port}/${proto} >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port=${port}/${proto} >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && (iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT)
        [ "$has_ip6tables" -eq 1 ] && (ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p ${proto} --dport ${port} -j ACCEPT)
    done

    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1

    if command_exists rc-service 2>/dev/null; then
        [ "$has_iptables" -eq 1 ] && iptables-save > /etc/iptables/rules.v4 2>/dev/null
        [ "$has_ip6tables" -eq 1 ] && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
    else
        if ! command_exists netfilter-persistent; then
            manage_packages install iptables-persistent || yellow "请手动安装netfilter-persistent或保存iptables规则"
            netfilter-persistent save >/dev/null 2>&1
        elif command_exists service; then
            service iptables save 2>/dev/null
            service ip6tables save 2>/dev/null
        fi
    fi
}

# 下载并安装 sing-box,cloudflared
install_singbox() {
    clear
    purple "正在安装sing-box中，请稍后..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64' | 'amd64')  ARCH='amd64' ;;
        'x86' | 'i686' | 'i386') ARCH='386' ;;
        'aarch64' | 'arm64') ARCH='arm64' ;;
        'armv7l')  ARCH='armv7' ;;
        's390x')   ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 777 "${work_dir}" && mkdir -p "${conf_dir}"

    # ---------- 下载 sing-box（下载后必须能实际执行，否则回退） ----------
    # 官方包解压后约 80~90MB（含 libcronet.so）；小磁盘机器管道解压仍可能不够。
    # 策略：可用空间 < 200MB 时优先镜像（约 40MB 单文件）；官方用 curl|tar 不落盘 tar.gz。
    purple "正在下载最新版 sing-box..."
    SB_ARCH="${ARCH}"

    _disk_free_mb() {
        local p="${1:-$work_dir}"
        local kb
        kb=$(df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4}')
        [ -z "$kb" ] && kb=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')
        [ -z "$kb" ] && { echo 9999; return; }
        echo $((kb / 1024))
    }

    _singbox_bin_ok() {
        [ -f "${work_dir}/sing-box" ] || return 1
        chmod +x "${work_dir}/sing-box" 2>/dev/null || true
        "${work_dir}/sing-box" version >/dev/null 2>&1
    }

    # [v2.6.0] GitHub API 未认证限速约 60次/小时/IP，命中限流时给出明确提示，
    # 并把上一次成功获取到的版本号缓存到本地，作为 API 失败时的 fallback，
    # 避免"版本号拿不到就直接跳去镜像、用户却不知道发生了限流"的静默行为。
    _sb_version_cache="${work_dir}/.sb_latest_version_cache"
    _sb_get_latest_version() {
        local ver api_out
        api_out=$(curl -sL --connect-timeout 10 --max-time 30 -w '\n%{http_code}' \
            "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null)
        local http_code="${api_out##*$'\n'}"
        local body="${api_out%$'\n'*}"

        if [ "$http_code" = "403" ] || [ "$http_code" = "429" ]; then
            yellow "GitHub API 限流(HTTP ${http_code})，可能是当前出口 IP 请求过于频繁"
        fi

        ver=$(printf '%s' "$body" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/^v//')
        if [ -z "$ver" ]; then
            ver=$(curl -sL --connect-timeout 10 --max-time 30 \
                "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null \
                | grep -oE 'tag/v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's|tag/v||')
        fi

        if [ -n "$ver" ]; then
            mkdir -p "$(dirname "$_sb_version_cache")" 2>/dev/null || true
            printf '%s' "$ver" > "$_sb_version_cache" 2>/dev/null || true
        elif [ -f "$_sb_version_cache" ]; then
            ver=$(cat "$_sb_version_cache" 2>/dev/null)
            [ -n "$ver" ] && yellow "使用本地缓存的版本号: ${ver}（上次成功获取时记录）"
        fi
        printf '%s' "$ver"
    }

    # 官方：curl 管道直接解压，不把 tar.gz 写到磁盘（峰值≈解压后体积）
    download_singbox_official() {
        local variant="${1:-}"
        local tmpdir version tarball url bin suffix_label free_mb
        free_mb=$(_disk_free_mb "$work_dir")
        # 官方解压后约 90MB，预留一点余量
        if [ "$free_mb" -lt 100 ]; then
            yellow "  可用空间约 ${free_mb}MB，不足以解压官方包，跳过"
            return 1
        fi
        tmpdir=$(mktemp -d)
        version="${SB_LATEST_VERSION:-}"
        if [ -z "$version" ]; then
            version=$(_sb_get_latest_version)
            SB_LATEST_VERSION="$version"
        fi
        [ -z "$version" ] && { rm -rf "$tmpdir"; return 1; }

        if [ -n "$variant" ]; then
            tarball="sing-box-${version}-linux-${SB_ARCH}-${variant}.tar.gz"
            suffix_label=" (${variant})"
        else
            tarball="sing-box-${version}-linux-${SB_ARCH}.tar.gz"
            suffix_label=""
        fi
        url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${tarball}"
        purple "  官方版本: ${version}  架构: ${SB_ARCH}${suffix_label}（管道解压，可用 ${free_mb}MB）"

        # 只解压 sing-box 主文件，尽量少占空间；失败再全量解压
        if curl -sL --connect-timeout 15 --max-time 180 "$url" | tar -xz -C "$tmpdir" 2>/dev/null; then
            bin=$(find "$tmpdir" -type f -name "sing-box" 2>/dev/null | head -1)
            if [ -n "$bin" ] && [ -f "$bin" ]; then
                # 先删同包其它大文件再拷贝，降低峰值
                find "$tmpdir" -type f ! -name "sing-box" -delete 2>/dev/null || true
                cp -f "$bin" "${work_dir}/sing-box"
                chmod +x "${work_dir}/sing-box"
                rm -rf "$tmpdir"
                if _singbox_bin_ok; then
                    return 0
                fi
                yellow "官方二进制${suffix_label}无法在本系统执行"
                rm -f "${work_dir}/sing-box"
                return 1
            fi
        fi
        rm -rf "$tmpdir"
        return 1
    }

    download_singbox_mirror() {
        local free_mb
        free_mb=$(_disk_free_mb "$work_dir")
        if [ "$free_mb" -lt 45 ]; then
            yellow "  可用空间约 ${free_mb}MB，镜像二进制约 40MB+，可能仍不足"
        fi
        yellow "尝试镜像源: https://${ARCH}.eooce.com/sb （约 40MB，适合小磁盘）"
        # 先写临时文件再 mv，避免半截覆盖
        if curl -sL --connect-timeout 15 --max-time 180 -o "${work_dir}/sing-box.part" "https://${ARCH}.eooce.com/sb"; then
            mv -f "${work_dir}/sing-box.part" "${work_dir}/sing-box"
            chmod +x "${work_dir}/sing-box"
            if _singbox_bin_ok; then
                return 0
            fi
            yellow "镜像二进制无法执行"
            rm -f "${work_dir}/sing-box"
        fi
        rm -f "${work_dir}/sing-box.part" 2>/dev/null || true
        return 1
    }

    sb_got=0
    SB_LATEST_VERSION=""
    SB_FREE_MB=$(_disk_free_mb "$work_dir")
    purple "安装目录可用空间约: ${SB_FREE_MB} MB"

    # 可用空间 < 200MB：优先镜像（避免官方 80MB+ 解压撑爆 120MB 机）
    # Alpine 且空间尚可：仍可试官方 musl
    if [ "$SB_FREE_MB" -lt 200 ]; then
        yellow "磁盘较小（<200MB），优先使用体积更小的镜像二进制"
        if download_singbox_mirror; then
            sb_got=1
        elif command_exists apk 2>/dev/null && download_singbox_official "musl"; then
            sb_got=1
        elif download_singbox_official; then
            sb_got=1
        fi
    elif command_exists apk 2>/dev/null; then
        purple "检测到 Alpine/musl，优先尝试官方 musl 构建..."
        if download_singbox_official "musl"; then
            sb_got=1
        elif download_singbox_official; then
            sb_got=1
        elif download_singbox_mirror; then
            sb_got=1
        fi
    else
        if download_singbox_official; then
            sb_got=1
        elif download_singbox_mirror; then
            sb_got=1
        fi
    fi

    if [ "$sb_got" -eq 1 ] && _singbox_bin_ok; then
        sb_ver=$("${work_dir}/sing-box" version 2>/dev/null | head -1)
        green "sing-box 下载成功: ${purple}${sb_ver}${re}"
        green "二进制大小: $(du -h "${work_dir}/sing-box" 2>/dev/null | awk '{print $1}')"
    else
        red "sing-box 下载失败或无法在本系统执行"
        red "当前可用约 ${SB_FREE_MB}MB。官方解压需约 100MB+，镜像约 45MB。"
        red "可手动放入兼容二进制到 ${work_dir}/sing-box 后重试；Alpine 也可: apk add sing-box"
        exit 1
    fi

    # ---------- 下载 cloudflared（优先官方，失败或不可执行则回退镜像） ----------
    case "${ARCH}" in
        amd64)  CF_ARCH="amd64" ;;
        386)    CF_ARCH="386" ;;
        arm64)  CF_ARCH="arm64" ;;
        armv7)  CF_ARCH="arm" ;;
        *)      CF_ARCH="amd64" ;;
    esac
    _argo_bin_ok() {
        [ -f "${work_dir}/argo" ] || return 1
        chmod +x "${work_dir}/argo" 2>/dev/null || true
        "${work_dir}/argo" version >/dev/null 2>&1
    }
    purple "正在下载 cloudflared..."
    argo_got=0
    CF_FREE_MB=$(_disk_free_mb "$work_dir")
    # 官方与镜像体积接近(~38MB)；空间极紧时仍先试镜像路径更短
    _cf_try_official() {
        curl -sL --connect-timeout 15 --max-time 180 \
            -o "${work_dir}/argo.part" \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
        && mv -f "${work_dir}/argo.part" "${work_dir}/argo"
    }
    _cf_try_mirror() {
        curl -sL --connect-timeout 15 --max-time 180 \
            -o "${work_dir}/argo.part" "https://${ARCH}.eooce.com/bot" \
        && mv -f "${work_dir}/argo.part" "${work_dir}/argo"
    }
    if [ "$CF_FREE_MB" -lt 50 ]; then
        yellow "可用空间约 ${CF_FREE_MB}MB，cloudflared 约 38MB，可能不足；仍尝试下载"
    fi
    if [ "$CF_FREE_MB" -lt 100 ]; then
        # 小盘：镜像与官方体积接近，先官方后镜像均可
        if _cf_try_official && _argo_bin_ok; then
            argo_got=1
        else
            rm -f "${work_dir}/argo" "${work_dir}/argo.part" 2>/dev/null || true
            _cf_try_mirror && _argo_bin_ok && argo_got=1 || rm -f "${work_dir}/argo" 2>/dev/null || true
        fi
    else
        if _cf_try_official && _argo_bin_ok; then
            argo_got=1
        else
            yellow "官方 cloudflared 失败，回退镜像..."
            rm -f "${work_dir}/argo" "${work_dir}/argo.part" 2>/dev/null || true
            if _cf_try_mirror && _argo_bin_ok; then
                argo_got=1
            else
                yellow "cloudflared 下载失败（Argo 可能不可用）"
                rm -f "${work_dir}/argo" "${work_dir}/argo.part" 2>/dev/null || true
            fi
        fi
    fi
    rm -f "${work_dir}/argo.part" 2>/dev/null || true

    chown root:root ${work_dir} 2>/dev/null || true
    chmod +x "${work_dir}/${server_name}" 2>/dev/null || true
    [ -f "${work_dir}/argo" ] && chmod +x "${work_dir}/argo" 2>/dev/null || true

    # 显示版本信息
    if [ -x "${work_dir}/sing-box" ]; then
        sb_ver=$("${work_dir}/sing-box" version 2>/dev/null | head -1 || echo "unknown")
        green "sing-box 版本: ${purple}${sb_ver}${re}"
    fi
    if [ -x "${work_dir}/argo" ] && _argo_bin_ok; then
        argo_ver=$("${work_dir}/argo" version 2>/dev/null | head -1 || echo "unknown")
        green "cloudflared 版本: ${purple}${argo_ver}${re}"
    fi

    # ---------- 输入：前缀 / UUID / 端口（支持环境变量，交互模式可覆盖） ----------
    # 前缀
    if [ -z "$node_prefix" ]; then
        if [ -t 0 ]; then
            reading "请输入节点前缀名称 (回车默认使用 ISP 信息): " node_prefix
        fi
    fi
    export node_prefix

    # UUID
    if [ -z "$uuid" ]; then
        if [ -t 0 ]; then
            reading "请输入 UUID (回车随机生成): " uuid
        fi
    fi
    if [ -z "$uuid" ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
        green "已随机生成 UUID: ${purple}${uuid}${re}"
    else
        if ! echo "$uuid" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
            yellow "UUID 格式不正确，已重新随机生成"
            uuid=$(cat /proc/sys/kernel/random/uuid)
            green "新 UUID: ${purple}${uuid}${re}"
        else
            green "使用 UUID: ${purple}${uuid}${re}"
        fi
    fi

    # ---------- 直连协议端口（vless_port ~ +3）----------
    # SKIP_DIRECT=1 时不安装 Reality / HY2 / TUIC / AnyTLS
    export SKIP_DIRECT="${SKIP_DIRECT:-0}"
    while true; do
        if [ -z "$vless_port" ] && [ -t 0 ]; then
            reading "请输入直连起始端口 (回车进入下一步选择；将占用 +0~+3 共4个端口): " input_vless_port
            if [ -z "$input_vless_port" ]; then
                reading "起始端口为空。是否使用随机端口安装直连协议? (y=随机端口 / n=跳过直连仅装 Argo) [y/n]: " yn_direct
                case "${yn_direct}" in
                    n|N)
                        SKIP_DIRECT=1
                        export SKIP_DIRECT
                        yellow "已选择：跳过直连协议，仅安装 Argo 隧道节点"
                        break
                        ;;
                    *)
                        vless_port=$(shuf -i 1000-65000 -n 1)
                        green "已随机直连起始端口: ${purple}${vless_port}${re}"
                        ;;
                esac
            else
                vless_port=$input_vless_port
            fi
        fi
        if [ "$SKIP_DIRECT" = "1" ]; then
            break
        fi
        if [ -z "$vless_port" ]; then
            # 非交互或已确认随机
            vless_port=$(shuf -i 1000-65000 -n 1)
        fi
        if ! [[ "$vless_port" =~ ^[0-9]+$ ]] || [ "$vless_port" -lt 1 ] || [ "$vless_port" -gt 65532 ]; then
            red "端口必须为 1-65532 的数字（需预留 +3）"
            vless_port=""
            continue
        fi
        # 统一走 port_really_in_use：仅有实际监听进程才算真冲突，TIME_WAIT 等误报直接放行
        conflict_list=""
        false_positive_direct_list=""
        for p in "$vless_port" "$((vless_port+1))" "$((vless_port+2))" "$((vless_port+3))"; do
            port_really_in_use "$p"
            _rc=$?
            if [ "$_rc" -eq 0 ]; then
                conflict_list="${conflict_list} ${p}"
            elif [ "$_rc" -eq 2 ]; then
                false_positive_direct_list="${false_positive_direct_list} ${p}"
            fi
        done
        if [ -n "$false_positive_direct_list" ] && [ -z "$conflict_list" ]; then
            yellow "直连端口检测对${false_positive_direct_list} 曾报占用，但系统无实际监听进程，已按空闲处理"
        fi
        if [ -n "$conflict_list" ]; then
            red "以下直连端口已被占用:${conflict_list}"
            yellow "说明: 起始端口 ${vless_port} 会同时占用 Reality/HY2/TUIC/WS = ${vless_port}~$((vless_port+3))"
            if [ -t 0 ]; then
                reading "请重新输入起始端口 (回车随机；输入 n 跳过直连): " input_vless_port
                if [ "$input_vless_port" = "n" ] || [ "$input_vless_port" = "N" ]; then
                    SKIP_DIRECT=1
                    export SKIP_DIRECT
                    yellow "已选择：跳过直连协议，仅安装 Argo 隧道节点"
                    break
                elif [ -n "$input_vless_port" ]; then
                    vless_port=$input_vless_port
                else
                    vless_port=$(shuf -i 1000-65000 -n 1)
                    green "已随机: ${purple}${vless_port}${re}"
                fi
            else
                vless_port=$(shuf -i 1000-65000 -n 1)
            fi
            continue
        fi
        break
    done
    if [ "$SKIP_DIRECT" = "1" ]; then
        vless_port=""
        hy2_port=""
        tuic_port=""
        anytls_port=""
        green "直连协议: 已跳过（不占用公网端口）"
    else
        green "直连端口: Reality=${purple}${vless_port}${re}  HY2=$((vless_port+1))  TUIC=$((vless_port+2))  AnyTLS=$((vless_port+3))"
    fi

    # ---------- Argo 端口（ARGO_PORT 及 +10~+12；订阅另用 SUB_PORT）----------
    # 重装场景：若仅是本机旧 nginx 占着默认入口，先停掉以免误报 8001 被占用
    if command_exists nginx && type _nginx_stop_all >/dev/null 2>&1; then
        if port_in_use "${ARGO_PORT:-8001}" 2>/dev/null; then
            local _hold
            _hold=$(port_holder_info "${ARGO_PORT:-8001}" 2>/dev/null || true)
            if echo "$_hold" | grep -qi nginx; then
                yellow "检测到旧 nginx 占用 Argo 入口端口，安装前先停止..."
                _nginx_stop_all >/dev/null 2>&1 || true
            fi
        fi
    elif command_exists nginx; then
        if port_in_use "${ARGO_PORT:-8001}" 2>/dev/null; then
            local _hold
            _hold=$(port_holder_info "${ARGO_PORT:-8001}" 2>/dev/null || true)
            if echo "$_hold" | grep -qi nginx; then
                yellow "检测到旧 nginx 占用 Argo 入口端口，安装前先停止..."
                nginx -s stop >/dev/null 2>&1 || true
                command_exists rc-service && rc-service nginx stop >/dev/null 2>&1 || true
                pkill -x nginx >/dev/null 2>&1 || true
                sleep 0.5
            fi
        fi
    fi
    # Argo 端口冲突检测：
    # - 与直连重叠 / port_really_in_use 判为真实冲突（有实际监听进程） → 需换端口
    # - port_really_in_use 判为误报（无实际监听进程） → 沿用当前端口，不打断安装
    # 与直连端口检测使用同一套 port_really_in_use 标准，避免两处判断不一致
    while true; do
        base="${ARGO_PORT:-8001}"
        real_conflict_list=""
        real_conflict_detail=""
        false_positive_list=""
        for offset_name in "0:Argo入口" "10:VMess内部" "11:VLESS内部" "12:Trojan内部"; do
            off="${offset_name%%:*}"
            name="${offset_name#*:}"
            p=$((base + off))
            # 与直连端口重叠：真实冲突
            if [ -n "${vless_port:-}" ] && {
                [ "$p" = "$vless_port" ] || [ "$p" = "$((vless_port+1))" ] || [ "$p" = "$((vless_port+2))" ] || [ "$p" = "$((vless_port+3))" ]
            }; then
                real_conflict_list="${real_conflict_list} ${p}"
                real_conflict_detail="${real_conflict_detail}\n  - ${p} (${name}) 与直连端口重叠"
                continue
            fi
            port_really_in_use "$p"
            _rc=$?
            if [ "$_rc" -eq 0 ]; then
                real_conflict_list="${real_conflict_list} ${p}"
                real_conflict_detail="${real_conflict_detail}\n  - ${p} (${name}) 已被占用"
            elif [ "$_rc" -eq 2 ]; then
                false_positive_list="${false_positive_list} ${p}"
            fi
        done
        if [ -n "$false_positive_list" ] && [ -z "$real_conflict_list" ]; then
            yellow "端口检测对${false_positive_list} 曾报占用，但系统无监听进程，已按空闲处理（沿用 ${base}，无需改端口）"
            ARGO_PORT="$base"
            export ARGO_PORT
            break
        fi
        if [ -z "$real_conflict_list" ]; then
            ARGO_PORT="$base"
            export ARGO_PORT
            break
        fi
        red "Argo 相关端口真实冲突 (当前 ARGO 起始=${base}):"
        echo -e "${red}${real_conflict_detail}${re}"
        yellow "占用详情:"
        for _cp in $real_conflict_list; do
            yellow "  端口 ${_cp}:"
            port_holder_info "$_cp" | while IFS= read -r _line; do
                [ -n "$_line" ] && echo -e "    ${purple}${_line}${re}"
            done
        done
        yellow "将占用: Argo=${base}  内部WS=${base}+10~+12"
        if [ -t 0 ]; then
            reading "请输入新的 Argo 起始端口 (回车自动随机空闲端口): " input_argo
            if [ -n "$input_argo" ]; then
                if ! [[ "$input_argo" =~ ^[0-9]+$ ]] || [ "$input_argo" -lt 1 ] || [ "$input_argo" -gt 65522 ]; then
                    red "端口无效，请输入 1-65522"
                    continue
                fi
                ARGO_PORT="$input_argo"
            else
                found=""
                for _ in $(seq 1 80); do
                    cand=$(shuf -i 2000-64000 -n 1)
                    ok=1
                    for off in 0 10 11 12; do
                        p=$((cand + off))
                        if [ -n "${vless_port:-}" ] && {
                            [ "$p" = "$vless_port" ] || [ "$p" = "$((vless_port+1))" ] || [ "$p" = "$((vless_port+2))" ] || [ "$p" = "$((vless_port+3))" ]
                        }; then
                            ok=0; break
                        fi
                        # 自动分配时同样统一走 port_really_in_use：误报(rc=2)不算冲突
                        port_really_in_use "$p"
                        [ $? -eq 0 ] && { ok=0; break; }
                    done
                    if [ "$ok" -eq 1 ]; then
                        found=$cand
                        break
                    fi
                done
                if [ -n "$found" ]; then
                    ARGO_PORT="$found"
                    green "已自动分配 Argo 起始端口: ${purple}${ARGO_PORT}${re}"
                else
                    red "自动分配失败，请手动输入"
                    continue
                fi
            fi
            export ARGO_PORT
        else
            found=""
            for _ in $(seq 1 80); do
                cand=$(shuf -i 2000-64000 -n 1)
                ok=1
                for off in 0 10 11 12; do
                    p=$((cand + off))
                    if [ -n "${vless_port:-}" ] && {
                        [ "$p" = "$vless_port" ] || [ "$p" = "$((vless_port+1))" ] || [ "$p" = "$((vless_port+2))" ] || [ "$p" = "$((vless_port+3))" ]
                    }; then
                        ok=0; break
                    fi
                    port_really_in_use "$p"
                    [ $? -eq 0 ] && { ok=0; break; }
                done
                [ "$ok" -eq 1 ] && { found=$cand; break; }
            done
            if [ -n "$found" ]; then
                ARGO_PORT="$found"
                export ARGO_PORT
                green "已自动分配 Argo 起始端口: ${purple}${ARGO_PORT}${re}"
                break
            else
                # 非交互且找不到：仍沿用默认，避免安装中断
                yellow "无法确认空闲端口，沿用 ARGO_PORT=${base}"
                ARGO_PORT="$base"
                export ARGO_PORT
                break
            fi
        fi
    done
    green "Argo 端口: ${purple}${ARGO_PORT}${re}"
    if [ "${SKIP_DIRECT:-0}" = "1" ]; then
        green "将使用端口: 仅 Argo=${ARGO_PORT}（已跳过直连）"
    else
        green "将使用端口: Reality=${vless_port}  HY2=$((vless_port+1))  TUIC=$((vless_port+2))  AnyTLS=$((vless_port+3))  Argo=${ARGO_PORT}"
    fi

    # ---------- 交互式输入：隧道类型 / 固定隧道域名 / 隧道令牌 ----------
    # 支持环境变量预设：ARGO_DOMAIN / ARGO_TOKEN / ARGO_USE_FIXED=1
    # 交互模式下可覆盖；非交互（-i）时若未设置则默认临时隧道
    export ARGO_DOMAIN="${ARGO_DOMAIN:-}"
    export ARGO_TOKEN="${ARGO_TOKEN:-}"
    # 环境变量中的令牌同样做前缀清理
    [ -n "$ARGO_TOKEN" ] && ARGO_TOKEN=$(clean_argo_token "$ARGO_TOKEN")
    export ARGO_USE_FIXED="${ARGO_USE_FIXED:-0}"

    if [ -t 0 ]; then
        echo ""
        purple "=== Argo 隧道配置 ==="
        yellow "直接配置固定隧道。域名留空 → 立即使用临时隧道；令牌留空 → 回退临时隧道"
        echo ""

        # 若环境变量已完整提供，则直接使用，不再询问
        if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_TOKEN" ]; then
            green "检测到环境变量已设置固定隧道域名与令牌，将直接使用"
            ARGO_USE_FIXED=1
        else
            # 先询问域名；域名留空则直接回退，不再询问令牌
            if [ -z "$ARGO_DOMAIN" ]; then
                reading "请输入固定隧道域名 (例如: argo.example.com，直接回车则使用临时隧道): " ARGO_DOMAIN
            fi

            if [ -z "$ARGO_DOMAIN" ]; then
                yellow "域名为空，已自动回退为临时隧道 (trycloudflare.com)"
                clear_argo_fixed_conf
            else
                if [ -z "$ARGO_TOKEN" ]; then
                    yellow "令牌获取：Cloudflare Zero Trust → Networks → Tunnels → 复制 Token；或使用 JSON 凭证"
                    yellow "可直接粘贴完整命令，脚本会自动去除前缀仅保留 eyJ 开头的有效令牌"
                    reading "请输入隧道令牌 (Token) 或 JSON 凭证 (直接回车则使用临时隧道): " ARGO_TOKEN
                    ARGO_TOKEN=$(clean_argo_token "$ARGO_TOKEN")
                fi
                if [ -z "$ARGO_TOKEN" ]; then
                    yellow "令牌为空，已自动回退为临时隧道 (trycloudflare.com)"
                    clear_argo_fixed_conf
                else
                    ARGO_USE_FIXED=1
                fi
            fi
        fi

        if [ "$ARGO_USE_FIXED" = "1" ] && [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_TOKEN" ]; then
            if ! echo "$ARGO_DOMAIN" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$'; then
                yellow "域名格式可能不正确，仍将尝试使用: ${ARGO_DOMAIN}"
            fi
            green "隧道域名: ${purple}${ARGO_DOMAIN}${re}"
            if echo "$ARGO_TOKEN" | grep -q 'TunnelSecret'; then
                green "检测到 JSON 凭证格式"
            elif echo "$ARGO_TOKEN" | grep -Eq '^[A-Za-z0-9=]{100,}$'; then
                green "检测到 Token 格式"
            else
                yellow "令牌格式未明确识别，将按输入内容配置"
            fi
            save_argo_fixed_conf
            green "已记录固定隧道配置（流量: Cloudflare → Nginx:${ARGO_PORT} → 三协议）"
        else
            clear_argo_fixed_conf
        fi
        export ARGO_USE_FIXED ARGO_DOMAIN ARGO_TOKEN
    else
        if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_TOKEN" ]; then
            ARGO_USE_FIXED=1
            save_argo_fixed_conf
            green "非交互模式：已启用固定隧道 ${purple}${ARGO_DOMAIN}${re}"
        else
            clear_argo_fixed_conf
            green "非交互模式：使用临时隧道"
        fi
        export ARGO_USE_FIXED
    fi

    # Argo 内部端口（仅本机访问，由 Nginx 统一对外监听 ARGO_PORT）
    vmess_ws_port=$(($ARGO_PORT + 10))
    vless_ws_port=$(($ARGO_PORT + 11))
    trojan_ws_port=$(($ARGO_PORT + 12))

    private_key=""
    public_key=""
    if [ "${SKIP_DIRECT:-0}" != "1" ]; then
        # 公网协议端口：Reality / Hysteria2 / TUIC / AnyTLS
        hy2_port=$(($vless_port + 1))
        tuic_port=$(($vless_port + 2))
        anytls_port=$(($vless_port + 3))
        output=$(/etc/sing-box/sing-box generate reality-keypair 2>/dev/null)
        private_key=$(echo "${output}" | grep -i 'PrivateKey' | awk '{print $NF}' | tr -d '\r')
        public_key=$(echo "${output}" | grep -i 'PublicKey' | awk '{print $NF}' | tr -d '\r')
        if [ -z "$private_key" ] || [ -z "$public_key" ]; then
            output=$(/etc/sing-box/sing-box generate reality-keypair 2>&1)
            private_key=$(echo "${output}" | sed -n 's/.*PrivateKey:[[:space:]]*//p' | head -1 | tr -d '\r')
            public_key=$(echo "${output}" | sed -n 's/.*PublicKey:[[:space:]]*//p' | head -1 | tr -d '\r')
        fi
        if [ -z "$private_key" ] || [ -z "$public_key" ]; then
            red "Reality 密钥生成失败，请检查 sing-box 二进制是否正常"
            red "输出: ${output}"
            exit 1
        fi
        green "Reality 密钥已生成"
        # 持久化 Reality 公钥，供 get_info 在新 shell 中回读
        {
            printf 'PUBLIC_KEY=%s\n' "$public_key"
            printf 'PRIVATE_KEY=%s\n' "$private_key"
        } > "${work_dir}/reality.keys"
        chmod 600 "${work_dir}/reality.keys" 2>/dev/null || true
        allow_port $vless_port/tcp $hy2_port/udp $tuic_port/udp $anytls_port/tcp ${ARGO_PORT}/tcp > /dev/null 2>&1
    else
        allow_port ${ARGO_PORT}/tcp > /dev/null 2>&1
        green "已跳过 Reality 密钥与直连端口放行"
        rm -f "${work_dir}/reality.keys" 2>/dev/null || true
    fi

    # 持久化 SKIP_DIRECT + 订阅令牌/端口/开关
    ensure_sub_token
    SUB_ENABLED=1
    export SUB_ENABLED
    # 若 SUB_PORT 与 Argo 冲突则自动错开；同时避开直连端口区间（vless_port ~ +3）
    if [ "${SUB_PORT}" = "${ARGO_PORT}" ] || [ "${SUB_PORT}" = "$((ARGO_PORT + 10))" ] || [ "${SUB_PORT}" = "$((ARGO_PORT + 11))" ] || [ "${SUB_PORT}" = "$((ARGO_PORT + 12))" ]; then
        SUB_PORT=$((ARGO_PORT + 20))
        export SUB_PORT
    fi
    if [ -n "${vless_port:-}" ] && [ "${SUB_PORT}" -ge "${vless_port}" ] 2>/dev/null && [ "${SUB_PORT}" -le "$((vless_port + 3))" ] 2>/dev/null; then
        SUB_PORT=$((ARGO_PORT + 21))
        export SUB_PORT
    fi
    save_sub_conf
    allow_port ${SUB_PORT}/tcp > /dev/null 2>&1

    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" | cut -d'=' -f2 | sed 's/:/%3A/g')

    dns_strategy=$(ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "prefer_ipv4" || \
        (ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1 && echo "prefer_ipv6" || echo "prefer_ipv4"))

    cat > "${conf_dir}/log.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "$work_dir/sb.log",
    "timestamp": true
  }
}
EOF

    cat > ${conf_dir}/ntp.json << EOF
{
    "ntp": {
        "enabled": true,
        "server": "time.apple.com",
        "server_port": 123,
        "interval": "60m"
    }
}
EOF

    cat > "${conf_dir}/dns.json" << EOF
{
  "dns": {
    "servers": [
      {
        "tag": "local",
        "type": "local"
      }
    ],
    "strategy": "$dns_strategy"
  }
}
EOF

    # 生成 inbounds：Argo 三协议始终安装；直连四协议受 SKIP_DIRECT 控制
    if [ "${SKIP_DIRECT:-0}" = "1" ]; then
        cat > "${conf_dir}/inbounds.json" << EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "listen_port": $vmess_ws_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": $vless_ws_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "listen_port": $trojan_ws_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/trojan-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ]
}
EOF
    else
        cat > "${conf_dir}/inbounds.json" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $vless_port,
      "users": [
        {
          "uuid": "$uuid",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.iij.ad.jp",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.iij.ad.jp",
            "server_port": 443
          },
          "private_key": "$private_key",
          "short_id": [""]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "listen_port": $vmess_ws_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vmess-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": $vless_ws_port,
      "users": [
        {
          "uuid": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/vless-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "trojan",
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "listen_port": $trojan_ws_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/trojan-argo",
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "::",
      "listen_port": $hy2_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls",
      "listen": "::",
      "listen_port": $anytls_port,
      "users": [
        {
          "password": "$uuid"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": $tuic_port,
      "users": [
        {
          "uuid": "$uuid",
          "password": "$uuid"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$work_dir/cert.pem",
        "key_path": "$work_dir/private.key"
      }
    }
  ]
}
EOF
    fi

    cat > "${conf_dir}/outbounds.json" << EOF
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    cat > "${conf_dir}/endpoints.json" << EOF
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

    cat > "${conf_dir}/route.json" << EOF
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
}

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
    if [ -z "$node_prefix" ]; then
        prefix="$isp"
    else
        prefix="${node_prefix}-${isp}"
    fi

    VMESS="{ \"v\": \"2\", \"ps\": \"${prefix}-argo-vmess\", \"add\": \"${CFIP}\", \"port\": \"${CFPORT}\", \"id\": \"${uuid}\", \"aid\": \"0\", \"scy\": \"auto\", \"net\": \"ws\", \"type\": \"none\", \"host\": \"${argodomain}\", \"path\": \"/vmess-argo?ed=2560\", \"tls\": \"tls\", \"sni\": \"${argodomain}\", \"alpn\": \"\", \"fp\": \"firefox\", \"allowInsecure\": \"false\"}"

    extra_lines=""
    if [ -f "${client_dir}" ]; then
        extra_lines=$(grep -vE '^(vless://|vmess://|hysteria2://|tuic://|trojan://)' "${client_dir}" || true)
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
REMOTE_URL="${SB_REMOTE_URL:-https://raw.githubusercontent.com/gxjxzgx/sing-box/refs/heads/main/sing-box1.sh}"
exec bash <(curl -fsSL "$REMOTE_URL") "$@"
EOF
    chmod +x "$work_dir/sb.sh"
    ln -sf "$work_dir/sb.sh" /usr/bin/sb
    if [ -L /usr/bin/sb ] || [ -x /usr/bin/sb ]; then
        green "\n快捷指令 sb 创建成功（始终远程拉取: ${SB_REMOTE_URL:-https://raw.githubusercontent.com/gxjxzgx/sing-box/refs/heads/main/sing-box1.sh}）\n"
    else
        red "\n快捷指令创建失败\n"
    fi
}


# =========================
# Telegram 通知模块
# =========================
tg_conf_file="${work_dir}/tg.conf"

load_tg_config() {
    # 优先配置文件，未设置时再读取环境变量 BOT_TOKEN / CHAT_ID
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_ENABLED=""
    if [ -f "$tg_conf_file" ]; then
        # shellcheck source=/dev/null
        source "$tg_conf_file" 2>/dev/null || true
    fi
    # 配置文件未设置的项，回退到环境变量
    [ -z "$TG_BOT_TOKEN" ] && [ -n "${BOT_TOKEN:-}" ] && TG_BOT_TOKEN="$BOT_TOKEN"
    [ -z "$TG_CHAT_ID" ] && [ -n "${CHAT_ID:-}" ] && TG_CHAT_ID="$CHAT_ID"
    # TG_ENABLED：配置文件已写则尊重；未写且 Token+ChatID 齐全则默认启用
    if [ -z "$TG_ENABLED" ]; then
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            TG_ENABLED="1"
        else
            TG_ENABLED="0"
        fi
    fi
}

save_tg_config() {
    mkdir -p "$(dirname "$tg_conf_file")"
    cat > "$tg_conf_file" << TGEOF
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
TG_ENABLED="${TG_ENABLED}"
TGEOF
    chmod 600 "$tg_conf_file"
}

# HTML 转义（Telegram parse_mode=HTML）
tg_html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# 发送 Telegram 文本消息
# 用法: send_tg_msg "内容" [html]
# 第二参数为 html 时启用 parse_mode=HTML（用于 <pre> 代码块，客户端可一键复制）
send_tg_msg() {
    local msg="$1"
    local mode="${2:-}"
    load_tg_config
    if [ "$TG_ENABLED" != "1" ] || [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi
    # Telegram 消息最长约 4096，超长截断
    if [ ${#msg} -gt 4000 ]; then
        msg="${msg:0:4000}...(已截断)"
    fi
    if [ "$mode" = "html" ]; then
        curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${msg}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "disable_web_page_preview=true" \
            >/dev/null 2>&1
    else
        curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TG_CHAT_ID}" \
            --data-urlencode "text=${msg}" \
            --data-urlencode "disable_web_page_preview=true" \
            >/dev/null 2>&1
    fi
}

# 获取服务纯文本状态（无颜色码，供 TG 推送使用）
get_plain_status() {
    local service_name="$1"
    local service_file="$2"
    if [ "$service_name" = "nginx" ]; then
        command_exists nginx || { echo "not installed"; return 2; }
    else
        [ -z "$service_file" ] || [ ! -f "$service_file" ] && { echo "not installed"; return 2; }
    fi
    if command_exists apk; then
        rc-service "${service_name}" status 2>/dev/null | grep -q "started" && echo "running" || echo "not running"
    else
        systemctl is-active "${service_name}" 2>/dev/null | grep -q "^active$" && echo "running" || echo "not running"
    fi
}

# 发送当前节点信息到 Telegram（含 sing-box / Argo / Nginx 状态）
send_tg_nodes() {
    load_tg_config
    if [ "$TG_ENABLED" != "1" ] || [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        return 1
    fi
    if [ ! -f "$client_dir" ]; then
        return 1
    fi

    local server_ip hostname_info node_text node_escaped
    server_ip=$(get_realip 2>/dev/null || echo "unknown")
    hostname_info=$(hostname 2>/dev/null || echo "server")
    node_text=$(cat "$client_dir" 2>/dev/null)
    node_escaped=$(tg_html_escape "$node_text")

    local sb_status argo_status nginx_status
    sb_status=$(get_plain_status "sing-box" "${work_dir}/${server_name}")
    argo_status=$(get_plain_status "argo" "${work_dir}/argo")
    nginx_status=$(get_plain_status "nginx" "$(command -v nginx 2>/dev/null)")

    # 节点列表用 <pre> 代码块发送，Telegram 客户端可显示「复制代码」
    local msg
    msg="📡 <b>sing-box 节点通知</b>
主机: $(tg_html_escape "$hostname_info")
IP: $(tg_html_escape "$server_ip")
时间: $(date '+%Y-%m-%d %H:%M:%S')

—— 服务状态 ——
sing-box: ${sb_status}
Argo: ${argo_status}
Nginx: ${nginx_status}

—— 节点列表 ——
<pre>${node_escaped}</pre>"

    send_tg_msg "$msg" "html" && green "节点信息已推送到 Telegram" || yellow "Telegram 推送失败（请检查 Token/ChatID）"
}

# 配置 Telegram
setup_telegram() {
    load_tg_config
    clear
    echo ""
    green "=== Telegram 通知设置 ===\n"
    if [ "$TG_ENABLED" = "1" ] && [ -n "$TG_BOT_TOKEN" ]; then
        green "当前状态: ${green}已启用${re}"
        yellow "Bot Token: ${TG_BOT_TOKEN:0:10}********"
        yellow "Chat ID: ${TG_CHAT_ID}"
    else
        yellow "当前状态: 未启用"
    fi
    echo ""
    skyblue "----------------"
    green "1. 配置/修改 Bot Token 与 Chat ID"
    skyblue "----------------"
    green "2. 发送测试消息"
    skyblue "----------------"
    green "3. 推送当前节点信息"
    skyblue "----------------"
    green "4. 开启通知"
    skyblue "----------------"
    red   "5. 关闭通知"
    skyblue "----------------"
    green "6. 安装/更新离线监控 (可自定义间隔)"
    skyblue "----------------"
    red   "7. 卸载离线监控"
    skyblue "----------------"
    purple "0. 返回主菜单"
    skyblue "----------------"
    reading "请输入选择: " tg_choice
    case "$tg_choice" in
        1)
            yellow "配置优先写入 ${work_dir}/tg.conf；未配置时回退读取环境变量 BOT_TOKEN / CHAT_ID"
            reading "请输入 Telegram Bot Token (回车使用环境变量 BOT_TOKEN): " input_token
            reading "请输入 Telegram Chat ID (回车使用环境变量 CHAT_ID): " input_chat
            [ -z "$input_token" ] && input_token="${BOT_TOKEN:-}"
            [ -z "$input_chat" ] && input_chat="${CHAT_ID:-}"
            if [ -n "$input_token" ] && [ -n "$input_chat" ]; then
                TG_BOT_TOKEN="$input_token"
                TG_CHAT_ID="$input_chat"
                TG_ENABLED="1"
                save_tg_config
                green "已保存到配置文件并启用 Telegram 通知"
                send_tg_msg "✅ sing-box Telegram 通知已配置成功
主机: $(hostname)
时间: $(date '+%Y-%m-%d %H:%M:%S')"
            else
                red "Token 或 Chat ID 不能为空（可先 export BOT_TOKEN / CHAT_ID，或写入配置文件）"
            fi
            ;;
        2)
            load_tg_config
            if send_tg_msg "🔔 sing-box 测试消息
主机: $(hostname)
时间: $(date '+%Y-%m-%d %H:%M:%S')"; then
                green "测试消息已发送，请检查 Telegram"
            else
                red "发送失败，请先完成配置并开启通知"
            fi
            ;;
        3)
            send_tg_nodes
            ;;
        4)
            load_tg_config
            if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
                red "请先配置 Bot Token 与 Chat ID"
            else
                TG_ENABLED="1"
                save_tg_config
                green "已开启 Telegram 通知"
            fi
            ;;
        5)
            TG_ENABLED="0"
            save_tg_config
            yellow "已关闭 Telegram 通知"
            ;;
        6)
            install_tg_monitor
            ;;
        7)
            uninstall_tg_monitor
            ;;
        0) return ;;
        *) red "无效选项" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回...\033[0m'
    setup_telegram
}

# 确保系统有 crontab（Alpine 默认可能没有，需装 dcron）
ensure_crontab() {
    if command_exists crontab; then
        return 0
    fi
    yellow "未找到 crontab，尝试安装 cron 组件..."
    if command_exists apk; then
        # Alpine: dcron 提供 crontab；busybox 的 crond 不一定带 crontab 命令
        apk add --no-cache dcron 2>/dev/null || apk add --no-cache cronie 2>/dev/null || true
        if command_exists rc-service; then
            rc-update add dcron default 2>/dev/null || rc-update add crond default 2>/dev/null || true
            rc-service dcron start 2>/dev/null || rc-service crond start 2>/dev/null || true
        fi
    elif command_exists apt; then
        DEBIAN_FRONTEND=noninteractive apt install -y cron 2>/dev/null || true
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
    elif command_exists dnf; then
        dnf install -y cronie 2>/dev/null || true
        systemctl enable crond 2>/dev/null || true
        systemctl start crond 2>/dev/null || true
    elif command_exists yum; then
        yum install -y cronie 2>/dev/null || true
        systemctl enable crond 2>/dev/null || true
        systemctl start crond 2>/dev/null || true
    fi
    if command_exists crontab; then
        green "crontab 已就绪"
        return 0
    fi
    red "无法安装 crontab（Alpine 可手动: apk add dcron && rc-service dcron start）"
    return 1
}

# 离线监控脚本（供 cron 调用）
install_tg_monitor() {
    load_tg_config
    if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
        red "请先配置 Bot Token 与 Chat ID"
        return 1
    fi
    TG_ENABLED="1"
    save_tg_config

    if ! ensure_crontab; then
        return 1
    fi

    reading "请输入检测间隔(分钟，回车默认2，最小1): " mon_min
    [ -z "$mon_min" ] && mon_min=2
    if ! [[ "$mon_min" =~ ^[0-9]+$ ]] || [ "$mon_min" -lt 1 ]; then
        mon_min=2
    fi
    green "离线检测间隔: ${purple}每 ${mon_min} 分钟${re}"

    cat > "${work_dir}/tg_monitor.sh" << 'MONEOF'
#!/bin/bash
work_dir="/etc/sing-box"
tg_conf_file="${work_dir}/tg.conf"
[ -f "$tg_conf_file" ] || exit 0
# shellcheck source=/dev/null
source "$tg_conf_file" 2>/dev/null || exit 0
[ "$TG_ENABLED" = "1" ] || exit 0
[ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ] || exit 0

send_msg() {
    curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=$1" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1
}

is_active() {
    local name="$1"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$name" && return 0
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$name" status 2>/dev/null | grep -q started && return 0
    fi
    return 1
}

host=$(hostname 2>/dev/null || echo server)
now=$(date '+%Y-%m-%d %H:%M:%S')
state_file="${work_dir}/tg_monitor.state"
prev_sb=1; prev_argo=1; prev_nginx=1
[ -f "$state_file" ] && . "$state_file" 2>/dev/null || true

check_svc() {
    local name="$1" prev="$2" var="$3"
    local cur=0
    is_active "$name" && cur=1
    if [ "$cur" -eq 0 ] && [ "$prev" -eq 1 ]; then
        send_msg "⚠️ 服务离线提醒
主机: ${host}
服务: ${name}
状态: 已停止/异常
时间: ${now}"
    elif [ "$cur" -eq 1 ] && [ "$prev" -eq 0 ]; then
        send_msg "✅ 服务恢复通知
主机: ${host}
服务: ${name}
状态: 已恢复运行
时间: ${now}"
    fi
    eval "$var=$cur"
}

check_svc sing-box "$prev_sb" cur_sb
check_svc argo "$prev_argo" cur_argo
check_svc nginx "$prev_nginx" cur_nginx

cat > "$state_file" << SEOF
prev_sb=${cur_sb:-1}
prev_argo=${cur_argo:-1}
prev_nginx=${cur_nginx:-1}
SEOF
MONEOF
    chmod +x "${work_dir}/tg_monitor.sh"

    # 写入 crontab（失败则明确报错，不假装成功）
    local cron_line="*/${mon_min} * * * * ${work_dir}/tg_monitor.sh >/dev/null 2>&1"
    if (crontab -l 2>/dev/null | grep -v "tg_monitor.sh"; echo "$cron_line") | crontab - 2>/dev/null; then
        green "离线监控已安装（每 ${mon_min} 分钟检测 sing-box / argo / nginx）"
        yellow "状态变化时会推送离线/恢复通知到 Telegram"
        # 确认 cron 守护进程在跑
        if command_exists rc-service; then
            rc-service dcron status 2>/dev/null | grep -q started || \
            rc-service crond status 2>/dev/null | grep -q started || \
            yellow "提示: 请确认 dcron/crond 服务已启动（rc-service dcron start）"
        elif command_exists systemctl; then
            systemctl is-active --quiet cron || systemctl is-active --quiet crond || \
            yellow "提示: 请确认 cron/crond 服务已启动"
        fi
    else
        red "写入 crontab 失败，离线监控未生效"
        return 1
    fi
}

uninstall_tg_monitor() {
    if command_exists crontab; then
        crontab -l 2>/dev/null | grep -v "tg_monitor.sh" | crontab - 2>/dev/null || true
    fi
    rm -f "${work_dir}/tg_monitor.sh" "${work_dir}/tg_monitor.state"
    green "离线监控已卸载"
}


# 适配alpine
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 非交互静默安装（-i 参数；仍走官方优先下载与 IPv4 逻辑）
auto_install() {
    local force_install="${1:-0}"
    if [ -x "${work_dir}/sing-box" ] && [ "$force_install" != "1" ]; then
        yellow "sing-box 已经安装。"
        yellow "如需重装请先执行: sb -u  或使用: sb -i --force"
        exit 1
    fi
    if [ -x "${work_dir}/sing-box" ] && [ "$force_install" = "1" ]; then
        yellow "检测到已安装，--force 将先卸载再安装..."
        auto_uninstall
    fi

    green "开始无交互式安装 sing-box..."
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
        red "不支持的 init 系统，安装中止。"
        exit 1
    fi

    # 给 cloudflared 更多启动时间，再由 get_info 内轮询域名
    sleep 3
    get_info
    add_nginx_conf
    create_shortcut
    if command_exists nginx; then
        if restart_nginx; then
            green "Nginx 已重启完成"
        else
            red "Nginx 重启未成功，请执行: nginx -t && systemctl status nginx.service"
        fi
    fi
    green "\nsing-box 安装完成\n"
}

# 无交互静默卸载（-u 参数），含 nginx
auto_uninstall() {
    green "开始无交互式卸载sing-box..."

    if command_exists rc-service; then
        rc-service sing-box stop  > /dev/null 2>&1
        rc-service argo stop      > /dev/null 2>&1
        rc-update del sing-box default > /dev/null 2>&1
        rc-update del argo default     > /dev/null 2>&1
        rm -f /etc/init.d/sing-box /etc/init.d/argo
    elif command_exists systemctl; then
        systemctl stop    sing-box > /dev/null 2>&1
        systemctl stop    argo     > /dev/null 2>&1
        systemctl disable sing-box > /dev/null 2>&1
        systemctl disable argo     > /dev/null 2>&1
        systemctl daemon-reload    > /dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service \
              /etc/systemd/system/argo.service
    fi

    rm -rf "${work_dir}"
    rm -f /usr/bin/sb

    if command_exists nginx; then
        if command_exists rc-service; then
            rc-service nginx stop   > /dev/null 2>&1
            rc-update del nginx default > /dev/null 2>&1
        elif command_exists systemctl; then
            systemctl stop    nginx > /dev/null 2>&1
            systemctl disable nginx > /dev/null 2>&1
        fi
        rm -f /etc/nginx/conf.d/sing-box.conf /etc/nginx/conf.d/argo-ws.conf /etc/nginx/conf.d/sb-sub.conf
        manage_packages uninstall nginx
        [ -f /etc/nginx/nginx.conf.bak.sb ] && \
            mv /etc/nginx/nginx.conf.bak.sb /etc/nginx/nginx.conf > /dev/null 2>&1
    else
        yellow "nginx 未安装，跳过卸载 nginx。"
    fi

    green "\nsing-box 及 nginx 已完全卸载!\n"
}

# 变更配置
change_config() {
    local singbox_status=$(check_singbox 2>/dev/null)
    local singbox_installed=$?

    if [ $singbox_installed -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
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
            case "${choice}" in
                1)
                    while true; do
                        reading "\n请输入vless-reality端口 (回车跳过将使用随机端口): " new_port
                        [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                            red "端口无效"; continue
                        fi
                        port_really_in_use "$new_port"
                        _rc=$?
                        if [ "$_rc" -eq 0 ]; then
                            red "端口 ${new_port} 已被占用，请重新输入"; continue
                        elif [ "$_rc" -eq 2 ]; then
                            yellow "端口 ${new_port} 检测曾报占用，但系统无实际监听进程，按空闲处理"
                        fi
                        break
                    done
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
                    while true; do
                        reading "\n请输入hysteria2端口 (回车跳过将使用随机端口): " new_port
                        [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                            red "端口无效"; continue
                        fi
                        port_really_in_use "$new_port"
                        _rc=$?
                        if [ "$_rc" -eq 0 ]; then
                            red "端口 ${new_port} 已被占用，请重新输入"; continue
                        elif [ "$_rc" -eq 2 ]; then
                            yellow "端口 ${new_port} 检测曾报占用，但系统无实际监听进程，按空闲处理"
                        fi
                        break
                    done
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
                    while true; do
                        reading "\n请输入tuic端口 (回车跳过将使用随机端口): " new_port
                        [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                            red "端口无效"; continue
                        fi
                        port_really_in_use "$new_port"
                        _rc=$?
                        if [ "$_rc" -eq 0 ]; then
                            red "端口 ${new_port} 已被占用，请重新输入"; continue
                        elif [ "$_rc" -eq 2 ]; then
                            yellow "端口 ${new_port} 检测曾报占用，但系统无实际监听进程，按空闲处理"
                        fi
                        break
                    done
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
                    while true; do
                        reading "\n请输入Argo对外端口 (当前Nginx入口, 回车跳过将使用随机端口): " new_port
                        [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                            red "端口无效"; continue
                        fi
                        port_really_in_use "$new_port"
                        _rc=$?
                        if [ "$_rc" -eq 0 ]; then
                            red "端口 ${new_port} 已被占用，请重新输入"; continue
                        elif [ "$_rc" -eq 2 ]; then
                            yellow "端口 ${new_port} 检测曾报占用，但系统无实际监听进程，按空闲处理"
                        fi
                        break
                    done
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
                    while true; do
                        reading "\n请输入 AnyTLS 端口 (回车随机): " new_port
                        [ -z "$new_port" ] && new_port=$(shuf -i 2000-65000 -n 1)
                        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                            red "端口无效"; continue
                        fi
                        port_really_in_use "$new_port"
                        _rc=$?
                        if [ "$_rc" -eq 0 ]; then
                            red "端口 ${new_port} 已被占用，请重新输入"; continue
                        elif [ "$_rc" -eq 2 ]; then
                            yellow "端口 ${new_port} 检测曾报占用，但系统无实际监听进程，按空闲处理"
                        fi
                        break
                    done
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
            local _vm_line _vm_enc _vm_dec _vm_upd _vm_new
            while IFS= read -r _vm_line; do
                [ -z "$_vm_line" ] && continue
                _vm_enc="${_vm_line#vmess://}"
                _vm_dec=$(echo "$_vm_enc" | b64_decode) || continue
                _vm_upd=$(echo "$_vm_dec" | jq --arg id "$new_uuid" '.id = $id' 2>/dev/null) || continue
                [ -z "$_vm_upd" ] && continue
                _vm_new=$(echo "$_vm_upd" | base64 -w0 2>/dev/null || echo "$_vm_upd" | base64 | tr -d '\n')
                sed -i "s|${_vm_line}|vmess://${_vm_new}|" "$client_dir"
            done < <(grep -o 'vmess://[^[:space:]]*' "$client_dir" 2>/dev/null || true)
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
            isp=$(get_isp "node")
            # [修复] 原实现在删除旧 hysteria2 行之前先记下它的行号，
            # 但 sed 删除后文件整体少了一行，再按旧行号插入会导致新行
            # 比预期位置晚插入一行（off-by-one，纯展示顺序问题，不影响功能）。
            # 改为直接删除后追加到文件末尾，不依赖行号计算。
            sed -i.bak "/hysteria2:/d" $client_dir
            echo "hysteria2://$uuid@$ip:$listen_port?peer=www.bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none&mport=$listen_port,$min_port-$max_port#$isp" >> $client_dir
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
            reading "\n请输入新的节点前缀名称 (回车清空前缀，仅使用 ISP): " new_prefix
            export node_prefix="$new_prefix"

            if [ -z "$new_prefix" ]; then
                prefix_display="(仅使用 ISP)"
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

            if [ -z "$node_prefix" ]; then
                prefix="$isp"
            else
                prefix="${node_prefix}-${isp}"
            fi

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
            local _vm_line _vm_enc _vm_dec _vm_upd _vm_new
            while IFS= read -r _vm_line; do
                [ -z "$_vm_line" ] && continue
                _vm_enc="${_vm_line#vmess://}"
                _vm_dec=$(echo "$_vm_enc" | b64_decode) || continue
                _vm_upd=$(echo "$_vm_dec" | jq --arg ps "${prefix}-argo-vmess" '.ps = $ps' 2>/dev/null) || continue
                [ -z "$_vm_upd" ] && continue
                _vm_new=$(echo "$_vm_upd" | base64 -w0 2>/dev/null || echo "$_vm_upd" | base64 | tr -d '\n')
                sed -i "s|${_vm_line}|vmess://${_vm_new}|" "$client_dir"
            done < <(grep -o 'vmess://[^[:space:]]*' "$client_dir" 2>/dev/null || true)

            refresh_sub
            green "\n节点前缀已更新，可复制以下节点或更新订阅\n"
            while IFS= read -r line; do yellow "$line"; done < "$client_dir"
            ;;
        0) menu ;;
        *) red "无效的选项！\n" ;;
    esac
}

# singbox 管理（优化版：循环 + 状态刷新）
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
                green "\n当前使用固定隧道,无需获取临时域名"; sleep 2; menu
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
                yellow "当前使用固定隧道，无法获取临时隧道"; sleep 2; menu
            fi
            ;;
        0) menu ;;
        *) red "无效的选项！" ;;
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
    # 节点文件不存在时创建空文件，便于后续补写 Argo 节点
    if [ ! -f "$client_dir" ]; then
        mkdir -p "$(dirname "$client_dir")"
        : > "$client_dir"
        yellow "节点文件不存在，已新建: $client_dir"
    fi

    content=$(cat "$client_dir")

    # ---- 解析 uuid / 前缀 / 优选，用于缺失时补建 ----
    local _uuid _isp _prefix _cfip _cfport
    _uuid=$(jq -r '.inbounds[] | select(.users != null) | .users[]? | select(.uuid != null) | .uuid' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
    [ -z "$_uuid" ] && _uuid=$(jq -r '.inbounds[] | select(.users != null) | .users[]? | select(.password != null) | .password' "${conf_dir}/inbounds.json" 2>/dev/null | head -1)
    [ -z "$_uuid" ] && _uuid="${uuid:-}"
    _isp=$(get_isp "node" 2>/dev/null || echo "node")
    if [ -z "${node_prefix:-}" ]; then
        _prefix="$_isp"
    else
        _prefix="${node_prefix}-${_isp}"
    fi
    _cfip="${CFIP:-cdns.doon.eu.org}"
    _cfport="${CFPORT:-443}"

    # 1. 更新已有全部 vmess 的 host/sni
    local _vm_line _vm_enc _vm_dec _vm_upd _vm_new _vm_updated=0
    while IFS= read -r _vm_line; do
        [ -z "$_vm_line" ] && continue
        _vm_enc="${_vm_line#vmess://}"
        _vm_dec=$(echo "$_vm_enc" | b64_decode) || continue
        _vm_upd=$(echo "$_vm_dec" | jq --arg d "$ArgoDomain" '.host = $d | .sni = $d' 2>/dev/null) || continue
        [ -z "$_vm_upd" ] && continue
        _vm_new=$(echo "$_vm_upd" | base64 -w0 2>/dev/null || echo "$_vm_upd" | base64 | tr -d '\n')
        content=$(echo "$content" | sed "s|${_vm_line}|vmess://${_vm_new}|")
        _vm_updated=1
    done < <(grep -o 'vmess://[^[:space:]]*' "$client_dir" 2>/dev/null || true)
    [ "$_vm_updated" = "1" ] && green "vmess 节点已更新"

    # 2. 更新已有 vless-argo（按 path 限定行）
    if echo "$content" | grep -qE 'path=%2Fvless-argo|path=/vless-argo'; then
        content=$(echo "$content" | sed -E "/path=%2Fvless-argo|path=\\/vless-argo/ s#(sni=)[^&[:space:]#]+#\\1${ArgoDomain}#g")
        content=$(echo "$content" | sed -E "/path=%2Fvless-argo|path=\\/vless-argo/ s#(host=)[^&[:space:]#]+#\\1${ArgoDomain}#g")
        green "vless-argo 节点已更新"
    fi

    # 3. 更新已有 trojan-argo
    if echo "$content" | grep -qE 'path=%2Ftrojan-argo|path=/trojan-argo'; then
        content=$(echo "$content" | sed -E "/path=%2Ftrojan-argo|path=\\/trojan-argo/ s#(sni=)[^&[:space:]#]+#\\1${ArgoDomain}#g")
        content=$(echo "$content" | sed -E "/path=%2Ftrojan-argo|path=\\/trojan-argo/ s#(host=)[^&[:space:]#]+#\\1${ArgoDomain}#g")
        green "trojan-argo 节点已更新"
    fi

    # 4. 缺失则补建（安装时域名超时跳过写入后的补救路径）
    if [ -n "$_uuid" ]; then
        if ! echo "$content" | grep -q 'vmess://'; then
            local _vmess_json _vmess_b64
            _vmess_json=$(jq -nc \
                --arg ps "${_prefix}-argo-vmess" \
                --arg add "$_cfip" \
                --argjson port "$(printf '%s' "$_cfport" | grep -E '^[0-9]+$' || echo 443)" \
                --arg id "$_uuid" \
                --arg host "$ArgoDomain" \
                --arg sni "$ArgoDomain" \
                '{v:"2",ps:$ps,add:$add,port:($port|tostring),id:$id,aid:"0",scy:"auto",net:"ws",type:"none",host:$host,path:"/vmess-argo?ed=2560",tls:"tls",sni:$sni,alpn:"",fp:"firefox",allowInsecure:"false"}' 2>/dev/null)
            if [ -n "$_vmess_json" ]; then
                _vmess_b64=$(echo "$_vmess_json" | base64 -w0 2>/dev/null || echo "$_vmess_json" | base64 | tr -d '\n')
                content="${content}"$'\n'"vmess://${_vmess_b64}"
                green "已补建 vmess-argo 节点"
            fi
        fi
        if ! echo "$content" | grep -qE 'path=%2Fvless-argo|path=/vless-argo'; then
            content="${content}"$'\n'"vless://${_uuid}@${_cfip}:${_cfport}?encryption=none&security=tls&sni=${ArgoDomain}&fp=firefox&type=ws&host=${ArgoDomain}&path=%2Fvless-argo%3Fed%3D2560#${_prefix}-argo-vless"
            green "已补建 vless-argo 节点"
        fi
        if ! echo "$content" | grep -qE 'path=%2Ftrojan-argo|path=/trojan-argo'; then
            content="${content}"$'\n'"trojan://${_uuid}@${_cfip}:${_cfport}?security=tls&sni=${ArgoDomain}&fp=firefox&type=ws&host=${ArgoDomain}&path=%2Ftrojan-argo%3Fed%3D2560#${_prefix}-argo-trojan"
            green "已补建 trojan-argo 节点"
        fi
    else
        yellow "未能从配置读取 UUID，若 Argo 节点仍缺失请重新安装或手动补全"
    fi

    # 清理多余空行后写回
    echo "$content" | sed '/^$/N;/^\n$/D' > "$client_dir"
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
    local _vm_line _vm_enc _vm_dec _vm_upd _vm_new _count=0
    while IFS= read -r _vm_line; do
        [ -z "$_vm_line" ] && continue
        _vm_enc="${_vm_line#vmess://}"
        _vm_dec=$(echo "$_vm_enc" | b64_decode) || continue
        _vm_upd=$(echo "$_vm_dec" | jq --arg cfip "$cfip" --argjson cfport "$cfport" '.add = $cfip | .port = ($cfport|tonumber)' 2>/dev/null) || continue
        [ -z "$_vm_upd" ] && continue
        _vm_new=$(echo "$_vm_upd" | base64 -w0 2>/dev/null || echo "$_vm_upd" | base64 | tr -d '\n')
        sed -i "s|${_vm_line}|vmess://${_vm_new}|" "$client_dir"
        _count=$((_count + 1))
    done < <(grep -o 'vmess://[^[:space:]]*' "$client_dir" 2>/dev/null || true)

    # 同步更新 argo 的 vless/trojan 节点中的 CFIP:CFPORT（仅 argo path 行）
    sed -i -E "/path=%2Fvless-argo|path=\/vless-argo/ s#@[^:?]+(:[0-9]+)?\?#@${cfip}:${cfport}?#" "$client_dir" 2>/dev/null || true
    sed -i -E "/path=%2Ftrojan-argo|path=\/trojan-argo/ s#@[^:?]+(:[0-9]+)?\?#@${cfip}:${cfport}?#" "$client_dir" 2>/dev/null || true

    export CFIP="$cfip" CFPORT="$cfport"
    refresh_sub
    green "\n优选域名已更新为：${purple}${cfip}:${cfport}${re}（vmess 更新 ${_count} 条）\n"
}

# WARP 分流管理
warp_manage() {
    check_singbox &>/dev/null
    if [ $? -eq 2 ]; then
        yellow "sing-box 尚未安装！"; sleep 1; menu; return
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
        0)  menu ;;
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
        yellow "sing-box 尚未安装！请先安装 sing-box。"; sleep 2; menu; return
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
        0) menu; return ;;
        *) red "无效的选项！" ;;
    esac
    read -n 1 -s -r -p $'\n\033[1;91m按任意键返回协议管理菜单...\033[0m\n'
    manage_protocols
}

# 主菜单
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
