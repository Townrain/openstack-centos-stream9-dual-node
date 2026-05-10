#!/bin/bash
###############################################################################
# OpenStack Dalmatian (CentOS Stream 9) 基础环境准备脚本
# 运行位置: 控制节点 (controller-63)
# 执行方式: bash openstack_base_env.sh
# 功能:     配置控制节点 → SSH 远程配置计算节点
# SSH:      自动生成密钥 + ssh-copy-id 免密一次，后续全部免密
# 网络:     控制节点网卡/网关自动检测；计算节点 SSH 远程自动检测
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"

# ==================== 运行模式判断 ====================
REMOTE_MODE=0
if [ $# -ge 7 ]; then
    REMOTE_MODE=1
fi

if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 账户运行本脚本"
    exit 1
fi

# ==================== 通用工具函数 ====================

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

# 通过 SSH 远程获取计算节点活动网卡
get_remote_ifaces() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "${COMPUTE_USER}@${COMPUTE_IP}" \
        "ip -o link show up 2>/dev/null | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs' | awk -F': ' '{print \$2}' | tr -d '@'" 2>/dev/null
}

get_remote_iface_ip() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "${COMPUTE_USER}@${COMPUTE_IP}" \
        "ip -4 -o addr show $1 2>/dev/null | awk '{print \$4}' | head -1" 2>/dev/null
}

get_remote_iface_gw() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "${COMPUTE_USER}@${COMPUTE_IP}" \
        "nmcli -t -f IP4.GATEWAY device show $1 2>/dev/null | cut -d':' -f2" 2>/dev/null
}

# ==================== SSH 密钥设置 ====================
setup_ssh_keys() {
    log_step "配置 SSH 免密登录"

    local keyfile="/root/.ssh/id_rsa"

    # 1. 如果密钥不存在，生成
    if [ ! -f "$keyfile" ]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        log_info "生成 SSH 密钥对..."
        ssh-keygen -t rsa -b 2048 -N "" -f "$keyfile" -C "openstack-deploy" -q
        log_info "密钥已生成: ${keyfile}"
    else
        log_info "SSH 密钥已存在: ${keyfile}"
    fi

    # 2. 尝试免密连接（已配置过则跳过）
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" "hostname" &>/dev/null; then
        log_info "免密登录计算节点已就绪"
        return 0
    fi

    # 3. 使用 ssh-copy-id 复制公钥（仅需输入一次密码）
    echo ""
    echo ">>> 即将复制公钥到计算节点，请输入 ${COMPUTE_USER}@${COMPUTE_IP} 的密码:"
    if ssh-copy-id -o StrictHostKeyChecking=no "${COMPUTE_USER}@${COMPUTE_IP}" 2>/dev/null; then
        log_info "公钥已复制到计算节点"
    else
        log_error "ssh-copy-id 失败，请检查计算节点 IP、用户名和密码"
        exit 1
    fi

    # 4. 验证免密连接
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" "hostname" &>/dev/null; then
        log_info "免密登录验证成功"
    else
        log_error "免密登录验证失败"
        exit 1
    fi
}

# ==================== 通用: 检查虚拟化 ====================
check_virtualization() {
    log_step "检查 CPU 虚拟化支持"
    if grep -Eq "vmx|svm" /proc/cpuinfo; then
        local flag=$(grep -Eo "vmx|svm" /proc/cpuinfo | head -1)
        log_info "虚拟化已开启 (${flag})"
    else
        log_warn "未检测到虚拟化标志，请确保已开启 Intel VT-x 或 AMD-V"
        if [ "$REMOTE_MODE" -eq 0 ]; then
            read -r -p "是否继续? [y/N]: " confirm
            [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
        fi
    fi
}

# ==================== 通用: 设置主机名 ====================
set_hostname() {
    local hostname="$1"
    log_step "设置主机名"
    hostnamectl set-hostname "${hostname}"
    log_info "主机名已设置为: ${hostname}"
}

# ==================== 通用: 配置网络 ====================
backup_network_config() {
    local iface="$1"
    local src="/etc/NetworkManager/system-connections/${iface}.nmconnection"
    if [ -f "$src" ]; then
        cp "$src" "${src}.bak.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
        log_info "已备份 ${src}"
    fi
}

configure_network_interface() {
    local iface="$1" ip="$2" prefix="$3" gateway="$4"

    local file="/etc/NetworkManager/system-connections/${iface}.nmconnection"
    backup_network_config "$iface"

    local uuid_val
    if [ -f "$file" ]; then
        uuid_val=$(grep -oP 'uuid=\K.*' "$file" | head -1)
    fi
    uuid_val="${uuid_val:-$(uuidgen)}"

    local addr_suffix=""
    [ -n "$gateway" ] && addr_suffix=",${gateway}"

    cat > "$file" << NMEOF
[connection]
id=${iface}
uuid=${uuid_val}
type=ethernet
autoconnect-priority=-999
interface-name=${iface}

[ethernet]

[ipv4]
address1=${ip}/${prefix}${addr_suffix}
dns=8.8.8.8;
method=manual

[ipv6]
addr-gen-mode=eui64
method=auto

[proxy]
NMEOF
    chmod 600 "$file"
    log_info "网卡 ${iface} 配置已写入"

    nmcli connection reload
    nmcli connection down "${iface}" 2>/dev/null || true
    nmcli connection up "${iface}"

    log_info "${iface} IP: $(ip -4 -o addr show "${iface}" 2>/dev/null | awk '{print $4}' || echo '获取失败')"

    if [ -n "$gateway" ] && ping -c 2 -W 2 "${gateway}" &>/dev/null 2>&1; then
        log_info "网关 ${gateway} 连通正常"
    elif [ -n "$gateway" ]; then
        log_warn "无法 ping 通网关 ${gateway}"
    fi
}

# ==================== 通用: 关闭防火墙和 SELinux ====================
disable_firewall_selinux() {
    log_step "关闭防火墙和 SELinux"

    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    log_info "firewalld 已停止并禁用"

    local cfg="/etc/selinux/config"
    [ -f "$cfg" ] && cp -n "$cfg" "${cfg}.bak" 2>/dev/null || true
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' "$cfg"
    sed -i 's/^SELINUX=permissive/SELINUX=disabled/' "$cfg"
    setenforce 0 2>/dev/null || true
    log_info "SELinux 已设置为 disabled (当前: $(getenforce 2>/dev/null || echo 'unknown'))"
}

# ==================== 通用: 配置 hosts ====================
configure_hosts() {
    local controller_ip="$1"
    local compute_ip="$2"

    log_step "配置 /etc/hosts"

    local hosts_file="/etc/hosts"
    cp -n "$hosts_file" "${hosts_file}.bak" 2>/dev/null || true

    sed -i "/${CTRL_HOSTNAME}/d" "$hosts_file"
    sed -i "/${COMPUTE_HOSTNAME}/d" "$hosts_file"

    cat >> "$hosts_file" << EOF
${controller_ip}    ${CTRL_HOSTNAME}
${compute_ip}       ${COMPUTE_HOSTNAME}
EOF
    log_info "已写入:"
    grep -E "${CTRL_HOSTNAME}|${COMPUTE_HOSTNAME}" "$hosts_file"
}

# ==================== 通用: 配置仓库并安装软件 ====================
setup_repos_and_packages() {
    log_step "配置 OpenStack Dalmatian 仓库并安装基础软件"

    if [ -n "${OFFLINE_REPO_PATH:-}" ]; then
        # ===== 离线模式 =====
        log_info "离线模式，跳过外部仓库配置"

        local pkg_dir="${OFFLINE_REPO_PATH}/packages"
        [ -d "$pkg_dir" ] || { [ -d "$OFFLINE_REPO_PATH" ] && ls "$OFFLINE_REPO_PATH"/*.rpm &>/dev/null 2>&1 && pkg_dir="$OFFLINE_REPO_PATH"; }

        # 用户输入的是 ISO 文件路径，自动挂载
        if [ ! -d "$pkg_dir" ] && [ -f "$OFFLINE_REPO_PATH" ] && [[ "$OFFLINE_REPO_PATH" =~ \.[iI][sS][oO]$ ]]; then
            local mount_pt="/root/openstack-offline"
            if ! mountpoint -q "$mount_pt" 2>/dev/null; then
                mkdir -p "$mount_pt"
                log_info "检测到 ISO: ${OFFLINE_REPO_PATH}，挂载到 ${mount_pt}..."
                mount -o loop "$OFFLINE_REPO_PATH" "$mount_pt" 2>/dev/null || {
                    log_error "挂载失败: mount -o loop ${OFFLINE_REPO_PATH} ${mount_pt}"
                    exit 1
                }
                log_info "ISO 已挂载"
            fi
            pkg_dir="${mount_pt}/packages"
        fi

        # 路径仍不存在，搜索 /root 下的 ISO 自动挂载
        if [ ! -d "$pkg_dir" ]; then
            local iso_found=""
            for candidate in /root/openstack-dalmatian-offline.iso /root/openstack-offline.iso \
                             /root/*.iso /tmp/openstack-dalmatian-offline.iso; do
                [ -f "$candidate" ] && { iso_found="$candidate"; break; }
            done
            if [ -n "$iso_found" ]; then
                local mount_pt="/root/openstack-offline"
                if ! mountpoint -q "$mount_pt" 2>/dev/null; then
                    mkdir -p "$mount_pt"
                    log_info "发现 ISO: ${iso_found}，挂载到 ${mount_pt}..."
                    mount -o loop "$iso_found" "$mount_pt" 2>/dev/null || {
                        log_error "挂载失败"
                        exit 1
                    }
                    log_info "ISO 已自动挂载"
                fi
                pkg_dir="${mount_pt}/packages"
            fi
        fi

        if [ ! -d "$pkg_dir" ]; then
            echo ""
            log_error "离线仓库路径不存在: ${pkg_dir}"
            echo ""
            echo "  请先执行以下操作之一:"
            echo ""
            echo "  1) 构建离线 ISO:  bash build-openstack-offline-iso.sh"
            echo "  2) 挂载已有 ISO:  mount /root/openstack-dalmatian-offline.iso ${OFFLINE_REPO_PATH}"
            echo "  3) 或重新运行并选择 [1] 在线部署模式"
            echo ""
            exit 1
        fi

        if [ ! -f /etc/yum.repos.d/openstack-offline.repo ]; then
            dnf config-manager --set-disabled '*' 2>/dev/null || true
            cat > /etc/yum.repos.d/openstack-offline.repo << OFFLINEREPO
[openstack-offline]
name=OpenStack Dalmatian Offline Repository
baseurl=file://${pkg_dir}
enabled=1
gpgcheck=0
priority=1
module_hotfixes=1
OFFLINEREPO
            log_info "离线仓库已配置: ${pkg_dir}"
        else
            log_info "离线仓库已存在"
        fi
    else
        # ===== 在线模式 =====
        log_info "安装 dnf-plugins-core..."
        dnf install -y dnf-plugins-core

        log_info "启用 crb 仓库..."
        dnf config-manager --set-enabled crb

        log_info "安装 centos-release-openstack-dalmatian..."
        dnf install -y centos-release-openstack-dalmatian
    fi

    log_info "更新 DNF 缓存..."
    dnf makecache

    if [ -n "${OFFLINE_REPO_PATH:-}" ]; then
        log_info "离线模式: 跳过系统更新，直接安装基础软件包"
    else
        log_info "系统更新（可能耗时较长）..."
        dnf update -y
    fi

    log_info "安装基础软件包..."
    if [ -n "${OFFLINE_REPO_PATH:-}" ]; then
        dnf install -y vim openstack-selinux python3-openstackclient wget 2>/dev/null || {
            log_warn "尝试 --allowerasing..."
            dnf install -y --allowerasing vim openstack-selinux python3-openstackclient wget 2>/dev/null || {
                log_warn "尝试 --skip-broken --nobest..."
                dnf install -y --skip-broken --nobest vim openstack-selinux python3-openstackclient wget 2>/dev/null || {
                    log_warn "基础包安装不完整，部分功能可能受限"
                }
            }
        }
    else
        dnf install -y vim openstack-selinux python3-openstackclient wget
    fi
    log_info "基础软件安装完成"
}

# ==================== 保存环境变量配置 ====================
save_env_config() {
    cat > /root/openstack_env.conf << EOF
# OpenStack Dalmatian 环境变量配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 所有后续脚本在非交互模式下自动读取此文件，无需重复确认

# ========== 节点信息 ==========
CTRL_HOSTNAME="${CTRL_HOSTNAME}"
COMPUTE_HOSTNAME="${COMPUTE_HOSTNAME}"
CONTROLLER_IP="${CONTROLLER_IP}"
COMPUTE_IP="${COMPUTE_IP}"
COMPUTE_USER="${COMPUTE_USER:-root}"

# ========== 网络 ==========
INT_IP="${CTRL_INT_IP:-}"
INT_IFACE="${CTRL_INT_IFACE:-}"
COMPUTE_INT_IFACE="${COMPUTE_INT_IFACE:-}"
COMPUTE_MGMT_IFACE="${COMPUTE_MGMT_IFACE:-}"
COMPUTE_INT_IP="${COMPUTE_INT_IP:-}"
COMPUTE_MGMT_IP="${COMPUTE_MGMT_IP:-}"

# ========== 基础密码 ==========
MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS}"
ADMIN_PASS="${ADMIN_PASS}"

# ========== 统一服务密码 ==========
SERVICE_PASS="${SERVICE_PASS}"
RABBIT_PASS="${RABBIT_PASS}"

# ========== 各服务密码 ==========
KEYSTONE_DBPASS="${KEYSTONE_DBPASS}"
GLANCE_DBPASS="${GLANCE_DBPASS}"
GLANCE_PASS="${GLANCE_PASS}"
PLACEMENT_DBPASS="${PLACEMENT_DBPASS}"
PLACEMENT_PASS="${PLACEMENT_PASS}"
NOVA_PASS="${NOVA_PASS}"
NEUTRON_PASS="${NEUTRON_PASS}"
CINDER_PASS="${CINDER_PASS}"
SWIFT_PASS="${SWIFT_PASS}"

# ========== 其他 ==========
METADATA_SECRET="${METADATA_SECRET}"
CINDER_LOOP_GB="${CINDER_LOOP_GB}"
CINDER_DISK_DEV="${CINDER_DISK_DEV}"
CINDER_MODE="${CINDER_MODE}"
SWIFT_LOOP_GB="${SWIFT_LOOP_GB}"
SWIFT_DISK_DEV="${SWIFT_DISK_DEV}"
SWIFT_MODE="${SWIFT_MODE}"
OFFLINE_REPO_PATH="${OFFLINE_REPO_PATH:-}"
EOF
    log_info "配置已保存至 /root/openstack_env.conf"
}

# ==================== SSH 远程配置计算节点 ====================
remote_setup_compute() {
    log_step "远程配置计算节点"

    local script_path
    script_path="$(readlink -f "$0")"

    log_info "复制脚本到计算节点..."
    scp -o StrictHostKeyChecking=no \
        "${script_path}" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_base_env.sh"
    scp -o StrictHostKeyChecking=no \
        "${SCRIPT_DIR}/openstack_common.sh" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_common.sh"
    scp -o StrictHostKeyChecking=no \
        /root/openstack_env.conf "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_env.conf" 2>/dev/null || true

    # 离线模式: 先复制 ISO 到计算节点
    if [ -n "${OFFLINE_REPO_PATH:-}" ] && [ -f "${OFFLINE_REPO_PATH}" ]; then
        log_info "复制离线 ISO 到计算节点..."
        scp -o StrictHostKeyChecking=no \
            "${OFFLINE_REPO_PATH}" "${COMPUTE_USER}@${COMPUTE_IP}:${OFFLINE_REPO_PATH}"
        log_info "ISO 已复制到计算节点"
    fi

    log_info "远程执行计算节点配置..."
    ssh -o StrictHostKeyChecking=no \
        "${COMPUTE_USER}@${COMPUTE_IP}" \
        "export OFFLINE_REPO_PATH='${OFFLINE_REPO_PATH:-}'; bash /root/openstack_base_env.sh \
            --remote \
            '${COMPUTE_HOSTNAME}' \
            '${COMPUTE_MGMT_IFACE}' \
            '${COMPUTE_MGMT_IP}' \
            '${COMPUTE_MGMT_PREFIX}' \
            '${COMPUTE_MGMT_GW}' \
            '${COMPUTE_INT_IFACE}' \
            '${COMPUTE_INT_IP}' \
            '${COMPUTE_INT_PREFIX}' \
            '${COMPUTE_INT_GW}' \
            '${CONTROLLER_IP}' \
            '${COMPUTE_IP}' \
            '${MYSQL_ROOT_PASS}' \
            '${ADMIN_PASS}' \
            '${CTRL_HOSTNAME}'"

    log_info "计算节点基础环境配置完成"
}

# ==================== 远程自动模式（计算节点专用） ====================
remote_mode_execute() {
    local hostname="$1"
    local mgmt_iface="$2"   mgmt_ip="$3"   mgmt_prefix="$4"   mgmt_gw="$5"
    local int_iface="$6"    int_ip="$7"    int_prefix="$8"    int_gw="$9"
    local controller_ip="${10}"  compute_ip="${11}"
    local mysql_pass="${12}" admin_pass="${13}"
    local ctrl_hostname="${14}"

    log_info "远程自动模式 — 计算节点配置"

    CTRL_HOSTNAME="$ctrl_hostname"
    COMPUTE_HOSTNAME="$hostname"

    check_virtualization
    set_hostname "${hostname}"
    configure_network_interface "${mgmt_iface}" "${mgmt_ip}" "${mgmt_prefix}" "${mgmt_gw}"
    configure_network_interface "${int_iface}"  "${int_ip}"  "${int_prefix}"  "${int_gw}"
    disable_firewall_selinux
    configure_hosts "${controller_ip}" "${compute_ip}"
    setup_repos_and_packages

    # 离线模式: 更新系统包 (计算节点无需 SSH 外出，安全)
    if [ -n "${OFFLINE_REPO_PATH:-}" ]; then
        log_info "离线模式: 更新计算节点系统包..."
        dnf update -y --allowerasing 2>/dev/null || {
            dnf update -y --skip-broken --nobest 2>/dev/null || true
        }
        log_info "计算节点系统更新完成"
    fi

    CONTROLLER_IP="$controller_ip"
    COMPUTE_IP="$compute_ip"
    COMPUTE_USER="root"
    MYSQL_ROOT_PASS="$mysql_pass"
    ADMIN_PASS="$admin_pass"
    SERVICE_PASS="${ADMIN_PASS}"
    RABBIT_PASS="${ADMIN_PASS}"
    KEYSTONE_DBPASS="${ADMIN_PASS}"
    GLANCE_DBPASS="${ADMIN_PASS}"
    GLANCE_PASS="${ADMIN_PASS}"
    PLACEMENT_DBPASS="${ADMIN_PASS}"
    PLACEMENT_PASS="${ADMIN_PASS}"
    NOVA_PASS="${ADMIN_PASS}"
    NEUTRON_PASS="${ADMIN_PASS}"
    CINDER_PASS="${ADMIN_PASS}"
    SWIFT_PASS="${ADMIN_PASS}"
    METADATA_SECRET=""
    CINDER_LOOP_GB="5"
    CINDER_DISK_DEV=""
    CINDER_MODE="1"
    SWIFT_LOOP_GB="5"
    SWIFT_DISK_DEV=""
    SWIFT_MODE="1"
    COMPUTE_INT_IP="${int_ip}"
    COMPUTE_MGMT_IP="${mgmt_ip}"
    INT_IP="${int_ip}"
    INT_IFACE="${int_iface}"
    save_env_config

    log_info "计算节点配置完成，请重启: reboot"
}

# ==================== 自动检测控制节点本机网络 ====================
auto_detect_local_network() {
    echo ""
    log_step "正在检测本机网络接口..."

    local ifaces
    ifaces=($(get_active_ifaces))

    if [ ${#ifaces[@]} -eq 0 ]; then
        log_warn "未检测到活动物理网卡，请手动输入"
        return 1
    fi

    echo ""
    echo "检测到 ${#ifaces[@]} 个活动网卡:"
    for i in "${!ifaces[@]}"; do
        local iface="${ifaces[$i]}"
        local ip_info=$(get_iface_ip "$iface")
        local ip_only=$(get_iface_ip_only "$ip_info")
        local prefix=$(get_iface_prefix "$ip_info")
        local gw=$(get_iface_gateway "$iface")
        [ -z "$ip_only" ] && ip_only="未配置"
        [ -z "$prefix" ]  && prefix="-"
        [ -z "$gw" ]       && gw="未检测到"
        echo "  [$((i+1))] ${iface}   IP: ${ip_only}/${prefix}   网关: ${gw}"
    done

    echo ""
    echo "网卡角色说明:"
    echo "  管理网卡(NAT)      — 对外通信，通常有默认网关"
    echo "  内部网卡(Host-only) — OpenStack 内部通信"
    echo ""

    # 管理网卡 — 默认取有默认路由的
    local default_iface=""
    local default_gw=$(get_default_gateway)
    if [ -n "$default_gw" ]; then
        default_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
    fi
    [ -z "$default_iface" ] && default_iface="${ifaces[0]}"

    while true; do
        read -r -p "管理网卡 (NAT) [$default_iface]: " mgmt_iface
        mgmt_iface="${mgmt_iface:-$default_iface}"
        if ip link show "$mgmt_iface" &>/dev/null; then break; else log_warn "网卡 $mgmt_iface 不存在"; fi
    done

    local mgmt_ip_info=$(get_iface_ip "$mgmt_iface")
    local mgmt_ip=$(get_iface_ip_only "$mgmt_ip_info")
    local mgmt_prefix=$(get_iface_prefix "$mgmt_ip_info")
    local mgmt_gw=$(get_iface_gateway "$mgmt_iface")

    read -r -p "管理IP [${mgmt_ip}]: " input
    mgmt_ip="${input:-$mgmt_ip}"
    read -r -p "管理子网前缀 [${mgmt_prefix:-24}]: " input
    mgmt_prefix="${input:-${mgmt_prefix:-24}}"
    read -r -p "管理网关 [${mgmt_gw:-无}]: " input
    mgmt_gw="${input:-$mgmt_gw}"

    # 内部网卡 — 默认取另一个
    local int_default=""
    for iface in "${ifaces[@]}"; do
        if [ "$iface" != "$mgmt_iface" ]; then
            int_default="$iface"
            break
        fi
    done
    [ -z "$int_default" ] && int_default="${ifaces[0]}"

    echo ""
    while true; do
        read -r -p "内部网卡 (Host-only) [$int_default]: " int_iface
        int_iface="${int_iface:-$int_default}"
        if [ "$int_iface" = "$mgmt_iface" ]; then
            log_warn "内部网卡不能与管理网卡相同"
        elif ip link show "$int_iface" &>/dev/null; then
            break
        else
            log_warn "网卡 $int_iface 不存在"
        fi
    done

    local int_ip_info=$(get_iface_ip "$int_iface")
    local int_ip=$(get_iface_ip_only "$int_ip_info")
    local int_prefix=$(get_iface_prefix "$int_ip_info")
    local int_gw=$(get_iface_gateway "$int_iface")

    read -r -p "内部IP [${int_ip:-未配置}]: " input
    int_ip="${input:-$int_ip}"
    read -r -p "内部子网前缀 [${int_prefix:-24}]: " input
    int_prefix="${input:-${int_prefix:-24}}"
    read -r -p "内部网关 [${int_gw:-无}]: " input
    int_gw="${input:-$int_gw}"

    CTRL_MGMT_IFACE="$mgmt_iface"
    CTRL_MGMT_IP="$mgmt_ip"
    CTRL_MGMT_PREFIX="$mgmt_prefix"
    CTRL_MGMT_GW="$mgmt_gw"
    CTRL_INT_IFACE="$int_iface"
    CTRL_INT_IP="$int_ip"
    CTRL_INT_PREFIX="$int_prefix"
    CTRL_INT_GW="$int_gw"
}

# ==================== 自动检测计算节点远程网络 ====================
auto_detect_remote_network() {
    echo ""
    log_step "正在通过 SSH 检测计算节点网络接口..."

    local ifaces
    ifaces=($(get_remote_ifaces))

    if [ ${#ifaces[@]} -eq 0 ]; then
        log_warn "未检测到计算节点活动网卡"
        return 1
    fi

    echo ""
    echo "计算节点检测到 ${#ifaces[@]} 个活动网卡:"
    for i in "${!ifaces[@]}"; do
        local iface="${ifaces[$i]}"
        local ip_info=$(get_remote_iface_ip "$iface")
        local ip_only=$(get_iface_ip_only "$ip_info")
        local prefix=$(get_iface_prefix "$ip_info")
        local gw=$(get_remote_iface_gw "$iface")
        [ -z "$ip_only" ] && ip_only="未配置"
        [ -z "$prefix" ]  && prefix="-"
        [ -z "$gw" ]       && gw="未检测到"
        echo "  [$((i+1))] ${iface}   IP: ${ip_only}/${prefix}   网关: ${gw}"
    done

    # 管理网卡 — 取有默认网关的
    local remote_default_gw
    remote_default_gw=$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
        "${COMPUTE_USER}@${COMPUTE_IP}" \
        "ip -4 route show default 2>/dev/null | awk '{print \$3}' | head -1" 2>/dev/null || echo "")
    local remote_default_iface
    if [ -n "$remote_default_gw" ]; then
        remote_default_iface=$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
            "${COMPUTE_USER}@${COMPUTE_IP}" \
            "ip -4 route show default 2>/dev/null | awk '{print \$5}' | head -1" 2>/dev/null || echo "")
    fi
    [ -z "$remote_default_iface" ] && remote_default_iface="${ifaces[0]}"

    echo ""
    echo "网卡角色说明:"
    echo "  管理网卡(NAT)      — 对外通信"
    echo "  内部网卡(Host-only) — OpenStack 内部通信"
    echo ""

    while true; do
        read -r -p "计算节点管理网卡 [$remote_default_iface]: " input
        COMPUTE_MGMT_IFACE="${input:-$remote_default_iface}"
        if get_remote_iface_ip "$COMPUTE_MGMT_IFACE" &>/dev/null || \
           ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" \
               "ip link show ${COMPUTE_MGMT_IFACE} &>/dev/null" 2>/dev/null; then
            break
        else
            log_warn "网卡 $COMPUTE_MGMT_IFACE 在计算节点不存在"
        fi
    done

    # 管理IP: 优先取检测到的IP，否则用 COMPUTE_IP
    local remote_mgmt_ip_info remote_mgmt_ip remote_mgmt_prefix remote_mgmt_gw
    remote_mgmt_ip_info=$(get_remote_iface_ip "$COMPUTE_MGMT_IFACE")
    remote_mgmt_ip=$(get_iface_ip_only "$remote_mgmt_ip_info")
    remote_mgmt_prefix=$(get_iface_prefix "$remote_mgmt_ip_info")
    remote_mgmt_gw=$(get_remote_iface_gw "$COMPUTE_MGMT_IFACE")

    read -r -p "管理IP [${remote_mgmt_ip:-${COMPUTE_IP}}]: " input
    COMPUTE_MGMT_IP="${input:-${remote_mgmt_ip:-${COMPUTE_IP}}}"
    read -r -p "管理子网前缀 [${remote_mgmt_prefix:-24}]: " input
    COMPUTE_MGMT_PREFIX="${input:-${remote_mgmt_prefix:-24}}"
    read -r -p "管理网关 [${remote_mgmt_gw:-${CTRL_MGMT_GW}}]: " input
    COMPUTE_MGMT_GW="${input:-${remote_mgmt_gw:-${CTRL_MGMT_GW}}}"

    # 内部网卡 — 默认取除去管理网卡之后的另一个
    local remote_int_default=""
    for iface in "${ifaces[@]}"; do
        if [ "$iface" != "$COMPUTE_MGMT_IFACE" ]; then
            remote_int_default="$iface"
            break
        fi
    done
    [ -z "$remote_int_default" ] && remote_int_default="${ifaces[0]}"

    echo ""
    while true; do
        read -r -p "计算节点内部网卡 [$remote_int_default]: " input
        COMPUTE_INT_IFACE="${input:-$remote_int_default}"
        if [ "$COMPUTE_INT_IFACE" = "$COMPUTE_MGMT_IFACE" ]; then
            log_warn "内部网卡不能与管理网卡相同"
        elif ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" \
               "ip link show ${COMPUTE_INT_IFACE} &>/dev/null" 2>/dev/null; then
            break
        else
            log_warn "网卡 $COMPUTE_INT_IFACE 在计算节点不存在"
        fi
    done

    local remote_int_ip_info remote_int_ip remote_int_prefix remote_int_gw
    remote_int_ip_info=$(get_remote_iface_ip "$COMPUTE_INT_IFACE")
    remote_int_ip=$(get_iface_ip_only "$remote_int_ip_info")
    remote_int_prefix=$(get_iface_prefix "$remote_int_ip_info")
    remote_int_gw=$(get_remote_iface_gw "$COMPUTE_INT_IFACE")

    read -r -p "内部IP [${remote_int_ip:-未配置}]: " input
    COMPUTE_INT_IP="${input:-${remote_int_ip}}"
    read -r -p "内部子网前缀 [${remote_int_prefix:-24}]: " input
    COMPUTE_INT_PREFIX="${input:-${remote_int_prefix:-24}}"
    read -r -p "内部网关 [${remote_int_gw:-${CTRL_INT_GW}}]: " input
    COMPUTE_INT_GW="${input:-${remote_int_gw:-${CTRL_INT_GW}}}"

    log_info "计算节点网络检测完成"
}

# ==================== ====================
#       交互主模式
# ==================== ====================
interactive_main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   OpenStack Dalmatian (CentOS Stream 9) 基础环境准备        ║"
    echo "║   运行位置: 控制节点 → SSH 远程配置计算节点                 ║"
    echo "║   网卡/网关自动检测，按回车确认即可                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    check_virtualization

    # ========== 0. 主机名配置 ==========
    echo ""
    echo "========== 主机名配置 =========="
    read -r -p "控制节点主机名 [controller-63]: " CTRL_HOSTNAME
    CTRL_HOSTNAME="${CTRL_HOSTNAME:-controller-63}"
    read -r -p "计算节点主机名 [compute-63]: " COMPUTE_HOSTNAME
    COMPUTE_HOSTNAME="${COMPUTE_HOSTNAME:-compute-63}"

    # ========== 1. 控制节点网络自动检测 ==========
    auto_detect_local_network
    CONTROLLER_IP="${CTRL_MGMT_IP}"

    # ========== 2. 计算节点基本信息和 SSH 配置 ==========
    echo ""
    echo "========== 计算节点 (${COMPUTE_HOSTNAME}) 信息 =========="
    read -r -p "计算节点管理IP: " COMPUTE_IP
    read -r -p "SSH 用户名 [root]: " COMPUTE_USER
    COMPUTE_USER="${COMPUTE_USER:-root}"

    # 先建立免密登录
    setup_ssh_keys

    # ========== 3. 远程检测计算节点网络 ==========
    auto_detect_remote_network

    # ========== 4. 密码与存储配置（一次收集，后续脚本无需重复确认）==========
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  全局配置（一次性收集，后续模块自动读取）                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # ---------- 密码配置 ----------
    echo "===== 密码配置 ====="
    echo "  默认统一密码 (123456) 适用于 MySQL、Admin 及所有服务"
    read -r -p "  是否使用默认统一密码? [Y/n]: " USE_UNIFIED
    USE_UNIFIED="${USE_UNIFIED:-Y}"

    _DEFAULT_PASS="123456"

    if [[ "$USE_UNIFIED" =~ ^[Yy]$ ]]; then
        read -r -s -p "  统一密码 [默认=${_DEFAULT_PASS}]: " _PASS
        echo ""
        _PASS="${_PASS:-${_DEFAULT_PASS}}"
        MYSQL_ROOT_PASS="$_PASS"
        ADMIN_PASS="$_PASS"
        SERVICE_PASS="$_PASS"
        log_info "已使用统一密码: ${_PASS:0:2}****"
    else
        echo ""
        read -r -s -p "  MySQL root 密码 [默认=${_DEFAULT_PASS}]: " MYSQL_ROOT_PASS; echo ""
        MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-${_DEFAULT_PASS}}"
        read -r -s -p "  Admin 密码 (Keystone/Dashboard) [默认=${_DEFAULT_PASS}]: " ADMIN_PASS; echo ""
        ADMIN_PASS="${ADMIN_PASS:-${_DEFAULT_PASS}}"
        read -r -s -p "  服务统一密码 (RPC/数据库等) [默认=${_DEFAULT_PASS}]: " SERVICE_PASS; echo ""
        SERVICE_PASS="${SERVICE_PASS:-${_DEFAULT_PASS}}"
        echo ""
        echo "  --- 各服务独立密码 (回车使用服务统一密码) ---"
        read -r -s -p "  Keystone DB  [回车=统一值]: " KEYSTONE_DBPASS; echo ""
        KEYSTONE_DBPASS="${KEYSTONE_DBPASS:-${SERVICE_PASS}}"
        read -r -s -p "  Glance       [回车=统一值]: " input; GLANCE_PASS="${input:-${SERVICE_PASS}}"; echo ""
        GLANCE_DBPASS="${GLANCE_PASS}"
        read -r -s -p "  Placement    [回车=统一值]: " input; PLACEMENT_PASS="${input:-${SERVICE_PASS}}"; echo ""
        PLACEMENT_DBPASS="${PLACEMENT_PASS}"
        read -r -s -p "  Nova         [回车=统一值]: " NOVA_PASS; echo ""
        NOVA_PASS="${NOVA_PASS:-${SERVICE_PASS}}"
        read -r -s -p "  Neutron      [回车=统一值]: " NEUTRON_PASS; echo ""
        NEUTRON_PASS="${NEUTRON_PASS:-${SERVICE_PASS}}"
        read -r -s -p "  Cinder       [回车=统一值]: " CINDER_PASS; echo ""
        CINDER_PASS="${CINDER_PASS:-${SERVICE_PASS}}"
        read -r -s -p "  Swift        [回车=统一值]: " SWIFT_PASS; echo ""
        SWIFT_PASS="${SWIFT_PASS:-${SERVICE_PASS}}"
    fi

    RABBIT_PASS="${SERVICE_PASS}"
    KEYSTONE_DBPASS="${KEYSTONE_DBPASS:-${SERVICE_PASS}}"
    GLANCE_PASS="${GLANCE_PASS:-${SERVICE_PASS}}"
    GLANCE_DBPASS="${GLANCE_DBPASS:-${GLANCE_PASS}}"
    PLACEMENT_PASS="${PLACEMENT_PASS:-${SERVICE_PASS}}"
    PLACEMENT_DBPASS="${PLACEMENT_DBPASS:-${PLACEMENT_PASS}}"
    NOVA_PASS="${NOVA_PASS:-${SERVICE_PASS}}"
    NEUTRON_PASS="${NEUTRON_PASS:-${SERVICE_PASS}}"
    CINDER_PASS="${CINDER_PASS:-${SERVICE_PASS}}"
    SWIFT_PASS="${SWIFT_PASS:-${SERVICE_PASS}}"

    # 生成随机 metadata 共享密钥
    METADATA_SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)
    read -r -p "Metadata 共享密钥 [${METADATA_SECRET}]: " input
    METADATA_SECRET="${input:-${METADATA_SECRET}}"

    # ---------- 存储配置 ----------
    echo ""
    echo "===== Cinder 块存储 ====="
    echo "  [1] Loopback 文件 (测试, 推荐)"
    echo "  [2] 物理磁盘 (生产环境)"
    echo "  [3] 跳过不安装"
    read -r -p "  请选择 [1]: " CINDER_MODE; CINDER_MODE="${CINDER_MODE:-1}"

    CINDER_LOOP_GB=""
    CINDER_DISK_DEV=""
    case "$CINDER_MODE" in
        2)
            echo ""
            echo "  正在检测存储节点可用磁盘..."
            local cinder_available=""
            cinder_available=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER:-root}@${COMPUTE_IP}" \
                'for d in $(lsblk -nd -o NAME,TYPE 2>/dev/null | grep disk | awk "{print \$1}"); do
                    [ "$(lsblk -d /dev/$d -o RO -n 2>/dev/null)" = "1" ] && continue
                    has_parts=$(lsblk /dev/$d -n -o TYPE 2>/dev/null | grep -v disk | head -1)
                    [ -n "$has_parts" ] && continue
                    size=$(lsblk -d /dev/$d -o SIZE -n 2>/dev/null | tr -d " ")
                    echo "$d ${size}"
                done' 2>/dev/null || echo "")
            if [ -n "$cinder_available" ]; then
                echo "  可用磁盘:"
                echo "$cinder_available" | while read -r line; do
                    [ -z "$line" ] && continue
                    echo "    /dev/$(echo "$line" | awk '{print $1}')  $(echo "$line" | awk '{print $2}')"
                done
                local cinder_first; cinder_first=$(echo "$cinder_available" | head -1 | awk '{print $1}')
                CINDER_DISK_DEV="/dev/${cinder_first:-sdb}"
            else
                log_warn "未检测到可用磁盘"
                CINDER_DISK_DEV="/dev/sdb"
            fi
            read -r -p "  磁盘设备 [${CINDER_DISK_DEV}]: " input; CINDER_DISK_DEV="${input:-${CINDER_DISK_DEV}}"
            ;;
        3)
            CINDER_LOOP_GB="0"
            log_info "跳过 Cinder 安装"
            ;;
        *)
            read -r -p "  Loopback 大小(GB) [5]: " input; CINDER_LOOP_GB="${input:-5}"
            ;;
    esac

    echo ""
    echo "===== Swift 对象存储 ====="
    echo "  [1] Loopback 文件 (测试, 推荐)"
    echo "  [2] 物理磁盘 (生产环境)"
    echo "  [3] 跳过不安装"
    read -r -p "  请选择 [1]: " SWIFT_MODE; SWIFT_MODE="${SWIFT_MODE:-1}"

    SWIFT_LOOP_GB=""
    SWIFT_DISK_DEV=""
    case "$SWIFT_MODE" in
        2)
            echo ""
            echo "  正在检测存储节点可用磁盘..."
            local swift_available=""
            swift_available=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER:-root}@${COMPUTE_IP}" \
                "for d in \$(lsblk -nd -o NAME,TYPE 2>/dev/null | grep disk | awk '{print \$1}'); do
                    [ \"\$(lsblk -d /dev/\$d -o RO -n 2>/dev/null)\" = \"1\" ] && continue
                    lsblk /dev/\$d -n -o TYPE 2>/dev/null | grep -qv disk && continue
                    s=\$(lsblk -d /dev/\$d -o SIZE -n 2>/dev/null | tr -d ' ')
                    echo \"\$d \${s}\"
                done" 2>/dev/null || echo "")
            if [ -n "$swift_available" ]; then
                echo "  可用磁盘:"
                echo "$swift_available" | while read -r line; do
                    [ -z "$line" ] && continue
                    echo "    /dev/$(echo "$line" | awk '{print $1}')  $(echo "$line" | awk '{print $2}')"
                done
                local swift_first; swift_first=$(echo "$swift_available" | head -1 | awk '{print $1}')
                SWIFT_DISK_DEV="/dev/${swift_first:-sdb}"
            else
                log_warn "未检测到可用磁盘"
                SWIFT_DISK_DEV="/dev/sdb"
            fi
            read -r -p "  磁盘设备 [${SWIFT_DISK_DEV}]: " input; SWIFT_DISK_DEV="${input:-${SWIFT_DISK_DEV}}"
            ;;
        3)
            SWIFT_LOOP_GB="0"
            log_info "跳过 Swift 安装"
            ;;
        *)
            read -r -p "  Loopback 大小(GB) [5]: " input; SWIFT_LOOP_GB="${input:-5}"
            ;;
    esac

    # ========== 5. 部署模式 ==========
    echo ""
    echo "===== 部署模式选择 ====="
    echo "  [1] 在线部署 (从互联网安装, 默认)"
    echo "  [2] 离线部署 (使用本地 ISO 软件源)"
    read -r -p "  请选择 [1]: " DEPLOY_MODE_CHOICE; DEPLOY_MODE_CHOICE="${DEPLOY_MODE_CHOICE:-1}"

    if [ "$DEPLOY_MODE_CHOICE" = "2" ]; then
        echo ""
        echo "  请输入离线软件源路径 (ISO 挂载点或 packages 目录)"
        read -r -p "  路径 [/root/openstack-dalmatian-offline.iso]: " input
        OFFLINE_REPO_PATH="${input:-/root/openstack-dalmatian-offline.iso}"
        log_info "离线模式: 软件源路径 = ${OFFLINE_REPO_PATH}"
    else
        OFFLINE_REPO_PATH=""
        log_info "在线模式: 从互联网安装"
    fi

    # ========== 6. 配置摘要 ==========
    echo ""
    echo "============================================"
    echo "  配置摘要"
    echo "============================================"
    echo "  部署模式: $( [ -n "${OFFLINE_REPO_PATH:-}" ] && echo '离线' || echo '在线' )"
    [ -n "${OFFLINE_REPO_PATH:-}" ] && echo "  离线源路径: ${OFFLINE_REPO_PATH}"
    echo ""
    echo "  [控制节点] ${CTRL_HOSTNAME}"
    echo "    管理: ${CTRL_MGMT_IFACE}  ${CTRL_MGMT_IP}/${CTRL_MGMT_PREFIX}  网关: ${CTRL_MGMT_GW}"
    echo "    内部: ${CTRL_INT_IFACE}  ${CTRL_INT_IP}/${CTRL_INT_PREFIX}  网关: ${CTRL_INT_GW}"
    echo ""
    echo "  [计算节点] ${COMPUTE_HOSTNAME}"
    echo "    管理: ${COMPUTE_MGMT_IFACE}  ${COMPUTE_MGMT_IP}/${COMPUTE_MGMT_PREFIX}  网关: ${COMPUTE_MGMT_GW}"
    echo "    内部: ${COMPUTE_INT_IFACE}  ${COMPUTE_INT_IP}/${COMPUTE_INT_PREFIX}  网关: ${COMPUTE_INT_GW}"
    echo "============================================"
    read -r -p "确认以上配置? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { log_error "用户取消"; exit 1; }

    # ========== 7. 配置控制节点 ==========
    log_step "【阶段一】配置控制节点"
    set_hostname "${CTRL_HOSTNAME}"
    configure_network_interface "${CTRL_MGMT_IFACE}" "${CTRL_MGMT_IP}" "${CTRL_MGMT_PREFIX}" "${CTRL_MGMT_GW}"
    configure_network_interface "${CTRL_INT_IFACE}"  "${CTRL_INT_IP}"  "${CTRL_INT_PREFIX}"  "${CTRL_INT_GW}"
    disable_firewall_selinux
    configure_hosts "${CONTROLLER_IP}" "${COMPUTE_IP}"
    setup_repos_and_packages
    save_env_config
    log_info "控制节点基础环境配置完成"

    # ========== 8. SSH 配置计算节点 ==========
    remote_setup_compute

    # ========== 9. 离线模式: 系统更新 (SSH 操作完成后执行) ==========
    if [ -n "${OFFLINE_REPO_PATH:-}" ]; then
        log_step "【阶段三】离线环境系统更新"
        log_info "更新控制节点系统包 (同步 glibc/openssl 等依赖)..."
        dnf update -y --allowerasing 2>/dev/null || {
            log_warn "部分更新失败，尝试 --skip-broken..."
            dnf update -y --skip-broken --nobest 2>/dev/null || true
        }
        log_info "控制节点系统更新完成"
    fi

    # ========== 10. 完成 ==========
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    全部节点基础环境准备完成                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    log_warn "请分别在两个节点上执行 reboot 重启使所有配置生效:"
    echo ""
    echo "  控制节点:  reboot"
    echo "  计算节点:  ssh ${COMPUTE_USER}@${COMPUTE_IP} 'reboot'"
    echo ""
    echo "重启后请验证:"
    echo "  1. hostname       — 主机名是否正确"
    echo "  2. ip addr        — IP 是否配置正确"
    echo "  3. ping ${CTRL_HOSTNAME} / ${COMPUTE_HOSTNAME} — hosts 解析是否生效"
    echo "  4. getenforce     — SELinux 状态是否为 Disabled"
    echo "  5. systemctl status firewalld — 防火墙是否已关闭"
    if [ -n "${OFFLINE_REPO_PATH:-}" ]; then
        echo ""
        echo "  离线模式说明:"
        echo "    将此 ISO 复制到计算节点相同路径:"
        echo "    scp ${OFFLINE_REPO_PATH} ${COMPUTE_USER}@${COMPUTE_IP}:${OFFLINE_REPO_PATH}"
        echo ""
        echo "    部署全部完成后，恢复网络源:"
        echo "    source /root/openstack_common.sh && restore_network_repos"
    fi
    echo ""
}

# ==================== 入口 ====================
if [ "$REMOTE_MODE" -eq 1 ]; then
    remote_mode_execute "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}" "${15}"
else
    interactive_main
fi
