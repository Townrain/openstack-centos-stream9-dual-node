#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Horizon Dashboard 安装
# 运行节点: 控制节点 (controller)
# 执行方式: bash openstack_horizon.sh
# 运行用户: root
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
load_env

[ "$(id -u)" -ne 0 ] && { log_error "请使用 root 账户"; exit 1; }


echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       OpenStack Dalmatian - Horizon Dashboard 安装          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [ "$NON_INTERACTIVE" -eq 1 ]; then
    CTRL_HOSTNAME="${CTRL_HOSTNAME}"
else
    read -r -p "控制节点主机名 [${CTRL_HOSTNAME}]: " input; CTRL_HOSTNAME="${input:-${CTRL_HOSTNAME}}"
fi

# ==================== 1. 安装 ====================
log_step "1. 安装 openstack-dashboard"
dnf install -y openstack-dashboard || dnf install -y --allowerasing openstack-dashboard || { log_error "安装 openstack-dashboard 失败"; exit 1; }
log_info "openstack-dashboard 安装完成"

# ==================== 2. 配置 local_settings ====================
log_step "2. 配置 local_settings"
LOCAL_SETTINGS="/etc/openstack-dashboard/local_settings"
[ ! -f "$LOCAL_SETTINGS" ] && { log_error "${LOCAL_SETTINGS} 不存在"; exit 1; }
backup_file "$LOCAL_SETTINGS"

# OPENSTACK_HOST
sed -i "s/^OPENSTACK_HOST\s*=.*/OPENSTACK_HOST = \"${CTRL_HOSTNAME}\"/" "$LOCAL_SETTINGS"
grep -q "^OPENSTACK_HOST" "$LOCAL_SETTINGS" || echo "OPENSTACK_HOST = \"${CTRL_HOSTNAME}\"" >> "$LOCAL_SETTINGS"

# ALLOWED_HOSTS
sed -i "s/^ALLOWED_HOSTS\s*=.*/ALLOWED_HOSTS = ['*']/" "$LOCAL_SETTINGS"
grep -q "^ALLOWED_HOSTS" "$LOCAL_SETTINGS" || echo "ALLOWED_HOSTS = ['*']" >> "$LOCAL_SETTINGS"

# SESSION_ENGINE
sed -i "s/^SESSION_ENGINE\s*=.*/SESSION_ENGINE = 'django.contrib.sessions.backends.cache'/" "$LOCAL_SETTINGS"
grep -q "^SESSION_ENGINE" "$LOCAL_SETTINGS" || echo "SESSION_ENGINE = 'django.contrib.sessions.backends.cache'" >> "$LOCAL_SETTINGS"

# CACHES (sed 多行不便，直接检查并追加)
if ! grep -q "django.core.cache.backends.memcached" "$LOCAL_SETTINGS" 2>/dev/null; then
    cat >> "$LOCAL_SETTINGS" << 'CACHEEOF'

CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.PyMemcacheCache',
        'LOCATION': '__CTRL_HOSTNAME__:11211',
    }
}
CACHEEOF
    sed -i "s/__CTRL_HOSTNAME__/${CTRL_HOSTNAME}/" "$LOCAL_SETTINGS"
fi

# OPENSTACK_KEYSTONE_URL
sed -i "s|^OPENSTACK_KEYSTONE_URL\s*=.*|OPENSTACK_KEYSTONE_URL = \"http://%s:5000/identity/v3\" % OPENSTACK_HOST|" "$LOCAL_SETTINGS"
grep -q "^OPENSTACK_KEYSTONE_URL" "$LOCAL_SETTINGS" || echo "OPENSTACK_KEYSTONE_URL = \"http://%s:5000/identity/v3\" % OPENSTACK_HOST" >> "$LOCAL_SETTINGS"

# OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT
sed -i "s/^OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT\s*=.*/OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True/" "$LOCAL_SETTINGS"
grep -q "^OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT" "$LOCAL_SETTINGS" || echo "OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True" >> "$LOCAL_SETTINGS"

# OPENSTACK_API_VERSIONS
if ! grep -q "\"volume\": 3" "$LOCAL_SETTINGS" 2>/dev/null; then
    cat >> "$LOCAL_SETTINGS" << 'APIEOF'

OPENSTACK_API_VERSIONS = {
    "identity": 3,
    "image": 2,
    "volume": 3,
}
APIEOF
fi

# WEBROOT
sed -i "s|^WEBROOT\s*=.*|WEBROOT = '/dashboard/'|" "$LOCAL_SETTINGS"
grep -q "^WEBROOT" "$LOCAL_SETTINGS" || echo "WEBROOT = '/dashboard/'" >> "$LOCAL_SETTINGS"

# TIME_ZONE
sed -i "s|^TIME_ZONE\s*=.*|TIME_ZONE = \"Asia/Shanghai\"|" "$LOCAL_SETTINGS"
grep -q "^TIME_ZONE" "$LOCAL_SETTINGS" || echo "TIME_ZONE = \"Asia/Shanghai\"" >> "$LOCAL_SETTINGS"

log_info "local_settings 已配置"

# ==================== 3. 配置 openstack-dashboard.conf ====================
log_step "3. 配置 Apache Dashboard"
DASHBOARD_CONF="/etc/httpd/conf.d/openstack-dashboard.conf"
if [ -f "$DASHBOARD_CONF" ]; then
    backup_file "$DASHBOARD_CONF"

    # 添加 WSGIApplicationGroup
    grep -q "WSGIApplicationGroup" "$DASHBOARD_CONF" || echo "WSGIApplicationGroup %{GLOBAL}" >> "$DASHBOARD_CONF"

    # 修改 WSGIScriptAlias — 把 django.wsgi 换成 wsgi.py
    if grep -q "wsgi/django.wsgi" "$DASHBOARD_CONF"; then
        sed -i 's|/usr/share/openstack-dashboard/openstack_dashboard/wsgi/django.wsgi|/usr/share/openstack-dashboard/openstack_dashboard/wsgi.py|' "$DASHBOARD_CONF"
    fi

    # 修改 Directory 路径（仅替换 <Directory ...> 行，不动 WSGIScriptAlias）
    sed -i 's|<Directory /usr/share/openstack-dashboard/openstack_dashboard/wsgi>|<Directory /usr/share/openstack-dashboard/openstack_dashboard>|' "$DASHBOARD_CONF"

    # 确保 Directory 块内有 Require all granted
    if ! grep -A10 "<Directory /usr/share/openstack-dashboard/openstack_dashboard>" "$DASHBOARD_CONF" | grep -q "Require all granted"; then
        sed -i '/<Directory \/usr\/share\/openstack-dashboard\/openstack_dashboard>/a \    Require all granted' "$DASHBOARD_CONF"
    fi

    # 添加 WSGI 守护进程配置（解决 403）
    grep -q "WSGIDaemonProcess dashboard" "$DASHBOARD_CONF" || echo "WSGIDaemonProcess dashboard user=apache group=apache" >> "$DASHBOARD_CONF"
    grep -q "WSGIProcessGroup dashboard" "$DASHBOARD_CONF" || echo "WSGIProcessGroup dashboard" >> "$DASHBOARD_CONF"

    log_info "openstack-dashboard.conf 已配置"
else
    log_warn "${DASHBOARD_CONF} 不存在"
fi

# 生成缺失的 policy 文件（修复 Horizon 创建网络/资源回跳问题）
log_info "编译 Horizon 静态资源与策略文件..."
cd /usr/share/openstack-dashboard
python3 manage.py collectstatic --noinput 2>/dev/null || true
python3 manage.py compress --force 2>/dev/null || true
# 创建缺失的 default_policies yaml 文件（消除 Apache error log 中的 policy 警告）
mkdir -p openstack_dashboard/conf/default_policies
for svc in keystone nova cinder glance neutron; do
    [ -f "openstack_dashboard/conf/default_policies/${svc}.yaml" ] || echo "[]" > "openstack_dashboard/conf/default_policies/${svc}.yaml"
done
cd - >/dev/null
log_info "Horizon 静态资源与策略文件已编译"

# ==================== 4. 重启服务 ====================
log_step "4. 重启服务"
systemctl restart httpd memcached
sleep 2
for svc in httpd memcached; do
    systemctl is-active "$svc" &>/dev/null && log_info "${svc} 已重启" || log_warn "${svc} 异常"
done

# ==================== 5. 验证 ====================
log_step "5. 验证 Horizon"
DASHBOARD_URL="http://${CTRL_HOSTNAME}/dashboard/"
echo ""
if curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "${DASHBOARD_URL}" 2>/dev/null | grep -qE "^(200|301|302)"; then
    log_info "Horizon 页面可达: ${DASHBOARD_URL}"
else
    log_warn "Horizon 无法访问: ${DASHBOARD_URL}"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║               Horizon Dashboard 安装完成                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  访问地址: ${DASHBOARD_URL}"
echo "  用户名:   admin"
echo "  密码:     在 /root/admin-openrc 中查看"
echo ""
