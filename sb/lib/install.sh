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
            reading "请输入节点前缀名称 (回车默认使用服务商名称；自定义后不再附加服务商): " node_prefix
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

