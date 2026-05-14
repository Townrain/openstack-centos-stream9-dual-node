#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Nova 计算服务安装（控制节点 + SSH 远程配置计算节点）
# 运行位置: 控制节点
# 执行方式: bash openstack_nova.sh
# 运行用户: root
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"

[ "$(id -u)" -ne 0 ] && { log_error "请使用 root 账户"; exit 1; }

# ==================== 运行模式判断 ====================
REMOTE_MODE=0
[ $# -ge 5 ] && REMOTE_MODE=1

# ==================== 加载环境 ====================
load_env() {
    # 调用公共库的 load_env 以加载统一变量
    if type load_env_common &>/dev/null; then
        load_env_common
    else
        # 如果公共库未定义 load_env_common，则手动加载
        [ -f /root/openstack_env.conf ] && source /root/openstack_env.conf 2>/dev/null
        CTRL_HOSTNAME="${CTRL_HOSTNAME:-controller-63}"
        CONTROLLER_IP="${CONTROLLER_IP:-192.168.63.10}"
        COMPUTE_IP="${COMPUTE_IP:-}"
        COMPUTE_USER="${COMPUTE_USER:-root}"
        MYSQL_ROOT_PASS="${MYSQL_ROOT_PASS:-}"
        ADMIN_PASS="${ADMIN_PASS:-123456}"
        SERVICE_PASS="${SERVICE_PASS:-${ADMIN_PASS}}"
        RABBIT_PASS="${RABBIT_PASS:-${SERVICE_PASS}}"
    fi
    [ -f /root/admin-openrc ] && source /root/admin-openrc 2>/dev/null && log_info "已加载 admin-openrc" || { log_error "请先安装 Keystone"; exit 1; }
}

# ==================== SSH 远程配置计算节点 ====================
remote_setup_compute() {
    log_step "远程配置计算节点 Nova"

    # 检查 COMPUTE_IP 是否设置
    if [ -z "${COMPUTE_IP:-}" ]; then
        log_error "计算节点 IP 未设置，请检查环境变量"
        exit 1
    fi

    local script_path; script_path="$(readlink -f "$0")"

    # 测试 SSH 连接
    log_info "测试 SSH 连接到 ${COMPUTE_USER}@${COMPUTE_IP}..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" "hostname" &>/dev/null; then
        log_error "无法通过 SSH 连接到计算节点 ${COMPUTE_IP}"
        log_error "请检查：1) SSH 免密配置 2) 计算节点防火墙 3) 计算节点 SSH 服务"
        exit 1
    fi
    log_info "SSH 连接正常"

    # 通过 SSH 检测计算节点网卡和 IP
    log_info "检测计算节点网络信息..."
    local remote_ifaces remote_mgmt_iface remote_int_iface
    remote_ifaces=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "${COMPUTE_USER}@${COMPUTE_IP}" \
        "ip -o link show up 2>/dev/null | grep -vE 'lo|virbr|docker|br-|veth|tun|tap|vnet|ovs' | awk -F': ' '{print \$2}' | tr -d '@'" 2>/dev/null || echo "")

    if [ -n "$remote_ifaces" ]; then
        remote_mgmt_iface=$(echo "$remote_ifaces" | head -1)
        local remote_int; remote_int=$(echo "$remote_ifaces" | sed -n '2p')
        remote_int_iface="${remote_int:-$remote_mgmt_iface}"
        echo "  计算节点网卡: mgmt=${remote_mgmt_iface} int=${remote_int_iface}"
    else
        remote_mgmt_iface="ens33"
        remote_int_iface="ens34"
        log_warn "无法检测计算节点网卡，使用默认值"
    fi

    log_info "复制脚本到计算节点..."
    scp -o StrictHostKeyChecking=no "$script_path" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_nova.sh"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/openstack_common.sh" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_common.sh"

    # 检查必要变量
    if [ -z "${CTRL_HOSTNAME:-}" ] || [ -z "${NOVA_PASS:-}" ] || [ -z "${RABBIT_PASS:-}" ] || [ -z "${PLACEMENT_PASS:-}" ] || [ -z "${NEUTRON_PASS:-}" ] || [ -z "${CONTROLLER_IP:-}" ]; then
        log_error "必要变量未设置: CTRL_HOSTNAME=$CTRL_HOSTNAME NOVA_PASS=$NOVA_PASS RABBIT_PASS=$RABBIT_PASS PLACEMENT_PASS=$PLACEMENT_PASS NEUTRON_PASS=$NEUTRON_PASS CONTROLLER_IP=$CONTROLLER_IP"
        exit 1
    fi

    log_info "远程执行计算节点配置..."
    ssh -o StrictHostKeyChecking=no "${COMPUTE_USER}@${COMPUTE_IP}" \
        "bash /root/openstack_nova.sh \
            --remote \
            '${CTRL_HOSTNAME}' \
            '${COMPUTE_IP}' \
            '${NOVA_PASS}' \
            '${RABBIT_PASS}' \
            '${PLACEMENT_PASS}' \
            '${NEUTRON_PASS}' \
            '${CONTROLLER_IP}'"

    log_info "计算节点 Nova 配置完成"
}

# ==================== 远程模式：计算节点自动配置 ====================
remote_compute_mode() {
    local ctrl_hostname="$1"
    local compute_mgmt_ip="$2"
    local nova_pass="$3"
    local rabbit_pass="$4"
    local placement_pass="$5"
    local neutron_pass="${6:-123456}"
    local ctrl_mgmt_ip="${7:-192.168.63.10}"

    # 参数验证
    if [ -z "$ctrl_hostname" ] || [ -z "$compute_mgmt_ip" ] || [ -z "$nova_pass" ] || [ -z "$rabbit_pass" ] || [ -z "$placement_pass" ]; then
        log_error "远程模式参数不足: ctrl_hostname=$ctrl_hostname compute_mgmt_ip=$compute_mgmt_ip nova_pass=$nova_pass rabbit_pass=$rabbit_pass placement_pass=$placement_pass"
        exit 1
    fi

    log_info "远程自动模式 — Nova 计算节点配置"

    # 兜底：确保 hosts 中有控制器域名解析
    log_step "确保 hosts 解析"
    grep -q "${ctrl_hostname}" /etc/hosts 2>/dev/null || echo "${ctrl_mgmt_ip} ${ctrl_hostname}" >> /etc/hosts
    log_info "hosts: $(grep ${ctrl_hostname} /etc/hosts)"

    log_step "安装 Nova Compute 及虚拟化组件"
    dnf install -y openstack-nova-compute || dnf install -y --allowerasing openstack-nova-compute || { log_error "安装 openstack-nova-compute 失败"; exit 1; }
    dnf install -y libvirt libvirt-daemon-kvm libvirt-client qemu-kvm qemu-img || dnf install -y --allowerasing libvirt libvirt-daemon-kvm libvirt-client qemu-kvm qemu-img || { log_error "安装虚拟化组件失败"; exit 1; }

    log_step "配置 nova.conf"
    local conf="/etc/nova/nova.conf"
    [ ! -f "$conf" ] && { log_error "${conf} 不存在"; exit 1; }
    backup_file "$conf"

    cat >> "$conf" << NOVAEOF

# === OpenStack Dalmatian Nova Compute Configuration ===

[DEFAULT]
enabled_apis = osapi_compute,metadata
transport_url = rabbit://openstack:${rabbit_pass}@${ctrl_hostname}:5672
my_ip = ${compute_mgmt_ip}
use_neutron = true
firewall_driver = nova.virt.firewall.NoopFirewallDriver
compute_driver = libvirt.LibvirtDriver
log_dir = /var/log/nova
state_path = /var/lib/nova
instances_path = \$state_path/instances

[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://${ctrl_hostname}:5000/v3
auth_url = http://${ctrl_hostname}:5000/v3
memcached_servers = ${ctrl_hostname}:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = nova
password = ${nova_pass}

[service_user]
send_service_user_token = true
auth_url = http://${ctrl_hostname}:5000/v3
auth_strategy = keystone
auth_type = password
project_domain_name = Default
project_name = service
user_domain_name = Default
username = nova
password = ${nova_pass}

[vnc]
enabled = true
server_listen = 0.0.0.0
server_proxyclient_address = \$my_ip
novncproxy_base_url = http://${ctrl_mgmt_ip}:6080/vnc_auto.html

[glance]
api_servers = http://${ctrl_hostname}:9292

[oslo_concurrency]
lock_path = /var/lib/nova/tmp

[placement]
region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://${ctrl_hostname}:5000/v3
username = placement
password = ${placement_pass}

[neutron]
auth_url = http://${ctrl_hostname}:5000/v3
auth_type = password
project_domain_name = Default
user_domain_name = Default
region_name = RegionOne
project_name = service
username = neutron
password = ${neutron_pass}
NOVAEOF

    # 硬件加速检测
    if [ "$(egrep -c '(vmx|svm)' /proc/cpuinfo)" -eq 0 ]; then
        log_warn "未检测到硬件虚拟化，设置 virt_type = qemu"
        cat >> "$conf" << NOVAEOF2

[libvirt]
virt_type = qemu
NOVAEOF2
    fi

    log_info "nova.conf 已更新"

    log_step "初始化 compute_id"
    mkdir -p /var/lib/nova
    touch /var/lib/nova/compute_id
    chown nova:nova /var/lib/nova/compute_id
    chmod 755 /var/lib/nova/compute_id
    uuidgen > /var/lib/nova/compute_id
    log_info "compute_id: $(cat /var/lib/nova/compute_id)"

    log_step "启动计算节点服务"
    log_info "启用并启动 libvirtd..."
    systemctl enable libvirtd --now
    log_info "启用 openstack-nova-compute（非阻塞）..."
    systemctl enable openstack-nova-compute
    nohup systemctl start openstack-nova-compute &>/dev/null &
    log_info "Nova 计算节点服务已触发启动"
}

# ==================== 控制节点安装 ====================
setup_rabbitmq() {
    log_step "0. 安装配置 RabbitMQ"
    if ! rpm -q rabbitmq-server &>/dev/null; then
        dnf install -y rabbitmq-server || dnf install -y --allowerasing rabbitmq-server || { log_error "安装 rabbitmq-server 失败"; exit 1; }
    fi
    if ! systemctl is-active rabbitmq-server &>/dev/null; then
        systemctl enable rabbitmq-server --now
    fi
    log_info "RabbitMQ 已启动"

    if rabbitmqctl list_users 2>/dev/null | grep -q openstack; then
        log_info "RabbitMQ openstack 用户已存在"
    else
        rabbitmqctl add_user openstack "${RABBIT_PASS}"
        rabbitmqctl set_permissions openstack ".*" ".*" ".*"
        log_info "RabbitMQ openstack 用户已创建"
    fi
}

setup_mysql() {
    log_step "1. 配置 Nova 数据库"
    for DB in nova_api nova nova_cell0; do
        if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "USE ${DB};" &>/dev/null 2>&1; then
            log_info "${DB} 已存在，跳过"
        else
            mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "CREATE DATABASE ${DB};"
            log_info "${DB} 已创建"
        fi
        mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON ${DB}.* TO 'nova'@'localhost' IDENTIFIED BY '${NOVA_PASS}';" 2>/dev/null || true
        mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON ${DB}.* TO 'nova'@'%' IDENTIFIED BY '${NOVA_PASS}';" 2>/dev/null || true
    done
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "FLUSH PRIVILEGES;"
    log_info "Nova 数据库配置完成"
}

setup_keystone() {
    log_step "2. 配置 Nova Keystone 认证"
    openstack user show nova &>/dev/null || { openstack user create --domain default --password "${NOVA_PASS}" nova; log_info "nova 用户已创建"; }
    openstack role assignment list --user nova --project service --names 2>/dev/null | grep -q admin || { openstack role add --project service --user nova admin; log_info "admin 角色已添加"; }
    openstack service show nova &>/dev/null || { openstack service create --name nova --description "OpenStack Compute" compute; log_info "nova 服务实体已创建"; }

    local ep="http://${CTRL_HOSTNAME}:8774/v2.1"
    openstack endpoint list 2>/dev/null | grep -q "nova.*public" || {
        openstack endpoint create --region RegionOne compute public   "${ep}"
        openstack endpoint create --region RegionOne compute internal "${ep}"
        openstack endpoint create --region RegionOne compute admin    "${ep}"
        log_info "API 端点已创建"
    }
}

install_controller_packages() {
    log_step "3. 安装 Nova 控制节点软件包"
    dnf install -y openstack-nova-api openstack-nova-conductor \
        openstack-nova-novncproxy openstack-nova-scheduler || \
        dnf install -y --allowerasing openstack-nova-api openstack-nova-conductor \
        openstack-nova-novncproxy openstack-nova-scheduler || \
        { log_error "安装 Nova 控制节点软件包失败"; exit 1; }
    log_info "Nova 控制节点软件包安装完成"
}

configure_nova_controller() {
    log_step "4. 配置 Nova 控制节点"
    local conf="/etc/nova/nova.conf"
    [ ! -f "$conf" ] && { log_error "${conf} 不存在"; exit 1; }
    backup_file "$conf"

    cat >> "$conf" << NOVAEOF

# === OpenStack Dalmatian Nova Controller Configuration ===

[DEFAULT]
enabled_apis = osapi_compute,metadata
transport_url = rabbit://openstack:${RABBIT_PASS}@${CTRL_HOSTNAME}:5672/
my_ip = ${CONTROLLER_IP}
log_dir = /var/log/nova

[api_database]
connection = mysql+pymysql://nova:${NOVA_PASS}@${CTRL_HOSTNAME}/nova_api

[database]
connection = mysql+pymysql://nova:${NOVA_PASS}@${CTRL_HOSTNAME}/nova

[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://${CTRL_HOSTNAME}:5000/v3
auth_url = http://${CTRL_HOSTNAME}:5000/v3
memcached_servers = ${CTRL_HOSTNAME}:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = nova
password = ${NOVA_PASS}

[service_user]
send_service_user_token = true
auth_url = http://${CTRL_HOSTNAME}:5000/v3
auth_strategy = keystone
auth_type = password
project_domain_name = Default
project_name = service
user_domain_name = Default
username = nova
password = ${NOVA_PASS}

[vnc]
enabled = true
server_listen = \$my_ip
server_proxyclient_address = \$my_ip

[glance]
api_servers = http://${CTRL_HOSTNAME}:9292

[oslo_concurrency]
lock_path = /var/lib/nova/tmp

[placement]
region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://${CTRL_HOSTNAME}:5000/v3
username = placement
password = ${PLACEMENT_PASS}

[scheduler]
discover_hosts_in_cells_interval = 300
NOVAEOF
    log_info "nova.conf 已更新"
}

sync_database() {
    log_step "5. 同步 Nova 数据库"
    mkdir -p /var/lib/nova/tmp
    chown nova:nova /var/lib/nova/tmp

    log_info "同步 api_db..."
    su -s /bin/sh -c "nova-manage api_db sync" nova

    log_info "注册 cell0..."
    su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova

    log_info "创建 cell1..."
    su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova

    log_info "同步 nova 主库..."
    su -s /bin/sh -c "nova-manage db sync" nova

    log_info "cell 列表:"
    su -s /bin/sh -c "nova-manage cell_v2 list_cells" nova
}

start_controller_services() {
    log_step "6. 启动 Nova 控制服务"
    systemctl enable --now \
        openstack-nova-api \
        openstack-nova-scheduler \
        openstack-nova-conductor \
        openstack-nova-novncproxy
    for svc in openstack-nova-api openstack-nova-scheduler openstack-nova-conductor openstack-nova-novncproxy; do
        systemctl is-active "$svc" &>/dev/null && log_info "${svc} 已启动" || log_warn "${svc} 异常"
    done
}

verify_nova() {
    log_step "7. 验证 Nova"

    echo ""
    echo "--- Nova 服务列表 ---"
    openstack compute service list 2>/dev/null || echo "  (待计算节点注册后可见)"

    # 发现计算节点
    echo ""
    log_info "尝试发现计算节点..."
    su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova 2>/dev/null || log_warn "discover_hosts 未找到新主机"

    echo ""
    openstack compute service list 2>/dev/null

    echo ""
    echo "--- Nova 端点 ---"
    openstack endpoint list 2>/dev/null | grep nova || true
}

# ==================== 交互主模式 ====================
interactive_main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   OpenStack Dalmatian - Nova 计算服务安装                   ║"
    echo "║   运行位置: 控制节点 → 自动 SSH 配置计算节点                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    load_env

    # === 收集参数 ===
    local detected_ip; detected_ip=$(detect_local_ip)

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        CTRL_HOSTNAME="${CTRL_HOSTNAME}"
        CONTROLLER_IP="${CONTROLLER_IP:-${detected_ip}}"
        NOVA_PASS="${NOVA_PASS:-${SERVICE_PASS}}"
        RABBIT_PASS="${RABBIT_PASS:-${NOVA_PASS}}"
        PLACEMENT_PASS="${PLACEMENT_PASS:-${NOVA_PASS}}"
        NEUTRON_PASS="${NEUTRON_PASS:-${NOVA_PASS}}"
    else
        echo "========== 控制节点配置 =========="
        read -r -p "控制节点主机名 [${CTRL_HOSTNAME}]: " input; CTRL_HOSTNAME="${input:-${CTRL_HOSTNAME}}"
        read -r -p "控制节点管理IP [${detected_ip}]: " input; CONTROLLER_IP="${input:-${detected_ip}}"

        echo ""
        echo "========== 计算节点信息 =========="
        read -r -p "计算节点管理IP [${COMPUTE_IP:-未配置}]: " input
        COMPUTE_IP="${input:-${COMPUTE_IP:-}}"
        [ -z "$COMPUTE_IP" ] && { log_error "计算节点 IP 不能为空"; exit 1; }
        read -r -p "SSH 用户名 [${COMPUTE_USER:-root}]: " COMPUTE_USER; COMPUTE_USER="${COMPUTE_USER:-root}"

        echo ""
        echo "========== 密码配置 =========="
        [ -z "${MYSQL_ROOT_PASS:-}" ] && { read -r -s -p "MySQL root 密码: " MYSQL_ROOT_PASS; echo ""; }
        read -r -s -p "Nova 密码 [默认: 123456]: " NOVA_PASS; echo ""
        NOVA_PASS="${NOVA_PASS:-123456}"
        read -r -p "RabbitMQ 密码 [${NOVA_PASS}]: " RABBIT_PASS; RABBIT_PASS="${RABBIT_PASS:-${NOVA_PASS}}"
        read -r -p "Placement 密码 [${NOVA_PASS}]: " PLACEMENT_PASS; PLACEMENT_PASS="${PLACEMENT_PASS:-${NOVA_PASS}}"
        read -r -p "Neutron 密码 [${NOVA_PASS}]: " NEUTRON_PASS; NEUTRON_PASS="${NEUTRON_PASS:-${NOVA_PASS}}"
    fi

    # === 摘要 ===
    echo ""
    echo "============================================"
    echo "  配置摘要"
    echo "============================================"
    echo "  [控制节点] ${CTRL_HOSTNAME}  IP: ${CONTROLLER_IP}"
    echo "  [计算节点] IP: ${COMPUTE_IP}"
    echo "  RabbitMQ:   openstack@${CTRL_HOSTNAME}:5672"
    echo "============================================"
    if ! confirm "确认以上配置?"; then
        log_error "取消"; exit 1
    fi

    # === 建立 SSH 免密 ===
    setup_ssh "$COMPUTE_IP" "$COMPUTE_USER"

    # === 阶段一：控制节点 ===
    log_step "【阶段一】配置控制节点 Nova"
    setup_rabbitmq
    setup_mysql
    setup_keystone
    install_controller_packages
    configure_nova_controller
    sync_database
    start_controller_services

    # === 阶段二：计算节点 ===
    remote_setup_compute

    # === 验证 ===
    verify_nova

    # === 完成 ===
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  Nova 计算服务安装完成                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Nova URL:  http://${CTRL_HOSTNAME}:8774/v2.1"
    echo "  验证:      openstack compute service list"
    echo "  重启控制:   reboot"
    echo "  重启计算:   ssh ${COMPUTE_USER}@${COMPUTE_IP} 'reboot'"
    echo ""
}

# ==================== 入口 ====================
if [ "$REMOTE_MODE" -eq 1 ]; then
    remote_compute_mode "$2" "$3" "$4" "$5" "$6" "$7" "${8:-192.168.63.10}"
else
    interactive_main
fi
