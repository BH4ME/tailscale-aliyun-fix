#!/bin/bash
# tailscale-aliyun-fix.sh
# 一键解决 Tailscale 与阿里云 VPC 网络冲突
# 适用系统: Ubuntu 18.04+ / Debian 10+ / CentOS 7+
# 使用方法: sudo bash tailscale-aliyun-fix.sh

set -e

echo "=== Tailscale + 阿里云 内网冲突修复脚本 ==="

# ---------- 1. sysctl 配置 ----------
echo "[1/4] 配置 sysctl..."
cat > /etc/sysctl.d/99-tailscale-aliyun.conf << 'EOF'
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
EOF
sysctl --system > /dev/null 2>&1
echo "  sysctl 配置完成"

# ---------- 2. 路由脚本 ----------
echo "[2/4] 创建路由脚本..."
cat > /usr/local/bin/tailscale-aliyun-route.sh << 'SCRIPT'
#!/bin/bash
# 阿里云关键内网 IP（按需增删）
ALIYUN_IPS=(
  100.100.100.100/32  # 实例元数据
  100.100.2.136/32    # 内网 YUM 源
  100.100.2.138/32    # 内网 YUM 源
)

PRIORITY=5200
for ip in "${ALIYUN_IPS[@]}"; do
  ip rule del to "$ip" table main 2>/dev/null
  ip rule add to "$ip" table main priority $PRIORITY
  PRIORITY=$((PRIORITY + 1))
done
SCRIPT
chmod +x /usr/local/bin/tailscale-aliyun-route.sh
echo "  路由脚本创建完成"

# ---------- 3. systemd 服务 ----------
echo "[3/4] 创建 systemd 服务..."
cat > /etc/systemd/system/tailscale-aliyun-route.service << 'EOF'
[Unit]
Description=Add Alibaba Cloud internal routes to bypass Tailscale
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/tailscale-aliyun-route.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tailscale-aliyun-route.service
systemctl start tailscale-aliyun-route.service
echo "  systemd 服务已启动"

# ---------- 4. 验证 ----------
echo "[4/4] 验证..."
echo ""
echo "策略路由规则:"
ip rule list | grep -E "520[0-9]" || echo "  (无规则，可能阿里云内网 IP 段无冲突)"
echo ""
echo "100.100.100.100 路由走向:"
ip route get 100.100.100.100 2>/dev/null || echo "  (查询失败)"
echo ""
echo "元数据服务测试:"
META_RESP=$(curl -s --connect-timeout 3 http://100.100.100.100/latest/meta-data/instance-id 2>/dev/null)
if [[ "$META_RESP" == i-* ]]; then
  echo "  成功! 实例 ID: $META_RESP"
else
  echo "  返回内容: ${META_RESP:0:100}..."
  echo "  (如果不是 i-xxx 格式，请检查网关是否正确)"
fi
echo ""
echo "Tailscale 状态:"
tailscale status 2>/dev/null | head -3
echo ""
echo "=== 修复完成 ==="
