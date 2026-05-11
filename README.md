# OpenStack Dalmatian 双节点自动部署

基于 CentOS Stream 9 的 OpenStack Dalmatian 双节点一键部署脚本，支持在线/离线两种模式，交互式和非交互式两种方式。

## 一键部署（在线模式）

```bash
bash <(curl -sSL "https://raw.githubusercontent.com/Townrain/openstack-centos-stream9-dual-node/main/v3/openstack_all.sh")
```

> 脚本自动从 GitHub 拉取全部依赖脚本到 `/root/`，然后启动一键部署。首次运行会自动下载，后续运行跳过已存在的脚本。

## 离线部署

适用于无互联网环境。先在联网机器上构建离线 ISO，再传入目标环境部署。

### 1. 构建离线 ISO

在任意已配置 OpenStack Dalmatian 仓库的 CentOS Stream 9 机器上：

```bash
bash build-openstack-offline-iso.sh
```

输出 `/root/openstack-dalmatian-offline.iso`（约 600 MB）。需联网 + root + ~10 GB 磁盘。

> ISO 含完整依赖（openssl、openssh、glibc 等），确保目标系统更新后 ssh 仍可用。

### 2. 部署

将 ISO 传入控制节点 `/root/`，运行一键脚本：

```bash
bash openstack_all.sh → [A]
```

首个模块选择 `[2] 离线部署`，输入 ISO 路径。脚本自动：
- 挂载 ISO 并配置本地 yum 仓库
- 备份并禁用外部网络源
- 同步系统包（glibc/openssl/openssh 等）
- 部署全部 OpenStack 组件
- **部署完成后自动恢复网络源**

## 配置选项

首次运行 `[A]` 或 `[01]` 基础环境时，会一次性收集以下配置：

| 类别 | 选项 |
|------|------|
| 主机名 | 控制节点/计算节点 hostname |
| 网络 | 管理网卡 IP/网关、内部网卡 IP（自动检测） |
| 数据库 | MySQL root 密码 |
| 管理密码 | admin 密码 (Keystone/Dashboard 登录) |
| 服务密码 | 可选统一密码或逐服务单独设置 |
| Metadata | 自动生成随机密钥 |
| Cinder | Loopback 大小 / 物理磁盘路径 / 跳过 |
| Swift | Loopback 大小 / 物理磁盘路径 / 跳过 |

所有配置保存至 `/root/openstack_env.conf`，后续模块自动读取。

## 自定义仓库

通过环境变量指定其他分支或仓库：

```bash
GITHUB_REPO=myuser/myfork GITHUB_REF=dev GITHUB_PATH=v3 bash <(curl -sSL "https://raw.githubusercontent.com/Townrain/openstack-centos-stream9-dual-node/main/v3/openstack_all.sh")
```

## 镜像上传

部署完成后上传测试镜像：

```bash
source /root/admin-openrc
openstack image create "cirros" \
    --file /path/to/cirros-0.6.3-x86_64-disk.img \
    --disk-format qcow2 \
    --container-format bare \
    --architecture x86_64 \
    --public
```

## 常见问题

**Q: 部署失败如何查看日志？**

```bash
journalctl -u <服务名> --no-pager -n 50
tail -100 /var/log/nova/nova-api.log
tail -100 /var/log/neutron/server.log
```

**Q: 如何重新运行失败的模块？**

```bash
bash openstack_all.sh → 选择对应编号
```

**Q: 计算节点 OVS 端口 DOWN？**

```bash
# 在计算节点执行
ip link set <内部网卡> up
systemctl restart neutron-openvswitch-agent openstack-nova-compute
```

**Q: Horizon 上传镜像后创建实例失败？**

需设置镜像架构属性：
```bash
source /root/admin-openrc
openstack image set --architecture x86_64 <镜像名>
```

**Q: 离线部署时 ssh 报 `OpenSSL version mismatch`？**

ISO 构建时已包含匹配的 `openssh-clients`，`dnf update` 同步系统后 ssh 应正常。若使用旧 ISO 出现该错误，重启后即可恢复。

**Q: 离线部署完成后网络源未恢复？**

脚本在全部模块部署完成后会自动调用 `restore_network_repos` 恢复 `/etc/yum.repos.d.backup/` 中的原始仓库。如未自动恢复，手动执行：
```bash
source /root/openstack_common.sh && restore_network_repos
```

## 文件说明

```
openstack_all.sh              # 总控脚本（支持 curl 管道自举）
openstack_common.sh           # 公共库（颜色、日志、工具函数、离线仓库/恢复）
openstack_base_env.sh         # 基础环境准备（在线/离线双模式）
openstack_verify.sh           # 基础环境验证（离线模式自动跳过不适用的检查）
openstack_keystone.sh         # Keystone 安装
openstack_keystone_verify.sh  # Keystone 验证
openstack_glance.sh           # Glance 安装
openstack_glance_verify.sh    # Glance 验证
openstack_placement.sh        # Placement 安装
openstack_placement_verify.sh # Placement 验证
openstack_nova.sh             # Nova 安装（控制+计算节点）
openstack_nova_verify.sh      # Nova 验证
openstack_neutron.sh          # Neutron 安装（控制+计算节点）
openstack_neutron_verify.sh   # Neutron 验证
openstack_horizon.sh          # Horizon 安装
openstack_horizon_verify.sh   # Horizon 验证
openstack_cinder.sh           # Cinder 安装（控制+存储节点）
openstack_cinder_verify.sh    # Cinder 验证
openstack_swift.sh            # Swift 安装（控制+存储节点）
openstack_swift_verify.sh     # Swift 验证
build-openstack-offline-iso.sh # 离线 ISO 构建脚本
README.md                     # 本文件
```
