#!/bin/bash
# tailscale-aliyun-fix.sh
# 一键解决 Tailscale 与阿里云 VPC / Workbench 网络冲突
# 适用系统: Ubuntu 18.04+ / Debian 10+ / CentOS 7+
# 使用方法: sudo bash tailscale-aliyun-fix.sh

set -e

echo "=== Tailscale + 阿里云 内网 / Workbench 冲突修复脚本 ==="

# ---------- 1. sysctl 配置 ----------
echo "[1/6] 配置 sysctl..."
cat > /etc/sysctl.d/99-tailscale-aliyun.conf << 'EOF'
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
EOF
sysctl --system > /dev/null 2>&1
echo "  sysctl 配置完成"

# ---------- 2. 出站路由脚本 ----------
echo "[2/6] 创建阿里云内网路由脚本..."
cat > /usr/local/bin/tailscale-aliyun-route.sh << 'SCRIPT'
#!/bin/bash
# 阿里云关键内网 IP（按需增删）
ALIYUN_IPS=(
  100.100.100.200/32  # 实例元数据
  100.100.100.100/32  # 备用元数据
  100.100.2.136/32    # 内网 YUM 源
  100.100.2.138/32    # 内网 YUM 源
  100.100.2.148/32    # 内网镜像源
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

# ---------- 3. 出站路由 systemd 服务 ----------
echo "[3/6] 创建阿里云内网路由 systemd 服务..."
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
systemctl restart tailscale-aliyun-route.service
echo "  路由 systemd 服务已启动"

# ---------- 4. Workbench 入站修复 ----------
echo "[4/6] 创建 Workbench 入站 SSH 放行脚本..."
cat > /usr/local/sbin/allow-aliyun-workbench-ssh << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CHAIN="ts-input"
IFACE="eth0"
DROP_SRC="100.64.0.0/10"
WORKBENCH_SRC="100.104.0.0/16"

insert_before_tailscale_drop() {
  local rule=("$@")

  while iptables -C "$CHAIN" "${rule[@]}" >/dev/null 2>&1; do
    iptables -D "$CHAIN" "${rule[@]}"
  done

  local drop_line
  drop_line=$(iptables -L "$CHAIN" --line-numbers -n | awk -v src="$DROP_SRC" '$2 == "DROP" && $5 == src {print $1; exit}')
  if [ -n "${drop_line:-}" ]; then
    iptables -I "$CHAIN" "$drop_line" "${rule[@]}"
  else
    iptables -A "$CHAIN" "${rule[@]}"
  fi
}

for _ in $(seq 1 30); do
  if iptables -nL "$CHAIN" >/dev/null 2>&1; then
    insert_before_tailscale_drop -i "$IFACE" -s "$DROP_SRC" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    insert_before_tailscale_drop -i "$IFACE" -s "$WORKBENCH_SRC" -p tcp --dport 22 -j RETURN
    exit 0
  fi
  sleep 1
done

echo "Tailscale chain $CHAIN not found" >&2
exit 1
SCRIPT
chmod +x /usr/local/sbin/allow-aliyun-workbench-ssh

cat > /etc/systemd/system/allow-aliyun-workbench-ssh.service << 'EOF'
[Unit]
Description=Allow Alibaba Cloud Workbench SSH before Tailscale CGNAT drop
After=network-online.target tailscaled.service ssh.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/allow-aliyun-workbench-ssh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/system/tailscaled.service.d
cat > /etc/systemd/system/tailscaled.service.d/20-aliyun-workbench.conf << 'EOF'
[Service]
ExecStartPost=/usr/local/sbin/allow-aliyun-workbench-ssh
EOF

systemctl daemon-reload
systemctl enable allow-aliyun-workbench-ssh.service
systemctl restart allow-aliyun-workbench-ssh.service
echo "  Workbench 入站 SSH 放行已启用"

# ---------- 5. 验证 ----------
echo "[5/6] 验证阿里云内网路由..."
echo ""
echo "策略路由规则:"
ip rule list | grep -E "520[0-9]" || echo "  (无规则，可能阿里云内网 IP 段无冲突)"
echo ""
echo "100.100.100.200 路由走向:"
ip route get 100.100.100.200 2>/dev/null || echo "  (查询失败)"
echo ""
echo "元数据服务测试:"
META_RESP=$(curl -s --connect-timeout 3 http://100.100.100.200/latest/meta-data/instance-id 2>/dev/null)
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

echo "[6/6] 验证 Workbench 入站放行规则..."
echo ""
echo "Workbench 修复服务:"
systemctl is-enabled allow-aliyun-workbench-ssh.service 2>/dev/null || true
systemctl is-active allow-aliyun-workbench-ssh.service 2>/dev/null || true
echo ""
echo "Tailscale ts-input 规则:"
iptables -L ts-input -n -v --line-numbers 2>/dev/null | grep -E "100\\.104\\.0\\.0/16|100\\.64\\.0\\.0/10|DROP" || echo "  (未找到 ts-input，可能 Tailscale 尚未创建防火墙链)"
echo ""
echo "=== 修复完成 ==="
