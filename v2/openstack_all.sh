#!/bin/bash
###############################################################################
# OpenStack Dalmatian 一键部署总脚本
# 运行位置: 控制节点
# 运行用户: root
#
# 本地运行:
#   bash openstack_all.sh
#
# 远程一键运行:
#   bash <(curl -sSL https://raw.githubusercontent.com/...) --keep    # 保留脚本
#   bash <(curl -sSL https://raw.githubusercontent.com/...)           # 完成后清理
###############################################################################

set -euo pipefail

# ==================== 参数解析 ====================
KEEP_SCRIPTS=0
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP_SCRIPTS=1 ;;
    esac
done

# ==================== 自举: 检测并下载缺失脚本 ====================
# GitHub 仓库地址 (可通过环境变量覆盖)
GITHUB_REPO="${GITHUB_REPO:-Townrain/openstack-centos-stream9-dual-node}"
GITHUB_REF="${GITHUB_REF:-main}"
GITHUB_PATH="${GITHUB_PATH:-v2}"
GITHUB_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/${GITHUB_REF}/${GITHUB_PATH}"

# 尝试从当前目录检测脚本
_CANDIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [ -n "${_CANDIDATE_DIR:-}" ] && [ -f "${_CANDIDATE_DIR}/openstack_common.sh" ]; then
    SCRIPT_DIR="${_CANDIDATE_DIR}"
    BOOTSTRAPPED=0
else
    SCRIPT_DIR="$(mktemp -d /tmp/openstack-deploy-XXXXXX)"
    BOOTSTRAPPED=1

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  检测到通过 curl 管道运行，正在从 GitHub 下载脚本...       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    SCRIPTS=(
        openstack_common.sh
        openstack_base_env.sh   openstack_verify.sh
        openstack_keystone.sh   openstack_keystone_verify.sh
        openstack_glance.sh     openstack_glance_verify.sh
        openstack_placement.sh  openstack_placement_verify.sh
        openstack_nova.sh       openstack_nova_verify.sh
        openstack_neutron.sh    openstack_neutron_verify.sh
        openstack_horizon.sh    openstack_horizon_verify.sh
        openstack_cinder.sh     openstack_cinder_verify.sh
        openstack_swift.sh      openstack_swift_verify.sh
    )

    for f in "${SCRIPTS[@]}"; do
        printf "  下载 %s ... " "$f"
        if curl -sSL --connect-timeout 10 "${GITHUB_BASE}/${f}" -o "${SCRIPT_DIR}/${f}" 2>/dev/null; then
            echo "OK"
        else
            echo "失败"
            echo ""
            echo "  无法从 ${GITHUB_BASE} 下载脚本"
            echo "  请检查网络或手动指定仓库:"
            echo "    GITHUB_REPO=user/repo GITHUB_REF=main bash <(curl ...)"
            exit 1
        fi
    done
    chmod +x "${SCRIPT_DIR}"/*.sh
    echo ""
    echo "  所有脚本下载完成，开始部署..."
    echo ""

    # 退出时清理 (除非指定 --keep)
    if [ "$KEEP_SCRIPTS" -eq 0 ]; then
        _cleanup_dir="${SCRIPT_DIR}"
        trap 'rm -rf "${_cleanup_dir}"' EXIT
    fi
fi

# ==================== 加载公共库 ====================
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

    # 自举清理提示
    if [ "${BOOTSTRAPPED:-0}" -eq 1 ]; then
        if [ "$KEEP_SCRIPTS" -eq 1 ]; then
            echo ""
            echo -e "${YELLOW}脚本已保留在: ${SCRIPT_DIR}${NC}"
        else
            echo ""
            echo -e "${YELLOW}脚本将在退出后自动清理。如需保留, 下次运行时加 --keep${NC}"
            echo "  bash <(curl -sSL ...) --keep"
        fi
    fi
}

main
