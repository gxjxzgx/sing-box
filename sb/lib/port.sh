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
