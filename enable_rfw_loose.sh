#!/bin/bash
set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查并启动服务
start_service() {
    systemctl daemon-reload
    local service=$1
    if ! systemctl is-active --quiet $service; then
        log "启动 $service 服务..."
        systemctl start $service
    else
        log "$service 服务已在运行"
    fi

    if ! systemctl is-enabled --quiet $service; then
        log "启用 $service 服务..."
        systemctl enable $service
    else
        log "$service 服务已启用"
    fi
}

# 带重试的下载函数
download_with_retry() {
    local url=$1
    local output=$2
    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log "下载 $url (第 $attempt 次)..."
        if curl -L -o "$output" "$url"; then
            return 0
        else
            log "下载失败"
            if [ $attempt -eq $max_attempts ]; then
                log "下载失败，已达最大重试次数"
                return 1
            fi
            attempt=$((attempt + 1))
            sleep 5
        fi
    done
}

# 主脚本
log "开始安装 rfw 防火墙..."

# ------------------------------------
# 检测旧版本并清理（最终稳定版本）
# ------------------------------------
if systemctl list-unit-files | grep -q "rfw.service"; then
    log "检测到旧版本 rfw，开始清理..."

    # 停止服务
    systemctl stop rfw 2>/dev/null || true

    # 禁用服务
    systemctl disable rfw 2>/dev/null || true

    # 删除旧 service 文件（多个位置）
    rm -f /etc/systemd/system/rfw.service
    rm -f /usr/lib/systemd/system/rfw.service
    rm -f /lib/systemd/system/rfw.service

    # 删除程序目录
    rm -rf /root/rfw

    systemctl daemon-reload
    log "旧版本 rfw 已清理完成"
fi

# ------------------------------------
# 检测架构
# ------------------------------------
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        ARCH_SUFFIX="x86_64"
        ;;
    aarch64|arm64)
        ARCH_SUFFIX="aarch64"
        ;;
    *)
        log "❌ 不支持架构: $ARCH (仅支持 x86_64 / aarch64)"
        exit 1
        ;;
esac

log "检测到架构: $ARCH ($ARCH_SUFFIX)"

# ------------------------------------
# 检查 curl
# ------------------------------------
if ! command -v curl &>/dev/null; then
    log "安装 curl..."
    if command -v apt &>/dev/null; then
        apt update && apt install -y curl
    elif command -v yum &>/dev/null; then
        yum install -y curl
    else
        log "错误: 无法安装 curl，请手动安装。"
        exit 1
    fi
fi

# ------------------------------------
# 开始安装 rfw
# ------------------------------------
log "下载 rfw 程序..."

mkdir -p /root/rfw

if ! download_with_retry \
    "https://github.com/narwhal-cloud/rfw/releases/latest/download/rfw-$ARCH-unknown-linux-musl" \
    "/root/rfw/rfw"; then
    log "rfw 下载失败"
    exit 1
fi

chmod +x /root/rfw/rfw

# ------------------------------------
# 创建 systemd 服务
# ------------------------------------
log "创建 rfw 系统服务..."

interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))

if [ ${#interfaces[@]} -eq 0 ]; then
    echo "未找到网络接口！"
    exit 1
fi

echo "可用的网络接口："
for i in "${!interfaces[@]}"; do
    echo "$((i+1)). ${interfaces[$i]}"
done

while true; do
    read -p "请选择网卡编号(1-${#interfaces[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#interfaces[@]} ]; then
        selected_interface="${interfaces[$((choice-1))]}"
        break
    else
        echo "无效输入，请重新选择。"
    fi
done

echo "使用网卡: $selected_interface"

cat >/etc/systemd/system/rfw.service <<EOF
[Unit]
Description=RFW Firewall Service
After=network.target

[Service]
Type=simple
User=root
Environment=RUST_LOG=info
ExecStart=/root/rfw/rfw --iface $selected_interface --block-email --block-http --block-socks5 --block-fet-loose --block-wireguard --countries CN
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ------------------------------------
# 启动服务
# ------------------------------------
start_service rfw

# ------------------------------------
# 显示服务状态
# ------------------------------------
log "rfw 服务状态如下："
systemctl status rfw
