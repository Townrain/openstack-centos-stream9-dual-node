#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Swift 对象存储验证脚本
# 运行节点: 控制节点
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
echo "║           Swift 对象存储服务验证                            ║"
echo "║           检测时间: $(date '+%Y-%m-%d %H:%M:%S')                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ==================== 1. Keystone ====================
section "1. Keystone 认证"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null
    check "swift 用户存在"              "openstack user show swift"
    check "swift 服务实体存在"          "openstack service show swift"
    check "object-store public 端点"    "openstack endpoint list 2>/dev/null | grep object-store | grep -q public"
fi

# ==================== 2. 软件包 ====================
section "2. 控制节点软件包"
check "openstack-swift-proxy 已安装"  "rpm -q openstack-swift-proxy"
check "python3-swiftclient 已安装"    "rpm -q python3-swiftclient"

# ==================== 3. 配置文件 ====================
section "3. 配置文件"
check "proxy-server.conf 存在"       "test -f /etc/swift/proxy-server.conf"
check "swift.conf 存在"              "test -f /etc/swift/swift.conf"
check "account.ring.gz 存在"         "test -f /etc/swift/account.ring.gz"
check "container.ring.gz 存在"       "test -f /etc/swift/container.ring.gz"
check "object.ring.gz 存在"          "test -f /etc/swift/object.ring.gz"
check "Ring 属主为 swift"             "stat -c '%U' /etc/swift/object.ring.gz 2>/dev/null | grep -q swift"

# ==================== 4. 服务 ====================
section "4. Proxy 服务"
ACT=$(systemctl is-active openstack-swift-proxy 2>/dev/null || echo "inactive")
if [ "$ACT" = "active" ]; then
    echo -e "  openstack-swift-proxy  运行: ${GREEN}active${NC}"
else
    echo -e "  openstack-swift-proxy  运行: ${RED}${ACT}${NC}"
fi

# ==================== 5. Swift API ====================
section "5. Swift API 验证"
if [ -f /root/admin-openrc ]; then
    source /root/admin-openrc 2>/dev/null

    if swift stat &>/dev/null 2>&1; then
        echo -e "  swift stat                              ${PASS}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "  swift stat                              ${WARN}"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi

    check_w "swift upload 功能"  "echo test > /tmp/.swift-v; swift upload test-container /tmp/.swift-v 2>/dev/null"
    check_w "swift list 功能"     "swift list test-container 2>/dev/null | grep -q '.swift-v'"
    check_w "swift download 功能" "swift download test-container tmp/.swift-v -o /tmp/.swift-vd 2>/dev/null && rm -f /tmp/.swift-v /tmp/.swift-vd"
fi

check_w "HTTP ${CTRL_HOSTNAME}:8080 可达"  "curl -s --connect-timeout 5 'http://${CTRL_HOSTNAME}:8080/' &>/dev/null"

# ==================== 汇总 ====================
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    验证结果汇总                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  ${GREEN}通过: %-3d${NC}  ${RED}失败: %-3d${NC}  ${YELLOW}警告: %-3d${NC}  共计: %-3d              ║\n" "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$TOTAL"
echo "╚══════════════════════════════════════════════════════════════╝"

[ "$FAIL_COUNT" -eq 0 ] && echo -e "\n${GREEN}Swift 对象存储验证通过！${NC}" && exit 0 || { echo -e "\n${RED}存在 ${FAIL_COUNT} 项未通过。${NC}"; exit 1; }
