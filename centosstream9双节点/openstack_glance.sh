#!/bin/bash
###############################################################################
# OpenStack Dalmatian (CentOS Stream 9) Glance 镜像服务安装
# 运行节点: 控制节点 (controller)
# 执行方式: bash openstack_glance.sh
# 运行用户: root
###############################################################################

set -euo pipefail

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}"; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 账户运行本脚本"
    exit 1
fi

# ==================== 加载环境配置 ====================
if [ -f /root/openstack_env.conf ]; then
    # shellcheck source=/dev/null
    source /root/openstack_env.conf
    log_info "已加载环境配置 /root/openstack_env.conf"
fi
CTRL_HOSTNAME="${CTRL_HOSTNAME:-controller-63}"
CONTROLLER_IP="${CONTROLLER_IP:-127.0.0.1}"
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-}"

# ==================== 加载管理员凭证 ====================
if [ -f /root/admin-openrc ]; then
    # shellcheck source=/dev/null
    source /root/admin-openrc
    log_info "已加载管理员凭证 /root/admin-openrc"
else
    log_error "/root/admin-openrc 不存在，请先安装 Keystone"
    exit 1
fi

# ==================== 收集参数 ====================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         OpenStack Dalmatian - Glance 镜像服务安装           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

CURRENT_HOST=$(hostname)
read -r -p "控制节点主机名/域名 [${CURRENT_HOST}]: " input
CTRL_HOSTNAME="${input:-$CURRENT_HOST}"

if [ -z "${MYSQL_ROOT_PASS:-}" ]; then
    read -r -s -p "MySQL root 密码: " MYSQL_ROOT_PASS
    echo ""
fi

read -r -s -p "Glance 数据库用户密码 [默认: 123456]: " GLANCE_DBPASS
echo ""
GLANCE_DBPASS="${GLANCE_DBPASS:-123456}"

read -r -s -p "Glance Keystone 用户密码 [默认: 123456]: " GLANCE_PASS
echo ""
GLANCE_PASS="${GLANCE_PASS:-123456}"

# ==================== 工具函数 ====================
backup_file() {
    local src="$1"
    if [ -f "$src" ]; then
        cp -n "$src" "${src}.bak.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
        log_info "已备份 ${src}"
    fi
}

# ==================== 1. 配置 MySQL 数据库 ====================
setup_mysql_database() {
    log_step "1. 配置 Glance 数据库"

    if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "USE glance;" &>/dev/null 2>&1; then
        log_info "glance 数据库已存在，跳过创建"
    else
        log_info "创建 glance 数据库并授权..."
        mysql -uroot -p"${MYSQL_ROOT_PASS}" << EOF
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '${GLANCE_DBPASS}';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '${GLANCE_DBPASS}';
FLUSH PRIVILEGES;
EOF
        log_info "glance 数据库已创建"
    fi

    if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "SHOW DATABASES LIKE 'glance';" 2>/dev/null | grep -q glance; then
        log_info "数据库验证通过: glance 库存在"
    else
        log_error "数据库验证失败"
        exit 1
    fi
}

# ==================== 2. Keystone 认证配置 ====================
setup_keystone_auth() {
    log_step "2. 配置 Glance Keystone 认证"

    # 创建 glance 用户
    if openstack user show glance &>/dev/null 2>&1; then
        log_info "glance 用户已存在"
    else
        log_info "创建 glance 用户..."
        openstack user create --domain default --password "${GLANCE_PASS}" glance
        log_info "glance 用户已创建"
    fi

    # 为 glance 添加 admin 角色到 service 项目
    if openstack role assignment list --user glance --project service --names 2>/dev/null | grep -q admin; then
        log_info "glance 已有 service 项目的 admin 角色"
    else
        log_info "为 glance 添加 admin 角色..."
        openstack role add --project service --user glance admin
        log_info "admin 角色已添加"
    fi

    # 创建 glance 服务实体
    if openstack service show glance &>/dev/null 2>&1; then
        log_info "glance 服务实体已存在"
    else
        log_info "创建 glance 服务实体..."
        openstack service create --name glance --description "OpenStack Image" image
        log_info "glance 服务实体已创建"
    fi

    # 创建 API 端点
    local endpoint_url="http://${CTRL_HOSTNAME}:9292"
    if openstack endpoint list 2>/dev/null | grep -q "glance.*public"; then
        log_info "glance 端点已存在"
    else
        log_info "创建 glance API 端点..."
        openstack endpoint create --region RegionOne image public   "${endpoint_url}"
        openstack endpoint create --region RegionOne image internal "${endpoint_url}"
        openstack endpoint create --region RegionOne image admin    "${endpoint_url}"
        log_info "API 端点已创建"
    fi
}

# ==================== 3. 安装软件包 ====================
install_packages() {
    log_step "3. 安装 Glance 软件包"

    dnf install -y openstack-glance
    log_info "openstack-glance 安装完成"
}

# ==================== 4. 配置 glance-api.conf ====================
configure_glance() {
    log_step "4. 配置 Glance"

    local conf="/etc/glance/glance-api.conf"

    if [ ! -f "$conf" ]; then
        log_error "${conf} 不存在，请检查 openstack-glance 是否安装成功"
        exit 1
    fi

    backup_file "$conf"

    # Glance 默认配置注释掉了大部分选项，直接用 cat 覆盖写入关键段
    cat >> "$conf" << GLANCEEOF

# === OpenStack Dalmatian Glance Configuration ===

[database]
connection = mysql+pymysql://glance:${GLANCE_DBPASS}@${CTRL_HOSTNAME}/glance

[keystone_authtoken]
www_authenticate_uri = http://${CTRL_HOSTNAME}:5000/v3
auth_url = http://${CTRL_HOSTNAME}:5000/v3
memcached_servers = ${CTRL_HOSTNAME}:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = glance
password = ${GLANCE_PASS}

[paste_deploy]
flavor = keystone

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
GLANCEEOF

    log_info "配置文件已更新: ${conf}"

    # 显示关键配置
    echo ""
    echo "关键配置项:"
    grep -E "^(connection|www_authenticate_uri|auth_url|flavor|stores|default_store)" "$conf" 2>/dev/null || true
}

# ==================== 5. 同步数据库 ====================
populate_database() {
    log_step "5. 同步 Glance 数据库"

    # 确保镜像存储目录存在
    mkdir -p /var/lib/glance/images/
    chown glance:glance /var/lib/glance/images/

    log_info "同步数据库..."
    su -s /bin/sh -c "glance-manage db_sync" glance
    log_info "数据库同步完成"
}

# ==================== 6. 启动服务 ====================
start_service() {
    log_step "6. 启动 Glance 服务"

    log_info "启动 openstack-glance-api..."
    systemctl enable openstack-glance-api --now

    if systemctl is-active openstack-glance-api &>/dev/null; then
        log_info "openstack-glance-api 服务已启动"
    else
        log_warn "服务启动状态异常，查看日志:"
        systemctl status openstack-glance-api --no-pager -l 2>/dev/null || true
        journalctl -u openstack-glance-api --no-pager -n 20 2>/dev/null || true
    fi
}

# ==================== 7. 验证 ====================
verify_glance() {
    log_step "7. 验证 Glance 服务"

    # 检查服务端点
    echo ""
    echo "--- 镜像服务端点 ---"
    openstack endpoint list 2>/dev/null | grep image || true

    # 检查服务状态
    echo ""
    echo "--- Glance API 状态 ---"
    openstack image list 2>/dev/null || log_warn "openstack image list 失败"

    # 可选：上传测试镜像
    echo ""
    echo "--- 上传测试镜像（可选） ---"
    read -r -p "是否上传 cirros 测试镜像? [y/N]: " UPLOAD_IMAGE

    if [[ "$UPLOAD_IMAGE" =~ ^[Yy]$ ]]; then
        CIRROS_IMG="/root/cirros-0.6.3-x86_64-disk.img"
        [ ! -f "$CIRROS_IMG" ] && CIRROS_IMG="/root/cirros.img"
        for p in /root/cirros-*.img /root/cirros*.qcow2 /opt/cirros.img; do
            [ -f "$p" ] && { CIRROS_IMG="$p"; break; }
        done

        if [ ! -f "$CIRROS_IMG" ]; then
            read -r -p "请输入镜像路径: " path
            [ -f "$path" ] && CIRROS_IMG="$path" || log_warn "文件不存在，跳过上传"
        fi

        if [ -f "$CIRROS_IMG" ]; then
            openstack image show cirros &>/dev/null 2>&1 && log_info "cirros 已存在" || {
                log_info "上传中..."
                openstack image create "cirros" \
                    --file "${CIRROS_IMG}" \
                    --disk-format qcow2 \
                    --container-format bare \
                    --architecture x86_64 \
                    --public
                log_info "cirros 上传完成"
            }
        fi
    else
        log_info "跳过镜像上传（后续可在 Horizon 创建时需填写架构为 x86_64）"
    fi

    # 镜像列表
    echo ""
    echo "--- 当前镜像列表 ---"
    openstack image list 2>/dev/null
}

# ==================== 主流程 ====================
main() {
    setup_mysql_database
    setup_keystone_auth
    install_packages
    configure_glance
    populate_database
    start_service
    verify_glance

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  Glance 镜像服务安装完成                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  查看镜像:    openstack image list"
    echo "  服务端点:    openstack endpoint list | grep image"
    echo "  Glance URL:  http://${CTRL_HOSTNAME}:9292"
    echo ""
}

main
