#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Swift 对象存储验证脚本
# 运行节点: 控制节点
###############################################################################

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"
reset_counts

load_env
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
print_summary
exit $?
