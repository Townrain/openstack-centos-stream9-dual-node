#!/bin/bash
###############################################################################
# OpenStack Dalmatian (CentOS Stream 9) 离线 ISO 软件源构建脚本
# 运行条件: 需要互联网连接 + root 权限 + 至少 10GB 磁盘空间
# 执行方式: bash build-openstack-offline-iso.sh
# 输出:     /root/openstack-dalmatian-offline.iso
# 内容:     仅 RPM 包仓库 (不含镜像/脚本)
###############################################################################
set -euo pipefail

# ==================== 路径配置 ====================
WORK_DIR="/tmp/openstack-offline-build"
ISO_CONTENT="${WORK_DIR}/openstack-offline"
PKGS_DIR="${ISO_CONTENT}/packages"
OUTPUT_ISO="/root/openstack-dalmatian-offline.iso"

# ==================== 颜色 ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}"; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用 root 运行"
    exit 1
fi

# ==================== 全部组件清单 ====================
ALL_PACKAGES=(
    # ===== 基础工具 =====
    "dnf-plugins-core"
    "centos-release-openstack-dalmatian"
    "vim-enhanced"
    "wget"
    "crudini"
    "net-tools"
    "bind-utils"
    "bash-completion"
    "tar"
    "gzip"
    "rsync"
    "openssh-clients"
    "openssh-server"

    # ===== SELinux =====
    "openstack-selinux"

    # ===== Python 客户端库 =====
    "python3-openstackclient"
    "python3-PyMySQL"
    "python3-swiftclient"
    "python3-keystoneclient"
    "python3-keystone"

    # ===== 数据库 / 消息队列 / 缓存 =====
    "mariadb"
    "mariadb-server"
    "rabbitmq-server"
    "memcached"

    # ===== Web 服务器 =====
    "httpd"
    "python3-mod_wsgi"

    # ===== Keystone 身份认证 =====
    "openstack-keystone"

    # ===== Glance 镜像服务 =====
    "openstack-glance"
    "qemu-img"

    # ===== Placement 布局服务 =====
    "openstack-placement-api"
    "openstack-placement-common"

    # ===== Nova 计算服务 (控制节点) =====
    "openstack-nova-api"
    "openstack-nova-conductor"
    "openstack-nova-novncproxy"
    "openstack-nova-scheduler"

    # ===== Nova 计算服务 (计算节点) =====
    "openstack-nova-compute"
    "libvirt"
    "libvirt-daemon-kvm"
    "libvirt-client"
    "qemu-kvm"

    # ===== Neutron 网络服务 =====
    "openstack-neutron"
    "openstack-neutron-ml2"
    "openstack-neutron-openvswitch"
    "ebtables"

    # ===== Horizon Dashboard =====
    "openstack-dashboard"

    # ===== Cinder 块存储 =====
    "openstack-cinder"
    "targetcli"
    "python3-rtslib"
    "iscsi-initiator-utils"
    "lvm2"
    "device-mapper-persistent-data"

    # ===== Swift 对象存储 =====
    "openstack-swift-proxy"
    "openstack-swift-account"
    "openstack-swift-container"
    "openstack-swift-object"
    "xfsprogs"
    "rsync-daemon"

    # ===== 其他依赖 =====
    "genisoimage"
    "createrepo_c"
)

# ==================== 1. 准备构建环境 ====================
prepare_env() {
    log_step "1. 准备构建环境"

    rm -rf "$WORK_DIR"
    mkdir -p "$PKGS_DIR"

    dnf install -y dnf-plugins-core createrepo_c genisoimage wget 2>/dev/null || true
    log_info "构建环境准备完成"
}

# ==================== 2. 配置 YUM 仓库 ====================
configure_repos() {
    log_step "2. 配置 YUM 仓库"

    # 启用 CRB (CodeReady Builder) — OpenStack 依赖所需
    log_info "启用 CRB 仓库..."
    dnf config-manager --set-enabled crb 2>/dev/null || true

    # 启用 OpenStack Dalmatian 仓库 (优先 RPM 包，失败则直接写 repo 文件)
    log_info "启用 OpenStack Dalmatian 仓库..."
    if ! rpm -q centos-release-openstack-dalmatian &>/dev/null 2>&1; then
        if ! dnf install -y centos-release-openstack-dalmatian 2>/dev/null; then
            log_info "RPM 包不可用，直接配置仓库文件..."
            cat > /etc/yum.repos.d/centos-openstack-dalmatian.repo << 'REPOEOF'
[centos-openstack-dalmatian]
name=CentOS Stream 9 - OpenStack Dalmatian
baseurl=https://mirror.stream.centos.org/SIGs/9-stream/cloud/$basearch/openstack-dalmatian/
gpgcheck=0
enabled=1
module_hotfixes=1
REPOEOF
            log_info "仓库文件已手动创建"
        fi
    fi

    # 清除离线部署残留 (上次测试可能禁用了所有仓库)
    rm -f /etc/yum.repos.d/openstack-offline.repo
    log_info "恢复基础仓库..."
    dnf config-manager --set-enabled baseos 2>/dev/null || true
    dnf config-manager --set-enabled appstream 2>/dev/null || true
    dnf config-manager --set-enabled crb 2>/dev/null || true

    # 确保 EPEL 已禁用 (避免依赖冲突)
    dnf config-manager --set-disabled epel 2>/dev/null || true
    dnf config-manager --set-disabled epel-next 2>/dev/null || true
    log_info "EPEL 保持禁用 (避免依赖冲突)"

    dnf makecache
    log_info "仓库配置完成"
}

# ==================== 3. 下载全部 RPM ====================
download_all_rpms() {
    log_step "3. 下载全部 RPM 包 (含依赖)"

    local total=${#ALL_PACKAGES[@]}
    local count=0
    local failed=""
    local succeeded=0

    # 使用 --installroot 模拟裸机安装下载，确保全量依赖
    log_info "解析全部依赖并下载 (可能耗时较长)..."
    echo ""

    local tmp_root="/tmp/dnf-offline-root"
    rm -rf "$tmp_root"
    mkdir -p "$tmp_root/var/lib/rpm" "$tmp_root/etc/yum.repos.d" "$tmp_root/etc/dnf"
    rpm --root "$tmp_root" --initdb 2>/dev/null || true

    # 复制宿主机仓库配置到 installroot
    cp -a /etc/yum.repos.d/* "$tmp_root/etc/yum.repos.d/" 2>/dev/null || true
    cp -a /etc/dnf/dnf.conf "$tmp_root/etc/dnf/" 2>/dev/null || true
    cp -a /etc/dnf/vars "$tmp_root/etc/dnf/" 2>/dev/null || true

    # 模拟全量安装 → 下载所有解析出的 RPM
    dnf install \
        --installroot="$tmp_root" \
        --downloadonly --downloaddir="$PKGS_DIR" \
        --setopt=install_weak_deps=False \
        --releasever=9 \
        -y "${ALL_PACKAGES[@]}" 2>/dev/null && log_info "全量依赖解析完成" || log_warn "批量下载部分失败，逐个兜底..."

    # 逐包验证并补漏
    for pkg in "${ALL_PACKAGES[@]}"; do
        count=$((count + 1))
        printf "  [%3d/%3d] %-45s " "$count" "$total" "$pkg"
        local existing
        existing=$(ls "$PKGS_DIR/${pkg}"-[0-9]*.rpm 2>/dev/null | grep -v debug | head -1 || true)
        if [ -n "$existing" ]; then
            echo -e "${GREEN}已存在${NC}"
            succeeded=$((succeeded + 1))
        else
            dnf install --installroot="$tmp_root" --downloadonly --downloaddir="$PKGS_DIR" \
                --setopt=install_weak_deps=False --releasever=9 -y "$pkg" 2>/dev/null && {
                echo -e "${GREEN}OK${NC}"; succeeded=$((succeeded + 1))
            } || {
                echo -e "${YELLOW}失败${NC}"; failed="${failed} ${pkg}"
            }
        fi
    done

    rm -rf "$tmp_root"

    local rpm_count
    rpm_count=$(ls "$PKGS_DIR"/*.rpm 2>/dev/null | wc -l)
    echo ""
    log_info "顶层包: ${succeeded}/${total} 成功  磁盘文件: ${rpm_count} 个 RPM"

    if [ -n "$failed" ]; then
        log_warn "以下包下载失败 (不影响已有包):${failed}"
        log_warn "这些包对应的 OpenStack 服务将无法离线安装"
    fi
}

# ==================== 3.5 过滤系统级库 (防止部署时覆盖 ssh/scp 依赖) ====================
filter_system_libs() {
    log_step "3.5 过滤系统级库 RPM (openssl 等)"

    local filtered=0
    local names=("openssl-[0-9]*.rpm" "openssl-libs-[0-9]*.rpm" "libssl-[0-9]*.rpm" "libcrypto-[0-9]*.rpm")

    for name_pattern in "${names[@]}"; do
        local before
        before=$(find "$PKGS_DIR" -maxdepth 1 -name "$name_pattern" -type f 2>/dev/null | wc -l)
        if [ "$before" -gt 0 ]; then
            find "$PKGS_DIR" -maxdepth 1 -name "$name_pattern" -type f -delete 2>/dev/null || true
            filtered=$((filtered + before))
            log_info "已剔除: ${name_pattern} (${before} 个)"
        fi
    done

    if [ "$filtered" -gt 0 ]; then
        log_info "共剔除 ${filtered} 个系统级库 RPM，避免部署时覆盖运行中的 ssh/scp"
    else
        log_info "无需过滤"
    fi
}

# ==================== 4. 生成 RPM 仓库元数据 ====================
create_repo_metadata() {
    log_step "4. 生成 RPM 仓库元数据 (createrepo_c)"

    local rpm_count
    rpm_count=$(ls "$PKGS_DIR"/*.rpm 2>/dev/null | wc -l)
    if [ "$rpm_count" -eq 0 ]; then
        log_error "无 RPM 包可打包，请检查网络"
        exit 1
    fi

    log_info "扫描 ${rpm_count} 个 RPM 文件..."
    createrepo_c --workers 4 "$PKGS_DIR" 2>/dev/null || \
    createrepo "$PKGS_DIR" 2>/dev/null || {
        log_error "createrepo 失败"
        exit 1
    }
    log_info "repodata 生成完成"
}

# ==================== 5. 生成 ISO ====================
create_iso() {
    log_step "5. 生成 ISO 文件"

    local rpm_count; rpm_count=$(ls "$PKGS_DIR"/*.rpm 2>/dev/null | wc -l)
    local total_size; total_size=$(du -sh "$ISO_CONTENT" 2>/dev/null | cut -f1)

    log_info "打包内容: ${rpm_count} 个 RPM  |  总大小: ${total_size}"

    cd "$WORK_DIR"
    mkisofs -o "$OUTPUT_ISO" -R -J -V "OS_DALMATIAN" openstack-offline/ 2>/dev/null || {
        log_error "mkisofs 失败，确认 genisoimage 已安装"
        exit 1
    }

    local iso_size; iso_size=$(du -h "$OUTPUT_ISO" | cut -f1)
    log_info "ISO 已生成: ${OUTPUT_ISO} (${iso_size})"
}

# ==================== 6. 清理 ====================
cleanup() {
    log_step "6. 清理临时文件"
    rm -rf "$WORK_DIR"
    log_info "清理完成"
}

# ==================== 主流程 ====================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   OpenStack Dalmatian 离线 ISO 软件源构建脚本               ║"
    echo "║   输出: /root/openstack-dalmatian-offline.iso               ║"
    echo "║   需要: 互联网连接 + root + ~10GB 磁盘                      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    prepare_env
    configure_repos
    download_all_rpms
    create_repo_metadata
    create_iso
    cleanup

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ISO 构建完成!                                             ║"
    echo "║  文件: /root/openstack-dalmatian-offline.iso               ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  使用方式:                                                 ║"
    echo "║    mount /root/openstack-dalmatian-offline.iso /mnt         ║"
    echo "║    创建 /etc/yum.repos.d/openstack-offline.repo:            ║"
    echo "║      [openstack-offline]                                   ║"
    echo "║      name=OpenStack Offline                                ║"
    echo "║      baseurl=file:///mnt/packages                          ║"
    echo "║      enabled=1                                             ║"
    echo "║      gpgcheck=0                                            ║"
    echo "║    dnf clean all && dnf makecache                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

main
