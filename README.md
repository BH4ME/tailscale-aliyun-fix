# Tailscale 与阿里云内网冲突解决方案

## 问题背景

Tailscale 和阿里云 VPC 都使用 `100.64.0.0/10`（CGNAT 地址段），导致路由冲突。安装 Tailscale 后，阿里云关键内网服务可能不可达。

### 受影响的阿里云内网服务

| 服务 | IP 地址 | 用途 |
|------|---------|------|
| 实例元数据 | `100.100.100.100` | 获取实例 ID、Region、RAM 角色凭证等 |
| 内网 YUM/APT 源 | `100.100.2.136`, `100.100.2.138` 等 | 软件包更新 |
| 内网 DNS | DHCP 分配 | DNS 解析 |
| 内网 NTP | `100.100.1.x` 等 | 时间同步 |
| SLB 健康检查 | `100.64.0.0/10` 内地址 | 负载均衡健康探测 |

## 诊断

### 1. 确认冲突

```bash
# 查看 Tailscale 路由表（优先级 5270，高于 main 表的 32766）
ip rule list

# 查看 Tailscale 路由表是否劫持了阿里云 IP
ip route show table 52 | grep 100

# 测试元数据服务是否可达
curl -s http://100.100.100.100/latest/meta-data/instance-id
```

如果元数据服务返回 Tailscale Web UI 的 HTML 页面而不是实例 ID，说明存在冲突。

### 2. 查看当前阿里云内网路由

```bash
# 主路由表中 DHCP 下发的阿里云内网路由
ip route show table main | grep "100."
```

## 解决方案

核心思路：为阿里云关键内网 IP 添加高优先级策略路由规则，让这些流量走主路由表（eth0），而非 Tailscale 的 table 52。

### 步骤 1：关闭反向路径过滤（rp_filter）

Tailscale 的非对称路由与 rp_filter 不兼容。

```bash
# 创建 sysctl 配置文件
cat > /etc/sysctl.d/99-tailscale-aliyun.conf << 'EOF'
# 关闭反向路径过滤（Tailscale 非对称路由必需）
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# 开启 IP 转发（子网路由/Exit Node 需要）
net.ipv4.ip_forward = 1
EOF

# 立即生效
sysctl --system
```

### 步骤 2：添加策略路由规则

为需要绕开 Tailscale 的阿里云内网 IP 添加策略路由规则，优先级必须高于 Tailscale 的 rule 5270。

```bash
# 元数据服务（最关键）
ip rule add to 100.100.100.100/32 table main priority 5200

# 内网软件源（如果有多个 IP，逐个添加或使用网段）
ip rule add to 100.100.2.136/32 table main priority 5201
ip rule add to 100.100.2.138/32 table main priority 5202
```

> **优先级说明**：数字越小优先级越高。Tailscale 的 rule 在 5270，所以我们的规则必须使用小于 5270 的数字。

### 步骤 3：持久化路由规则

编辑 `/etc/network/interfaces` 或创建 systemd 服务，使重启后规则自动生效。

**方案 A：networkd-dispatcher（推荐，适用 Ubuntu 18.04+）**

```bash
cat > /etc/networkd-dispatcher/routable.d/50-tailscale-aliyun << 'SCRIPT'
#!/bin/bash
# 添加阿里云内网 IP 的策略路由，避免被 Tailscale 劫持

ALIYUN_IPS=(
  100.100.100.100/32  # 元数据服务
  100.100.2.136/32    # 内网 YUM 源
  100.100.2.138/32    # 内网 YUM 源
)

PRIORITY=5200
for ip in "${ALIYUN_IPS[@]}"; do
  # 先删除可能已存在的规则，再添加
  ip rule del to "$ip" table main 2>/dev/null
  ip rule add to "$ip" table main priority $PRIORITY
  PRIORITY=$((PRIORITY + 1))
done
SCRIPT

chmod +x /etc/networkd-dispatcher/routable.d/50-tailscale-aliyun
```

**方案 B：systemd 服务（通用方案）**

```bash
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

cat > /usr/local/bin/tailscale-aliyun-route.sh << 'SCRIPT'
#!/bin/bash
# 阿里云关键内网 IP 列表
ALIYUN_IPS=(
  100.100.100.100/32
  100.100.2.136/32
  100.100.2.138/32
)

PRIORITY=5200
for ip in "${ALIYUN_IPS[@]}"; do
  ip rule del to "$ip" table main 2>/dev/null
  ip rule add to "$ip" table main priority $PRIORITY
  PRIORITY=$((PRIORITY + 1))
done
SCRIPT

chmod +x /usr/local/bin/tailscale-aliyun-route.sh
systemctl daemon-reload
systemctl enable tailscale-aliyun-route.service
systemctl start tailscale-aliyun-route.service
```

### 步骤 4：验证

```bash
# 1. 确认策略路由规则生效（优先级 < 5270）
ip rule list | grep -E "520[0-9]"

# 2. 确认阿里云 IP 走 eth0 而非 tailscale0
ip route get 100.100.100.100
# 期望输出: 100.100.100.100 via <gateway> dev eth0 ...

# 3. 确认元数据服务正常
curl -s http://100.100.100.100/latest/meta-data/instance-id
# 期望输出: i-xxxxxxxxxxxxx

curl -s http://100.100.100.100/latest/meta-data/region-id
# 期望输出: cn-xxxxxxx

# 4. 确认 Tailscale 仍正常工作
tailscale status
tailscale ping <另一台Tailscale节点>
```

## 完整自动化脚本

如果你需要在多台服务器上操作，可以直接运行以下脚本：

```bash
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
```

## 原理说明

```
默认策略路由优先级:
  0:      local 表（本地地址）
  5210-5250: Tailscale fwmark 规则
  5270:   Tailscale table 52（接管所有 100.64.0.0/10 流量）
  32766:  main 表
  32767:  default 表

修复后:
  0:      local 表
  5200:   阿里云元数据 → main 表（新增，优先于 Tailscale）
  5210-5250: Tailscale fwmark 规则
  5270:   Tailscale table 52（其余 100.x 流量仍走 Tailscale）
  32766:  main 表
  32767:  default 表
```

关键点：为阿里云 IP 添加优先级 5200 的规则，数字小于 5270，会先于 Tailscale 的路由表被匹配，从而绕过 Tailscale 直连 eth0。

## 常见问题

**Q: 如何找到所有需要绕行的阿里云内网 IP？**
```bash
# 方法1: 查看 DHCP 下发的阿里云路由
ip route show table main | grep "100."

# 方法2: 抓包分析（安装 Tailscale 前）
tcpdump -i eth0 -n net 100.64.0.0/10

# 方法3: 检查系统日志中的连接超时
dmesg | grep -i "unreachable\|timeout"
```

**Q: 如果不知道网关地址怎么办？**
```bash
# 获取默认网关
ip route show | grep default
# 或从 DHCP 记录中查找
cat /var/lib/dhcp/dhclient.*.leases | grep routers
```

**Q: 这个方案会影响 Tailscale 正常功能吗？**
不会。只是让特定的阿里云内网 IP 绕过 Tailscale 路由，其余流量（包括 Tailscale 节点间通信）不受影响。

**Q: 其他云厂商有类似问题吗？**
有。AWS、Azure、GCP 也使用 100.64.0.0/10 的子集用于内部服务，但冲突范围不同。本方案思路通用，只需替换对应的内网 IP 列表。

## 参考资料

- [Tailscale 文档: Unusual NAT Situations](https://tailscale.com/kb/1180/unusual-nat)
- [阿里云 ECS 实例元数据](https://help.aliyun.com/document_detail/49122.html)
- [Tailscale 源码: CGNAT range choice](https://github.com/tailscale/tailscale/blob/main/wgengine/router/router_linux.go)
