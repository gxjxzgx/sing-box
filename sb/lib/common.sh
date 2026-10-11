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

# [优化新增] 统一批量更新 vmess 节点字段
# 原脚本在"改UUID"/"改节点前缀"/"改优选IP"三处，各自重复写了一遍几乎相同的
# "读取所有 vmess:// 行 → base64解码 → jq改字段 → 重新编码写回 $client_dir"
# 循环（9行左右/处）。这里抽成通用函数，用法与直接调用 jq 一致：
#   update_all_vmess --arg id "$new_uuid" '.id = $id'
#   update_all_vmess --arg cfip "$cfip" --argjson cfport "$cfport" '.add=$cfip|.port=($cfport|tonumber)'
# 保留原有的 --arg/--argjson 传参方式（不做字符串拼接），避免变量注入风险。
# 直接原地更新 $client_dir，echo 输出成功更新的条数，调用方按需接收。
update_all_vmess() {
    local _vm_line _vm_enc _vm_dec _vm_upd _vm_new _count=0
    while IFS= read -r _vm_line; do
        [ -z "$_vm_line" ] && continue
        _vm_enc="${_vm_line#vmess://}"
        _vm_dec=$(echo "$_vm_enc" | b64_decode) || continue
        _vm_upd=$(echo "$_vm_dec" | jq "$@" 2>/dev/null) || continue
        [ -z "$_vm_upd" ] && continue
        _vm_new=$(echo "$_vm_upd" | base64 -w0 2>/dev/null || echo "$_vm_upd" | base64 | tr -d '\n')
        sed -i "s|${_vm_line}|vmess://${_vm_new}|" "$client_dir"
        _count=$((_count + 1))
    done < <(grep -o 'vmess://[^[:space:]]*' "$client_dir" 2>/dev/null || true)
    echo "$_count"
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
