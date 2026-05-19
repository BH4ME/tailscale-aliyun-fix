#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/tailscale-aliyun-fix.sh"
readme="$repo_root/README.md"

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "Expected $file to contain: $needle" >&2
    exit 1
  fi
}

assert_contains "$installer" "WORKBENCH_SRC=\"100.104.0.0/16\""
assert_contains "$installer" "/usr/local/sbin/allow-aliyun-workbench-ssh"
assert_contains "$installer" "/etc/systemd/system/allow-aliyun-workbench-ssh.service"
assert_contains "$installer" "/etc/systemd/system/tailscaled.service.d/20-aliyun-workbench.conf"
assert_contains "$installer" "ExecStartPost=/usr/local/sbin/allow-aliyun-workbench-ssh"
assert_contains "$installer" "--ctstate ESTABLISHED,RELATED"
assert_contains "$installer" "--dport 22"
assert_contains "$readme" "raw.githubusercontent.com/BH4ME/tailscale-aliyun-fix/master/tailscale-aliyun-fix.sh"
