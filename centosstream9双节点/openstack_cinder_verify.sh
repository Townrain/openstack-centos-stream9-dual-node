#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Cinder 块存储服务验证脚本
# 运行节点: 控制节点
# 运行方式: bash openstack_cinder_verify.sh
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS="${GREEN}[通过]${NC}"; FAIL="${RED}[失败]${NC}"; WARN="${YELLOW}[警告]${NC}"
PASS_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0

check()   { printf "  %-52s " "$1"; if eval "$2" &>/dev/null 2>&1; then echo -e "$PASS"; PASS_COUNT=$((PASS_COUNT + 1)); else echo -e "$FAIL"; FAIL_COUNT=$((FAIL_COUNT + 1)); fi }
check_w() { printf "  %-52s " "$1"; if eval "$2" &>/dev/null 2>&1; then echo -e "$PASS"; PASS_COUNT=$((PASS_COUNT + 1)); else echo -e "$WARN"; WARN_COUNT=$((WARN_COUNT + 1)); fi }
section() { echo ""; echo -e "${BLUE}---- $* ----${NC}"; }

[ -f /root/openstack_env.conf ] && source /root/openstack_env.conf 2>/dev/null || true
CTRL_HOSTNAME="${CTRL_HOSTNAME:-$(hostname)}"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Cinder 块存储服务验证                             ║"
echo "║           检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. MySQL ====================
section "1. Cinder 数据库"
if [ -n "${MYSQL_ROOT_PASS:-}" ]; then
    check "cinder 数据库存在"  "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e 'USE cinder;'"
    check "cinder 用户存在"    "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e \"SELECT user FROM mysql.user WHERE user='cinder';\" | grep -q cinder"
    TBL=$(mysql -uroot -p"${MYSQL_ROOT_PASS}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='cinder';" 2>/dev/null || echo "0")
    [ "$TBL" -gt 5 ] && echo -e "  cinder 数据表 ($TBL 张)                ${PASS}" && PASS_COUNT=$((PASS_COUNT + 1)) || { echo -e "  cinder 数据表 ($TBL 张)                ${WARN}"; WARN_COUNT=$((WARN_COUNT + 1)); }
fi

# ==================== 2. Keystone ====================
section "2. Keystone 认证"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    check "cinder 用户存在"             "openstack user show cinder"
    check "cinder 有 admin 角色"        "openstack role assignment list --user cinder --project service --names 2>/dev/null | grep -q admin"
    check "cinderv3 服务实体存在"       "openstack service show cinderv3"
    check "volumev3 public 端点"        "openstack endpoint list 2>/dev/null | grep volumev3 | grep -q public"
fi

# ==================== 3. 软件包 ====================
section "3. 控制节点软件包"
check "openstack-cinder 已安装"   "rpm -q openstack-cinder"

# ==================== 4. 配置 ====================
section "4. cinder.conf 配置"
CONF="/etc/cinder/cinder.conf"
check "cinder.conf 存在"            "test -f $CONF"
check "database connection 已配置"  "grep -q 'cinder' $CONF"
check "rabbit transport_url 已配置" "grep -q 'transport_url.*rabbit' $CONF"
check "keystone_authtoken 已配置"   "grep -q 'auth_url' $CONF"

# ==================== 5. 服务状态 ====================
section "5. Cinder 控制服务状态"
for svc in openstack-cinder-api openstack-cinder-scheduler; do
    ACT=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    EN=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
    if [ "$ACT" = "active" ]; then
        echo -e "  ${svc}  运行: ${GREEN}active${NC}  开机: ${EN}"
    else
        echo -e "  ${svc}  运行: ${RED}${ACT}${NC}  开机: ${EN}"
    fi
done

# ==================== 6. 服务列表 ====================
section "6. Cinder 服务列表"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    echo ""
    if openstack volume service list &>/dev/null 2>&1; then
        openstack volume service list 2>/dev/null
        echo ""
        check_w "cinder-volume 已注册"  "openstack volume service list 2>/dev/null | grep -q cinder-volume"
        check_w "cinder-scheduler 已注册" "openstack volume service list 2>/dev/null | grep -q cinder-scheduler"
    else
        echo -e "  volume service list                  ${WARN}"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

# ==================== 7. API ====================
section "7. Cinder API"
check_w "HTTP ${CTRL_HOSTNAME}:8776 可达"  "curl -s --connect-timeout 5 'http://${CTRL_HOSTNAME}:8776/' &>/dev/null"

# ==================== 汇总 ====================
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    验证结果汇总                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ${GREEN}通过: %-3d${NC}  ${RED}失败: %-3d${NC}  ${YELLOW}警告: %-3d${NC}  共计: %-3d              ║\n" "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$TOTAL"
echo "╚══════════════════════════════════════════════════════════════╝"

[ "$FAIL_COUNT" -eq 0 ] && echo -e "\n${GREEN}Cinder 块存储服务验证通过！${NC}" && exit 0 || { echo -e "\n${RED}存在 ${FAIL_COUNT} 项未通过。${NC}"; exit 1; }
