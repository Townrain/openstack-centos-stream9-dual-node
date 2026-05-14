#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Cinder 块存储服务安装（控制节点 + SSH 远程配置存储节点）
# 运行位置: 控制节点
# 执行方式: bash openstack_cinder.sh
# 运行用户: root
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"

[ "$(id -u)" -ne 0 ] && { log_error "请使用 root 账户"; exit 1; }

REMOTE_MODE=0
[ $# -ge 4 ] && REMOTE_MODE=1


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



# ==================== 远程模式：存储节点配置 ====================
remote_storage_mode() {
    local ctrl_hostname="$1"
    local ctrl_ip="$2"
    local storage_ip="$3"
    local cinder_pass="$4"
    local rabbit_pass="$5"
    local loop_gb="$6"
    local disk_dev="$7"

    log_info "远程自动模式 — Cinder 存储节点配置"

    grep -q "${ctrl_hostname}" /etc/hosts 2>/dev/null || echo "${ctrl_ip} ${ctrl_hostname}" >> /etc/hosts

    # ---- 1. 安装软件包 ----
    log_step "安装 Cinder Volume 及 iSCSI 组件"
    dnf install -y openstack-cinder targetcli python3-rtslib python3-keystone iscsi-initiator-utils lvm2 device-mapper-persistent-data || \
        dnf install -y --allowerasing openstack-cinder targetcli python3-rtslib python3-keystone iscsi-initiator-utils lvm2 device-mapper-persistent-data || \
        { log_error "安装 Cinder 存储节点软件包失败"; exit 1; }
    modprobe iscsi_target_mod 2>/dev/null || true
    echo "iscsi_target_mod" > /etc/modules-load.d/cinder-iscsi.conf

    # ---- 2. 存储后端：Loopback 或物理磁盘 ----
    if [ -n "${disk_dev}" ] && [ "${disk_dev}" != "0" ]; then
        # === 物理磁盘模式 ===
        log_step "物理磁盘模式: ${disk_dev}"

        if ! pvs "${disk_dev}" 2>/dev/null | grep -q cinder-volumes; then
            log_info "清除 ${disk_dev} 旧分区表..."
            wipefs -a "${disk_dev}" 2>/dev/null || true
            log_info "pvcreate ${disk_dev} ..."
            pvcreate -ff -y "${disk_dev}"
        else
            log_info "${disk_dev} 已在 VG cinder-volumes 中"
        fi

        if ! vgs cinder-volumes 2>/dev/null | grep -q cinder-volumes; then
            log_info "vgcreate cinder-volumes ${disk_dev}"
            vgcreate cinder-volumes "${disk_dev}"
        fi

        # 配置 LVM filter（只扫描该磁盘）
        log_info "配置 LVM filter..."
        sed -i 's/^[[:space:]]*filter =/# filter =/' /etc/lvm/lvm.conf
        sed -i '/^# filter =/a\    filter = [ "a|DISKDEV|", "r|.*|" ]' /etc/lvm/lvm.conf
        sed -i "s|DISKDEV|${disk_dev}|" /etc/lvm/lvm.conf
        sed -i 's/^\s*use_devicesfile =.*/use_devicesfile = 0/' /etc/lvm/lvm.conf

        log_info "VG cinder-volumes (磁盘模式):"
        vgdisplay cinder-volumes 2>/dev/null | grep -E "VG Name|VG Size|Free" || true

    else
        # === Loopback 文件模式 ===
        local LOOP_SIZE_MB=$((loop_gb * 1024))
        local LOOP_FILE="/cinder-volumes.img"

        log_step "Loopback 文件模式: ${loop_gb}GB"

        if [ ! -f "$LOOP_FILE" ]; then
            log_info "创建 ${loop_gb}GB loopback 文件..."
            dd if=/dev/zero of=${LOOP_FILE} bs=1M count=${LOOP_SIZE_MB} status=progress
        else
            log_info "${LOOP_FILE} 已存在 ($(du -h ${LOOP_FILE} | cut -f1))"
        fi

        local LOOP_DEV; LOOP_DEV=$(losetup -j ${LOOP_FILE} 2>/dev/null | cut -d: -f1)
        if [ -z "$LOOP_DEV" ]; then
            LOOP_DEV=$(losetup -f)
            losetup "$LOOP_DEV" "$LOOP_FILE"
        fi
        log_info "Loop 设备: ${LOOP_DEV}"

        # 开机自动挂载 loop 设备
        mkdir -p /etc/cinder
        cat > /etc/cinder/loop-setup.sh << 'LOOPEOF'
#!/bin/bash
LOOP_DEV=$(losetup -j /cinder-volumes.img 2>/dev/null | cut -d: -f1)
[ -z "$LOOP_DEV" ] && LOOP_DEV=$(losetup -f) && losetup "$LOOP_DEV" /cinder-volumes.img
vgchange -ay cinder-volumes 2>/dev/null || true
LOOPEOF
        chmod +x /etc/cinder/loop-setup.sh
        cat > /etc/systemd/system/cinder-loop.service << SVCUNIT
[Unit]
Description=Setup Cinder Loop Device
Before=openstack-cinder-volume.service
DefaultDependencies=no
[Service]
Type=oneshot
ExecStart=/etc/cinder/loop-setup.sh
RemainAfterExit=yes
[Install]
WantedBy=sysinit.target
SVCUNIT
        systemctl daemon-reload
        systemctl enable cinder-loop.service 2>/dev/null || true
        log_info "Loop 开机服务已配置"

        # LVM devices file (CentOS 9)
        log_info "配置 LVM devices file..."
        sed -i 's/^[[:space:]]*filter =.*/# filter disabled - using devices file/' /etc/lvm/lvm.conf
        lvmdevices --adddev "$LOOP_DEV" 2>/dev/null || true
        pvscan 2>/dev/null || true

        # 创建 PV + VG
        LOOP_DEV=$(losetup -j /cinder-volumes.img 2>/dev/null | cut -d: -f1)
        pvs "$LOOP_DEV" 2>/dev/null | grep -q cinder-volumes || pvcreate -y "$LOOP_DEV" 2>/dev/null || true
        vgs cinder-volumes 2>/dev/null | grep -q cinder-volumes || vgcreate cinder-volumes "$LOOP_DEV"
        log_info "VG cinder-volumes:"
        vgdisplay cinder-volumes 2>/dev/null | grep -E "VG Name|VG Size|Free" || true
    fi

    systemctl enable --now lvm2-lvmetad.service 2>/dev/null || true

    # ---- 3. 配置 iSCSI ----
    log_step "配置 iSCSI Initiator 与 Target"
    systemctl start iscsid iscsid.socket 2>/dev/null || true
    systemctl enable iscsid iscsid.socket 2>/dev/null || true
    if [ ! -f /etc/iscsi/initiatorname.iscsi ] || ! grep -q "InitiatorName=" /etc/iscsi/initiatorname.iscsi 2>/dev/null; then
        echo "InitiatorName=$(iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
    fi
    systemctl restart iscsid iscsid.socket 2>/dev/null || true
    log_info "Initiator: $(cat /etc/iscsi/initiatorname.iscsi)"

    # ---- 4. 配置 cinder.conf (存储节点) ----
    log_step "配置 cinder.conf"
    local cconf="/etc/cinder/cinder.conf"
    [ ! -f "$cconf" ] && { log_error "${cconf} 不存在"; exit 1; }
    backup_file "$cconf"
    cat > "$cconf" << CINDEREOF
[DEFAULT]
transport_url = rabbit://openstack:${rabbit_pass}@${ctrl_hostname}:5672/
auth_strategy = keystone
my_ip = ${storage_ip}
enabled_backends = lvm
glance_api_servers = http://${ctrl_hostname}:9292

[database]
connection = mysql+pymysql://cinder:${cinder_pass}@${ctrl_hostname}/cinder

[keystone_authtoken]
www_authenticate_uri = http://${ctrl_hostname}:5000
auth_url = http://${ctrl_hostname}:5000
memcached_servers = ${ctrl_hostname}:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = cinder
password = ${cinder_pass}

[lvm]
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
volume_group = cinder-volumes
target_protocol = iscsi
target_helper = lioadm
target_ip_address = ${storage_ip}

[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
CINDEREOF
    log_info "cinder.conf 已配置"

    # ---- 5. rootwrap 权限 ----
    log_step "配置 rootwrap 权限"
    mkdir -p /etc/cinder/rootwrap.d
    cat > /etc/cinder/rootwrap.d/volume.filters << 'FILTEREOF'
[Filters]
lvm: CommandFilter, lvm, root
lvcreate: CommandFilter, lvcreate, root
lvremove: CommandFilter, lvremove, root
lvchange: CommandFilter, lvchange, root
lvs: CommandFilter, lvs, root
vgs: CommandFilter, vgs, root
pvs: CommandFilter, pvs, root
pvcreate: CommandFilter, pvcreate, root
pvremove: CommandFilter, pvremove, root
vgcreate: CommandFilter, vgcreate, root
targetcli: CommandFilter, targetcli, root
tgtadm: CommandFilter, tgtadm, root
tgt-admin: CommandFilter, tgt-admin, root
iscsiadm: CommandFilter, iscsiadm, root
FILTEREOF
    rm -f /var/run/targetcli.lock /run/targetcli.lock
    log_info "rootwrap 已配置"

    # ---- 6. Nova 集成 ----
    log_step "配置 Nova [cinder] 集成"
    local nconf="/etc/nova/nova.conf"
    if [ -f "$nconf" ] && ! grep -q '^\[cinder\]' "$nconf"; then
        cat >> "$nconf" << NOVAEOF

[cinder]
os_region_name = RegionOne
NOVAEOF
        systemctl restart openstack-nova-compute 2>/dev/null || true
        log_info "Nova [cinder] 已添加"
    else
        log_info "Nova [cinder] 已存在或 Nova 未安装"
    fi

    # ---- 7. 启动服务 ----
    log_step "启动 Cinder Volume + iSCSI 服务"
    systemctl enable --now openstack-cinder-volume target.service iscsid 2>/dev/null || true
    sleep 2
    for svc in openstack-cinder-volume target iscsid; do
        systemctl is-active "$svc" &>/dev/null && log_info "${svc} 已启动" || log_warn "${svc} 异常"
    done
}

# ==================== SSH 远程配置存储节点 ====================
remote_setup_storage() {
    log_step "远程配置存储节点 Cinder"

    local script_path; script_path="$(readlink -f "$0")"
    log_info "复制脚本到存储节点..."
    scp -o StrictHostKeyChecking=no "$script_path" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_cinder.sh"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/openstack_common.sh" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_common.sh"

    log_info "远程执行..."
    ssh -o StrictHostKeyChecking=no "${COMPUTE_USER}@${COMPUTE_IP}" \
        "bash /root/openstack_cinder.sh \
            --remote \
            '${CTRL_HOSTNAME}' \
            '${CONTROLLER_IP}' \
            '${COMPUTE_IP}' \
            '${CINDER_PASS}' \
            '${RABBIT_PASS}' \
            '${LOOP_GB:-0}' \
            '${STORAGE_DEV:-}'"

    log_info "存储节点 Cinder 配置完成"
}



# ==================== 控制节点安装 ====================
setup_mysql() {
    log_step "1. 配置 Cinder 数据库"
    if mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "USE cinder;" &>/dev/null 2>&1; then
        log_info "cinder 数据库已存在"
    else
        mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "CREATE DATABASE cinder CHARACTER SET utf8mb4;"
        log_info "cinder 数据库已创建 (utf8mb4)"
    fi
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '${CINDER_PASS}';" 2>/dev/null || true
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '${CINDER_PASS}';" 2>/dev/null || true
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "FLUSH PRIVILEGES;"
    log_info "Cinder 数据库配置完成"
}

setup_keystone() {
    log_step "2. 配置 Cinder Keystone 认证"
    openstack user show cinder &>/dev/null || { openstack user create --domain default --password "${CINDER_PASS}" cinder; log_info "cinder 用户已创建"; }
    openstack role assignment list --user cinder --project service --names 2>/dev/null | grep -q admin || { openstack role add --project service --user cinder admin; log_info "admin 角色已添加"; }
    openstack service show cinderv3 &>/dev/null || { openstack service create --name cinderv3 --description "OpenStack Block Storage v3" volumev3; log_info "cinderv3 服务实体已创建"; }
    openstack service show cinderv2 &>/dev/null || { openstack service create --name cinderv2 --description "OpenStack Block Storage v2" volumev2; log_info "cinderv2 服务实体已创建"; }
    local ep_url_v3="http://${CTRL_HOSTNAME}:8776/v3/%(project_id)s"
    local ep_url_v2="http://${CTRL_HOSTNAME}:8776/v2/%(project_id)s"
    openstack endpoint list 2>/dev/null | grep -q "volumev3.*public" || {
        for ep in public internal admin; do
            openstack endpoint create --region RegionOne volumev3 "$ep" "${ep_url_v3}"
            openstack endpoint create --region RegionOne volumev2 "$ep" "${ep_url_v2}"
        done
        log_info "volumev2/v3 端点已创建"
    }
}

install_controller_packages() {
    log_step "3. 安装 Cinder 控制节点软件包"
    dnf install -y openstack-cinder || dnf install -y --allowerasing openstack-cinder || { log_error "安装 openstack-cinder 失败"; exit 1; }
    log_info "openstack-cinder 安装完成"
}

configure_cinder_controller() {
    log_step "4. 配置 cinder.conf (控制节点)"
    local conf="/etc/cinder/cinder.conf"
    [ ! -f "$conf" ] && { log_error "${conf} 不存在"; exit 1; }
    backup_file "$conf"
    cat >> "$conf" << CINDEREOF

# === Cinder Controller Configuration ===
[DEFAULT]
transport_url = rabbit://openstack:${RABBIT_PASS}@${CTRL_HOSTNAME}:5672/
auth_strategy = keystone
my_ip = ${CONTROLLER_IP}

[database]
connection = mysql+pymysql://cinder:${CINDER_PASS}@${CTRL_HOSTNAME}/cinder

[keystone_authtoken]
www_authenticate_uri = http://${CTRL_HOSTNAME}:5000/
auth_url = http://${CTRL_HOSTNAME}:5000/
memcached_servers = ${CTRL_HOSTNAME}:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = cinder
password = ${CINDER_PASS}

[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
CINDEREOF
    log_info "cinder.conf 已更新"
}

sync_database() {
    log_step "5. 同步 Cinder 数据库"
    mkdir -p /var/lib/cinder/tmp
    chown cinder:cinder /var/lib/cinder/tmp
    su -s /bin/sh -c "cinder-manage db sync" cinder
    log_info "数据库同步完成"
}

start_controller_services() {
    log_step "6. 启动 Cinder 控制服务"
    systemctl enable --now openstack-cinder-api openstack-cinder-scheduler 2>/dev/null || true
    for svc in openstack-cinder-api openstack-cinder-scheduler; do
        systemctl is-active "$svc" &>/dev/null && log_info "${svc} 已启动" || log_warn "${svc} 异常"
    done
}

verify_cinder() {
    log_step "7. 验证 Cinder"
    echo ""
    echo "--- Cinder 服务列表 ---"
    openstack volume service list 2>/dev/null || log_warn "服务列表为空"
    echo ""
    echo "--- Cinder 端点 ---"
    openstack endpoint list 2>/dev/null | grep volume || true
}

# ==================== 主流程 ====================
interactive_main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║    OpenStack Dalmatian - Cinder 块存储服务安装              ║"
    echo "║    运行位置: 控制节点 → SSH 远程配置存储节点                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    load_env

    local detected_ip; detected_ip=$(detect_local_ip)
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        CTRL_HOSTNAME="${CTRL_HOSTNAME}"
        CONTROLLER_IP="${CONTROLLER_IP:-${detected_ip}}"
        CINDER_PASS="${CINDER_PASS:-${SERVICE_PASS}}"
        RABBIT_PASS="${RABBIT_PASS:-${CINDER_PASS}}"
        STORAGE_CHOICE="${CINDER_MODE:-1}"
        if [ "$STORAGE_CHOICE" = "2" ]; then
            STORAGE_DEV="${CINDER_DISK_DEV:-/dev/sdb}"
            LOOP_GB=""
        elif [ "$STORAGE_CHOICE" = "3" ]; then
            log_info "Cinder 已配置为跳过安装"; exit 0
        else
            LOOP_GB="${CINDER_LOOP_GB:-5}"
            STORAGE_DEV=""
        fi
    else
        read -r -p "控制节点主机名 [${CTRL_HOSTNAME}]: " input; CTRL_HOSTNAME="${input:-${CTRL_HOSTNAME}}"
        read -r -p "控制节点管理IP [${detected_ip}]: " input; CONTROLLER_IP="${input:-${detected_ip:-127.0.0.1}}"

        echo ""
        read -r -p "存储节点管理IP [${COMPUTE_IP:-}]: " input; COMPUTE_IP="${input:-${COMPUTE_IP:-}}"
        [ -z "$COMPUTE_IP" ] && { log_error "存储节点 IP 不能为空"; exit 1; }
        read -r -p "SSH 用户名 [${COMPUTE_USER:-root}]: " input; COMPUTE_USER="${input:-${COMPUTE_USER:-root}}"

        echo ""
        [ -z "${MYSQL_ROOT_PASS:-}" ] && { read -r -s -p "MySQL root 密码: " MYSQL_ROOT_PASS; echo ""; }
        read -r -s -p "Cinder 密码 [默认: 123456]: " CINDER_PASS; echo ""; CINDER_PASS="${CINDER_PASS:-123456}"
        read -r -p "RabbitMQ 密码 [${CINDER_PASS}]: " RABBIT_PASS; RABBIT_PASS="${RABBIT_PASS:-${CINDER_PASS}}"

        echo ""
        echo "  存储后端选择:"
        echo "    [1] Loopback 文件 (测试环境, 默认)"
        echo "    [2] 物理磁盘 (生产环境, 如 /dev/sdb)"
        read -r -p "  请选择 [1]: " STORAGE_CHOICE; STORAGE_CHOICE="${STORAGE_CHOICE:-1}"

        if [ "$STORAGE_CHOICE" = "2" ]; then
            echo ""
            echo "  正在检测存储节点可用磁盘..."
            local available=""
            if ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER:-root}@${COMPUTE_IP}" "hostname" &>/dev/null 2>&1; then
                available=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER:-root}@${COMPUTE_IP}" \
                    'for d in $(lsblk -nd -o NAME,TYPE 2>/dev/null | grep disk | awk "{print \$1}"); do
                        [ "$(lsblk -d /dev/$d -o RO -n 2>/dev/null)" = "1" ] && continue
                        has_parts=$(lsblk /dev/$d -n -o TYPE 2>/dev/null | grep -v disk | head -1)
                        [ -n "$has_parts" ] && continue
                        size=$(lsblk -d /dev/$d -o SIZE -n 2>/dev/null | tr -d " ")
                        echo "$d ${size}"
                    done' 2>/dev/null || echo "")
            fi

            if [ -n "$available" ]; then
                echo "  存储节点可用磁盘:"
                echo "$available" | while read -r line; do
                    [ -z "$line" ] && continue
                    echo "    /dev/$(echo "$line" | awk '{print $1}')  $(echo "$line" | awk '{print $2}')"
                done || true
                local first; first=$(echo "$available" | head -1 | awk '{print $1}')
                [ -n "$first" ] && STORAGE_DEV="/dev/${first}" || STORAGE_DEV="/dev/sdb"
            else
                log_warn "无法检测存储节点磁盘"
                STORAGE_DEV="/dev/sdb"
            fi
            read -r -p "  磁盘设备路径 [${STORAGE_DEV}]: " input; STORAGE_DEV="${input:-${STORAGE_DEV}}"
            LOOP_GB=""
        else
            read -r -p "  Loopback 文件大小(GB) [5]: " input; LOOP_GB="${input:-5}"
            STORAGE_DEV=""
        fi
    fi

    echo ""
    echo "============================================"
    echo "  控制节点: ${CTRL_HOSTNAME}  IP: ${CONTROLLER_IP}"
    echo "  存储节点: ${COMPUTE_IP}"
    if [ "$STORAGE_CHOICE" = "2" ]; then
        echo "  存储类型: 物理磁盘 ${STORAGE_DEV}"
    else
        echo "  存储类型: Loopback ${LOOP_GB}GB"
    fi
    echo "============================================"
    if ! confirm "确认?"; then
        log_error "取消"; exit 1
    fi

    setup_ssh "$COMPUTE_IP" "$COMPUTE_USER"

    log_step "【阶段一】控制节点 Cinder 配置"
    setup_mysql
    setup_keystone
    install_controller_packages
    configure_cinder_controller
    sync_database
    start_controller_services

    # Nova [cinder] 集成 (控制节点)
    log_step "配置 Nova [cinder] (控制节点)"
    local nconf="/etc/nova/nova.conf"
    if [ -f "$nconf" ] && ! grep -q '^\[cinder\]' "$nconf"; then
        cat >> "$nconf" << NOVAEOF

[cinder]
os_region_name = RegionOne
NOVAEOF
        systemctl restart openstack-nova-api 2>/dev/null || true
        log_info "Nova [cinder] 已添加"
    fi

    log_step "【阶段二】存储节点 Cinder 配置"
    remote_setup_storage

    verify_cinder

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              Cinder 块存储服务安装完成                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo "  验证:  openstack volume service list"
    echo "  URL:   http://${CTRL_HOSTNAME}:8776"
    echo ""
}

# ==================== 入口 ====================
if [ "$REMOTE_MODE" -eq 1 ]; then
    remote_storage_mode "$2" "$3" "$4" "$5" "$6" "${7:-5}" "${8:-}"
else
    interactive_main
fi
