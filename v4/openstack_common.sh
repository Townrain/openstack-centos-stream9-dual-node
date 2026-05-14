#!/bin/bash
###############################################################################
# OpenStack Dalmatian (CentOS Stream 9) - 公共库
# 用途: 被所有安装/验证脚本 source，提供统一的颜色、日志、工具函数
###############################################################################

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS="${GREEN}[通过]${NC}"
FAIL="${RED}[失败]${NC}"
SKIP="${YELLOW}[跳过]${NC}"
WARN="${YELLOW}[警告]${NC}"

# ==================== 日志函数 ====================
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}"; }

# ==================== 工具函数 ====================
backup_file() {
    local src="$1"
    if [ -f "$src" ]; then
        cp -n "$src" "${src}.bak.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
        log_info "已备份 ${src}"
    fi
}

# ==================== 运行模式 ====================
# 非交互模式: 设置 NON_INTERACTIVE=1 或在参数中传递 --non-interactive
NON_INTERACTIVE=0
if [[ "${1:-}" == "--non-interactive" ]] || [[ "${NON_INTERACTIVE_ENV:-}" == "1" ]]; then
    NON_INTERACTIVE=1
fi

# ==================== 环境变量加载 ====================
load_env_common() {
    if [ -f /root/openstack_env.conf ]; then
        # shellcheck source=/dev/null
        source /root/openstack_env.conf 2>/dev/null || true
        if [ "$NON_INTERACTIVE" -ne 1 ]; then
            log_info "已加载 /root/openstack_env.conf"
        fi
    fi
    # 统一默认值
    CTRL_HOSTNAME="${CTRL_HOSTNAME:-controller-63}"
    CONTROLLER_IP="${CONTROLLER_IP:-192.168.63.10}"
    COMPUTE_IP="${COMPUTE_IP:-}"
    COMPUTE_USER="${COMPUTE_USER:-root}"
    MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-}"
    ADMIN_PASS="${ADMIN_PASS:-123456}"
    # 服务通用密码 (默认与 admin 密码相同)
    SERVICE_PASS="${SERVICE_PASS:-${ADMIN_PASS}}"
    RABBIT_PASS="${RABBIT_PASS:-${SERVICE_PASS}}"
    # 内部网络变量
    INT_IP="${INT_IP:-}"
    INT_IFACE="${INT_IFACE:-}"
    COMPUTE_INT_IFACE="${COMPUTE_INT_IFACE:-}"
    # 离线模式
    OFFLINE_REPO_PATH="${OFFLINE_REPO_PATH:-}"
}

load_env() {
    load_env_common
}

# ==================== 管理员凭证加载 ====================
load_admin_rc() {
    if [ -f /root/admin-openrc ]; then
        # shellcheck source=/dev/null
        source /root/admin-openrc 2>/dev/null || true
        return 0
    else
        log_error "/root/admin-openrc 不存在，请先安装 Keystone"
        return 1
    fi
}

# ==================== 交互式密码读取 ====================
# 非交互模式下直接使用默认值，交互模式下提示输入
read_password() {
    local prompt="$1"
    local default="${2:-}"
    local var_ref="$3"

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        printf -v "$var_ref" "%s" "$default"
        return
    fi

    read -r -s -p "${prompt} [默认: ${default}]: " input
    echo ""
    printf -v "$var_ref" "%s" "${input:-$default}"
}

read_input() {
    local prompt="$1"
    local default="${2:-}"
    local var_ref="$3"

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        printf -v "$var_ref" "%s" "$default"
        return
    fi

    read -r -p "${prompt} [${default}]: " input
    printf -v "$var_ref" "%s" "${input:-$default}"
}

# ==================== 网络检测 ====================
get_active_ifaces() {
    ip -o link show up 2>/dev/null \
        | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs' \
        | awk -F': ' '{print $2}' \
        | tr -d '@'
}

get_iface_ip() {
    ip -4 -o addr show "$1" 2>/dev/null | awk '{print $4}' | head -1
}

get_iface_ip_only() {
    echo "${1:-}" | cut -d'/' -f1
}

get_iface_prefix() {
    echo "${1:-}" | cut -d'/' -f2
}

get_default_gateway() {
    ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1
}

get_iface_gateway() {
    nmcli -t -f IP4.GATEWAY device show "$1" 2>/dev/null | cut -d':' -f2 | head -1
}

detect_local_ip() {
    local def_iface
    def_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
    local ip
    ip=$(ip -4 -o addr show "${def_iface:-ens33}" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1)
    echo "${ip:-127.0.0.1}"
}

detect_int_ip() {
    local def_iface
    def_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
    for iface in $(ip -o link show up 2>/dev/null | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs' | awk -F': ' '{print $2}' | tr -d '@'); do
        if [ "$iface" != "${def_iface:-}" ]; then
            ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1
            return
        fi
    done
    echo ""
}

detect_int_iface() {
    local def_iface
    def_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
    for iface in $(ip -o link show up 2>/dev/null | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs' | awk -F': ' '{print $2}' | tr -d '@'); do
        [ "$iface" != "${def_iface:-}" ] && { echo "$iface"; return; }
    done
    echo "ens34"
}

# ==================== SSH 免密 ====================
setup_ssh() {
    local target_ip="${1:-$COMPUTE_IP}"
    local target_user="${2:-$COMPUTE_USER}"

    [ ! -f /root/.ssh/id_rsa ] && {
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        ssh-keygen -t rsa -b 2048 -N "" -f /root/.ssh/id_rsa -q
        log_info "SSH 密钥已生成"
    }

    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${target_user}@${target_ip}" "hostname" &>/dev/null 2>&1; then
        return
    fi

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        log_error "非交互模式下无法配置 SSH 免密，请先手动执行 ssh-copy-id"
        exit 1
    fi

    echo ">>> 请输入 ${target_user}@${target_ip} 的密码:"
    ssh-copy-id -o StrictHostKeyChecking=no "${target_user}@${target_ip}" || { log_error "ssh-copy-id 失败"; exit 1; }
}

# ==================== 确认函数 (非交互模式自动跳过) ====================
confirm() {
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        return 0
    fi
    local cf
    read -r -p "$1 [y/N]: " cf
    [[ "$cf" =~ ^[Yy]$ ]]
}

# ==================== 离线模式判断 ====================
is_offline() {
    [ -n "${OFFLINE_REPO_PATH:-}" ]
}

# ==================== 验证检查函数 ====================
check() {
    printf "  %-52s " "$1"
    if eval "$2" &>/dev/null 2>&1; then
        echo -e "$PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "$FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
    return 0
}

check_w() {
    printf "  %-52s " "$1"
    if eval "$2" &>/dev/null 2>&1; then
        echo -e "$PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "$WARN"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
    return 0
}

section() {
    echo ""
    echo -e "${BLUE}---- $* ----${NC}"
}

# ==================== 验证计数器 ====================
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

reset_counts() {
    PASS_COUNT=0
    FAIL_COUNT=0
    WARN_COUNT=0
}

print_summary() {
    local total=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    验证结果汇总                              ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  ${GREEN}通过: ${PASS_COUNT}${NC}  ${RED}失败: ${FAIL_COUNT}${NC}  ${YELLOW}警告: ${WARN_COUNT}${NC}  共计: ${total}                                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo -e "\n${RED}存在 ${FAIL_COUNT} 项检查未通过。${NC}"
        return 1
    else
        echo -e "\n${GREEN}所有检查项已通过！${NC}"
        return 0
    fi
}

# ==================== 离线仓库自动配置 ====================
# 此代码块在 source 时自动执行，检测 env.conf 中的 OFFLINE_REPO_PATH
# 若已配置则自动设置离线 yum 源并禁用外部仓库
_offline_path=""
if [ -f /root/openstack_env.conf ]; then
    _offline_path=$(grep -oP '^OFFLINE_REPO_PATH=\K.*' /root/openstack_env.conf 2>/dev/null | tr -d "'\" " || true)
fi
if [ -n "${_offline_path:-}" ]; then
    OFFLINE_REPO_PATH="$_offline_path"

    # 如果是 ISO 文件，自动挂载
    if [ -f "$OFFLINE_REPO_PATH" ] && [[ "$OFFLINE_REPO_PATH" =~ \.[iI][sS][oO]$ ]]; then
        _mount_point="/root/openstack-offline"
        if mountpoint -q "$_mount_point" 2>/dev/null; then
            log_info "ISO 已挂载: ${_mount_point}"
        else
            mkdir -p "$_mount_point"
            mount -o loop "$OFFLINE_REPO_PATH" "$_mount_point" 2>/dev/null && \
                log_info "ISO 已自动挂载: ${OFFLINE_REPO_PATH} → ${_mount_point}" || \
                log_warn "ISO 挂载失败: ${OFFLINE_REPO_PATH}"
        fi
        _pkg_dir="${_mount_point}/packages"
    else
        # 自动探测 packages 子目录
        _pkg_dir="${OFFLINE_REPO_PATH}/packages"
        if [ ! -d "$_pkg_dir" ]; then
            [ -d "$OFFLINE_REPO_PATH" ] && ls "$OFFLINE_REPO_PATH"/*.rpm &>/dev/null 2>&1 && _pkg_dir="$OFFLINE_REPO_PATH"
        fi
    fi

    if [ -d "$_pkg_dir" ]; then
        # 备份原有仓库文件 (仅首次离线部署时执行，无论 repo 是否已存在)
        if [ ! -d /etc/yum.repos.d.backup ] && ls /etc/yum.repos.d/*.repo &>/dev/null 2>&1; then
            mkdir -p /etc/yum.repos.d.backup
            cp -a /etc/yum.repos.d/*.repo /etc/yum.repos.d.backup/ 2>/dev/null || true
            log_info "原有仓库已备份至 /etc/yum.repos.d.backup/"
        fi

        if [ ! -f /etc/yum.repos.d/openstack-offline.repo ]; then
        log_info "检测到离线模式，配置本地仓库: ${_pkg_dir}"

        # 禁用全部外部仓库
        for repo in $(dnf repolist --enabled 2>/dev/null | awk 'NR>1 {print $1}' | grep -v '^$'); do
            dnf config-manager --set-disabled "$repo" 2>/dev/null || true
        done

        cat > /etc/yum.repos.d/openstack-offline.repo << OFFLINEREPO
[openstack-offline]
name=OpenStack Dalmatian Offline Repository
baseurl=file://${_pkg_dir}
enabled=1
gpgcheck=0
priority=1
module_hotfixes=1
OFFLINEREPO

        dnf clean all 2>/dev/null || true
        dnf makecache 2>/dev/null || true
        log_info "离线仓库已就绪 (dnf repolist: $(dnf repolist --enabled 2>/dev/null | grep openstack || echo 'OK'))"
    fi
fi
fi
unset _offline_path _pkg_dir

# ==================== 恢复网络源 ====================
restore_network_repos() {
    log_step "恢复网络仓库"

    if [ ! -f /root/openstack_env.conf ]; then
        log_info "未检测到 env.conf，跳过"
        return 0
    fi
    local _off_path
    _off_path=$(grep -oP '^OFFLINE_REPO_PATH=\K.*' /root/openstack_env.conf 2>/dev/null | tr -d "'\" " || true)
    if [ -z "${_off_path:-}" ]; then
        log_info "非离线模式部署，无需恢复"
        return 0
    fi

    # 1. 删除离线仓库
    if [ -f /etc/yum.repos.d/openstack-offline.repo ]; then
        rm -f /etc/yum.repos.d/openstack-offline.repo
        log_info "已移除离线仓库配置"
    fi

    # 2. 从备份恢复原始仓库
    if [ -d /etc/yum.repos.d.backup ]; then
        cp -af /etc/yum.repos.d.backup/*.repo /etc/yum.repos.d/ 2>/dev/null || true
        log_info "已从 /etc/yum.repos.d.backup/ 恢复原始仓库"
    else
        log_warn "未找到备份目录 /etc/yum.repos.d.backup/，跳过"
    fi

    # 3. 卸载离线 ISO
    if mountpoint -q /root/openstack-offline 2>/dev/null; then
        umount /root/openstack-offline 2>/dev/null || true
        log_info "已卸载离线 ISO"
    fi

    # 4. 刷新缓存
    dnf clean all 2>/dev/null || true
    dnf makecache 2>/dev/null || true
    log_info "网络仓库已恢复"
}

# ==================== 导出变量 ====================
export CTRL_HOSTNAME CONTROLLER_IP COMPUTE_IP COMPUTE_USER
export MYSQL_ROOT_PASS ADMIN_PASS SERVICE_PASS RABBIT_PASS
export NON_INTERACTIVE OFFLINE_REPO_PATH
