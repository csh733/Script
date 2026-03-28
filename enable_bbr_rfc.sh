#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0"
  exit 1
fi

CONF_FILE="/etc/sysctl.d/99-bbr-proxy.conf"
BACKUP_FILE="${CONF_FILE}.bak.$(date +%F-%H%M%S)"

echo "======================================"
echo " BBR + Provider Sysctl (独立配置文件)"
echo "======================================"

echo "[1/6] 当前内核"
uname -r

echo
echo "[2/6] 检查 BBR 模块"

if ! modinfo tcp_bbr >/dev/null 2>&1; then
  echo "错误：当前内核未包含 tcp_bbr 模块"
  exit 1
fi

if ! lsmod | grep -q tcp_bbr; then
  echo "BBR 未加载 -> 正在加载"
  modprobe tcp_bbr
else
  echo "BBR 已加载"
fi

echo "设置开机自动加载"
echo tcp_bbr > /etc/modules-load.d/bbr.conf

echo
echo "[3/6] 检查拥塞控制支持"
sysctl -n net.ipv4.tcp_available_congestion_control || true

echo
echo "[4/6] 处理旧配置"

if [[ -f "$CONF_FILE" ]]; then
  cp "$CONF_FILE" "$BACKUP_FILE"
  echo "旧配置已备份: $BACKUP_FILE"
fi

echo
echo "[5/6] 写入新配置 -> $CONF_FILE"

cat > "$CONF_FILE" <<'EOF'

# ===== Provider Network Tuning =====
fs.file-max                     = 6815744
net.ipv4.tcp_max_syn_backlog    = 8192
net.core.somaxconn              = 8192
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_abort_on_overflow  = 1
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_no_metrics_save    = 1
net.ipv4.tcp_ecn                = 0
net.ipv4.tcp_frto               = 0
net.ipv4.tcp_mtu_probing        = 0
net.ipv4.tcp_rfc1337            = 1
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_fack               = 1
net.ipv4.tcp_window_scaling     = 1
net.ipv4.tcp_adv_win_scale      = 2
net.ipv4.tcp_moderate_rcvbuf    = 1
net.ipv4.tcp_fin_timeout        = 30
net.ipv4.tcp_rmem               = 4096 87380 67108864
net.ipv4.tcp_wmem               = 4096 65536 67108864
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.ipv4.udp_rmem_min           = 8192
net.ipv4.udp_wmem_min           = 8192
net.ipv4.ip_local_port_range    = 1024 65535
net.ipv4.tcp_timestamps         = 1
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward             = 1
net.ipv6.conf.all.forwarding    = 1
net.ipv6.conf.default.forwarding= 1
net.ipv4.conf.all.route_localnet= 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

EOF

echo
echo "[6/6] 应用配置"
sysctl --system

echo
echo "=========== 验证结果 ==========="
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
lsmod | grep bbr || true

echo
echo "完成"
echo "配置文件: $CONF_FILE"
[[ -f "$BACKUP_FILE" ]] && echo "旧配置备份: $BACKUP_FILE"
