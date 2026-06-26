#!/bin/bash
###############################################################################
# OpenStack Dalmatian - 清理验证脚本
# 运行位置: 控制节点
# 执行方式: bash openstack_cleanup_verify.sh [--non-interactive]
# 用途: 确认 openstack_cleanup.sh 已成功移除所有 OpenStack 部署产物
###############################################################################

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
reset_counts

# 加载环境变量 (获取 MYSQL_ROOT_PASS 等)
load_env_common
# 尝试加载 admin-openrc (清理后可能不存在)
[ -f /root/admin-openrc ] && source /root/admin-openrc 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          OpenStack 清理验证                                  ║"
echo "║          检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. 数据库检查 ====================
section "1. MariaDB 数据库检查"

if [ -n "${MYSQL_ROOT_PASS:-}" ]; then
    check "Keystone 数据库已删除"   "! mysql -uroot -p${MYSQL_ROOT_PASS} -e 'USE keystone;' 2>/dev/null"
    check "Glance 数据库已删除"     "! mysql -uroot -p${MYSQL_ROOT_PASS} -e 'USE glance;' 2>/dev/null"
    check "Placement 数据库已删除"  "! mysql -uroot -p${MYSQL_ROOT_PASS} -e 'USE placement;' 2>/dev/null"
    check "Nova API 数据库已删除"   "! mysql -uroot -p${MYSQL_ROOT_PASS} -e 'USE nova_api;' 2>/dev/null"
    check "Nova 数据库已删除"       "! mysql -uroot -p${MYSQL_ROOT_PASS} -e 'USE nova;' 2>/dev/null"
    check "Nova Cell0 数据库已删除" "! mysql -uroot -p${MYSQL_ROOT_PASS} -e 'USE nova_cell0;' 2>/dev/null"
    check "Neutron 数据库已删除"    "! mysql -uroot -p${MYSQL_ROOT_PASS} -e 'USE neutron;' 2>/dev/null"
    check "Cinder 数据库已删除"     "! mysql -uroot -p${MYSQL_ROOT_PASS} -e 'USE cinder;' 2>/dev/null"
else
    echo -e "  MySQL root 密码未知      ${WARN}  (跳过数据库检查)"
    WARN_COUNT=$((WARN_COUNT + 8))
fi

# ==================== 2. 软件包检查 ====================
section "2. 软件包检查"

check "openstack-keystone 已移除"     "! rpm -q openstack-keystone 2>/dev/null"
check "openstack-glance 已移除"       "! rpm -q openstack-glance 2>/dev/null"
check "openstack-placement-api 已移除" "! rpm -q openstack-placement-api 2>/dev/null"
check "openstack-nova-api 已移除"     "! rpm -q openstack-nova-api 2>/dev/null"
check "openstack-neutron 已移除"      "! rpm -q openstack-neutron 2>/dev/null"
check "openstack-dashboard 已移除"    "! rpm -q openstack-dashboard 2>/dev/null"
check "openstack-cinder 已移除"       "! rpm -q openstack-cinder 2>/dev/null"
check "openstack-swift-proxy 已移除"  "! rpm -q openstack-swift-proxy 2>/dev/null"
check "rabbitmq-server 已移除"        "! rpm -q rabbitmq-server 2>/dev/null"

# ==================== 3. 配置目录检查 ====================
section "3. 配置目录检查"

check "/etc/keystone 已删除"              "! [ -d /etc/keystone ]"
check "/etc/glance 已删除"                "! [ -d /etc/glance ]"
check "/etc/placement 已删除"             "! [ -d /etc/placement ]"
check "/etc/nova 已删除"                  "! [ -d /etc/nova ]"
check "/etc/neutron 已删除"               "! [ -d /etc/neutron ]"
check "/etc/cinder 已删除"                "! [ -d /etc/cinder ]"
check "/etc/swift 已删除"                 "! [ -d /etc/swift ]"
check "/etc/openstack-dashboard 已删除"   "! [ -d /etc/openstack-dashboard ]"

# ==================== 4. 服务状态检查 ====================
section "4. 服务状态检查"

check "openstack-nova-api 已停止"     "! systemctl is-active openstack-nova-api 2>/dev/null"
check "openstack-glance-api 已停止"   "! systemctl is-active openstack-glance-api 2>/dev/null"
check "neutron-server 已停止"         "! systemctl is-active neutron-server 2>/dev/null"
check "openstack-cinder-api 已停止"   "! systemctl is-active openstack-cinder-api 2>/dev/null"
check "openstack-swift-proxy 已停止"  "! systemctl is-active openstack-swift-proxy 2>/dev/null"
check "httpd 已停止"                  "! systemctl is-active httpd 2>/dev/null"
check "rabbitmq-server 已停止"        "! systemctl is-active rabbitmq-server 2>/dev/null"

# ==================== 5. OVS 网桥检查 ====================
section "5. OVS 网桥检查"

check "br-provider 已删除"  "! ovs-vsctl br-exists br-provider 2>/dev/null"
check "br-int 已删除"       "! ovs-vsctl br-exists br-int 2>/dev/null"
check "br-tun 已删除"       "! ovs-vsctl br-exists br-tun 2>/dev/null"

# ==================== 6. 数据目录检查 ====================
section "6. 数据目录检查"

check "/var/lib/nova 已删除"     "! [ -d /var/lib/nova ]"
check "/var/lib/glance 已删除"   "! [ -d /var/lib/glance ]"
check "/var/lib/neutron 已删除"  "! [ -d /var/lib/neutron ]"
check "/var/lib/cinder 已删除"   "! [ -d /var/lib/cinder ]"

# ==================== 7. 根目录文件检查 ====================
section "7. 根目录文件检查"

check "admin-openrc 已删除"       "! [ -f /root/admin-openrc ]"
check "openstack_env.conf 已删除" "! [ -f /root/openstack_env.conf ]"

# ==================== 8. 系统恢复检查 ====================
section "8. 系统恢复检查"

check_w "SELinux 已恢复"     "grep -q '^SELINUX=enforcing' /etc/selinux/config"
check_w "firewalld 已启用"   "systemctl is-enabled firewalld 2>/dev/null"

# ==================== 汇总 ====================
print_summary
