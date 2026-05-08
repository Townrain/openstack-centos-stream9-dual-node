#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Neutron 网络服务安装（控制节点 + SSH 远程配置计算节点）
# 运行位置: 控制节点
# 执行方式: bash openstack_neutron.sh
# 运行用户: root
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"

[ "$(id -u)" -ne 0 ] && { log_error "请使用 root 账户"; exit 1; }

REMOTE_MODE=0
[ $# -ge 5 ] && REMOTE_MODE=1


# ==================== 加载环境 ====================
load_env() {
    [ -f /root/openstack_env.conf ] && source /root/openstack_env.conf 2>/dev/null
    CTRL_HOSTNAME="${CTRL_HOSTNAME:-controller-63}"
    CONTROLLER_IP="${CONTROLLER_IP:-192.168.63.10}"
    MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-}"
    COMPUTE_IP="${COMPUTE_IP:-}"
    COMPUTE_USER="${COMPUTE_USER:-root}"
    INT_IP="${INT_IP:-}"
    INT_IFACE="${INT_IFACE:-}"
    [ -f /root/admin-openrc ] && source /root/admin-openrc 2>/dev/null || { log_error "请先安装 Keystone"; exit 1; }
}







# ==================== 远程模式：计算节点配置 ====================
remote_compute_mode() {
    local ctrl_hostname="$1"
    local ctrl_mgmt_ip="$2"
    local compute_mgmt_ip="$3"
    local int_iface="$4"
    local neutron_pass="$5"
    local rabbit_pass="$6"
    local metadata_secret="$7"

    log_info "远程自动模式 — Neutron 计算节点配置"

    # hosts 兜底
    grep -q "${ctrl_hostname}" /etc/hosts 2>/dev/null || echo "${ctrl_mgmt_ip} ${ctrl_hostname}" >> /etc/hosts

    log_step "安装 openstack-neutron-openvswitch"
    dnf install -y openstack-neutron-openvswitch

    log_step "配置 neutron.conf"
    local nconf="/etc/neutron/neutron.conf"
    backup_file "$nconf"
    cat >> "$nconf" << EOF

# === Neutron Compute Node ===
[DEFAULT]
transport_url = rabbit://openstack:${rabbit_pass}@${ctrl_hostname}:5672/

[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
EOF
    log_info "neutron.conf 已更新"

    log_step "配置 OVS 代理"
    local ovs_conf="/etc/neutron/plugins/ml2/openvswitch_agent.ini"
    backup_file "$ovs_conf"
    cat >> "$ovs_conf" << EOF

# === Neutron Compute OVS Agent ===
[ovs]
bridge_mappings = provider:br-provider
local_ip = ${compute_mgmt_ip}

[agent]
tunnel_types = vxlan
l2_population = true

[securitygroup]
enable_security_group = true
firewall_driver = openvswitch
EOF
    log_info "OVS 代理配置已更新 (local_ip=${compute_mgmt_ip})"

    log_step "创建 OVS 网桥"
    systemctl enable openvswitch --now 2>/dev/null || true
    if [ -n "$int_iface" ]; then
        nmcli connection show 2>/dev/null | grep "${int_iface}" | awk '{print $1}' | while read -r conn; do
            nmcli connection delete "$conn" 2>/dev/null || true
        done || true
        mkdir -p /etc/NetworkManager/conf.d
        cat > "/etc/NetworkManager/conf.d/99-ovs-${int_iface}.conf" << NMEOF
[keyfile]
unmanaged-devices=interface-name:${int_iface}
NMEOF
        nmcli general reload 2>/dev/null || true
        ip addr flush dev "$int_iface" 2>/dev/null || true
    fi
    ovs-vsctl add-br br-provider 2>/dev/null || true
    ovs-vsctl add-port br-provider "${int_iface:-ens34}" 2>/dev/null || true
    ip link set "${int_iface:-ens34}" up 2>/dev/null || true
    ip link set br-provider up 2>/dev/null || true
    ovs-vsctl show
    log_info "OVS 网桥已配置，NM 已永久忽略 ${int_iface}"

    # 确保重启后 OVS 桥端口自动 UP
    mkdir -p /etc/systemd/system/openvswitch.service.d
    cat > /etc/systemd/system/openvswitch.service.d/ovs-br-provider-up.conf << NMEOF
[Service]
ExecStartPost=/usr/bin/bash -c "ip link set ${int_iface:-ens34} up; ip link set br-provider up"
NMEOF
    systemctl daemon-reload
    log_info "已添加 OVS 桥开机自启"

    log_step "追加 [neutron] 到 nova.conf"
    local nova_conf="/etc/nova/nova.conf"
    if [ -f "$nova_conf" ]; then
        backup_file "$nova_conf"
        cat >> "$nova_conf" << EOF

[neutron]
auth_url = http://${ctrl_hostname}:5000/v3
auth_type = password
project_domain_name = Default
user_domain_name = Default
region_name = RegionOne
project_name = service
username = neutron
password = ${neutron_pass}
EOF
        log_info "nova.conf [neutron] 已追加"
    fi

    log_step "重启服务并启用代理"
    systemctl restart openstack-nova-compute 2>/dev/null || log_warn "nova-compute 重启异常"
    systemctl enable neutron-openvswitch-agent --now 2>/dev/null || true

    log_step "开启 IP 转发"
    echo 1 > /proc/sys/net/ipv4/ip_forward
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
    grep -q "net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    log_info "IP 转发已开启: $(sysctl -n net.ipv4.ip_forward)"

    log_info "计算节点 Neutron 配置完成"
}

# ==================== SSH 远程配置计算节点 ====================
remote_setup_compute() {
    log_step "远程配置计算节点 Neutron"

    local script_path; script_path="$(readlink -f "$0")"

    # 检测计算节点内部网卡名称（用于 OVS 桥端口）
    log_info "检测计算节点内部网卡..."
    local remote_def_iface
    remote_def_iface=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" \
        "ip -4 route show default 2>/dev/null | awk '{print \$5}' | head -1" 2>/dev/null || echo "")
    local remote_int_iface
    remote_int_iface=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" \
        "for i in \$(ip -o link show up 2>/dev/null | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs' | awk -F': ' '{print \$2}' | tr -d '@'); do [ \"\$i\" != '${remote_def_iface}' ] && echo \$i && break; done" 2>/dev/null || echo "ens34")

    echo "  内部网卡(OVS端口): ${remote_int_iface}"

    log_info "复制脚本到计算节点..."
    scp -o StrictHostKeyChecking=no "$script_path" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_neutron.sh"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/openstack_common.sh" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_common.sh"

    log_info "远程执行..."
    ssh -o StrictHostKeyChecking=no "${COMPUTE_USER}@${COMPUTE_IP}" \
        "bash /root/openstack_neutron.sh \
            --remote \
            '${CTRL_HOSTNAME}' \
            '${CONTROLLER_IP}' \
            '${COMPUTE_IP}' \
            '${remote_int_iface}' \
            '${NEUTRON_PASS}' \
            '${RABBIT_PASS}' \
            '${METADATA_SECRET}'"

    log_info "计算节点 Neutron 配置完成"
}

# ==================== SSH 免密 ====================


# ==================== 控制节点安装 ====================
setup_mysql() {
    log_step "1. 配置 Neutron 数据库"
    if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "USE neutron;" &>/dev/null 2>&1; then
        log_info "neutron 数据库已存在"
    else
        mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "CREATE DATABASE neutron CHARACTER SET utf8mb4;"
        log_info "neutron 数据库已创建 (utf8mb4)"
    fi
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '${NEUTRON_PASS}';" 2>/dev/null || true
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '${NEUTRON_PASS}';" 2>/dev/null || true
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "FLUSH PRIVILEGES;"
    log_info "Neutron 数据库配置完成"
}

setup_keystone() {
    log_step "2. 配置 Neutron Keystone 认证"
    openstack user show neutron &>/dev/null || { openstack user create --domain default --password "${NEUTRON_PASS}" neutron; log_info "neutron 用户已创建"; }
    openstack role assignment list --user neutron --project service --names 2>/dev/null | grep -q admin || { openstack role add --project service --user neutron admin; log_info "admin 角色已添加"; }
    openstack service show neutron &>/dev/null || { openstack service create --name neutron --description "OpenStack Networking" network; log_info "neutron 服务实体已创建"; }
    local ep="http://${CTRL_HOSTNAME}:9696"
    openstack endpoint list 2>/dev/null | grep -q "neutron.*public" || {
        openstack endpoint create --region RegionOne network public   "${ep}"
        openstack endpoint create --region RegionOne network internal "${ep}"
        openstack endpoint create --region RegionOne network admin    "${ep}"
        log_info "API 端点已创建"
    }
}

install_packages() {
    log_step "3. 安装 Neutron 软件包"
    dnf install -y openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch ebtables
    log_info "Neutron 软件包安装完成"
}

configure_neutron() {
    log_step "4. 配置 neutron.conf"
    local conf="/etc/neutron/neutron.conf"
    backup_file "$conf"
    cat >> "$conf" << EOF

# === Neutron Controller Configuration ===
[DEFAULT]
core_plugin = ml2
service_plugins = router
transport_url = rabbit://openstack:${RABBIT_PASS}@${CTRL_HOSTNAME}:5672
auth_strategy = keystone
notify_nova_on_port_status_changes = true
notify_nova_on_port_data_changes = true
log_dir = /var/log/neutron

[database]
connection = mysql+pymysql://neutron:${NEUTRON_PASS}@${CTRL_HOSTNAME}/neutron

[keystone_authtoken]
www_authenticate_uri = http://${CTRL_HOSTNAME}:5000/v3
auth_url = http://${CTRL_HOSTNAME}:5000/v3
memcached_servers = ${CTRL_HOSTNAME}:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = neutron
password = ${NEUTRON_PASS}

[oslo_concurrency]
lock_path = /var/lib/neutron/lock

[nova]
auth_url = http://${CTRL_HOSTNAME}:5000/v3
auth_type = password
project_domain_name = Default
user_domain_name = Default
region_name = RegionOne
project_name = service
username = nova
password = ${NOVA_PASS}
EOF
    log_info "neutron.conf 已更新"
}

configure_ml2() {
    log_step "5. 配置 ML2 插件"
    local conf="/etc/neutron/plugins/ml2/ml2_conf.ini"
    backup_file "$conf"
    cat >> "$conf" << EOF

# === ML2 Configuration ===
[ml2]
type_drivers = flat,vlan,vxlan
tenant_network_types = vxlan
mechanism_drivers = openvswitch,l2population
extension_drivers = port_security,qos

[ml2_type_flat]
flat_networks = provider

[ml2_type_vxlan]
vni_ranges = 1:1000
EOF
    log_info "ML2 插件已配置"
}

configure_ovs_agent() {
    log_step "6. 配置 OVS 代理"
    local conf="/etc/neutron/plugins/ml2/openvswitch_agent.ini"
    backup_file "$conf"
    cat >> "$conf" << EOF

# === OVS Agent ===
[ovs]
bridge_mappings = provider:br-provider
local_ip = ${CONTROLLER_IP}

[agent]
tunnel_types = vxlan
l2_population = true

[securitygroup]
enable_security_group = true
firewall_driver = openvswitch
EOF
    log_info "OVS 代理已配置"

    # 创建 OVS 网桥 — 先彻底移除内部网卡 IP 和 NM 管理
    log_info "创建 OVS 网桥 br-provider..."
    systemctl enable openvswitch --now 2>/dev/null || true

    # 1. 删除所有 NM 连接配置
    nmcli connection show 2>/dev/null | grep "${INT_IFACE}" | awk '{print $1}' | while read -r conn; do
        nmcli connection delete "$conn" 2>/dev/null && log_info "已删除 NM 连接: $conn" || true
    done || true
    # 2. 告诉 NetworkManager 永久忽略该网卡
    mkdir -p /etc/NetworkManager/conf.d
    cat > "/etc/NetworkManager/conf.d/99-ovs-${INT_IFACE}.conf" << NMEOF
[keyfile]
unmanaged-devices=interface-name:${INT_IFACE}
NMEOF
    # 3. 重载 NM 并清 IP
    nmcli general reload 2>/dev/null || true
    ip addr flush dev "${INT_IFACE}" 2>/dev/null || true

    ovs-vsctl add-br br-provider 2>/dev/null || true
    ovs-vsctl add-port br-provider "${INT_IFACE}" 2>/dev/null || true
    ip link set "${INT_IFACE}" up 2>/dev/null || true
    ip link set br-provider up 2>/dev/null || true
    ovs-vsctl show
    log_info "OVS 网桥 br-provider 已创建"
    log_info "VXLAN 隧道 IP: local_ip=${CONTROLLER_IP} (管理网卡)"

    # 确保重启后 OVS 桥端口自动 UP
    mkdir -p /etc/systemd/system/openvswitch.service.d
    cat > /etc/systemd/system/openvswitch.service.d/ovs-br-provider-up.conf << NMEOF
[Service]
ExecStartPost=/usr/bin/bash -c "ip link set ${INT_IFACE} up; ip link set br-provider up"
NMEOF
    systemctl daemon-reload
    log_info "已添加 OVS 桥开机自启 (${INT_IFACE} + br-provider)"
}

configure_l3_agent() {
    log_step "7. 配置 L3 代理"
    local conf="/etc/neutron/l3_agent.ini"
    backup_file "$conf"
    cat >> "$conf" << EOF

[DEFAULT]
interface_driver = openvswitch
external_network_bridge = br-provider
router_delete_namespaces = True

[agent]
polling_interval = 2
report_interval = 4
EOF
    log_info "L3 代理已配置"
}

configure_dhcp_agent() {
    log_step "8. 配置 DHCP 代理"
    local conf="/etc/neutron/dhcp_agent.ini"
    backup_file "$conf"
    cat >> "$conf" << EOF

[DEFAULT]
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
interface_driver = neutron.agent.linux.interface.OVSInterfaceDriver
enable_isolated_metadata = true
ovs_use_veth = true
EOF
    log_info "DHCP 代理已配置"
}

configure_metadata_agent() {
    log_step "9. 配置元数据代理"
    local conf="/etc/neutron/metadata_agent.ini"
    backup_file "$conf"
    cat >> "$conf" << EOF

[DEFAULT]
nova_metadata_host = ${CTRL_HOSTNAME}
metadata_proxy_shared_secret = ${METADATA_SECRET}
EOF
    log_info "元数据代理已配置"
}

configure_nova_neutron() {
    log_step "10. 追加 [neutron] 到 nova.conf"
    local conf="/etc/nova/nova.conf"
    backup_file "$conf"
    cat >> "$conf" << EOF

[neutron]
auth_url = http://${CTRL_HOSTNAME}:5000/v3
auth_type = password
project_domain_name = Default
user_domain_name = Default
region_name = RegionOne
project_name = service
username = neutron
password = ${NEUTRON_PASS}
service_metadata_proxy = true
metadata_proxy_shared_secret = ${METADATA_SECRET}
EOF
    log_info "nova.conf [neutron] 已追加"
}

create_symlink() {
    log_step "11. 创建 ML2 插件符号链接"
    ln -sf /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini
    log_info "plugin.ini 链接已创建"
}

populate_database() {
    log_step "12. 填充 Neutron 数据库"
    mkdir -p /var/lib/neutron/lock
    chown neutron:neutron /var/lib/neutron/lock
    su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
        --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
    log_info "Neutron 数据库同步完成"
}

restart_nova_api() {
    log_step "13. 重启 Nova API"
    systemctl restart openstack-nova-api
    systemctl is-active openstack-nova-api &>/dev/null && log_info "Nova API 已重启" || log_warn "Nova API 重启异常"
}

start_neutron_services() {
    log_step "14. 启动 Neutron 服务"

    # 等待 RabbitMQ 就绪
    for i in $(seq 1 15); do
        if rabbitmqctl status &>/dev/null 2>&1; then
            log_info "RabbitMQ 已就绪"
            break
        fi
        sleep 1
    done

    # 开启 IP 转发
    echo 1 > /proc/sys/net/ipv4/ip_forward
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
    grep -q "net.ipv4.ip_forward" /etc/sysctl.conf 2>/dev/null || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

    systemctl enable --now neutron-server \
        neutron-openvswitch-agent neutron-dhcp-agent \
        neutron-metadata-agent neutron-l3-agent 2>/dev/null || true

    sleep 3
    for svc in neutron-server neutron-openvswitch-agent neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent; do
        systemctl is-active "$svc" &>/dev/null && log_info "${svc} 已启动" || log_warn "${svc} 异常"
    done

    # 等待 neutron-server 完全就绪，然后重试未注册的 agent
    log_info "等待 neutron-server 完全就绪..."
    for i in $(seq 1 15); do
        if openstack network agent list 2>/dev/null | grep -q "Open vSwitch"; then
            log_info "neutron-server 已就绪"
            break
        fi
        sleep 2
    done

    # 重启可能未注册的 agent
    for agt in neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent; do
        systemctl restart "$agt" 2>/dev/null || true
    done
    sleep 3
    log_info "已重启 L3/DHCP/Metadata agent 确保注册"
}

verify_neutron() {
    log_step "15. 验证 Neutron"

    echo ""
    echo "--- Neutron 网络代理列表 ---"
    openstack network agent list 2>/dev/null || log_warn "代理列表为空"

    echo ""
    echo "--- Neutron 端点 ---"
    openstack endpoint list 2>/dev/null | grep neutron || true
}

# ==================== 主流程 ====================
interactive_main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║    OpenStack Dalmatian - Neutron 网络服务安装               ║"
    echo "║    运行位置: 控制节点 → SSH 远程配置计算节点                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    load_env

    local detected_mgmt; detected_mgmt=$(detect_local_ip)
    local detected_int; detected_int=$(detect_int_ip)
    local detected_int_iface; detected_int_iface=$(detect_int_iface)

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        CTRL_HOSTNAME="${CTRL_HOSTNAME}"
        CONTROLLER_IP="${CONTROLLER_IP:-${detected_mgmt}}"
        INT_IP="${INT_IP:-${detected_int}}"
        INT_IFACE="${INT_IFACE:-${detected_int_iface}}"
        NEUTRON_PASS="${NEUTRON_PASS:-${SERVICE_PASS}}"
        RABBIT_PASS="${RABBIT_PASS:-${NEUTRON_PASS}}"
        NOVA_PASS="${NOVA_PASS:-${NEUTRON_PASS}}"
        METADATA_SECRET="${METADATA_SECRET:-$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)}"
    else
        echo "========== 控制节点 =========="
        read -r -p "主机名 [${CTRL_HOSTNAME}]: " input; CTRL_HOSTNAME="${input:-${CTRL_HOSTNAME}}"
        read -r -p "管理IP [${detected_mgmt}]: " input; CONTROLLER_IP="${input:-${detected_mgmt}}"
        read -r -p "内部IP (VXLAN隧道) [${detected_int}]: " input; INT_IP="${input:-${detected_int}}"
        read -r -p "内部网卡 [${detected_int_iface}]: " input; INT_IFACE="${input:-${detected_int_iface}}"

        echo ""
        echo "========== 计算节点 =========="
        read -r -p "计算节点管理IP [${COMPUTE_IP:-}]: " input; COMPUTE_IP="${input:-${COMPUTE_IP:-}}"
        [ -z "$COMPUTE_IP" ] && { log_error "计算节点 IP 不能为空"; exit 1; }
        read -r -p "SSH 用户名 [${COMPUTE_USER:-root}]: " input; COMPUTE_USER="${input:-${COMPUTE_USER:-root}}"

        echo ""
        echo "========== 密码配置 =========="
        [ -z "${MYSQL_ROOT_PASS:-}" ] && { read -r -s -p "MySQL root 密码: " MYSQL_ROOT_PASS; echo ""; }
        read -r -s -p "Neutron 密码 [默认: 123456]: " NEUTRON_PASS; echo ""; NEUTRON_PASS="${NEUTRON_PASS:-123456}"
        read -r -p "RabbitMQ 密码 [${NEUTRON_PASS}]: " RABBIT_PASS; RABBIT_PASS="${RABBIT_PASS:-${NEUTRON_PASS}}"
        read -r -p "Nova 密码 [${NEUTRON_PASS}]: " NOVA_PASS; NOVA_PASS="${NOVA_PASS:-${NEUTRON_PASS}}"
        METADATA_SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 24)
        read -r -p "metadata 共享密钥 [${METADATA_SECRET}]: " input; METADATA_SECRET="${input:-${METADATA_SECRET}}"
    fi

    if ! confirm "确认?"; then
        log_error "取消"; exit 1
    fi

    setup_ssh "$COMPUTE_IP" "$COMPUTE_USER"

    log_step "【阶段一】控制节点 Neutron 配置"
    setup_mysql
    setup_keystone
    install_packages
    configure_neutron
    configure_ml2
    configure_ovs_agent
    configure_l3_agent
    configure_dhcp_agent
    configure_metadata_agent
    configure_nova_neutron
    create_symlink
    populate_database
    restart_nova_api
    start_neutron_services

    log_step "【阶段二】计算节点 Neutron 配置"
    remote_setup_compute

    verify_neutron

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                Neutron 网络服务安装完成                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo "  验证:  openstack network agent list"
    echo "  URL:   http://${CTRL_HOSTNAME}:9696"
    echo ""
}

# ==================== 入口 ====================
if [ "$REMOTE_MODE" -eq 1 ]; then
    remote_compute_mode "$2" "$3" "$4" "$5" "$6" "$7" "$8"
else
    interactive_main
fi
