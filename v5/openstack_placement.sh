#!/bin/bash
###############################################################################
# OpenStack Dalmatian (CentOS Stream 9) Placement 布局服务安装
# 运行节点: 控制节点 (controller)
# 执行方式: bash openstack_placement.sh
# 运行用户: root
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
load_env
load_admin_rc || exit 1

if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 账户运行本脚本"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       OpenStack Dalmatian - Placement 布局服务安装          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

CURRENT_HOST=$(hostname)

if [ "$NON_INTERACTIVE" -eq 1 ]; then
    CTRL_HOSTNAME="${CTRL_HOSTNAME:-$CURRENT_HOST}"
    PLACEMENT_DBPASS="${PLACEMENT_DBPASS:-${SERVICE_PASS}}"
    PLACEMENT_PASS="${PLACEMENT_PASS:-${SERVICE_PASS}}"
else
    read -r -p "控制节点主机名/域名 [${CURRENT_HOST}]: " input
    CTRL_HOSTNAME="${input:-$CURRENT_HOST}"

    if [ -z "${MYSQL_ROOT_PASS:-}" ]; then
        read -r -s -p "MySQL root 密码: " MYSQL_ROOT_PASS
        echo ""
    fi

    read -r -s -p "Placement 数据库用户密码 [默认: 123456]: " PLACEMENT_DBPASS
    echo ""
    PLACEMENT_DBPASS="${PLACEMENT_DBPASS:-123456}"

    read -r -s -p "Placement Keystone 用户密码 [默认: 123456]: " PLACEMENT_PASS
    echo ""
    PLACEMENT_PASS="${PLACEMENT_PASS:-123456}"
fi

# ==================== 1. 配置 MySQL 数据库 ====================
setup_mysql_database() {
    log_step "1. 配置 Placement 数据库"

    if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "USE placement;" &>/dev/null 2>&1; then
        log_info "placement 数据库已存在，跳过创建"
    else
        log_info "创建 placement 数据库并授权..."
        mysql -uroot -p"${MYSQL_ROOT_PASS}" << EOF
CREATE DATABASE placement;
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY '${PLACEMENT_DBPASS}';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY '${PLACEMENT_DBPASS}';
FLUSH PRIVILEGES;
EOF
        log_info "placement 数据库已创建"
    fi

    if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "SHOW DATABASES LIKE 'placement';" 2>/dev/null | grep -q placement; then
        log_info "数据库验证通过: placement 库存在"
    else
        log_error "数据库验证失败"
        exit 1
    fi
}

# ==================== 2. Keystone 认证 ====================
setup_keystone_auth() {
    log_step "2. 配置 Placement Keystone 认证"

    if openstack user show placement &>/dev/null 2>&1; then
        log_info "placement 用户已存在"
    else
        log_info "创建 placement 用户..."
        openstack user create --domain default --password "${PLACEMENT_PASS}" placement
        log_info "placement 用户已创建"
    fi

    if openstack role assignment list --user placement --project service --names 2>/dev/null | grep -q admin; then
        log_info "placement 已有 service 项目的 admin 角色"
    else
        log_info "为 placement 添加 admin 角色..."
        openstack role add --project service --user placement admin
        log_info "admin 角色已添加"
    fi

    if openstack service show placement &>/dev/null 2>&1; then
        log_info "placement 服务实体已存在"
    else
        log_info "创建 placement 服务实体..."
        openstack service create --name placement --description "Placement API" placement
        log_info "placement 服务实体已创建"
    fi

    local endpoint_url="http://${CTRL_HOSTNAME}:8778"
    if openstack endpoint list 2>/dev/null | grep -q "placement.*public"; then
        log_info "placement 端点已存在"
    else
        log_info "创建 placement API 端点..."
        openstack endpoint create --region RegionOne placement public   "${endpoint_url}"
        openstack endpoint create --region RegionOne placement internal "${endpoint_url}"
        openstack endpoint create --region RegionOne placement admin    "${endpoint_url}"
        log_info "API 端点已创建"
    fi
}

# ==================== 3. 安装软件包 ====================
install_packages() {
    log_step "3. 安装 Placement 软件包"

    dnf install -y openstack-placement-api || dnf install -y --allowerasing openstack-placement-api || { log_error "安装 openstack-placement-api 失败"; exit 1; }
    log_info "openstack-placement-api 安装完成"
}

# ==================== 4. 配置 placement.conf ====================
configure_placement() {
    log_step "4. 配置 Placement"

    local conf="/etc/placement/placement.conf"

    if [ ! -f "$conf" ]; then
        log_error "${conf} 不存在，请检查 openstack-placement-api 是否安装成功"
        exit 1
    fi

    backup_file "$conf"

    cat >> "$conf" << PLACEMENTEOF

# === OpenStack Dalmatian Placement Configuration ===

[placement_database]
connection = mysql+pymysql://placement:${PLACEMENT_DBPASS}@${CTRL_HOSTNAME}/placement

[api]
auth_strategy = keystone

[keystone_authtoken]
auth_url = http://${CTRL_HOSTNAME}:5000/v3
memcached_servers = ${CTRL_HOSTNAME}:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = placement
password = ${PLACEMENT_PASS}
PLACEMENTEOF

    log_info "配置文件已更新: ${conf}"

    echo ""
    echo "关键配置项:"
    grep -E "^(connection|auth_strategy|auth_url|username)" "$conf" 2>/dev/null || true
}

# ==================== 5. 同步数据库 ====================
populate_database() {
    log_step "5. 填充 Placement 数据库"

    log_info "同步数据库..."
    su -s /bin/sh -c "placement-manage db sync" placement
    log_info "数据库同步完成"
}

# ==================== 6. 配置 Apache ====================
configure_apache() {
    log_step "6. 配置 Apache Placement API"

    local apache_conf="/etc/httpd/conf.d/00-placement-api.conf"

    if [ ! -f "$apache_conf" ]; then
        log_error "${apache_conf} 不存在"
        exit 1
    fi

    # 检查是否已配置
    if grep -q "Require all granted" "$apache_conf" 2>/dev/null; then
        log_info "Apache Placement 配置已存在，跳过"
    else
        backup_file "$apache_conf"

        # 在 SSLCertificateKeyFile 行后插入 Directory 配置
        if grep -q "SSLCertificateKeyFile" "$apache_conf"; then
            sed -i "/SSLCertificateKeyFile/a \\
\\
  <Directory /usr/bin>\\
    <IfVersion >= 2.4>\\
      Require all granted\\
    </IfVersion>\\
    <IfVersion < 2.4>\\
      Order allow,deny\\
      Allow from all\\
    </IfVersion>\\
  </Directory>" "$apache_conf"
            log_info "已添加 Directory 配置到 ${apache_conf}"
        else
            # 如果没有 SSLCertificateKeyFile，直接追加到文件末尾
            cat >> "$apache_conf" << 'APACHEEOF'

  <Directory /usr/bin>
    <IfVersion >= 2.4>
      Require all granted
    </IfVersion>
    <IfVersion < 2.4>
      Order allow,deny
      Allow from all
    </IfVersion>
  </Directory>
APACHEEOF
            log_info "已追加 Directory 配置到 ${apache_conf}"
        fi
    fi
}

# ==================== 7. 重启 Apache ====================
restart_httpd() {
    log_step "7. 重启 Apache HTTP 服务"

    log_info "重启 httpd..."
    systemctl restart httpd

    if systemctl is-active httpd &>/dev/null; then
        log_info "httpd 已重启"
    else
        log_warn "httpd 重启异常"
        systemctl status httpd --no-pager -l 2>/dev/null || true
    fi
}

# ==================== 8. 验证 ====================
verify_placement() {
    log_step "8. 验证 Placement 服务"

    echo ""
    echo "--- placement-status upgrade check ---"
    if placement-status upgrade check 2>/dev/null; then
        log_info "Placement 状态检查通过"
    else
        log_warn "placement-status upgrade check 返回异常"
    fi

    echo ""
    echo "--- Placement 服务端点 ---"
    openstack endpoint list 2>/dev/null | grep placement || true

    echo ""
    echo "--- Placement HTTP 可用性 ---"
    if curl -s --connect-timeout 5 "http://${CTRL_HOSTNAME}:8778/" &>/dev/null; then
        log_info "HTTP ${CTRL_HOSTNAME}:8778 可达"
    else
        log_warn "HTTP ${CTRL_HOSTNAME}:8778 不可达，请检查 Apache 配置"
    fi
}

# ==================== 主流程 ====================
main() {
    setup_mysql_database
    setup_keystone_auth
    install_packages
    configure_placement
    populate_database
    configure_apache
    restart_httpd
    verify_placement

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                Placement 布局服务安装完成                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  验证:    placement-status upgrade check"
    echo "  Placement URL: http://${CTRL_HOSTNAME}:8778"
    echo ""
}

main
