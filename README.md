# Tailscale + 阿里云 VPC / Workbench 冲突解决方案

[![License](https://img.shields.io/github/license/BH4ME/tailscale-aliyun-fix)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-blue)](tailscale-aliyun-fix.sh)

Tailscale 和阿里云 VPC 都使用 `100.64.0.0/10`（CGNAT 地址段），容易触发两类冲突：

- 出站：实例元数据、内网 DNS、YUM/APT 源等阿里云内网地址被 Tailscale 策略路由接管。
- 入站：阿里云 Workbench 从 `100.x` 内网来源连接 SSH 时，被 Tailscale 的 `ts-input` 防伪造规则误丢弃，表现为 `SocketTimeoutException`、Workbench 转圈或连接后卡死。

本项目提供一键修复方案，同时保留 Tailscale 原本的安全保护。

## 问题

### 冲突原因

Tailscale 默认通过策略路由（priority 5270）接管部分 `100.64.0.0/10` 流量，而阿里云 VPC 也将内部服务部署在同一网段。导致访问 `100.100.100.200`（元数据服务）等地址时，流量可能被错误地路由到 Tailscale 而非 `eth0`。

同时，Tailscale 会在 `ts-input` 链中添加防伪造规则：

```text
DROP !tailscale0 100.64.0.0/10
```

该规则本身是合理的，但阿里云 Workbench 的 SSH 流量也可能从 `100.x` 来源地址经 `eth0` 进入实例，因此会被提前丢弃。

### 受影响的服务

| 服务 | IP 地址 | 影响 |
|------|---------|------|
| 实例元数据 | `100.100.100.200` | 无法获取实例 ID、Region、RAM 角色凭证 |
| 内网 YUM/APT 源 | `100.100.2.136`, `100.100.2.138` | 软件包更新失败 |
| 内网 DNS | DHCP 分配 | DNS 解析异常 |
| SLB 健康检查 | `100.64.0.0/10` 内地址 | 负载均衡健康探测失败 |
| Workbench SSH | 常见 `100.104.0.0/16` 来源 | `SocketTimeoutException`、SSH 超时 |

## 快速开始

```bash
# 下载并运行
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/BH4ME/tailscale-aliyun-fix/master/tailscale-aliyun-fix.sh)"
```

## 诊断

```bash
# 1. 查看 Tailscale 路由表（优先级 5270）
ip rule list

# 2. 检查 100.x 流量是否被 Tailscale 劫持
ip route show table 52 | grep 100

# 3. 测试元数据服务是否可达
curl -s http://100.100.100.200/latest/meta-data/instance-id

# 4. 查看 Tailscale 入站防火墙链
sudo iptables -L ts-input -n -v --line-numbers
```

如果 curl 返回的是 Tailscale Web UI 的 HTML，说明存在冲突。

如果 Workbench 连接报 `SocketTimeoutException`，且 `ts-input` 中 `DROP !tailscale0 100.64.0.0/10` 的计数增加，通常说明 Workbench 入站 SSH 被误丢弃。

## 手动修复

### 1. 关闭 rp_filter

```bash
cat > /etc/sysctl.d/99-tailscale-aliyun.conf << 'EOF'
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
EOF

sysctl --system
```

### 2. 添加策略路由规则

```bash
# 元数据服务
ip rule add to 100.100.100.200/32 table main priority 5200

# 内网软件源
ip rule add to 100.100.2.136/32 table main priority 5201
ip rule add to 100.100.2.138/32 table main priority 5202
```

> **注意**：priority 必须小于 5270（Tailscale 的优先级），数字越小优先级越高。

### 3. 持久化（systemd）

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

# 从本仓库复制路由脚本
cp tailscale-aliyun-fix.sh /usr/local/bin/tailscale-aliyun-route.sh
chmod +x /usr/local/bin/tailscale-aliyun-route.sh

systemctl daemon-reload
systemctl enable --now tailscale-aliyun-route.service
```

### 4. 放行 Workbench 入站 SSH

```bash
cat > /usr/local/sbin/allow-aliyun-workbench-ssh << 'EOF'
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

insert_before_tailscale_drop -i "$IFACE" -s "$DROP_SRC" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
insert_before_tailscale_drop -i "$IFACE" -s "$WORKBENCH_SRC" -p tcp --dport 22 -j RETURN
EOF

chmod +x /usr/local/sbin/allow-aliyun-workbench-ssh
```

### 5. 验证

```bash
# 确认规则生效（优先级 < 5270）
ip rule list | grep "520[0-9]"

# 确认元数据服务走 eth0
ip route get 100.100.100.200
# 期望: 100.100.100.200 via <网关> dev eth0 src <内网IP>

# 测试元数据服务
curl -s http://100.100.100.200/latest/meta-data/instance-id
# 期望: i-xxxxxxxxxxxxx

# 测试 Tailscale 仍正常
tailscale ping <另一节点>

# 确认 Workbench 放行在 Tailscale DROP 前
sudo iptables -L ts-input -n -v --line-numbers
```

## 原理

```
修复前:
  0:      local 表
  5270:   Tailscale table 52（接管所有 100.64.0.0/10）
  32766:  main 表

修复后:
  0:      local 表
  5200:   阿里云关键 IP → main 表  ← 新增，优先于 Tailscale
  5270:   Tailscale table 52
  32766:  main 表
```

为阿里云内网 IP 添加优先级 5200 的策略路由规则，数字小于 5270，会先于 Tailscale 被匹配，流量直连 eth0。

Workbench 修复则是在 `ts-input` 的 `DROP !tailscale0 100.64.0.0/10` 前插入两条更窄的 `RETURN` 规则：

```text
RETURN eth0 100.64.0.0/10 ctstate RELATED,ESTABLISHED
RETURN tcp eth0 100.104.0.0/16 tcp dpt:22
DROP   !tailscale0 100.64.0.0/10
```

这样既允许阿里云内网回包和 Workbench SSH 进入，又不会直接移除 Tailscale 的 CGNAT 防伪造保护。

安装脚本还会添加 `tailscaled.service` drop-in：

```text
ExecStartPost=/usr/local/sbin/allow-aliyun-workbench-ssh
```

因此重启 Tailscale 后，Workbench 放行规则会自动恢复。

## 常见问题

**Q: 如何发现所有受影响的阿里云内网 IP？**

```bash
# 查看 DHCP 下发的路由
ip route show table main | grep "100."

# 抓包分析
tcpdump -i eth0 -n net 100.64.0.0/10

# 查看系统日志中的超时
dmesg | grep -i "unreachable\|timeout"
```

**Q: 会影响 Tailscale 正常功能吗？**

不会。只让指定的阿里云 IP 绕过 Tailscale，其余流量（包括 Tailscale 节点通信、子网路由）不受影响。

**Q: Workbench 来源不是 `100.104.0.0/16` 怎么办？**

先查看 SSH 日志或抓包确认来源地址，再把 `WORKBENCH_SRC` 改成更准确的阿里云来源段。不要直接删除 Tailscale 的 `DROP !tailscale0 100.64.0.0/10` 规则。

**Q: 其他云厂商有类似问题吗？**

AWS、Azure、GCP 也使用 `100.64.0.0/10` 的子集，思路通用，只需替换对应的内网 IP 列表。

## 兼容性

- Ubuntu 18.04+ / Debian 10+ / CentOS 7+
- 需要 systemd

## License

MIT
