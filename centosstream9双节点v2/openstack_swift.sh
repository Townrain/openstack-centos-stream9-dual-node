#!/bin/bash
###############################################################################
# OpenStack Dalmatian - Swift 对象存储安装（控制器 + SSH 远程配置存储节点）
# 运行位置: 控制节点
# 执行方式: bash openstack_swift.sh
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
    [ -f /root/openstack_env.conf ] && source /root/openstack_env.conf 2>/dev/null
    CTRL_HOSTNAME="${CTRL_HOSTNAME:-controller-63}"
    CONTROLLER_IP="${CONTROLLER_IP:-192.168.63.10}"
    COMPUTE_IP="${COMPUTE_IP:-}"
    COMPUTE_USER="${COMPUTE_USER:-root}"
    [ -f /root/admin-openrc ] && source /root/admin-openrc 2>/dev/null || { log_error "请先安装 Keystone"; exit 1; }
}



# ==================== 远程模式：存储节点配置 ====================
remote_storage_mode() {
    local ctrl_hostname="$1"; local ctrl_ip="$2"; local storage_ip="$3"
    local swift_pass="$4"; local device_name="$5"; local storage_mode="$6"
    local loop_gb="${7:-5}"; local disk_dev="${8:-}"

    log_info "远程自动模式 — Swift 存储节点 (${storage_mode})"

    grep -q "${ctrl_hostname}" /etc/hosts 2>/dev/null || echo "${ctrl_ip} ${ctrl_hostname}" >> /etc/hosts

    # ---- 安装 ----
    log_step "安装 Swift 存储组件"
    dnf install -y openstack-swift-account openstack-swift-container openstack-swift-object \
        xfsprogs rsync rsync-daemon
    mkdir -p /var/cache/swift && chown -R root:swift /var/cache/swift && chmod -R 775 /var/cache/swift

    # ---- 创建存储 ----
    local mount_path="/srv/node/${device_name}"
    if [ "$storage_mode" = "loopback" ]; then
        log_step "Loopback 模式: 创建 ${loop_gb}GB 文件"
        local loop_file="/srv/swift-disk"
        if [ ! -f "$loop_file" ]; then
            truncate -s "${loop_gb}GB" "$loop_file"
            mkfs.xfs -f "$loop_file"
        fi
        mkdir -p "$mount_path"
        grep -q "$mount_path" /etc/fstab 2>/dev/null || \
            echo "${loop_file} ${mount_path} xfs loop,noatime,nodiratime 0 0" >> /etc/fstab
    else
        log_step "物理磁盘模式: ${disk_dev}"
        wipefs -a "${disk_dev}" 2>/dev/null || true
        mkfs.xfs -f "${disk_dev}"
        mkdir -p "$mount_path"
        local uuid; uuid=$(blkid "${disk_dev}" -s UUID -o value)
        grep -q "$mount_path" /etc/fstab 2>/dev/null || \
            echo "UUID=${uuid} ${mount_path} xfs defaults,noatime,nodiratime 0 2" >> /etc/fstab
    fi

    systemctl daemon-reload
    mount "$mount_path" 2>/dev/null || mount -a
    chown -R swift:swift /srv/node
    log_info "存储挂载点: ${mount_path}"

    # ---- 配置服务 ----
    log_step "配置存储服务"
    for srv in account container object; do
        local port
        case "$srv" in account) port=6202 ;; container) port=6201 ;; object) port=6200 ;; esac

        local daemon_section=""
        case "$srv" in
            account) daemon_section="[account-auditor]\n[account-replicator]" ;;
            container) daemon_section="[container-auditor]\n[container-replicator]\n[container-updater]" ;;
            object) daemon_section="[object-auditor]\n[object-replicator]\n[object-updater]" ;;
        esac

        local recon_lock=""
        [ "$srv" = "object" ] && recon_lock="recon_lock_path = /var/lock"

        cat > "/etc/swift/${srv}-server.conf" << SRVEOF
[DEFAULT]
bind_ip = ${storage_ip}
bind_port = ${port}
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon ${srv}-server

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
${recon_lock}

[filter:healthcheck]
use = egg:swift#healthcheck

[app:${srv}-server]
use = egg:swift#${srv}

${daemon_section}
SRVEOF
        log_info "${srv}-server.conf 已配置"
    done

    # ---- 配置 rsyncd ----
    log_step "配置 rsyncd"
    cat > /etc/rsyncd.conf << RSYNCEOF
pid file = /var/run/rsyncd.pid
log file = /var/log/rsyncd.log
uid = swift
gid = swift
address = ${storage_ip}

[account]
path = /srv/node
read only = false
write only = no
list = yes
incoming chmod = 0644
outgoing chmod = 0644
max connections = 25
lock file = /var/lock/account.lock

[container]
path = /srv/node
read only = false
write only = no
list = yes
incoming chmod = 0644
outgoing chmod = 0644
max connections = 25
lock file = /var/lock/container.lock

[object]
path = /srv/node
read only = false
write only = no
list = yes
incoming chmod = 0644
outgoing chmod = 0644
max connections = 25
lock file = /var/lock/object.lock
RSYNCEOF
    log_info "rsyncd.conf 已配置"

    # ---- 确认 Ring 文件权限 ----
    log_step "确认 Ring 文件"
    if ls /etc/swift/*.ring.gz &>/dev/null 2>&1; then
        chown swift:swift /etc/swift/*.ring.gz 2>/dev/null || true
        chown root:swift /etc/swift/swift.conf 2>/dev/null || true
        chmod 640 /etc/swift/swift.conf 2>/dev/null || true
        log_info "Ring 文件已就绪"
    else
        log_warn "Ring 文件未找到，请确保控制节点已分发"
    fi

    # ---- 启动服务 ----
    log_step "启动 Swift 存储服务"
    local services="rsyncd openstack-swift-account openstack-swift-account-auditor openstack-swift-account-replicator openstack-swift-container openstack-swift-container-auditor openstack-swift-container-replicator openstack-swift-container-updater openstack-swift-object openstack-swift-object-auditor openstack-swift-object-replicator openstack-swift-object-updater"
    systemctl enable --now $services 2>/dev/null || true
    sleep 2
    for srv in openstack-swift-account openstack-swift-container openstack-swift-object rsyncd; do
        systemctl is-active "$srv" &>/dev/null && log_info "${srv} 已启动" || log_warn "${srv} 异常"
    done
}

# ==================== SSH 远程配置存储节点 ====================
remote_setup_storage() {
    log_step "远程配置存储节点 Swift"

    local script_path; script_path="$(readlink -f "$0")"
    log_info "复制脚本到存储节点..."
    scp -o StrictHostKeyChecking=no "$script_path" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_swift.sh"
    scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/openstack_common.sh" "${COMPUTE_USER}@${COMPUTE_IP}:/root/openstack_common.sh"

    # 先分发 Ring 文件
    log_info "分发 Ring 文件到存储节点..."
    ssh -o StrictHostKeyChecking=no "${COMPUTE_USER}@${COMPUTE_IP}" "mkdir -p /etc/swift"
    scp -o StrictHostKeyChecking=no /etc/swift/*.ring.gz /etc/swift/swift.conf "${COMPUTE_USER}@${COMPUTE_IP}:/etc/swift/"

    log_info "远程执行..."
    ssh -o StrictHostKeyChecking=no "${COMPUTE_USER}@${COMPUTE_IP}" \
        "bash /root/openstack_swift.sh \
            --remote \
            '${CTRL_HOSTNAME}' \
            '${CONTROLLER_IP}' \
            '${COMPUTE_IP}' \
            '${SWIFT_PASS}' \
            '${SWIFT_DEVICE}' \
            '${SWIFT_MODE}' \
            '${SWIFT_LOOP_GB:-20}' \
            '${SWIFT_DISK_DEV:-}'"

    log_info "存储节点 Swift 配置完成"
}



# ==================== 控制节点安装 ====================
install_packages() {
    log_step "1. 安装 Swift Proxy"
    dnf install -y openstack-swift-proxy python3-swiftclient python3-keystoneclient
    mkdir -p /etc/swift && chown -R swift:swift /etc/swift
    log_info "Swift Proxy 安装完成"
}

setup_keystone() {
    log_step "2. Keystone 注册 Swift 服务"
    openstack user show swift &>/dev/null || { openstack user create --domain default --password "${SWIFT_PASS}" swift; log_info "swift 用户已创建"; }
    openstack role assignment list --user swift --project service --names 2>/dev/null | grep -q admin || { openstack role add --project service --user swift admin; log_info "admin 角色已添加"; }
    openstack service show swift &>/dev/null || { openstack service create --name swift --description "OpenStack Object Storage" object-store; log_info "swift 服务实体已创建"; }

    local ep_public="http://${CTRL_HOSTNAME}:8080/v1/AUTH_%(tenant_id)s"
    local ep_admin="http://${CTRL_HOSTNAME}:8080/v1"
    openstack endpoint list 2>/dev/null | grep -q "object-store.*public" || {
        openstack endpoint create --region RegionOne object-store public   "${ep_public}"
        openstack endpoint create --region RegionOne object-store internal "${ep_public}"
        openstack endpoint create --region RegionOne object-store admin    "${ep_admin}"
        log_info "API 端点已创建"
    }
}

configure_proxy() {
    log_step "3. 配置 proxy-server.conf"
    local conf="/etc/swift/proxy-server.conf"
    backup_file "$conf"
    cat > "$conf" << PROXYEOF
[DEFAULT]
bind_port = 8080
user = swift
swift_dir = /etc/swift

[pipeline:main]
pipeline = catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo versioned_writes symlink proxy-logging proxy-server

[app:proxy-server]
use = egg:swift#proxy
account_autocreate = True

[filter:keystoneauth]
use = egg:swift#keystoneauth
operator_roles = admin,user

[filter:authtoken]
paste.filter_factory = keystonemiddleware.auth_token:filter_factory
www_authenticate_uri = http://${CTRL_HOSTNAME}:5000
auth_url = http://${CTRL_HOSTNAME}:5000
memcached_servers = ${CTRL_HOSTNAME}:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = swift
password = ${SWIFT_PASS}
delay_auth_decision = True

[filter:cache]
use = egg:swift#memcache
memcache_servers = ${CTRL_HOSTNAME}:11211

[filter:catch_errors]
use = egg:swift#catch_errors
[filter:gatekeeper]
use = egg:swift#gatekeeper
[filter:healthcheck]
use = egg:swift#healthcheck
[filter:proxy-logging]
use = egg:swift#proxy_logging
[filter:container_sync]
use = egg:swift#container_sync
[filter:bulk]
use = egg:swift#bulk
[filter:ratelimit]
use = egg:swift#ratelimit
[filter:container-quotas]
use = egg:swift#container_quotas
[filter:account-quotas]
use = egg:swift#account_quotas
[filter:slo]
use = egg:swift#slo
[filter:dlo]
use = egg:swift#dlo
[filter:versioned_writes]
use = egg:swift#versioned_writes
[filter:symlink]
use = egg:swift#symlink
PROXYEOF
    log_info "proxy-server.conf 已配置"
}

generate_rings() {
    log_step "4. 生成 Ring 文件"

    # swift.conf
    cat > /etc/swift/swift.conf << 'SWIFTCONF'
[swift-hash]
swift_hash_path_suffix = swift_shared_2025
swift_hash_path_prefix = swift_shared_2025

[storage-policy:0]
name = Policy-0
default = yes
SWIFTCONF

    # 检查已生成的 ring 是否包含预期设备
    local need_rebuild=false
    if ls /etc/swift/*.ring.gz &>/dev/null 2>&1; then
        if swift-ring-builder /etc/swift/object.builder 2>/dev/null | grep -q "devices"; then
            if ! swift-ring-builder /etc/swift/object.builder 2>/dev/null | grep -q "${SWIFT_DEVICE}"; then
                log_warn "Ring 中无设备 '${SWIFT_DEVICE}'，重新生成"
                need_rebuild=true
                rm -f *.builder *.ring.gz /etc/swift/*.ring.gz
            else
                log_info "Ring 已包含设备 ${SWIFT_DEVICE}，跳过生成"
            fi
        else
            log_info "Ring 文件已就绪"
        fi
    else
        need_rebuild=true
    fi

    if $need_rebuild; then
        log_info "创建 Ring builder..."
        swift-ring-builder account.builder create 10 1 1
        swift-ring-builder container.builder create 10 1 1
        swift-ring-builder object.builder create 10 1 1

        log_info "添加存储节点: ${COMPUTE_IP} device=${SWIFT_DEVICE}"
        swift-ring-builder account.builder add \
            --region 1 --zone 1 --ip "${COMPUTE_IP}" --port 6202 --device "${SWIFT_DEVICE}" --weight 100
        swift-ring-builder container.builder add \
            --region 1 --zone 1 --ip "${COMPUTE_IP}" --port 6201 --device "${SWIFT_DEVICE}" --weight 100
        swift-ring-builder object.builder add \
            --region 1 --zone 1 --ip "${COMPUTE_IP}" --port 6200 --device "${SWIFT_DEVICE}" --weight 100

        log_info "Rebalance Ring..."
        swift-ring-builder account.builder rebalance
        swift-ring-builder container.builder rebalance
        swift-ring-builder object.builder rebalance

        cp *.ring.gz /etc/swift/
        log_info "Ring 文件已生成"
    fi

    chown swift:swift /etc/swift/*.ring.gz
    chown root:swift /etc/swift/swift.conf 2>/dev/null || true
    chmod 640 /etc/swift/swift.conf 2>/dev/null || true
}

start_proxy() {
    log_step "5. 启动 Swift Proxy"
    systemctl enable --now openstack-swift-proxy 2>/dev/null || true
    systemctl is-active openstack-swift-proxy &>/dev/null && log_info "openstack-swift-proxy 已启动" || log_warn "Proxy 异常"
}

verify_swift() {
    log_step "6. 验证 Swift"

    local have_credentials=false
    [ -f /root/admin-openrc ] && { source /root/admin-openrc 2>/dev/null; have_credentials=true; }

    echo ""
    if $have_credentials && swift stat 2>/dev/null; then
        log_info "swift stat 通过"
    else
        log_warn "swift stat 失败（存储节点可能尚未就绪）"
    fi

    echo ""
    echo "--- Swift 端点 ---"
    openstack endpoint list 2>/dev/null | grep object-store || true

    # 功能测试
    echo ""
    if $have_credentials && swift stat &>/dev/null 2>&1; then
        log_info "运行功能测试..."
        echo "Swift Test - $(date)" > /tmp/swift-test.txt
        swift post test-container 2>/dev/null || true
        swift upload test-container /tmp/swift-test.txt 2>/dev/null || true
        swift list test-container 2>/dev/null
        swift download test-container tmp/swift-test.txt -o /tmp/swift-downloaded.txt 2>/dev/null || true
        cat /tmp/swift-downloaded.txt 2>/dev/null || log_warn "下载功能测试未通过"
        log_info "功能测试完成"
    fi
}

# ==================== 主流程 ====================
interactive_main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║    OpenStack Dalmatian - Swift 对象存储安装                 ║"
    echo "║    运行位置: 控制节点 → SSH 远程配置存储节点                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    load_env

    local detected_ip; detected_ip=$(detect_local_ip)
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        CTRL_HOSTNAME="${CTRL_HOSTNAME}"
        CONTROLLER_IP="${CONTROLLER_IP:-${detected_ip}}"
        SWIFT_PASS="${SWIFT_PASS:-${SERVICE_PASS}}"
        STORAGE_CHOICE="${SWIFT_MODE:-1}"
        if [ "$STORAGE_CHOICE" = "2" ]; then
            SWIFT_DISK_DEV="${SWIFT_DISK_DEV:-/dev/sdb}"
            SWIFT_DEVICE=$(basename "$SWIFT_DISK_DEV")
            SWIFT_MODE="physical"
            SWIFT_LOOP_GB=""
        elif [ "$STORAGE_CHOICE" = "3" ]; then
            log_info "Swift 已配置为跳过安装"; exit 0
        else
            SWIFT_LOOP_GB="${SWIFT_LOOP_GB:-5}"
            SWIFT_DEVICE="LOOPFILE"
            SWIFT_MODE="loopback"
            SWIFT_DISK_DEV=""
        fi
    else
        read -r -p "控制节点主机名 [${CTRL_HOSTNAME}]: " input; CTRL_HOSTNAME="${input:-${CTRL_HOSTNAME}}"
        read -r -p "控制节点管理IP [${detected_ip}]: " input; CONTROLLER_IP="${input:-${detected_ip:-127.0.0.1}}"

        echo ""
        read -r -p "存储节点管理IP [${COMPUTE_IP:-}]: " input; COMPUTE_IP="${input:-${COMPUTE_IP:-}}"
        [ -z "$COMPUTE_IP" ] && { log_error "存储节点 IP 不能为空"; exit 1; }
        read -r -p "SSH 用户名 [${COMPUTE_USER:-root}]: " input; COMPUTE_USER="${input:-${COMPUTE_USER:-root}}"

        echo ""
        echo "  存储后端选择:"
        echo "    [1] Loopback 文件 (测试, 默认)"
        echo "    [2] 物理磁盘 (如 /dev/sdb)"
        read -r -p "  请选择 [1]: " STORAGE_CHOICE; STORAGE_CHOICE="${STORAGE_CHOICE:-1}"

        if [ "$STORAGE_CHOICE" = "2" ]; then
            echo ""
            echo "  正在检测存储节点可用磁盘..."
            local available=""
            if ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER:-root}@${COMPUTE_IP}" "hostname" &>/dev/null 2>&1; then
                available=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${COMPUTE_USER:-root}@${COMPUTE_IP}" \
                    "for d in \$(lsblk -nd -o NAME,TYPE 2>/dev/null | grep disk | awk '{print \$1}'); do
                        [ \"\$(lsblk -d /dev/\$d -o RO -n 2>/dev/null)\" = \"1\" ] && continue
                        lsblk /dev/\$d -n -o TYPE 2>/dev/null | grep -qv disk && continue
                        s=\$(lsblk -d /dev/\$d -o SIZE -n 2>/dev/null | tr -d ' ')
                        echo \"\$d \${s}\"
                    done" 2>/dev/null || echo "")
            fi

            if [ -n "$available" ]; then
                echo "  存储节点可用磁盘:"
                echo "$available" | while read -r line; do
                    [ -z "$line" ] && continue
                    local d; d=$(echo "$line" | awk '{print $1}')
                    local s; s=$(echo "$line" | awk '{print $2}')
                    echo "    /dev/${d} ${s}"
                done || true
                local first_disk; first_disk=$(echo "$available" | head -1 | awk '{print $1}')
                [ -n "$first_disk" ] && SWIFT_DISK_DEV="/dev/${first_disk}" || SWIFT_DISK_DEV="/dev/sdb"
            else
                log_warn "无法检测存储节点磁盘，请手动确认"
                SWIFT_DISK_DEV="/dev/sdb"
            fi
            read -r -p "  磁盘设备路径 [${SWIFT_DISK_DEV}]: " input; SWIFT_DISK_DEV="${input:-${SWIFT_DISK_DEV}}"
            SWIFT_DEVICE=$(basename "$SWIFT_DISK_DEV")
            SWIFT_MODE="physical"
            SWIFT_LOOP_GB=""
        else
            read -r -p "  Loopback 文件大小(GB) [5]: " input; SWIFT_LOOP_GB="${input:-5}"
            SWIFT_DEVICE="LOOPFILE"
            SWIFT_MODE="loopback"
            SWIFT_DISK_DEV=""
        fi

        echo ""
        echo "========== 密码配置 =========="
        read -r -s -p "Swift 密码 [默认: 123456]: " SWIFT_PASS; echo ""; SWIFT_PASS="${SWIFT_PASS:-123456}"
    fi

    echo ""
    echo "============================================"
    echo "  控制节点: ${CTRL_HOSTNAME}  IP: ${CONTROLLER_IP}"
    echo "  存储节点: ${COMPUTE_IP}"
    if [ "$SWIFT_MODE" = "physical" ]; then
        echo "  存储类型: 物理磁盘 ${SWIFT_DISK_DEV}  → 设备名: ${SWIFT_DEVICE}"
    else
        echo "  存储类型: Loopback ${SWIFT_LOOP_GB}GB  设备名: ${SWIFT_DEVICE}"
    fi
    echo "============================================"
    if ! confirm "确认?"; then
        log_error "取消"; exit 1
    fi

    setup_ssh "$COMPUTE_IP" "$COMPUTE_USER"

    log_step "【阶段一】控制节点 Swift Proxy"
    install_packages
    setup_keystone
    configure_proxy
    generate_rings
    start_proxy

    log_step "【阶段二】存储节点 Swift 存储"
    remote_setup_storage

    verify_swift

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              Swift 对象存储安装完成                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo "  验证:  swift stat"
    echo "  URL:   http://${CTRL_HOSTNAME}:8080"
    echo ""
}

# ==================== 入口 ====================
if [ "$REMOTE_MODE" -eq 1 ]; then
    remote_storage_mode "$2" "$3" "$4" "$5" "$6" "$7" "${8:-5}" "${9:-}"
else
    interactive_main
fi
