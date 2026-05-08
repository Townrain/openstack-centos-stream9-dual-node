#!/bin/bash
###############################################################################
# OpenStack Dalmatian (CentOS Stream 9) 基础环境验证脚本
# 运行方式: bash openstack_verify.sh [节点类型: controller|compute]
# 运行用户: root
###############################################################################

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"

check_val_eq() {
    local msg="$1"
    local expect="$2"
    local actual="$3"
    printf "  %-50s " "$msg"
    if [ "$expect" = "$actual" ]; then
        echo -e "$PASS  (${actual})"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "$FAIL  (期望: ${expect}, 实际: ${actual})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

check_nonempty() {
    local msg="$1"
    local val="$2"
    printf "  %-50s " "$msg"
    if [ -n "$val" ]; then
        echo -e "$PASS  (${val})"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "$FAIL  (值为空)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}



# ==================== 解析参数 ====================
NODE_TYPE="${1:-}"

# ==================== root 检查 ====================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}建议使用 root 运行以获取完整检测结果${NC}"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     OpenStack Dalmatian 基础环境验证                        ║"
echo "║     检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. 系统基本信息 ====================
section "1. 系统基本信息"
echo "  操作系统: $(grep -oP 'PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null || echo '未知')"
echo "  内核版本: $(uname -r)"
echo "  当前主机名: $(hostname)"
echo "  运行用户: $(whoami)"

if [ -n "$NODE_TYPE" ]; then
    echo "  预期节点类型: ${NODE_TYPE}"
fi

# ==================== 2. 主机名检查 ====================
section "2. 主机名检查"
CURRENT_HOSTNAME=$(hostname)
check_nonempty "主机名已设置" "$CURRENT_HOSTNAME"
if [ -f /root/openstack_env.conf ]; then
    # shellcheck source=/dev/null
    source /root/openstack_env.conf 2>/dev/null || true
fi

# ==================== 3. CPU 虚拟化检查 ====================
section "3. CPU 虚拟化"
check "CPU 支持虚拟化 (vmx/svm)" "grep -Eq 'vmx|svm' /proc/cpuinfo"

# ==================== 4. 网络配置检查 ====================
section "4. 网络配置"

# 获取所有活动物理网卡
ACTIVE_IFACES=$(ip -o link show up 2>/dev/null \
    | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs' \
    | awk -F': ' '{print $2}' | tr -d '@')

echo "  活动网卡:"
for i in $ACTIVE_IFACES; do
    ip_info=$(ip -4 -o addr show "$i" 2>/dev/null | awk '{print $4}' | head -1)
    ip_only=$(echo "${ip_info:-}" | cut -d'/' -f1)
    prefix=$(echo "${ip_info:-}" | cut -d'/' -f2)
    gw=$(nmcli -t -f IP4.GATEWAY device show "$i" 2>/dev/null | cut -d':' -f2)
    echo "    ${i}:  IP=${ip_only:-无}/${prefix:--}  网关=${gw:-无}"
done

# 检查默认网关
DEFAULT_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
if [ -n "$DEFAULT_GW" ]; then
    check "默认网关 ${DEFAULT_GW} 连通" "ping -c 2 -W 2 ${DEFAULT_GW}"
else
    echo -e "  默认网关                            ${WARN}  (未检测到默认路由)"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# DNS 可解析
check "DNS 解析 (8.8.8.8 可达)" "ping -c 1 -W 2 8.8.8.8"

# NetworkManager 连接状态
nmcli connection show --active &>/dev/null && \
    echo "  NetworkManager 活动连接: $(nmcli -t -f NAME connection show --active 2>/dev/null | tr '\n' ' ')" || true

# ==================== 5. hosts 解析检查 ====================
section "5. /etc/hosts 与域名解析"

check "hosts 中含 controller-63 或自定义域名" "grep -qE 'controller|compute' /etc/hosts 2>/dev/null"

# 读取 hosts 中的 IP
HOSTS_CTRL_IP=$(grep -E 'controller' /etc/hosts 2>/dev/null | awk '{print $1}' | head -1)
HOSTS_COMPUTE_IP=$(grep -E 'compute' /etc/hosts 2>/dev/null | awk '{print $1}' | head -1)
HOSTS_CTRL_NAME=$(grep -E 'controller' /etc/hosts 2>/dev/null | awk '{print $2}' | head -1)
HOSTS_COMPUTE_NAME=$(grep -E 'compute' /etc/hosts 2>/dev/null | awk '{print $2}' | head -1)

if [ -n "$HOSTS_CTRL_IP" ]; then
    echo "  hosts 控制节点: ${HOSTS_CTRL_IP} ${HOSTS_CTRL_NAME}"
    check "控制节点 ${HOSTS_CTRL_NAME} 可 ping 通" "ping -c 1 -W 2 ${HOSTS_CTRL_IP}"
fi

if [ -n "$HOSTS_COMPUTE_IP" ]; then
    echo "  hosts 计算节点: ${HOSTS_COMPUTE_IP} ${HOSTS_COMPUTE_NAME}"
    check "计算节点 ${HOSTS_COMPUTE_NAME} 可 ping 通" "ping -c 1 -W 2 ${HOSTS_COMPUTE_IP}"
fi

# ==================== 6. 防火墙检查 ====================
section "6. 防火墙状态"
FW_ACTIVE=$(systemctl is-active firewalld 2>/dev/null || true)
FW_ENABLED=$(systemctl is-enabled firewalld 2>/dev/null || true)
printf "  firewalld 状态: %s / 开机启动: %s\n" "$FW_ACTIVE" "$FW_ENABLED"
if [ "$FW_ACTIVE" = "inactive" ] || [ -z "$FW_ACTIVE" ]; then
    echo -e "  firewalld 已关闭                      ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "  firewalld 仍在运行                     ${FAIL}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ==================== 7. SELinux 检查 ====================
section "7. SELinux 状态"
SELINUX_MODE=$(getenforce 2>/dev/null || echo "unknown")
SELINUX_CONFIG=$(grep -oP '^SELINUX=\K.*' /etc/selinux/config 2>/dev/null || echo "unknown")
printf "  SELinux 当前模式: ${SELINUX_MODE}  /  配置文件: ${SELINUX_CONFIG}\n"
if [ "$SELINUX_CONFIG" = "disabled" ]; then
    echo -e "  SELinux 配置为 disabled               ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
elif [ "$SELINUX_CONFIG" = "unknown" ]; then
    echo -e "  SELinux 配置                          ${WARN}  (配置文件未找到)"
    WARN_COUNT=$((WARN_COUNT + 1))
else
    echo -e "  SELinux 未禁用                        ${FAIL}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ==================== 8. 仓库配置检查 ====================
section "8. YUM/DNF 仓库配置"

check "dnf-plugins-core 已安装" "rpm -q dnf-plugins-core"
check "crb 仓库已启用" "dnf repolist --enabled 2>/dev/null | grep -qi crb"
check "centos-release-openstack-dalmatian 已安装" "rpm -q centos-release-openstack-dalmatian"
check "OpenStack Dalmatian 仓库可用" "dnf repolist 2>/dev/null | grep -qi openstack"

# 检查 EPEL 是否被意外启用
if dnf repolist --enabled 2>/dev/null | grep -qi epel; then
    echo -e "  EPEL 仓库状态                        ${WARN}  (已启用，可能导致依赖冲突)"
    WARN_COUNT=$((WARN_COUNT + 1))
else
    echo -e "  EPEL 仓库已禁用                       ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
fi

# ==================== 9. 基础软件包检查 ====================
section "9. 基础软件包"

PKGS=("vim-enhanced|vim" "openstack-selinux" "python3-openstackclient" "wget")
for pkg_spec in "${PKGS[@]}"; do
    pkg_name="${pkg_spec%%|*}"
    pkg_display="${pkg_spec##*|}"
    check "${pkg_display} 已安装" "rpm -q ${pkg_name}"
done

# ==================== 10. SSH 配置检查（控制节点） ====================
section "10. SSH 免密登录 (控制节点可连计算节点)"

if [ -f /root/.ssh/id_rsa ]; then
    echo -e "  SSH 密钥已生成                        ${PASS}  (/root/.ssh/id_rsa)"
    PASS_COUNT=$((PASS_COUNT + 1))

    if [ -n "${COMPUTE_IP:-}" ] && [ -n "${COMPUTE_USER:-}" ]; then
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER}@${COMPUTE_IP}" "hostname" &>/dev/null 2>&1; then
            echo -e "  免密登录 ${COMPUTE_USER}@${COMPUTE_IP}            ${PASS}"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo -e "  免密登录 ${COMPUTE_USER}@${COMPUTE_IP}             ${WARN}  (密钥未配置或不可达)"
            WARN_COUNT=$((WARN_COUNT + 1))
        fi
    else
        echo -e "  计算节点 IP 未知                       ${WARN}  (/root/openstack_env.conf 缺少 COMPUTE_IP)"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
else
    echo -e "  SSH 密钥                              ${WARN}  (未生成，控制节点需 SSH 密钥连计算节点)"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ==================== 11. 环境配置文件检查 ====================
section "11. 环境配置文件 (/root/openstack_env.conf)"

if [ -f /root/openstack_env.conf ]; then
    echo -e "  配置文件存在                          ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
    echo ""
    echo "  配置内容:"
    grep -E '^(CTRL_HOSTNAME|COMPUTE_HOSTNAME|CONTROLLER_IP|COMPUTE_IP|COMPUTE_USER|MYSQL_ROOT_PASS|ADMIN_PASS)' \
        /root/openstack_env.conf 2>/dev/null | while read -r line; do
        key="${line%%=*}"
        if [[ "$key" =~ PASS ]]; then
            echo "    ${key}=****** (已设置)"
        else
            echo "    ${line}"
        fi
    done || true
else
    echo -e "  配置文件                              ${FAIL}  (不存在)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ==================== 12. 需要重启的提示 ====================
section "12. 待重启检查"

NEED_REBOOT=0
if [ "$(getenforce 2>/dev/null)" = "Permissive" ] && [ "$SELINUX_CONFIG" = "disabled" ]; then
    echo -e "  SELinux 当前 Permissive, 配置 Disabled  ${WARN}  (重启后完全生效)"
    NEED_REBOOT=1
fi

# 检查是否有 pending 的系统更新需要重启
if [ -f /var/run/reboot-required ] 2>/dev/null || needs-restarting -r &>/dev/null 2>&1; then
    echo -e "  系统内核已更新                          ${WARN}  (建议重启)"
    NEED_REBOOT=1
fi

if [ "$NEED_REBOOT" -eq 0 ]; then
    echo "  无需重启（或已重启生效）"
fi

# ==================== 汇总 ====================
print_summary
