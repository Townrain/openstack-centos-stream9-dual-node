#!/bin/bash
###############################################################################
# OpenStack Dalmatian 一键部署总脚本
# 运行位置: 控制节点
# 执行方式: bash openstack_all.sh
# 运行用户: root
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"

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
    echo "║     OpenStack Dalmatian 一键部署 (CentOS Stream 9)  v3     ║"
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
    local noninteractive="${4:-1}"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  [$id] 开始部署                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    if [ -f "${SCRIPT_DIR}/${script}" ]; then
        local run_opts=""
        [ "$noninteractive" -eq 1 ] && run_opts="--non-interactive"

        if bash "${SCRIPT_DIR}/${script}" $run_opts; then
            RESULTS+=("${id}|${PASS}")

            # 运行验证
            if [ -n "$verify" ] && [ -f "${SCRIPT_DIR}/${verify}" ]; then
                echo ""
                echo -e "${BLUE}--- [$id] 验证 ---${NC}"
                bash "${SCRIPT_DIR}/${verify}" --non-interactive && RESULTS+=("${id}v|${PASS}") || RESULTS+=("${id}v|${FAIL}")
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
        bash "${SCRIPT_DIR}/${verify}" --non-interactive && RESULTS+=("${id}v|${PASS}") || RESULTS+=("${id}v|${FAIL}")
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
            load_env
            for m in "${MODULES[@]}"; do
                local id; id=$(echo "$m" | cut -d'|' -f1)
                local name; name=$(echo "$m" | cut -d'|' -f2)
                local script; script=$(echo "$m" | cut -d'|' -f3)
                local verify; verify=$(echo "$m" | cut -d'|' -f4)

                echo -e "\n\n${BLUE}##############################################################${NC}"
                echo -e "${BLUE}#  ${id} - ${name}${NC}"
                echo -e "${BLUE}##############################################################${NC}"

                # 基础环境模块需要交互收集变量，后续模块非交互自动运行
                if [ "$id" = "01" ]; then
                    run_module "$id" "$script" "$verify" 0

                    # 离线模式: 检查系统更新后 SSH 是否仍可用
                    if is_offline; then
                        if ! ssh -o BatchMode=yes -o ConnectTimeout=3 \
                            "${COMPUTE_USER:-root}@${COMPUTE_IP:-}" "hostname" &>/dev/null 2>&1; then
                            echo ""
                            echo "╔══════════════════════════════════════════════════════════════╗"
                            echo "║  系统更新后 SSH 不可用 (openssl 版本不匹配)                ║"
                            echo "╠══════════════════════════════════════════════════════════════╣"
                            echo "║  请重建 ISO (已含 openssh-clients) 或重启后继续:           ║"
                            echo "║    reboot                                                  ║"
                            echo "║    重启后: bash openstack_all.sh → [A]                      ║"
                            echo "╚══════════════════════════════════════════════════════════════╝"
                            echo ""
                            log_warn "SSH 不可用，请重启后重新运行 [A]"
                            exit 0
                        fi
                        log_info "SSH 连接正常，继续部署..."
                    fi
                else
                    run_module "$id" "$script" "$verify" 1
                fi
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
                if [ "$id" = "01" ]; then
                    run_module "$id" "$script" "$verify" 0
                else
                    run_module "$id" "$script" "$verify" 1
                fi
            else
                echo -e "${RED}无效选择${NC}"
            fi
            ;;
    esac

    # 离线部署完成后恢复网络源
    load_env
    restore_network_repos

    if [ -n "${COMPUTE_IP:-}" ] && [ -n "${COMPUTE_USER:-}" ]; then
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER}@${COMPUTE_IP}" "test -f /root/openstack_common.sh" 2>/dev/null; then
            log_info "正在恢复计算节点网络源..."
            ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" \
                "source /root/openstack_common.sh && restore_network_repos" 2>/dev/null || \
                log_warn "计算节点网络源恢复失败，请手动执行: ssh ${COMPUTE_USER}@${COMPUTE_IP} 'source /root/openstack_common.sh && restore_network_repos'"
        fi
    fi

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
            echo -e "║  ${lid}\t${lstatus}                                           ║"
        done
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo -e "║  ${GREEN}通过: ${pass}${NC}  ${RED}失败: ${fail}${NC}  ${YELLOW}跳过: ${skip}${NC}  共计: ${#RESULTS[@]}                              ║"
        echo "╚══════════════════════════════════════════════════════════════╝"

        if [ "$fail" -gt 0 ]; then
            echo ""
            echo -e "${RED}存在 ${fail} 个失败项，查看错误日志:${NC}"
            echo "  journalctl -u <服务名> --no-pager -n 50"
            echo "  tail -100 /var/log/nova/nova-api.log"
            echo "  tail -100 /var/log/neutron/server.log"
            echo ""
            echo "  重新运行失败模块:"
            for r in "${RESULTS[@]}"; do
                local lid; lid=$(echo "$r" | cut -d'|' -f1)
                local lstatus; lstatus=$(echo "$r" | cut -d'|' -f2)
                [ "$lstatus" = "${FAIL}" ] && echo "    bash openstack_all.sh  → 选择 [${lid}]"
            done
        fi
    fi
}

main
