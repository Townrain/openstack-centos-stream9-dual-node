#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Keystone 身份服务验证脚本
# 运行节点: 控制节点
# 运行方式: bash openstack_keystone_verify.sh
# 运行用户: root
###############################################################################

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
reset_counts

check_val_eq() {
    printf "  %-52s " "$1"
    if [ "$2" = "$3" ]; then
        echo -e "$PASS  (${3})"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "$FAIL  (期望: ${2}, 实际: ${3})"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# ==================== 加载环境变量 ====================
load_env
CTRL_HOSTNAME="${CTRL_HOSTNAME:-$(hostname)}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Keystone 身份认证服务验证                          ║"
echo "║          检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. MySQL/MariaDB 数据库 ====================
section "1. MariaDB 数据库服务"
check "mariadb-server 已安装"           "rpm -q mariadb-server"
check "MariaDB 服务正在运行"            "systemctl is-active mariadb"
check "MariaDB 服务已设置开机启动"       "systemctl is-enabled mariadb 2>/dev/null | grep -qE 'enabled|indirect'"

if [ -n "${MYSQL_ROOT_PASS:-}" ]; then
    check "MySQL root 可登录"           "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e 'SELECT 1;'"
    check "keystone 数据库存在"         "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e 'USE keystone;'"
    check "keystone 用户有 table 权限"   "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e \"SHOW GRANTS FOR 'keystone'@'localhost';\" | grep -q 'ALL PRIVILEGES'"

    # 检查 keystone 数据库中表数量
    TABLE_COUNT=$(mysql -uroot -p"${MYSQL_ROOT_PASS}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='keystone';" 2>/dev/null || echo "0")
    if [ "$TABLE_COUNT" -gt 10 ]; then
        echo -e "  keystone 数据表 ($TABLE_COUNT 张)        ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  keystone 数据表 ($TABLE_COUNT 张)        ${WARN}  (表数量过少，db_sync 可能未完成)"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
else
    echo -e "  MySQL root 密码未知      ${WARN}  (加载 /root/openstack_env.conf 以检测)"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ==================== 2. 软件包 ====================
section "2. 软件包安装"
check "openstack-keystone 已安装"       "rpm -q openstack-keystone"
check "httpd 已安装"                    "rpm -q httpd"
check "python3-mod_wsgi 已安装"         "rpm -q python3-mod_wsgi"
check "python3-PyMySQL 已安装"          "rpm -q python3-PyMySQL"
check "memcached 已安装"                "rpm -q memcached"

# ==================== 3. Keystone 配置 ====================
section "3. Keystone 配置文件"
KEYSTONE_CONF="/etc/keystone/keystone.conf"

check "keystone.conf 存在"              "test -f $KEYSTONE_CONF"

if [ -f "$KEYSTONE_CONF" ]; then
    DB_CONN=$(grep -oP '^connection\s*=\s*\K.*' "$KEYSTONE_CONF" 2>/dev/null || echo "")
    check_nonempty() {
        printf "  %-52s " "$1"
        if [ -n "$2" ]; then
            echo -e "$PASS  (${2})"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo -e "$FAIL"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    }

    check_nonempty "[database] connection 已配置" "$DB_CONN"
    check "connection 含 mysql+pymysql" "grep -q 'mysql+pymysql' $KEYSTONE_CONF"
    check "connection 含 ${CTRL_HOSTNAME}" "grep -q '${CTRL_HOSTNAME}' $KEYSTONE_CONF"

    TOKEN_PROV=$(grep -oP '^provider\s*=\s*\K.*' "$KEYSTONE_CONF" 2>/dev/null || echo "")
    check_val_eq "[token] provider = fernet" "fernet" "$TOKEN_PROV"
fi

# ==================== 4. Fernet 密钥 ====================
section "4. Fernet 密钥存储"
check "fernet-keys 目录存在"            "test -d /etc/keystone/fernet-keys"
check "fernet 密钥文件存在"             "ls /etc/keystone/fernet-keys/ 2>/dev/null | grep -q '[0-9]'"
check "credential-keys 目录存在"        "test -d /etc/keystone/credential-keys"
check "credential 密钥文件存在"         "ls /etc/keystone/credential-keys/ 2>/dev/null | grep -q '[0-9]'"

FERNET_COUNT=$(ls /etc/keystone/fernet-keys/ 2>/dev/null | wc -l)
CRED_COUNT=$(ls /etc/keystone/credential-keys/ 2>/dev/null | wc -l)
echo "  fernet 密钥: $FERNET_COUNT 个   credential 密钥: $CRED_COUNT 个"

# 检查密钥文件权限
check "fernet-keys 属主为 keystone"     "stat -c '%U:%G' /etc/keystone/fernet-keys 2>/dev/null | grep -q 'keystone:keystone'"

# ==================== 5. Apache HTTP 服务 ====================
section "5. Apache HTTP 服务"
check "httpd 服务正在运行"              "systemctl is-active httpd"
check "httpd 服务开机启动"              "systemctl is-enabled httpd 2>/dev/null | grep -qE 'enabled|indirect'"
check "WSGI 配置文件链接存在"            "test -L /etc/httpd/conf.d/wsgi-keystone.conf"

# 检查 ServerName
SERVER_NAME=$(grep -oP '^ServerName\s+\K.*' /etc/httpd/conf/httpd.conf 2>/dev/null || echo "")
check_nonempty_ln() {
    printf "  %-52s " "$1"
    if [ -n "$2" ]; then
        echo -e "$PASS  (${2})"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "$FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}
check_nonempty_ln "ServerName 已配置" "$SERVER_NAME"

# 检查 Apache 是否监听 5000 端口
check "Apache 监听 5000 端口" "ss -tlnp 2>/dev/null | grep -q ':5000 '"

# ==================== 6. Keystone API 可用性 ====================
section "6. Keystone API 可用性"

# 直接 curl 测试
CURL_OK=0
if curl -s --connect-timeout 5 "http://${CTRL_HOSTNAME}:5000/v3/" &>/dev/null; then
    echo -e "  HTTP ${CTRL_HOSTNAME}:5000/v3/ 可达      ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
    CURL_OK=1
else
    echo -e "  HTTP ${CTRL_HOSTNAME}:5000/v3/ 可达      ${FAIL}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# 获取 API 版本
if [ "$CURL_OK" -eq 1 ]; then
    # 用 grep/sed 解析 JSON，避免依赖 python3
    API_VER=$(curl -s "http://${CTRL_HOSTNAME}:5000/" 2>/dev/null | grep -oP '"id"\s*:\s*"\K[^"]+' | head -1)
    if [ "${API_VER:0:2}" = "v3" ]; then
        echo -e "  Keystone API 版本: ${API_VER}            ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [ -n "$API_VER" ]; then
        echo -e "  Keystone API 版本: ${API_VER}            ${WARN}"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        echo -e "  Keystone API 版本解析                    ${WARN}  (JSON 结构异常)"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

# ==================== 7. 管理员凭证 ====================
section "7. 管理员凭证脚本"
ADMIN_RC="/root/admin-openrc"

check "admin-openrc 存在"               "test -f $ADMIN_RC"
check "admin-openrc 权限 600"           "stat -c '%a' $ADMIN_RC 2>/dev/null | grep -q '600'"

if [ -f "$ADMIN_RC" ]; then
    # shellcheck source=/dev/null
    source "$ADMIN_RC" 2>/dev/null

    check "OS_AUTH_URL 已设置"              "test -n \"\${OS_AUTH_URL:-}\""
    check "OS_USERNAME=admin"               "test \"\${OS_USERNAME:-}\" = admin"
    check "OS_PROJECT_NAME=admin"           "test \"\${OS_PROJECT_NAME:-}\" = admin"
    check "OS_IDENTITY_API_VERSION=3"       "test \"\${OS_IDENTITY_API_VERSION:-}\" = 3"
fi

# ==================== 8. 认证 Token 验证 ====================
section "8. Token 与服务验证"

if [ -f "$ADMIN_RC" ]; then
    source "$ADMIN_RC" 2>/dev/null

    # Token 获取
    if openstack token issue &>/dev/null 2>&1; then
        echo -e "  openstack token issue                  ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))

        # 显示 token 信息
        TOKEN_OUT=$(openstack token issue 2>/dev/null)
        TOKEN_ID=$(echo "$TOKEN_OUT" | grep -oP 'id\s+\|\s+\K\S+' | head -1)
        if [ -n "$TOKEN_ID" ]; then
            echo "    Token ID: ${TOKEN_ID:0:40}..."
        fi
    else
        echo -e "  openstack token issue                  ${FAIL}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    # 项目列表
    check "admin 项目存在"                "openstack project show admin"
    check "service 项目存在"              "openstack project show service"

    # 用户列表
    check "admin 用户存在"                "openstack user show admin"

    # 角色列表
    check "admin 角色存在"                "openstack role show admin"
    check "member 角色存在"               "openstack role show member"
    check "reader 角色存在"               "openstack role show reader"
    check "service 角色存在"              "openstack role show service"

    # 端点列表
    check "identity 服务端点存在"          "openstack endpoint list 2>/dev/null | grep -q identity"

    # 服务列表
    check "keystone 服务已注册"            "openstack service list 2>/dev/null | grep -q keystone"

    # Region
    check "RegionOne 存在"                "openstack region list 2>/dev/null | grep -q RegionOne"
else
    echo -e "  admin-openrc 不可用   ${WARN}  (跳过 Token 验证)"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ==================== 9. 系统服务状态汇总 ====================
section "9. 相关服务状态汇总"

for svc in mariadb httpd memcached; do
    ACTIVE=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")
    if [ "$ACTIVE" = "active" ]; then
        echo -e "  ${svc}  运行: ${GREEN}${ACTIVE}${NC}  开机: ${ENABLED}"
    else
        echo -e "  ${svc}  运行: ${RED}${ACTIVE}${NC}  开机: ${ENABLED}"
    fi
done

# ==================== 10. 常见问题检测 ====================
section "10. 常见问题检测"

# 检查 SELinux 是否可能阻止 httpd 连接数据库
if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    echo -e "  SELinux Enforcing                       ${WARN}  (可能阻止 httpd 连数据库)"
    WARN_COUNT=$((WARN_COUNT + 1))
else
    echo -e "  SELinux 非 Enforcing                    ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
fi

# 检查防火墙
if systemctl is-active firewalld &>/dev/null 2>&1; then
    if firewall-cmd --list-ports 2>/dev/null | grep -q "5000"; then
        echo -e "  防火墙 5000 端口已开放                   ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  防火墙运行中但 5000 端口未开放            ${WARN}"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
else
    echo -e "  防火墙已关闭                             ${PASS}"
    PASS_COUNT=$((PASS_COUNT + 1))
fi

# 检查 /etc/hosts 中的域名
check "hosts 含 ${CTRL_HOSTNAME}"  "grep -q '${CTRL_HOSTNAME}' /etc/hosts"

# ==================== 汇总 ====================
print_summary
