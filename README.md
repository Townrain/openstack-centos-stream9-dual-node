# OpenStack Dalmatian 双节点自动部署

基于 CentOS Stream 9 的 OpenStack Dalmatian 双节点一键部署脚本，支持交互式和非交互式两种模式。

## 一键部署

```bash
bash <(curl -sSL https://raw.githubusercontent.com/Townrain/openstack-centos-stream9-dual-node/main/centosstream9双节点v2/openstack_all.sh)
```

> 运行后选择 `[A]` 一键部署全部，第一个模块会交互式收集所有配置（密码、网络、存储），后续模块自动运行。

### 保留下载的脚本

```bash
bash <(curl -sSL ...) --keep
```

## 架构

| 节点 | 角色 | 网卡 |
|------|------|------|
| controller-63 | 控制节点（全部管理服务） | 管理(NAT) + 内部(Host-only) |
| compute-63 | 计算+存储节点 | 管理(NAT) + 内部(Host-only) |

## 部署组件

| 序号 | 模块 | 端口 | 说明 |
|------|------|------|------|
| 01 | 基础环境 | — | 网络配置、SSH 免密、仓库、SELinux/防火墙 |
| 02 | Keystone | 5000 | 身份认证服务 |
| 03 | Glance | 9292 | 镜像服务 |
| 04 | Placement | 8778 | 资源布局服务 |
| 05 | Nova | 8774 | 计算服务 (控制节点 + 远程配置计算节点) |
| 06 | Neutron | 9696 | 网络服务 (ML2/OVS/VXLAN) |
| 07 | Horizon | 80/dashboard | Web 管理界面 |
| 08 | Cinder | 8776 | 块存储 (支持 Loopback / 物理磁盘) |
| 09 | Swift | 8080 | 对象存储 (支持 Loopback / 物理磁盘) |

## 环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | CentOS Stream 9 (最小化安装) |
| 控制节点 | 4 vCPU, 8 GB RAM, 50 GB 磁盘 |
| 计算节点 | 4 vCPU, 8 GB RAM, 50 GB 磁盘 |
| 网络 | 2 张网卡（NAT + Host-only） |
| 虚拟化 | Intel VT-x 或 AMD-V 已开启 |
| 用户 | root |

## 使用方式

### 交互模式（单模块）

```bash
bash openstack_all.sh
# 选择对应编号单独部署某模块，如 [02] Keystone
```

### 非交互模式（已有 openstack_env.conf）

```bash
bash openstack_keystone.sh --non-interactive
```

### 验证全部

```bash
bash openstack_all.sh → 选择 [V]
```

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
GITHUB_REPO=myuser/myfork GITHUB_REF=dev GITHUB_PATH=scripts bash <(curl -sSL ...)
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

## 文件说明

```
openstack_all.sh              # 总控脚本（支持 curl 管道自举）
openstack_common.sh           # 公共库（颜色、日志、工具函数）
openstack_base_env.sh         # 基础环境准备
openstack_verify.sh           # 基础环境验证
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
README.md                     # 本文件
```
