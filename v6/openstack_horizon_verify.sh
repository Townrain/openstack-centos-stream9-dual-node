#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Horizon Dashboard 验证脚本
# 运行方式: bash openstack_horizon_verify.sh
###############################################################################

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
reset_counts

load_env
CTRL_HOSTNAME="${CTRL_HOSTNAME:-$(hostname)}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Horizon Dashboard 验证                           ║"
echo "║           检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. 软件包 ====================
section "1. 软件包安装"
check "openstack-dashboard 已安装" "rpm -q openstack-dashboard"

# ==================== 2. local_settings ====================
section "2. local_settings 配置"
LS="/etc/openstack-dashboard/local_settings"
check "local_settings 存在"         "test -f $LS"

if [ -f "$LS" ]; then
    check "OPENSTACK_HOST 已配置"   "grep -q 'OPENSTACK_HOST' $LS"
    check "ALLOWED_HOSTS = [*]"     "grep -q \"ALLOWED_HOSTS.*\\*\" $LS"
    check "SESSION_ENGINE = cache"  "grep -q 'SESSION_ENGINE.*cache' $LS"
    check "CACHES (memcached)"      "grep -q 'memcached' $LS"
    check "KEYSTONE_URL 已配置"     "grep -q 'OPENSTACK_KEYSTONE_URL' $LS"
    check "MULTIDOMAIN_SUPPORT"     "grep -q 'OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT.*True' $LS"
    check "API_VERSIONS 已配置"     "grep -q 'OPENSTACK_API_VERSIONS' $LS"
    check "WEBROOT /dashboard/"     "grep -q 'WEBROOT.*dashboard' $LS"
    check "TIME_ZONE 已配置"        "grep -q 'TIME_ZONE' $LS"
fi

# ==================== 3. Apache 配置 ====================
section "3. Apache Dashboard 配置"
DC="/etc/httpd/conf.d/openstack-dashboard.conf"
check "openstack-dashboard.conf 存在"  "test -f $DC"

if [ -f "$DC" ]; then
    check "WSGIApplicationGroup 已添加"  "grep -q 'WSGIApplicationGroup' $DC"
    check "WSGIScriptAlias 已配置"          "grep -qE 'openstack_dashboard[/.]wsgi\.py|openstack_dashboard\.py' $DC"
    check "Directory 路径已修正"          "grep -q '/usr/share/openstack-dashboard/openstack_dashboard>' $DC"
    check "Require all granted 已配置"      "grep -A10 '<Directory /usr/share/openstack-dashboard' $DC | grep -q 'Require all granted'"
    check "WSGIDaemonProcess 已配置"       "grep -q 'WSGIDaemonProcess dashboard' $DC"
    check "WSGIProcessGroup 已配置"        "grep -q 'WSGIProcessGroup dashboard' $DC"
fi

# ==================== 4. 服务状态 ====================
section "4. 服务状态"
for svc in httpd memcached; do
    ACT=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    if [ "$ACT" = "active" ]; then
        echo -e "  ${svc}  运行: ${GREEN}active${NC}"
    else
        echo -e "  ${svc}  运行: ${RED}${ACT}${NC}"
    fi
done

# ==================== 5. 页面可达性 ====================
section "5. Horizon 页面可达性"
DASHBOARD_URL="http://${CTRL_HOSTNAME}/dashboard/"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${DASHBOARD_URL}" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    echo -e "  HTTP ${HTTP_CODE}: ${DASHBOARD_URL}  ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    echo -e "  HTTP ${HTTP_CODE}: ${DASHBOARD_URL}  ${WARN}"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# 检查登录页面内容
if [ "$HTTP_CODE" = "200" ]; then
    if curl -s --connect-timeout 5 "${DASHBOARD_URL}" 2>/dev/null | grep -qi 'openstack\|login\|horizon'; then
        echo -e "  页面含登录表单                        ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  页面内容异常                          ${WARN}"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

# ==================== 6. Apache 错误检查 ====================
section "6. Apache 错误日志（最近 5 行）"
if journalctl -u httpd --no-pager -n 5 2>/dev/null | grep -q .; then
    journalctl -u httpd --no-pager -n 5 2>/dev/null || true
fi

# ==================== 汇总 ====================
print_summary
