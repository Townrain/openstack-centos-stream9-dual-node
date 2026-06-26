#!/bin/bash
###############################################################################
# OpenStack Dalmatian - 完整清理脚本（控制节点 + SSH 远程清理计算节点）
# 运行位置: 控制节点
# 执行方式: bash openstack_cleanup.sh [--force] [--section <name>]
# 运行用户: root
# 功能:     按部署逆序清理全部 OpenStack 组件，支持分段清理和远程计算节点清理
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/openstack_common.sh"

# ==================== 运行模式与参数解析 ====================
REMOTE_MODE=0
FORCE_MODE=0
SECTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote)   REMOTE_MODE=1; shift ;;
        --force)    FORCE_MODE=1; shift ;;
        --section)  SECTION="$2"; shift 2 ;;
        *)          shift ;;
    esac
done

[ "$(id -u)" -ne 0 ] && { log_error "请使用 root 账户"; exit 1; }

# ==================== 加载环境 ====================
load_cleanup_env() {
    log_step "加载环境配置"
    load_env_common
    if [ -f /root/openstack_env.conf ]; then
        log_info "已加载 /root/openstack_env.conf"
        log_info "  控制节点: ${CTRL_HOSTNAME:-未设置}  IP: ${CONTROLLER_IP:-未设置}"
        log_info "  计算节点: ${COMPUTE_USER:-root}@${COMPUTE_IP:-未设置}"
    else
        log_warn "未找到 /root/openstack_env.conf，部分清理可能受限"
    fi
    if [ -f /root/admin-openrc ]; then
        # shellcheck source=/dev/null
        source /root/admin-openrc 2>/dev/null || true
        log_info "已加载 /root/admin-openrc"
    else
        log_warn "未找到 /root/admin-openrc，Keystone 实体清理将跳过"
    fi
}

# ==================== 工具函数 ====================

# 安全停止并禁用服务（忽略不存在的服务）
safe_stop_service() {
    local svc="$1"
    if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
        systemctl stop "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
        log_info "已停止并禁用 ${svc}"
    fi
}

# 安全移除软件包（先检查是否已安装）
safe_remove_packages() {
    local pkg
    for pkg in "$@"; do
        if rpm -q "$pkg" &>/dev/null 2>&1; then
            dnf remove -y "$pkg" 2>/dev/null || {
                log_warn "移除 ${pkg} 失败，尝试 --nodeps"
                rpm -e --nodeps "$pkg" 2>/dev/null || true
            }
            log_info "已移除 ${pkg}"
        fi
    done
}

# 安全删除文件或目录
safe_remove() {
    local target="$1"
    if [ -e "$target" ]; then
        rm -rf "$target"
        log_info "已删除 ${target}"
    fi
}

# 安全删除符号链接
safe_remove_link() {
    local target="$1"
    if [ -L "$target" ]; then
        rm -f "$target"
        log_info "已删除链接 ${target}"
    fi
}

# 恢复最新备份文件
restore_backup() {
    local conf="$1"
    local latest_bak
    latest_bak=$(ls -t "${conf}.bak."* 2>/dev/null | head -1)
    if [ -n "$latest_bak" ] && [ -f "$latest_bak" ]; then
        cp -f "$latest_bak" "$conf"
        log_info "已恢复 ${conf} ← ${latest_bak}"
        return 0
    fi
    log_warn "未找到 ${conf} 的备份文件"
    return 1
}

# 移除配置文件及其所有备份
remove_conf_and_backups() {
    local conf="$1"
    rm -f "${conf}" "${conf}.bak."* 2>/dev/null || true
    [ -e "$conf" ] || log_info "已清理 ${conf} 及备份"
}

# 清理确认提示（--force 跳过）
confirm_cleanup() {
    local desc="$1"
    if [ "$FORCE_MODE" -eq 1 ]; then
        return 0
    fi
    if ! confirm "即将 ${desc}，是否继续?"; then
        log_warn "跳过: ${desc}"
        return 1
    fi
    return 0
}

# 清理 Keystone 实体（安全顺序：端点→角色→用户→服务→项目）
cleanup_keystone_entities() {
    # 加载凭证
    if [ ! -f /root/admin-openrc ]; then
        log_warn "admin-openrc 不存在，跳过 Keystone 实体清理"
        return 0
    fi
    # shellcheck source=/dev/null
    source /root/admin-openrc 2>/dev/null || { log_warn "加载 admin-openrc 失败"; return 0; }

    log_info "清理 Keystone 实体..."

    # 1. 删除所有端点
    local ep_ids
    ep_ids=$(openstack endpoint list -f value -c ID 2>/dev/null || true)
    for eid in $ep_ids; do
        openstack endpoint delete "$eid" 2>/dev/null || true
    done
    log_info "端点已清理"

    # 2. 移除角色分配（各服务用户）
    local svc_users="nova placement glance neutron cinder swift"
    for user in $svc_users; do
        openstack role remove --project service --user "$user" admin 2>/dev/null || true
    done
    log_info "角色分配已清理"

    # 3. 删除服务用户
    for user in $svc_users; do
        openstack user delete "$user" 2>/dev/null || true
    done
    log_info "服务用户已清理"

    # 4. 删除服务实体
    local svc_ids
    svc_ids=$(openstack service list -f value -c ID 2>/dev/null || true)
    for sid in $svc_ids; do
        openstack service delete "$sid" 2>/dev/null || true
    done
    log_info "服务实体已清理"

    # 5. 删除 service 项目
    openstack project delete service 2>/dev/null || true
    log_info "service 项目已清理"
}

# 清理 MySQL 数据库和用户
cleanup_mysql_db() {
    local db="$1"
    local user="$2"

    if [ -z "${MYSQL_ROOT_PASS:-}" ]; then
        log_warn "MYSQL_ROOT_PASS 未设置，跳过数据库清理: ${db}"
        return 0
    fi

    if ! command -v mysql &>/dev/null; then
        log_warn "mysql 命令不存在，跳过数据库清理: ${db}"
        return 0
    fi

    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "DROP DATABASE IF EXISTS ${db};" 2>/dev/null || true
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "DROP USER IF EXISTS '${user}'@'localhost';" 2>/dev/null || true
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "DROP USER IF EXISTS '${user}'@'%';" 2>/dev/null || true
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_info "已清理数据库 ${db} 及用户 ${user}"
}


###############################################################################
#                        控制节点清理函数（9 个阶段）
###############################################################################

# ==================== 阶段 1: Swift 对象存储 ====================
cleanup_swift_controller() {
    log_step "阶段 1/9: 清理 Swift (控制节点)"
    confirm_cleanup "清理 Swift 对象存储（控制节点）" || return 0

    # 停止服务
    safe_stop_service openstack-swift-proxy

    # 清理 Keystone 实体
    if [ -f /root/admin-openrc ]; then
        source /root/admin-openrc 2>/dev/null || true
        openstack role remove --project service --user swift admin 2>/dev/null || true
        openstack user delete swift 2>/dev/null || true
        # 删除 object-store 服务及其端点
        local svc_ids
        svc_ids=$(openstack service list -f value -c ID --long 2>/dev/null | grep object-store | awk '{print $1}' || true)
        for sid in $svc_ids; do
            openstack service delete "$sid" 2>/dev/null || true
        done
        log_info "Swift Keystone 实体已清理"
    fi

    # 移除软件包
    safe_remove_packages openstack-swift-proxy python3-swiftclient python3-keystoneclient

    # 清理配置和 Ring 文件
    safe_remove /etc/swift
    safe_remove /var/cache/swift

    log_info "Swift (控制节点) 清理完成"
}

# ==================== 阶段 2: Cinder 块存储 ====================
cleanup_cinder_controller() {
    log_step "阶段 2/9: 清理 Cinder (控制节点)"
    confirm_cleanup "清理 Cinder 块存储（控制节点）" || return 0

    # 停止服务
    safe_stop_service openstack-cinder-api
    safe_stop_service openstack-cinder-scheduler

    # 清理 Keystone 实体
    if [ -f /root/admin-openrc ]; then
        source /root/admin-openrc 2>/dev/null || true
        openstack role remove --project service --user cinder admin 2>/dev/null || true
        openstack user delete cinder 2>/dev/null || true
        local svc_ids
        svc_ids=$(openstack service list -f value -c ID --long 2>/dev/null | grep -E 'volumev[23]' | awk '{print $1}' || true)
        for sid in $svc_ids; do
            openstack service delete "$sid" 2>/dev/null || true
        done
        log_info "Cinder Keystone 实体已清理"
    fi

    # 清理数据库
    cleanup_mysql_db cinder cinder

    # 移除软件包
    safe_remove_packages openstack-cinder

    # 清理配置
    safe_remove /etc/cinder
    safe_remove /var/lib/cinder

    log_info "Cinder (控制节点) 清理完成"
}

# ==================== 阶段 3: Horizon Dashboard ====================
cleanup_horizon() {
    log_step "阶段 3/9: 清理 Horizon"
    confirm_cleanup "清理 Horizon Dashboard" || return 0

    # 停止 httpd（Horizon 与 Keystone/Placement 共用，仅在最后统一停止）
    # 这里只清理 Horizon 配置，httpd 在后续阶段处理
    safe_stop_service httpd

    # 清理 Horizon 配置
    local dashboard_conf="/etc/httpd/conf.d/openstack-dashboard.conf"
    if [ -f "$dashboard_conf" ]; then
        backup_file "$dashboard_conf"
        rm -f "$dashboard_conf"
        log_info "已移除 ${dashboard_conf}"
    fi

    # 移除软件包
    safe_remove_packages openstack-dashboard

    # 清理 Horizon 缓存和静态文件
    safe_remove /tmp/.openstack-dashboard-secret-key
    safe_remove /var/lib/openstack-dashboard

    log_info "Horizon 清理完成"
}

# ==================== 阶段 4: Neutron 网络服务 ====================
cleanup_neutron_controller() {
    log_step "阶段 4/9: 清理 Neutron (控制节点)"
    confirm_cleanup "清理 Neutron 网络服务（控制节点）" || return 0

    # 停止 5 个 Neutron 服务
    for svc in neutron-server neutron-openvswitch-agent neutron-dhcp-agent \
               neutron-metadata-agent neutron-l3-agent; do
        safe_stop_service "$svc"
    done

    # 清理 OVS 网桥
    if command -v ovs-vsctl &>/dev/null; then
        ovs-vsctl --if-exists del-br br-tun 2>/dev/null || true
        ovs-vsctl --if-exists del-br br-int 2>/dev/null || true
        ovs-vsctl --if-exists del-br br-provider 2>/dev/null || true
        log_info "OVS 网桥已清理"
    fi

    # 清理 OVS 开机自启配置
    safe_remove /etc/systemd/system/openvswitch.service.d

    # 清理 Keystone 实体
    if [ -f /root/admin-openrc ]; then
        source /root/admin-openrc 2>/dev/null || true
        openstack role remove --project service --user neutron admin 2>/dev/null || true
        openstack user delete neutron 2>/dev/null || true
        local svc_ids
        svc_ids=$(openstack service list -f value -c ID --long 2>/dev/null | grep network | awk '{print $1}' || true)
        for sid in $svc_ids; do
            openstack service delete "$sid" 2>/dev/null || true
        done
        log_info "Neutron Keystone 实体已清理"
    fi

    # 清理数据库
    cleanup_mysql_db neutron neutron

    # 移除软件包
    safe_remove_packages openstack-neutron openstack-neutron-ml2 \
        openstack-neutron-openvswitch ebtables

    # 清理配置
    safe_remove /etc/neutron
    safe_remove /var/lib/neutron

    # 恢复 NetworkManager 配置（移除 OVS 忽略规则）
    local nm_confs
    nm_confs=$(ls /etc/NetworkManager/conf.d/99-ovs-*.conf 2>/dev/null || true)
    for nm_conf in $nm_confs; do
        rm -f "$nm_conf"
        log_info "已移除 NM 配置: ${nm_conf}"
    done
    nmcli general reload 2>/dev/null || true

    # 恢复 sysctl（移除 ip_forward）
    sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf 2>/dev/null || true
    sysctl --system 2>/dev/null || true

    log_info "Neutron (控制节点) 清理完成"
}

# ==================== 阶段 5: Nova 计算服务 ====================
cleanup_nova_controller() {
    log_step "阶段 5/9: 清理 Nova (控制节点)"
    confirm_cleanup "清理 Nova 计算服务（控制节点）" || return 0

    # 停止 4 个控制服务
    for svc in openstack-nova-api openstack-nova-scheduler \
               openstack-nova-conductor openstack-nova-novncproxy; do
        safe_stop_service "$svc"
    done

    # 清理 Keystone 实体
    if [ -f /root/admin-openrc ]; then
        source /root/admin-openrc 2>/dev/null || true
        openstack role remove --project service --user nova admin 2>/dev/null || true
        openstack user delete nova 2>/dev/null || true
        local svc_ids
        svc_ids=$(openstack service list -f value -c ID --long 2>/dev/null | grep compute | awk '{print $1}' || true)
        for sid in $svc_ids; do
            openstack service delete "$sid" 2>/dev/null || true
        done
        log_info "Nova Keystone 实体已清理"
    fi

    # 清理数据库（3 个库）
    cleanup_mysql_db nova_api nova
    cleanup_mysql_db nova nova
    cleanup_mysql_db nova_cell0 nova

    # 移除软件包
    safe_remove_packages openstack-nova-api openstack-nova-conductor \
        openstack-nova-novncproxy openstack-nova-scheduler

    # 清理配置
    safe_remove /etc/nova
    safe_remove /var/lib/nova
    safe_remove /var/log/nova

    log_info "Nova (控制节点) 清理完成"
}

# ==================== 阶段 6: Placement 布局服务 ====================
cleanup_placement() {
    log_step "阶段 6/9: 清理 Placement"
    confirm_cleanup "清理 Placement 布局服务" || return 0

    # 停止 httpd（Placement 通过 Apache WSGI 提供服务）
    safe_stop_service httpd

    # 清理 Keystone 实体
    if [ -f /root/admin-openrc ]; then
        source /root/admin-openrc 2>/dev/null || true
        openstack role remove --project service --user placement admin 2>/dev/null || true
        openstack user delete placement 2>/dev/null || true
        local svc_ids
        svc_ids=$(openstack service list -f value -c ID --long 2>/dev/null | grep placement | awk '{print $1}' || true)
        for sid in $svc_ids; do
            openstack service delete "$sid" 2>/dev/null || true
        done
        log_info "Placement Keystone 实体已清理"
    fi

    # 清理数据库
    cleanup_mysql_db placement placement

    # 移除软件包
    safe_remove_packages openstack-placement-api

    # 清理 Apache 配置
    safe_remove /etc/httpd/conf.d/00-placement-api.conf

    # 清理配置
    safe_remove /etc/placement
    safe_remove /var/lib/placement

    log_info "Placement 清理完成"
}

# ==================== 阶段 7: Glance 镜像服务 ====================
cleanup_glance() {
    log_step "阶段 7/9: 清理 Glance"
    confirm_cleanup "清理 Glance 镜像服务" || return 0

    # 停止服务
    safe_stop_service openstack-glance-api

    # 清理 Keystone 实体
    if [ -f /root/admin-openrc ]; then
        source /root/admin-openrc 2>/dev/null || true
        openstack role remove --project service --user glance admin 2>/dev/null || true
        openstack user delete glance 2>/dev/null || true
        local svc_ids
        svc_ids=$(openstack service list -f value -c ID --long 2>/dev/null | grep image | awk '{print $1}' || true)
        for sid in $svc_ids; do
            openstack service delete "$sid" 2>/dev/null || true
        done
        log_info "Glance Keystone 实体已清理"
    fi

    # 清理数据库
    cleanup_mysql_db glance glance

    # 移除软件包
    safe_remove_packages openstack-glance

    # 清理配置和镜像存储
    safe_remove /etc/glance
    safe_remove /var/lib/glance
    safe_remove /var/log/glance

    log_info "Glance 清理完成"
}

# ==================== 阶段 8: Keystone 身份服务 ====================
cleanup_keystone() {
    log_step "阶段 8/9: 清理 Keystone"
    confirm_cleanup "清理 Keystone 身份服务（含所有 Keystone 实体）" || return 0

    # 停止 httpd
    safe_stop_service httpd

    # 清理所有 Keystone 实体（顺序很重要）
    cleanup_keystone_entities

    # 清理数据库
    cleanup_mysql_db keystone keystone

    # 移除软件包
    safe_remove_packages openstack-keystone python3-mod_wsgi

    # 清理 Apache Keystone 配置
    safe_remove_link /etc/httpd/conf.d/wsgi-keystone.conf

    # 清理配置和 Fernet 密钥
    safe_remove /etc/keystone
    safe_remove /var/lib/keystone
    safe_remove /var/log/keystone

    # 删除管理员凭证
    if [ -f /root/admin-openrc ]; then
        rm -f /root/admin-openrc
        log_info "已删除 /root/admin-openrc"
    fi

    log_info "Keystone 清理完成"
}

# ==================== 阶段 9: 基础环境 ====================
cleanup_base_env() {
    log_step "阶段 9/9: 清理基础环境"
    confirm_cleanup "清理基础环境（RabbitMQ/MariaDB/Memcached/httpd + 恢复系统配置）" || return 0

    # 停止基础服务
    for svc in rabbitmq-server memcached mariadb httpd openvswitch; do
        safe_stop_service "$svc"
    done

    # 移除基础软件包
    safe_remove_packages rabbitmq-server memcached mariadb mariadb-server \
        httpd python3-mod_wsgi openstack-selinux python3-openstackclient

    # 清理 RabbitMQ 数据
    safe_remove /var/lib/rabbitmq
    safe_remove /etc/rabbitmq

    # 清理 MariaDB 数据
    safe_remove /var/lib/mysql

    # 清理 Memcached 数据
    safe_remove /var/lib/memcached

    # 清理 httpd 配置残留
    safe_remove /etc/httpd/conf.d/wsgi-keystone.conf
    safe_remove /etc/httpd/conf.d/00-placement-api.conf
    safe_remove /etc/httpd/conf.d/openstack-dashboard.conf

    # 恢复 SELinux
    if [ -f /etc/selinux/config ]; then
        sed -i 's/^SELINUX=disabled/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
        sed -i 's/^SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
        log_info "SELinux 已恢复为 enforcing"
    fi

    # 恢复 firewalld
    systemctl enable firewalld 2>/dev/null || true
    systemctl start firewalld 2>/dev/null || true
    log_info "firewalld 已恢复"

    # 清理 /etc/hosts
    if [ -n "${CTRL_HOSTNAME:-}" ]; then
        sed -i "/${CTRL_HOSTNAME}/d" /etc/hosts 2>/dev/null || true
    fi
    if [ -n "${COMPUTE_IP:-}" ]; then
        sed -i "/${COMPUTE_IP}/d" /etc/hosts 2>/dev/null || true
    fi
    if [ -n "${COMPUTE_HOSTNAME:-}" ]; then
        sed -i "/${COMPUTE_HOSTNAME}/d" /etc/hosts 2>/dev/null || true
    fi
    log_info "/etc/hosts 已清理"

    # 清理 sysctl
    sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf 2>/dev/null || true
    sysctl --system 2>/dev/null || true

    # 恢复离线仓库
    restore_network_repos 2>/dev/null || true

    # 清理环境配置文件
    if [ -f /root/openstack_env.conf ]; then
        backup_file /root/openstack_env.conf
        rm -f /root/openstack_env.conf
        log_info "已删除 /root/openstack_env.conf"
    fi

    # 清理 NetworkManager OVS 忽略规则
    local nm_confs
    nm_confs=$(ls /etc/NetworkManager/conf.d/99-ovs-*.conf 2>/dev/null || true)
    for nm_conf in $nm_confs; do
        rm -f "$nm_conf"
        log_info "已移除 NM 配置: ${nm_conf}"
    done

    # 注意: 不删除 NM 连接文件（网卡配置不是 OpenStack 产物，删除会导致 SSH 断开）
    # NM 连接配置（ens33/ens37 等）由用户自行管理

    # DNF 清理
    dnf clean all 2>/dev/null || true
    dnf autoremove -y 2>/dev/null || true

    log_info "基础环境清理完成"
}


###############################################################################
#                        计算节点清理函数（4 个阶段）
###############################################################################

# ==================== 计算节点阶段 1: Swift 存储 ====================
cleanup_swift_compute() {
    log_step "计算节点阶段 1/4: 清理 Swift 存储"

    # 停止 12 个 Swift 存储服务
    local swift_svcs="rsyncd \
        openstack-swift-account openstack-swift-account-auditor openstack-swift-account-replicator \
        openstack-swift-container openstack-swift-container-auditor openstack-swift-container-replicator openstack-swift-container-updater \
        openstack-swift-object openstack-swift-object-auditor openstack-swift-object-replicator openstack-swift-object-updater"
    for svc in $swift_svcs; do
        safe_stop_service "$svc"
    done

    # 卸载 Swift 存储挂载点
    local mount_points
    mount_points=$(mount 2>/dev/null | grep '/srv/node' | awk '{print $3}' || true)
    for mp in $mount_points; do
        umount "$mp" 2>/dev/null || true
        log_info "已卸载 ${mp}"
    done

    # 移除 fstab 中的 Swift 条目
    sed -i '/swift-disk/d' /etc/fstab 2>/dev/null || true
    sed -i '/\/srv\/node/d' /etc/fstab 2>/dev/null || true

    # 移除 loopback 设备
    local loop_dev
    loop_dev=$(losetup -j /srv/swift-disk 2>/dev/null | cut -d: -f1 || true)
    [ -n "$loop_dev" ] && { losetup -d "$loop_dev" 2>/dev/null || true; log_info "已断开 loop 设备: ${loop_dev}"; }
    rm -f /srv/swift-disk 2>/dev/null || true

    # 移除挂载点和缓存
    safe_remove /srv/node
    safe_remove /var/cache/swift

    # 移除软件包
    safe_remove_packages openstack-swift-account openstack-swift-container \
        openstack-swift-object xfsprogs rsync-daemon

    # 清理配置
    safe_remove /etc/swift
    safe_remove /etc/rsyncd.conf

    log_info "Swift 存储节点清理完成"
}

# ==================== 计算节点阶段 2: Cinder 存储 ====================
cleanup_cinder_compute() {
    log_step "计算节点阶段 2/4: 清理 Cinder 存储"

    # 停止服务
    for svc in openstack-cinder-volume target iscsid lvm2-lvmetad; do
        safe_stop_service "$svc"
    done

    # 清理 LVM：移除 cinder-volumes VG
    if vgs cinder-volumes &>/dev/null 2>&1; then
        lvremove -f /dev/cinder-volumes/* 2>/dev/null || true
        vgremove -f cinder-volumes 2>/dev/null || true
        log_info "已移除 VG cinder-volumes"
    fi

    # 移除 loopback 设备
    local loop_dev
    loop_dev=$(losetup -j /cinder-volumes.img 2>/dev/null | cut -d: -f1 || true)
    if [ -n "$loop_dev" ]; then
        pvremove -f "$loop_dev" 2>/dev/null || true
        losetup -d "$loop_dev" 2>/dev/null || true
        log_info "已断开 loop 设备: ${loop_dev}"
    fi
    rm -f /cinder-volumes.img 2>/dev/null || true

    # 清理 iSCSI initiator
    safe_remove /etc/iscsi/initiatorname.iscsi

    # 清理 cinder-loop 开机服务
    safe_remove /etc/cinder/loop-setup.sh
    safe_remove /etc/systemd/system/cinder-loop.service
    systemctl daemon-reload 2>/dev/null || true

    # 移除软件包
    safe_remove_packages openstack-cinder targetcli python3-rtslib \
        python3-keystone iscsi-initiator-utils lvm2 device-mapper-persistent-data

    # 清理配置
    safe_remove /etc/cinder
    safe_remove /var/lib/cinder

    # 恢复 LVM 配置
    if [ -f /etc/lvm/lvm.conf ]; then
        sed -i 's/^[[:space:]]*filter =.*/# filter restored by cleanup/' /etc/lvm/lvm.conf 2>/dev/null || true
    fi

    log_info "Cinder 存储节点清理完成"
}

# ==================== 计算节点阶段 3: Neutron 网络 ====================
cleanup_neutron_compute() {
    log_step "计算节点阶段 3/4: 清理 Neutron 网络"

    # 停止服务
    safe_stop_service neutron-openvswitch-agent

    # 清理 OVS 网桥
    if command -v ovs-vsctl &>/dev/null; then
        ovs-vsctl --if-exists del-br br-tun 2>/dev/null || true
        ovs-vsctl --if-exists del-br br-int 2>/dev/null || true
        ovs-vsctl --if-exists del-br br-provider 2>/dev/null || true
        log_info "OVS 网桥已清理"
    fi

    # 清理 OVS 开机自启配置
    safe_remove /etc/systemd/system/openvswitch.service.d

    # 移除软件包
    safe_remove_packages openstack-neutron-openvswitch

    # 清理配置
    safe_remove /etc/neutron

    # 恢复 NetworkManager 配置
    local nm_confs
    nm_confs=$(ls /etc/NetworkManager/conf.d/99-ovs-*.conf 2>/dev/null || true)
    for nm_conf in $nm_confs; do
        rm -f "$nm_conf"
        log_info "已移除 NM 配置: ${nm_conf}"
    done
    nmcli general reload 2>/dev/null || true

    # 恢复 sysctl
    sed -i '/^net.ipv4.ip_forward/d' /etc/sysctl.conf 2>/dev/null || true
    sysctl --system 2>/dev/null || true

    log_info "Neutron 计算节点清理完成"
}

# ==================== 计算节点阶段 4: Nova 计算 ====================
cleanup_nova_compute() {
    log_step "计算节点阶段 4/4: 清理 Nova 计算"

    # 停止服务
    safe_stop_service openstack-nova-compute
    safe_stop_service libvirtd

    # 移除软件包
    safe_remove_packages openstack-nova-compute libvirt libvirt-daemon-kvm \
        libvirt-client qemu-kvm qemu-img

    # 清理配置
    safe_remove /etc/nova
    safe_remove /var/lib/nova
    safe_remove /var/log/nova

    log_info "Nova 计算节点清理完成"
}


###############################################################################
#                        远程清理调度
###############################################################################

# 计算节点完整清理（远程模式下执行）
remote_cleanup_compute() {
    log_step "计算节点完整清理"

    load_cleanup_env

    # 逆序清理计算节点组件
    cleanup_swift_compute
    cleanup_cinder_compute
    cleanup_neutron_compute
    cleanup_nova_compute

    # 清理计算节点基础环境
    log_step "清理计算节点基础环境"

    # 恢复 SELinux
    if [ -f /etc/selinux/config ]; then
        sed -i 's/^SELINUX=disabled/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
        sed -i 's/^SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null || true
        log_info "SELinux 已恢复为 enforcing"
    fi

    # 恢复 firewalld
    systemctl enable firewalld 2>/dev/null || true
    systemctl start firewalld 2>/dev/null || true
    log_info "firewalld 已恢复"

    # 清理 /etc/hosts
    if [ -n "${CTRL_HOSTNAME:-}" ]; then
        sed -i "/${CTRL_HOSTNAME}/d" /etc/hosts 2>/dev/null || true
    fi
    if [ -n "${COMPUTE_HOSTNAME:-}" ]; then
        sed -i "/${COMPUTE_HOSTNAME}/d" /etc/hosts 2>/dev/null || true
    fi
    if [ -n "${CONTROLLER_IP:-}" ]; then
        sed -i "/${CONTROLLER_IP}/d" /etc/hosts 2>/dev/null || true
    fi

    # 清理 scp 过来的脚本
    rm -f /root/openstack_cleanup.sh /root/openstack_common.sh 2>/dev/null || true

    # 恢复离线仓库
    if type restore_network_repos &>/dev/null; then
        restore_network_repos 2>/dev/null || true
    fi

    # 清理环境配置
    if [ -f /root/openstack_env.conf ]; then
        rm -f /root/openstack_env.conf
        log_info "已删除 /root/openstack_env.conf"
    fi

    # 清理 NM 配置残留
    local nm_confs
    nm_confs=$(ls /etc/NetworkManager/conf.d/99-ovs-*.conf 2>/dev/null || true)
    for nm_conf in $nm_confs; do
        rm -f "$nm_conf"
    done

    # 注意: 不删除 NM 连接文件（网卡配置不是 OpenStack 产物，删除会导致 SSH 断开）

    # DNF 清理
    dnf clean all 2>/dev/null || true
    dnf autoremove -y 2>/dev/null || true

    log_info "计算节点完整清理完成"
}

# SSH 调度：复制脚本到计算节点并远程执行
remote_cleanup_dispatch() {
    if [ -z "${COMPUTE_IP:-}" ]; then
        log_warn "COMPUTE_IP 未设置，跳过计算节点清理"
        return 0
    fi

    log_step "远程清理计算节点 (${COMPUTE_USER:-root}@${COMPUTE_IP})"

    # 测试 SSH 连接
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER:-root}@${COMPUTE_IP}" "hostname" &>/dev/null 2>&1; then
        log_warn "无法连接计算节点 ${COMPUTE_IP}，跳过远程清理"
        return 0
    fi

    local script_path
    script_path="$(readlink -f "$0")"

    # 复制脚本和公共库到计算节点
    log_info "复制清理脚本到计算节点..."
    scp -o StrictHostKeyChecking=no "$script_path" \
        "${COMPUTE_USER:-root}@${COMPUTE_IP}:/root/openstack_cleanup.sh"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/openstack_common.sh" \
        "${COMPUTE_USER:-root}@${COMPUTE_IP}:/root/openstack_common.sh"
    scp -o StrictHostKeyChecking=no /root/openstack_env.conf \
        "${COMPUTE_USER:-root}@${COMPUTE_IP}:/root/openstack_env.conf" 2>/dev/null || true

    # 远程执行清理
    log_info "远程执行计算节点清理..."
    ssh -o StrictHostKeyChecking=no "${COMPUTE_USER:-root}@${COMPUTE_IP}" \
        "export FORCE_MODE='${FORCE_MODE}'; \
         bash /root/openstack_cleanup.sh --remote"

    log_info "计算节点远程清理完成"
}


###############################################################################
#                        主流程
###############################################################################

main() {
    load_cleanup_env

    # 远程模式：直接执行计算节点清理
    if [ "$REMOTE_MODE" -eq 1 ]; then
        remote_cleanup_compute
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     OpenStack Dalmatian 完整清理脚本                        ║"
    echo "║     控制节点 + SSH 远程清理计算节点                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    if [ -n "${CTRL_HOSTNAME:-}" ] && [ -n "${CONTROLLER_IP:-}" ]; then
        echo "  控制节点: ${CTRL_HOSTNAME}  IP: ${CONTROLLER_IP}"
    fi
    if [ -n "${COMPUTE_IP:-}" ]; then
        echo "  计算节点: ${COMPUTE_USER:-root}@${COMPUTE_IP}"
    fi
    echo ""

    # 分段清理模式
    if [ -n "$SECTION" ]; then
        log_info "分段清理模式: --section ${SECTION}"
        case "$SECTION" in
            swift)          cleanup_swift_controller ;;
            cinder)         cleanup_cinder_controller ;;
            horizon)        cleanup_horizon ;;
            neutron)        cleanup_neutron_controller ;;
            nova)           cleanup_nova_controller ;;
            placement)      cleanup_placement ;;
            glance)         cleanup_glance ;;
            keystone)       cleanup_keystone ;;
            base)           cleanup_base_env ;;
            *)
                log_error "未知的清理段: ${SECTION}"
                echo "  可用段名: swift cinder horizon neutron nova placement glance keystone base"
                exit 1
                ;;
        esac
        log_info "分段清理完成: ${SECTION}"
        exit 0
    fi

    # 全量清理模式
    if ! confirm "即将清理 OpenStack 全部部署（控制节点 + 计算节点），此操作不可逆！"; then
        log_info "用户取消"
        exit 0
    fi

    # 按部署逆序清理（9 个阶段）
    cleanup_swift_controller
    cleanup_cinder_controller
    cleanup_horizon
    cleanup_neutron_controller
    cleanup_nova_controller
    cleanup_placement
    cleanup_glance
    cleanup_keystone
    cleanup_base_env

    # 远程清理计算节点
    remote_cleanup_dispatch

    # 完成
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    OpenStack 清理完成                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  已清理组件: Swift → Cinder → Horizon → Neutron → Nova"
    echo "              → Placement → Glance → Keystone → 基础环境"
    echo ""
    echo "  建议操作:"
    echo "    1. 重启控制节点:  reboot"
    if [ -n "${COMPUTE_IP:-}" ]; then
        echo "    2. 重启计算节点:  ssh ${COMPUTE_USER:-root}@${COMPUTE_IP} 'reboot'"
    fi
    echo "    3. 如需重新部署:  bash openstack_all.sh"
    echo ""
}

main
