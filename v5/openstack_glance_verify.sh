#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Glance 镜像服务验证脚本
# 运行节点: 控制节点
# 运行方式: bash openstack_glance_verify.sh
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
echo "║           Glance 镜像服务验证                               ║"
echo "║           检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. MySQL 数据库 ====================
section "1. Glance 数据库"
if [ -n "${MYSQL_ROOT_PASS:-}" ]; then
    check "glance 数据库存在"    "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e 'USE glance;'"
    check "glance 用户存在"      "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e \"SELECT user FROM mysql.user WHERE user='glance';\" | grep -q glance"

    TABLE_COUNT=$(mysql -uroot -p"${MYSQL_ROOT_PASS}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='glance';" 2>/dev/null || echo "0")
    if [ "$TABLE_COUNT" -gt 5 ]; then
        echo -e "  glance 数据表 ($TABLE_COUNT 张)          ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  glance 数据表 ($TABLE_COUNT 张)          ${WARN}  (表数量过少)"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
else
    echo -e "  MySQL root 密码未知      ${WARN}"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ==================== 2. 软件包 ====================
section "2. 软件包安装"
check "openstack-glance 已安装"  "rpm -q openstack-glance"
check "qemu-img 已安装"          "rpm -q qemu-img"

# ==================== 3. Keystone 认证 ====================
section "3. Keystone 认证配置"
if [ -f /root/admin-openrc ]; then
    # shellcheck source=/dev/null
    source /root/admin-openrc 2>/dev/null

    check "glance 用户存在"               "openstack user show glance"
    check "glance 有 admin 角色"           "openstack role assignment list --user glance --project service --names 2>/dev/null | grep -q admin"
    check "glance 服务实体存在"            "openstack service show glance"
    check "glance public 端点存在"         "openstack endpoint list 2>/dev/null | grep glance | grep -q public"
    check "glance internal 端点存在"       "openstack endpoint list 2>/dev/null | grep glance | grep -q internal"
    check "glance admin 端点存在"          "openstack endpoint list 2>/dev/null | grep glance | grep -q admin"
else
    echo -e "  admin-openrc 不可用   ${WARN}"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ==================== 4. glance-api.conf 配置 ====================
section "4. glance-api.conf 配置"
GLANCE_CONF="/etc/glance/glance-api.conf"
check "glance-api.conf 存在"              "test -f $GLANCE_CONF"

if [ -f "$GLANCE_CONF" ]; then
    check "database connection 已配置"     "grep -q 'mysql+pymysql' $GLANCE_CONF"
    check "keystone_authtoken 已配置"      "grep -q 'auth_url' $GLANCE_CONF"
    check "memcached_servers 已配置"       "grep -q 'memcached_servers' $GLANCE_CONF"
    check "paste_deploy flavor=keystone"   "grep -q 'flavor.*keystone' $GLANCE_CONF"
    check "glance_store stores 已配置"     "grep -q 'stores.*file' $GLANCE_CONF"
    check "default_store = file"           "grep -q 'default_store.*file' $GLANCE_CONF"
    check "filesystem_store_datadir 已配置" "grep -q 'filesystem_store_datadir' $GLANCE_CONF"
fi

# ==================== 5. 镜像存储目录 ====================
section "5. 镜像存储目录"
check "镜像目录存在"                       "test -d /var/lib/glance/images"
check "镜像目录属主为 glance"              "stat -c '%U:%G' /var/lib/glance/images 2>/dev/null | grep -q 'glance:glance'"

# ==================== 6. 服务状态 ====================
section "6. Glance 服务状态"
check "openstack-glance-api 已安装"       "test -f /usr/lib/systemd/system/openstack-glance-api.service || systemctl list-unit-files 2>/dev/null | grep -q openstack-glance-api"
check_w "openstack-glance-api 运行中"   "systemctl is-active openstack-glance-api"
check "openstack-glance-api 开机启动"     "systemctl is-enabled openstack-glance-api 2>/dev/null | grep -qE 'enabled|indirect'"

# ==================== 7. API 可用性 ====================
section "7. Glance API 可用性"
if curl -s --connect-timeout 5 "http://${CTRL_HOSTNAME}:9292/" &>/dev/null; then
    echo -e "  HTTP ${CTRL_HOSTNAME}:9292 可达           ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "  HTTP ${CTRL_HOSTNAME}:9292 可达           ${FAIL}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# ==================== 8. 镜像列表 ====================
section "8. 镜像操作验证"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null

    check "openstack image list 正常"     "openstack image list"

    # 可选：cirros 镜像检测
    if openstack image show cirros &>/dev/null 2>&1; then
        echo -e "  cirros 镜像存在                         ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  cirros 镜像未上传 (不影响服务运行)        ${WARN}"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

# ==================== 汇总 ====================
print_summary
