#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Placement 布局服务验证脚本
# 运行节点: 控制节点
# 运行方式: bash openstack_placement_verify.sh
# 运行用户: root
###############################################################################

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
reset_counts

load_env
CTRL_HOSTNAME="${CTRL_HOSTNAME:-$(hostname)}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Placement 布局服务验证                            ║"
echo "║           检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. MySQL 数据库 ====================
section "1. Placement 数据库"
if [ -n "${MYSQL_ROOT_PASS:-}" ]; then
    check "placement 数据库存在"  "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e 'USE placement;'"
    check "placement 用户存在"    "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e \"SELECT user FROM mysql.user WHERE user='placement';\" | grep -q placement"
    TBL=$(mysql -uroot -p"${MYSQL_ROOT_PASS}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='placement';" 2>/dev/null || echo "0")
    [ "$TBL" -gt 3 ] && echo -e "  placement 数据表 ($TBL 张)              ${PASS}" && PASS_COUNT=$((PASS_COUNT + 1)) || { echo -e "  placement 数据表 ($TBL 张)              ${WARN}"; WARN_COUNT=$((WARN_COUNT + 1)); }
else
    echo -e "  MySQL root 密码未知      ${WARN}"; WARN_COUNT=$((WARN_COUNT + 1))
fi

# ==================== 2. 软件包 ====================
section "2. 软件包安装"
check "openstack-placement-api 已安装"  "rpm -q openstack-placement-api"
check "openstack-placement-common 已安装" "rpm -q openstack-placement-common"

# ==================== 3. Keystone 认证 ====================
section "3. Keystone 认证配置"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    check "placement 用户存在"              "openstack user show placement"
    check "placement 有 admin 角色"         "openstack role assignment list --user placement --project service --names 2>/dev/null | grep -q admin"
    check "placement 服务实体存在"          "openstack service show placement"
    check "placement public 端点"           "openstack endpoint list 2>/dev/null | grep placement | grep -q public"
    check "placement internal 端点"         "openstack endpoint list 2>/dev/null | grep placement | grep -q internal"
    check "placement admin 端点"            "openstack endpoint list 2>/dev/null | grep placement | grep -q admin"
fi

# ==================== 4. placement.conf 配置 ====================
section "4. placement.conf 配置"
CONF="/etc/placement/placement.conf"
check "placement.conf 存在"              "test -f $CONF"
check "[placement_database] connection"  "grep -q 'mysql+pymysql.*placement' $CONF"
check "[api] auth_strategy = keystone"   "grep -q 'auth_strategy.*keystone' $CONF"
check "[keystone_authtoken] auth_url"    "grep -q 'auth_url' $CONF"
check "memcached_servers 已配置"          "grep -q 'memcached_servers' $CONF"
check "username = placement"             "grep -q 'username.*placement' $CONF"

# ==================== 5. Apache 配置 ====================
section "5. Apache Placement 配置"
APA="/etc/httpd/conf.d/00-placement-api.conf"
check "00-placement-api.conf 存在"       "test -f $APA"
check "Directory 权限配置存在"            "grep -q 'Require all granted' $APA"

# ==================== 6. 服务状态 ====================
section "6. 服务状态"
check "httpd 运行中"                     "systemctl is-active httpd"
check "httpd 开机启动"                   "systemctl is-enabled httpd 2>/dev/null | grep -qE 'enabled|indirect'"

# ==================== 7. API 与验证 ====================
section "7. Placement API 验证"
check_w "HTTP ${CTRL_HOSTNAME}:8778 可达"  "curl -s --connect-timeout 5 http://${CTRL_HOSTNAME}:8778/ &>/dev/null"
check_w "placement-status upgrade check"   "placement-status upgrade check"

# URL 返回内容
echo ""
RESULT=$(curl -s --connect-timeout 5 "http://${CTRL_HOSTNAME}:8778/" 2>/dev/null || echo "")
if [ -n "$RESULT" ]; then
    VER=$(echo "$RESULT" | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1)
    [ -n "$VER" ] && echo -e "  API 版本: ${VER}                          ${PASS}" && PASS_COUNT=$((PASS_COUNT + 1))
fi

print_summary
