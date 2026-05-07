#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Neutron 网络服务验证脚本
# 运行节点: 控制节点
# 运行方式: bash openstack_neutron_verify.sh
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
echo "║           Neutron 网络服务验证                              ║"
echo "║           检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. MySQL ====================
section "1. Neutron 数据库"
if [ -n "${MYSQL_ROOT_PASS:-}" ]; then
    check "neutron 数据库存在"     "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e 'USE neutron;'"
    check "neutron 用户存在"       "mysql -uroot -p'${MYSQL_ROOT_PASS}' -e \"SELECT user FROM mysql.user WHERE user='neutron';\" | grep -q neutron"
    TBL=$(mysql -uroot -p"${MYSQL_ROOT_PASS}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='neutron';" 2>/dev/null || echo "0")
    [ "$TBL" -gt 10 ] && echo -e "  neutron 数据表 ($TBL 张)               ${PASS}" && PASS_COUNT=$((PASS_COUNT + 1)) || { echo -e "  neutron 数据表 ($TBL 张)               ${WARN}"; WARN_COUNT=$((WARN_COUNT + 1)); }
fi

# ==================== 2. Keystone ====================
section "2. Keystone 认证"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    check "neutron 用户存在"           "openstack user show neutron"
    check "neutron 有 admin 角色"      "openstack role assignment list --user neutron --project service --names 2>/dev/null | grep -q admin"
    check "neutron 服务实体存在"       "openstack service show neutron"
    check "neutron public 端点"        "openstack endpoint list 2>/dev/null | grep neutron | grep -q public"
fi

# ==================== 3. 软件包 ====================
section "3. 控制节点软件包"
for pkg in openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch; do
    check "${pkg} 已安装" "rpm -q ${pkg}"
done
check "ebtables 已安装" "command -v ebtables"

# ==================== 4. 配置文件 ====================
section "4. 配置文件检查"
check "neutron.conf 存在"              "test -f /etc/neutron/neutron.conf"
check "ml2_conf.ini 存在"              "test -f /etc/neutron/plugins/ml2/ml2_conf.ini"
check "openvswitch_agent.ini 存在"     "test -f /etc/neutron/plugins/ml2/openvswitch_agent.ini"
check "l3_agent.ini 存在"              "test -f /etc/neutron/l3_agent.ini"
check "dhcp_agent.ini 存在"            "test -f /etc/neutron/dhcp_agent.ini"
check "metadata_agent.ini 存在"        "test -f /etc/neutron/metadata_agent.ini"
check "plugin.ini 符号链接"            "test -L /etc/neutron/plugin.ini"
check "neutron.conf database 已配置"   "grep -q 'connection.*neutron' /etc/neutron/neutron.conf"
check "neutron.conf rabbit 已配置"     "grep -q 'transport_url.*rabbit' /etc/neutron/neutron.conf"
check "ML2 type_drivers 已配置"        "grep -q 'type_drivers' /etc/neutron/plugins/ml2/ml2_conf.ini"
check "nova.conf [neutron] 已配置"     "grep -A3 '\[neutron\]' /etc/nova/nova.conf | grep -q auth_url"

# ==================== 5. OVS ====================
section "5. OVS 网桥"
check_w "openvswitch 运行中"             "systemctl is-active openvswitch"
check "br-provider 网桥存在"           "ovs-vsctl br-exists br-provider 2>/dev/null"

# 检测 OVS 桥端口是否泄漏 IP（应无 IPv4）
echo ""
echo "  OVS 端口 IP 检查:"
for port in $(ovs-vsctl list-ports br-provider 2>/dev/null); do
    LEAK_IP=$(ip -4 -o addr show "$port" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -n "$LEAK_IP" ]; then
        echo -e "    ${port}: ${LEAK_IP}  ${WARN}  (应无 IP)"
        WARN_COUNT=$((WARN_COUNT + 1))
    else
        echo -e "    ${port}: 无 IP ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    fi
done

# RabbitMQ 连接测试
check_w "RabbitMQ 5672 端口可达"           "timeout 3 bash -c 'echo >/dev/tcp/${CTRL_HOSTNAME}/5672' 2>/dev/null"

# 检查各 agent 是否全部 Alive
echo ""
echo "  Agent 活跃状态:"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    AGENTS=$(openstack network agent list -f value -c 'Alive' -c 'Binary' -c 'Host' 2>/dev/null)
    if [ -n "$AGENTS" ]; then
        echo "$AGENTS" | while read -r alive binary host; do
            bin_short=$(echo "$binary" | sed 's/neutron-//')
            if [ "$alive" = ":-)" ]; then
                echo -e "    ${host}: ${bin_short} ${alive} ${PASS}"
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                echo -e "    ${host}: ${bin_short} ${alive} ${WARN}"
                WARN_COUNT=$((WARN_COUNT + 1))
     fi
done

# 检测 OVS 桥端口物理状态
echo ""
echo "  OVS 端口状态:"
for port in $(ovs-vsctl list-ports br-provider 2>/dev/null); do
    STATE=$(ip -o link show "$port" 2>/dev/null | grep -oP 'state \K\w+')
    if [ "$STATE" = "UP" ]; then
        echo -e "    ${port}: ${STATE} ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "    ${port}: ${STATE:-DOWN} ${WARN}  (应 UP)"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
done
    fi
fi

# ==================== 6. 服务状态 ====================
section "6. Neutron 服务状态"
for svc in neutron-server neutron-openvswitch-agent neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent; do
    ACT=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
    EN=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
    if [ "$ACT" = "active" ]; then
        echo -e "  ${svc}  运行: ${GREEN}active${NC}  开机: ${EN}"
    else
        echo -e "  ${svc}  运行: ${RED}${ACT}${NC}  开机: ${EN}"
    fi
done

# ==================== 7. 网络代理 ====================
section "7. 网络代理列表"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    echo ""
    if openstack network agent list &>/dev/null 2>&1; then
        openstack network agent list 2>/dev/null
        echo ""
        check_w "DHCP agent 已注册"    "openstack network agent list 2>/dev/null | grep -q DHCP"
        check_w "L3 agent 已注册"      "openstack network agent list 2>/dev/null | grep -q 'L3 agent'"
        check_w "OVS agent (ctrl)"     "openstack network agent list 2>/dev/null | grep ${CTRL_HOSTNAME} | grep -q 'Open vSwitch'"
        check_w "OVS agent (compute)"  "openstack network agent list 2>/dev/null | grep -v ${CTRL_HOSTNAME} | grep -q 'Open vSwitch'"
    else
        echo -e "  network agent list                    ${WARN}"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
fi

# ==================== 8. API ====================
section "8. Neutron API"
check_w "HTTP ${CTRL_HOSTNAME}:9696 可达"  "curl -s --connect-timeout 5 'http://${CTRL_HOSTNAME}:9696/' &>/dev/null"

# ==================== 9. IP 转发 ====================
section "9. 系统配置"
IPFW=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
[ "$IPFW" = "1" ] && echo -e "  IP 转发: ${IPFW}                               ${PASS}" && PASS_COUNT=$((PASS_COUNT + 1)) || { echo -e "  IP 转发: ${IPFW}                               ${WARN}"; WARN_COUNT=$((WARN_COUNT + 1)); }

# ==================== 汇总 ====================
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    验证结果汇总                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ${GREEN}通过: %-3d${NC}  ${RED}失败: %-3d${NC}  ${YELLOW}警告: %-3d${NC}  共计: %-3d              ║\n" "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$TOTAL"
echo "╚══════════════════════════════════════════════════════════════╝"

[ "$FAIL_COUNT" -eq 0 ] && echo -e "\n${GREEN}Neutron 网络服务验证通过！${NC}" && exit 0 || { echo -e "\n${RED}存在 ${FAIL_COUNT} 项未通过。${NC}"; exit 1; }
