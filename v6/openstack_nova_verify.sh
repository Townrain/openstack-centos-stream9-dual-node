#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Nova 计算服务验证脚本
# 运行节点: 控制节点
# 运行方式: bash openstack_nova_verify.sh
###############################################################################

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
reset_counts

load_env
CTRL_HOSTNAME="${CTRL_HOSTNAME:-$(hostname)}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Nova 计算服务验证                                 ║"
echo "║           检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. MySQL 数据库 ====================
section "1. Nova 数据库"
if [ -n "${MYSQL_ROOT_PASS:-}" ]; then
    for DB in nova_api nova nova_cell0; do
        check "${DB} 数据库存在" "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e 'USE ${DB};'"
    done
    check "nova 用户存在" "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e \"SELECT user FROM mysql.user WHERE user='nova';\" | grep -q nova"
fi

# ==================== 2. RabbitMQ ====================
section "2. RabbitMQ 消息队列"
check "rabbitmq-server 已安装"   "rpm -q rabbitmq-server"
check "rabbitmq-server 运行中"    "systemctl is-active rabbitmq-server"
check "openstack 用户存在"        "rabbitmqctl list_users 2>/dev/null | grep -q openstack"

# ==================== 3. 软件包 ====================
section "3. Nova 控制节点软件包"
for pkg in openstack-nova-api openstack-nova-conductor openstack-nova-novncproxy openstack-nova-scheduler; do
    check "${pkg} 已安装" "rpm -q ${pkg}"
done

# ==================== 4. Keystone 认证 ====================
section "4. Keystone 认证配置"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    check "nova 用户存在"                "openstack user show nova"
    check "nova 有 admin 角色"           "openstack role assignment list --user nova --project service --names 2>/dev/null | grep -q admin"
    check "nova 服务实体存在"            "openstack service show nova"
    check "nova public 端点"             "openstack endpoint list 2>/dev/null | grep nova | grep -q public"
fi

# ==================== 5. nova.conf 配置 ====================
section "5. nova.conf 配置"
CONF="/etc/nova/nova.conf"
check "nova.conf 存在"                "test -f $CONF"
check "transport_url 已配置"           "grep -q 'transport_url.*rabbit' $CONF"
check "api_database 已配置"            "grep -q 'nova_api' $CONF"
check "database 已配置"                "grep -q 'nova' $CONF"
check "keystone_authtoken 已配置"      "grep -q 'auth_url' $CONF"
check "placement 已配置"               "grep -q 'placement' $CONF"
check "glance api_servers 已配置"       "grep -q 'api_servers.*9292' $CONF"
check "vnc enabled"                   "grep -q 'enabled.*true' $CONF"

# ==================== 6. 服务状态 ====================
section "6. 控制节点服务状态"
for svc in openstack-nova-api openstack-nova-scheduler openstack-nova-conductor openstack-nova-novncproxy rabbitmq-server; do
    ACT=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    EN=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
    if [ "$ACT" = "active" ]; then
        echo -e "  ${svc}  运行: ${GREEN}active${NC}  开机: ${EN}"
    else
        echo -e "  ${svc}  运行: ${RED}${ACT}${NC}  开机: ${EN}"
    fi
done

# ==================== 7. 计算节点检测 ====================
section "7. 计算服务列表"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    echo ""
    if openstack compute service list &>/dev/null 2>&1; then
        openstack compute service list 2>/dev/null
        echo ""
        check_w "nova-compute 服务已注册" "openstack compute service list 2>/dev/null | grep -q nova-compute"
    else
        echo -e "  compute service list                  ${WARN}"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    echo ""
    echo "--- Nova API 可用性 ---"
    check_w "Nova API :8774 可达" "curl -s --connect-timeout 5 'http://${CTRL_HOSTNAME}:8774/' &>/dev/null"
fi

print_summary
