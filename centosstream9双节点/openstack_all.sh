#!/bin/bash
###############################################################################
# OpenStack Dalmatian 一键部署总脚本
# 运行位置: 控制节点
# 执行方式: bash openstack_all.sh
# 运行用户: root
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS="${GREEN}[通过]${NC}"; FAIL="${RED}[失败]${NC}"; SKIP="${YELLOW}[跳过]${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}请使用 root 账户运行${NC}"; exit 1; }

# ==================== 模块定义 ====================
MODULES=(
    "01|基础环境准备|openstack_base_env.sh|openstack_verify.sh|是"
    "02|Keystone 身份认证|openstack_keystone.sh|openstack_keystone_verify.sh|否"
    "03|Glance 镜像服务|openstack_glance.sh|openstack_glance_verify.sh|否"
    "04|Placement 布局服务|openstack_placement.sh|openstack_placement_verify.sh|否"
    "05|Nova 计算服务|openstack_nova.sh|openstack_nova_verify.sh|否"
    "06|Neutron 网络服务|openstack_neutron.sh|openstack_neutron_verify.sh|否"
    "07|Horizon 界面服务|openstack_horizon.sh|openstack_horizon_verify.sh|否"
    "08|Cinder 块存储|openstack_cinder.sh|openstack_cinder_verify.sh|否"
    "09|Swift 对象存储|openstack_swift.sh|openstack_swift_verify.sh|否"
)

RESULTS=()

# ==================== 菜单 ====================
show_menu() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     OpenStack Dalmatian 一键部署 (CentOS Stream 9)          ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  模块:                                                      ║"
    for m in "${MODULES[@]}"; do
        local id; id=$(echo "$m" | cut -d'|' -f1)
        local name; name=$(echo "$m" | cut -d'|' -f2)
        local has_verify; has_verify=$(echo "$m" | cut -d'|' -f4)
        printf "║    [%s] %s" "$id" "$name"
        [ -f "${SCRIPT_DIR}/${has_verify}" ] && printf "  ${GREEN}(已验证)${NC}"
        echo ""
    done
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║    [A] 一键部署全部 (按顺序)                                 ║"
    echo "║    [V] 验证全部已部署模块                                    ║"
    echo "║    [Q] 退出                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
}

run_module() {
    local id="$1"
    local script="$2"
    local verify="$3"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  [$id] 开始部署                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    if [ -f "${SCRIPT_DIR}/${script}" ]; then
        if bash "${SCRIPT_DIR}/${script}"; then
            RESULTS+=("${id}|${PASS}")

            # 运行验证
            if [ -n "$verify" ] && [ -f "${SCRIPT_DIR}/${verify}" ]; then
                echo ""
                echo -e "${BLUE}--- [$id] 验证 ---${NC}"
                bash "${SCRIPT_DIR}/${verify}" && RESULTS+=("${id}v|${PASS}") || RESULTS+=("${id}v|${FAIL}")
            fi
        else
            RESULTS+=("${id}|${FAIL}")
            echo -e "\n${RED}[$id] 部署失败，继续下一模块${NC}"
        fi
    else
        echo -e "  ${SKIP} 脚本不存在: ${script}"
        RESULTS+=("${id}|${SKIP}")
    fi
}

run_verify() {
    local id="$1"
    local verify="$2"

    if [ -f "${SCRIPT_DIR}/${verify}" ]; then
        echo -e "\n${BLUE}--- [$id] 验证 ---${NC}"
        bash "${SCRIPT_DIR}/${verify}" && RESULTS+=("${id}v|${PASS}") || RESULTS+=("${id}v|${FAIL}")
    fi
}

# ==================== 主流程 ====================
main() {
    show_menu

    echo ""
    read -r -p "  请选择: " CHOICE

    case "$CHOICE" in
        [Qq]) exit 0 ;;

        [Aa])
            for m in "${MODULES[@]}"; do
                local id; id=$(echo "$m" | cut -d'|' -f1)
                local name; name=$(echo "$m" | cut -d'|' -f2)
                local script; script=$(echo "$m" | cut -d'|' -f3)
                local verify; verify=$(echo "$m" | cut -d'|' -f4)

                echo -e "\n\n${BLUE}##############################################################${NC}"
                echo -e "${BLUE}#  ${id} - ${name}${NC}"
                echo -e "${BLUE}##############################################################${NC}"

                run_module "$id" "$script" "$verify"
            done
            ;;

        [Vv])
            for m in "${MODULES[@]}"; do
                local id; id=$(echo "$m" | cut -d'|' -f1)
                local name; name=$(echo "$m" | cut -d'|' -f2)
                local verify; verify=$(echo "$m" | cut -d'|' -f4)
                [ -n "$verify" ] && run_verify "$id" "$verify"
            done
            ;;

        *)
            if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#MODULES[@]} ]; then
                local idx=$((CHOICE - 1))
                local m="${MODULES[$idx]}"
                local id; id=$(echo "$m" | cut -d'|' -f1)
                local name; name=$(echo "$m" | cut -d'|' -f2)
                local script; script=$(echo "$m" | cut -d'|' -f3)
                local verify; verify=$(echo "$m" | cut -d'|' -f4)
                run_module "$id" "$script" "$verify"
            else
                echo -e "${RED}无效选择${NC}"
            fi
            ;;
    esac

    # 汇总
    if [ ${#RESULTS[@]} -gt 0 ]; then
        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║                    部署结果汇总                              ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        local pass=0 fail=0 skip=0
        for r in "${RESULTS[@]}"; do
            local lid; lid=$(echo "$r" | cut -d'|' -f1)
            local lstatus; lstatus=$(echo "$r" | cut -d'|' -f2)
            case "$lstatus" in
                "${PASS}") pass=$((pass + 1)) ;;
                "${FAIL}") fail=$((fail + 1)) ;;
                "${SKIP}") skip=$((skip + 1)) ;;
            esac
            printf "║  %-6s %-45s ║\n" "$lid" "$lstatus"
        done
        echo "╠══════════════════════════════════════════════════════════════╣"
        printf "║  ${GREEN}通过: %-3d${NC}  ${RED}失败: %-3d${NC}  ${YELLOW}跳过: %-3d${NC}  共计: %-3d              ║\n" \
            "$pass" "$fail" "$skip" "${#RESULTS[@]}"
        echo "╚══════════════════════════════════════════════════════════════╝"
    fi
}

main
