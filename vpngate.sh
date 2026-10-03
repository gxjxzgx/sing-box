#!/bin/sh
# VPN Gate (OpenVPN) -> SOCKS5，Alpine + OpenRC 版
# 用法: sh vpngate-socks5-alpine.sh /root/vpngate.ovpn

set -e

OVPN_SRC="$1"
SOCKS_PORT=60002
SOCKS_USER="${SOCKS_USER:-zhoo}"
SOCKS_PASS="${SOCKS_PASS:-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
DIR=/etc/vpngate

# 没给 .ovpn 参数就自动从 VPN Gate 下载（默认选日本评分最高的节点）
if [ -z "$OVPN_SRC" ]; then
  COUNTRY="${COUNTRY:-JP}"
  OVPN_SRC=/root/vpngate.ovpn
  apk add --no-cache wget ca-certificates
  echo "自动下载 VPN Gate ${COUNTRY} 节点..."
  wget -qO- https://www.vpngate.net/api/iphone/ | tr -d '\r' \
    | grep ",${COUNTRY}," | sort -t, -k3 -nr | head -1 \
    | awk -F, '{print $15}' | base64 -d > "$OVPN_SRC" || true
fi
[ -s "$OVPN_SRC" ] || { echo "没有可用的 .ovpn 文件: $OVPN_SRC"; exit 1; }
[ -c /dev/net/tun ] || { echo "/dev/net/tun 不存在：容器没开 TUN，需要联系服务商开启"; exit 1; }

# 1. 安装依赖
apk add --no-cache openvpn iproute2
if ! apk add --no-cache microsocks; then
  apk add --no-cache git build-base
  git clone https://github.com/rofl0r/microsocks /tmp/microsocks
  make -C /tmp/microsocks
  install -m 755 /tmp/microsocks/microsocks /usr/local/bin/microsocks
fi

# 2. 配置（去掉 redirect-gateway，不接管默认路由）
mkdir -p $DIR
grep -v '^redirect-gateway' "$OVPN_SRC" > $DIR/vpngate.ovpn
echo "route-nopull" >> $DIR/vpngate.ovpn

cat > $DIR/socks.env <<EOF
SOCKS_PORT=${SOCKS_PORT}
SOCKS_USER=${SOCKS_USER}
SOCKS_PASS=${SOCKS_PASS}
EOF
chmod 600 $DIR/socks.env

# 3. 策略路由：只有来自 tun 地址的流量走 VPN
cat > $DIR/up.sh <<'EOF'
#!/bin/sh
DEV="$1"; LOCAL="$4"
ip rule del from "$LOCAL" table 100 2>/dev/null || true
ip rule add from "$LOCAL" table 100
ip route replace default dev "$DEV" table 100
# 重连后 tun 地址可能变化，杀掉 microsocks 让它重新绑定
pkill -x microsocks 2>/dev/null || true
EOF

cat > $DIR/down.sh <<'EOF'
#!/bin/sh
LOCAL="$4"
ip rule del from "$LOCAL" table 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true
EOF

cat > $DIR/socks.sh <<'EOF'
#!/bin/sh
. /etc/vpngate/socks.env
TUNIP=""
for i in $(seq 1 60); do
  TUNIP=$(ip -4 -o addr show tun0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  [ -n "$TUNIP" ] && break
  sleep 1
done
[ -z "$TUNIP" ] && { echo "tun0 未就绪"; exit 1; }
exec microsocks -i 0.0.0.0 -p "$SOCKS_PORT" -b "$TUNIP" -u "$SOCKS_USER" -P "$SOCKS_PASS"
EOF
chmod +x $DIR/*.sh

# 4. OpenRC 服务（supervise-daemon 自动重启）
cat > /etc/init.d/vpngate-ovpn <<'EOF'
#!/sbin/openrc-run
description="VPN Gate OpenVPN client"
supervisor=supervise-daemon
command="/usr/sbin/openvpn"
command_args="--config /etc/vpngate/vpngate.ovpn --dev tun0 --dev-type tun --script-security 2 --up /etc/vpngate/up.sh --down /etc/vpngate/down.sh --data-ciphers AES-256-GCM:AES-128-GCM:AES-128-CBC --data-ciphers-fallback AES-128-CBC --ping 10 --ping-restart 30 --persist-tun"
respawn_delay=10
respawn_max=0
depend() {
  need net
}
EOF

cat > /etc/init.d/vpngate-socks <<'EOF'
#!/sbin/openrc-run
description="SOCKS5 via VPN Gate tun0"
supervisor=supervise-daemon
command="/etc/vpngate/socks.sh"
respawn_delay=5
respawn_max=0
depend() {
  need net
  after vpngate-ovpn
}
EOF
chmod +x /etc/init.d/vpngate-ovpn /etc/init.d/vpngate-socks

rc-update add vpngate-ovpn default
rc-update add vpngate-socks default
rc-service vpngate-ovpn restart
rc-service vpngate-socks restart

echo
echo "完成。SOCKS5 端口: ${SOCKS_PORT}  用户: ${SOCKS_USER}  密码: ${SOCKS_PASS}"
echo "测试: curl --socks5 ${SOCKS_USER}:${SOCKS_PASS}@127.0.0.1:${SOCKS_PORT} ifconfig.me"
