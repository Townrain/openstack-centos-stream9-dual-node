#!/bin/bash
###############################################################################
# OpenStack Dalmatian (CentOS Stream 9) Keystone 身份验证服务安装
# 运行节点: 控制节点 (controller)
# 执行方式: bash openstack_keystone.sh
# 运行用户: root
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
load_env

if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 账户运行本脚本"
    exit 1
fi

# ==================== 收集参数 ====================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         OpenStack Dalmatian - Keystone 身份服务安装         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

CURRENT_HOST=$(hostname)

if [ "$NON_INTERACTIVE" -eq 1 ]; then
    CTRL_HOSTNAME="${CTRL_HOSTNAME:-$CURRENT_HOST}"
    MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS}"
    KEYSTONE_DBPASS="${KEYSTONE_DBPASS:-${SERVICE_PASS}}"
    ADMIN_PASS="${ADMIN_PASS:-123456}"
else
    read -r -p "控制节点主机名/域名 [${CURRENT_HOST}]: " CTRL_HOSTNAME
    CTRL_HOSTNAME="${CTRL_HOSTNAME:-$CURRENT_HOST}"

    if [ -z "${MYSQL_ROOT_PASS:-}" ]; then
        read -r -s -p "MySQL root 密码: " MYSQL_ROOT_PASS
        echo ""
        read -r -s -p "确认 MySQL root 密码: " MYSQL_ROOT_PASS_CONFIRM
        echo ""
        [ "$MYSQL_ROOT_PASS" != "$MYSQL_ROOT_PASS_CONFIRM" ] && { log_error "密码不一致"; exit 1; }
    fi

    read -r -s -p "Keystone 数据库用户密码 [默认: 123456]: " KEYSTONE_DBPASS
    echo ""
    KEYSTONE_DBPASS="${KEYSTONE_DBPASS:-123456}"

    read -r -s -p "OpenStack admin (bootstrap) 密码 [默认: 123456]: " ADMIN_PASS
    echo ""
    ADMIN_PASS="${ADMIN_PASS:-123456}"
fi

# ==================== 1. 配置 MySQL 数据库 ====================
setup_mysql_database() {
    log_step "1. 配置 Keystone 数据库"

    # 检测并安装 MySQL 客户端与服务端
    if ! command -v mysql &>/dev/null; then
        log_info "安装 MySQL 客户端..."
        dnf install -y mariadb
    fi

    if ! rpm -q mariadb-server &>/dev/null; then
        log_info "安装 MySQL 服务端..."
        dnf install -y mariadb-server
    fi

    # 启动 MySQL 服务
    if ! systemctl is-active mariadb &>/dev/null; then
        log_info "启动 MariaDB 服务..."
        systemctl enable mariadb --now
    fi

    # 增大最大连接数（Nova 等服务连接数较多）
    grep -q "max_connections" /etc/my.cnf.d/mariadb-server.cnf 2>/dev/null || \
        echo "max_connections = 500" >> /etc/my.cnf.d/mariadb-server.cnf
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "SET GLOBAL max_connections = 500;" 2>/dev/null || true

    # 等待 MySQL 就绪
    for i in $(seq 1 10); do
        if mysqladmin -uroot -p"${MYSQL_ROOT_PASS}" ping &>/dev/null 2>&1; then
            break
        fi
        log_warn "等待 MySQL 就绪... (${i}/10)"
        sleep 2
    done
    if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "USE keystone;" &>/dev/null 2>&1; then
        log_info "keystone 数据库已存在，跳过创建"
    else
        log_info "创建 keystone 数据库并授权..."
        mysql -uroot -p"${MYSQL_ROOT_PASS}" << EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '${KEYSTONE_DBPASS}';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '${KEYSTONE_DBPASS}';
FLUSH PRIVILEGES;
EOF
        log_info "keystone 数据库已创建"
    fi

    # 验证
    if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "SHOW DATABASES LIKE 'keystone';" 2>/dev/null | grep -q keystone; then
        log_info "数据库验证通过: keystone 库存在"
    else
        log_error "数据库验证失败"
        exit 1
    fi
}

# ==================== 2. 安装组件 ====================
install_packages() {
    log_step "2. 安装 Keystone 及相关组件"

    dnf install -y openstack-keystone httpd python3-mod_wsgi
    log_info "软件包安装完成"
}

# ==================== 3. 修改配置 ====================
configure_keystone() {
    log_step "3. 修改 Keystone 配置"

    local conf="/etc/keystone/keystone.conf"

    if [ ! -f "$conf" ]; then
        log_error "${conf} 不存在，请检查 openstack-keystone 是否安装成功"
        exit 1
    fi

    backup_file "$conf"

    # [database] 段
    # 先注释掉已有的 connection 行
    sed -i '/^\[database\]/,/^\[/{s/^connection[[:space:]]*=/#&/}' "$conf"

    # 在 [database] 段下插入 connection
    if grep -q "^\[database\]" "$conf"; then
        sed -i "/^\[database\]/a connection = mysql+pymysql://keystone:${KEYSTONE_DBPASS}@${CTRL_HOSTNAME}/keystone" "$conf"
    else
        cat >> "$conf" << EOF
[database]
connection = mysql+pymysql://keystone:${KEYSTONE_DBPASS}@${CTRL_HOSTNAME}/keystone
EOF
    fi

    # [token] 段
    # 先注释掉已有的 provider 行
    sed -i '/^\[token\]/,/^\[/{s/^provider[[:space:]]*=/#&/}' "$conf"

    if grep -q "^\[token\]" "$conf"; then
        sed -i "/^\[token\]/a provider = fernet" "$conf"
    else
        cat >> "$conf" << EOF
[token]
provider = fernet
EOF
    fi

    log_info "配置文件已更新: ${conf}"

    # 显示关键配置
    echo ""
    echo "关键配置项:"
    grep -A1 "^\[database\]" "$conf" | head -2
    grep -A1 "^\[token\]" "$conf" | head -2
}

# ==================== 4. 填充数据库 ====================
populate_database() {
    log_step "4. 填充身份服务数据库"

    log_info "同步数据库..."
    su -s /bin/sh -c "keystone-manage db_sync" keystone
    log_info "数据库同步完成"

    log_info "初始化 Fernet 密钥存储库..."
    keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
    keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
    log_info "Fernet 密钥初始化完成"
}

# ==================== 5. 引导身份服务 ====================
bootstrap_keystone() {
    log_step "5. 引导 Keystone 身份服务"

    keystone-manage bootstrap \
        --bootstrap-password "${ADMIN_PASS}" \
        --bootstrap-admin-url "http://${CTRL_HOSTNAME}:5000/v3/" \
        --bootstrap-internal-url "http://${CTRL_HOSTNAME}:5000/v3/" \
        --bootstrap-public-url "http://${CTRL_HOSTNAME}:5000/v3/" \
        --bootstrap-region-id RegionOne
    log_info "Keystone 引导完成"
}

# ==================== 6. 配置 Apache ====================
configure_apache() {
    log_step "6. 配置 Apache HTTP 服务"

    local httpd_conf="/etc/httpd/conf/httpd.conf"

    if [ -f "$httpd_conf" ]; then
        backup_file "$httpd_conf"

        if grep -q "^ServerName" "$httpd_conf"; then
            sed -i "s/^ServerName.*/ServerName ${CTRL_HOSTNAME}/" "$httpd_conf"
        else
            echo "ServerName ${CTRL_HOSTNAME}" >> "$httpd_conf"
        fi
        log_info "ServerName 已设置为 ${CTRL_HOSTNAME}"
    else
        log_warn "${httpd_conf} 不存在"
    fi

    # 创建 WSGI 链接
    if [ ! -L /etc/httpd/conf.d/wsgi-keystone.conf ]; then
        ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
        log_info "WSGI 链接已创建"
    else
        log_info "WSGI 链接已存在"
    fi

    # 启动 memcached（token 缓存依赖）
    log_info "启动 memcached 服务..."
    systemctl enable memcached --now

    # 启动 Apache
    log_info "启动 Apache HTTP 服务..."
    systemctl enable httpd --now

    if systemctl is-active httpd &>/dev/null; then
        log_info "Apache HTTP 服务已启动"
    else
        log_warn "Apache HTTP 服务启动状态异常"
        systemctl status httpd --no-pager -l 2>/dev/null || true
    fi
}

# ==================== 7. 创建管理员凭证脚本 ====================
create_admin_rc() {
    log_step "7. 创建管理员凭证脚本"

    cat > /root/admin-openrc << EOF
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_AUTH_URL=http://${CTRL_HOSTNAME}:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export KEYSTONE_DBPASS=${KEYSTONE_DBPASS}
EOF
    log_info "管理员凭证脚本已生成: /root/admin-openrc"
    chmod 600 /root/admin-openrc
}

# ==================== 8. 验证 ====================
verify_keystone() {
    log_step "8. 验证 Keystone 服务"

    # 加载管理员凭证
    # shellcheck source=/dev/null
    source /root/admin-openrc

    echo ""
    echo "--- 请求认证 Token ---"
    if openstack token issue; then
        log_info "Token 认证成功"
    else
        log_error "Token 认证失败"
        exit 1
    fi

    echo ""
    echo "--- 创建 service 项目 ---"
    if openstack project show service &>/dev/null 2>&1; then
        log_info "service 项目已存在"
    else
        openstack project create --domain default --description "Service Project" service
        log_info "service 项目已创建"
    fi

    echo ""
    echo "--- 当前项目列表 ---"
    openstack project list

    echo ""
    echo "--- 当前用户列表 ---"
    openstack user list

    echo ""
    echo "--- 服务端点列表 ---"
    openstack endpoint list
}

# ==================== 主流程 ====================
main() {
    setup_mysql_database
    install_packages
    configure_keystone
    populate_database
    bootstrap_keystone
    configure_apache
    create_admin_rc
    verify_keystone

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                Keystone 身份服务安装完成                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  管理员凭证: source /root/admin-openrc"
    echo "  验证命令:   openstack token issue"
    echo "  Keystone URL: http://${CTRL_HOSTNAME}:5000/v3/"
    echo ""
}

main
