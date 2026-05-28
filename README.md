# 🚀 OpenStack Dalmatian 双节点自动部署

> **一键部署** OpenStack Dalmatian 到 CentOS Stream 9 双节点环境。支持在线/离线双模式、交互/非交互双方式、单模块/全量双粒度。

---

## 📑 目录

- [架构概览](#-架构概览)
- [组件清单](#-组件清单)
- [快速开始](#-快速开始)
- [部署流程](#-部署流程)
- [配置说明](#-配置说明)
- [高级用法](#-高级用法)
- [常见问题](#-常见问题)
- [文件结构](#-文件结构)

---

## 🏗 架构概览

```
                     ┌─────────────────────────────────┐
    互联网 ──────────│       控制节点 (Controller)      │
      │             │  hostname: controller-63          │
      │ 管理网络     │  IP: 192.168.63.10               │
      │             │                                  │
      ▼             │  ┌ Keystone (5000) ─ 身份认证 ─┐ │
  ┌─────────┐       │  ├ Glance   (9292) ─ 镜像服务  ┤ │
  │ 在线模式  │       │  ├ Placement(8778) ─ 资源调度  ┤ │
  └─────────┘       │  ├ Nova     (8774) ─ 计算控制  ┤ │
      │             │  ├ Neutron  (9696) ─ 网络控制  ┤ │
      │ 离线模式     │  ├ Horizon  (80)   ─ Web界面   ┤ │
      ▼             │  ├ Cinder   (8776) ─ 块存储控制┤ │
  ┌─────────┐       │  └ Swift    (8080) ─ 对象代理  ┘ │
  │ ISO离线包│       │                                  │
  └─────────┘       │  基础设施: MariaDB | RabbitMQ     │
                     │           Memcached | Apache     │
                     └───────────┬─────────────────────┘
                                 │ SSH 免密 (管理网络)
                                 │
                     ┌───────────▼─────────────────────┐
                     │      计算/存储节点 (Compute)      │
                     │  hostname: compute-63            │
                     │                                 │
                     │  ┌ Nova-Compute ─ KVM/libvirt ┐  │
                     │  ├ Neutron-OVS-Agent ─ VXLAN  ┤  │
                     │  ├ Cinder-Volume ─ LVM/iSCSI  ┤  │
                     │  └ Swift-Storage ─ XFS/rsync  ┘  │
                     │                                 │
                     │  网络: OVS br-provider           │
                     │        VXLAN 隧道 (br-int/br-tun)│
                     └─────────────────────────────────┘
```

**网络拓扑**：每个节点配置 **双网卡** — 管理网卡(NAT,有默认网关)对外通信 + 内部网卡(Host-only)承载 VXLAN 隧道和内部流量。控制节点 br-provider 可选配置外部 IP，为实例提供外部网络接入。

---

## 🧩 组件清单

### OpenStack 服务

| 序号 | 服务 | 端口 | 功能 | 安装位置 |
|:----:|------|:-----:|------|----------|
| 02 | **Keystone** | 5000 | 身份认证与权限管理 | 控制节点 |
| 03 | **Glance** | 9292 | 虚拟机镜像管理 | 控制节点 |
| 04 | **Placement** | 8778 | 资源调度与跟踪 | 控制节点 |
| 05 | **Nova** | 8774 | 计算服务（虚拟机生命周期） | 控制 + 计算 |
| 06 | **Neutron** | 9696 | 网络服务（VXLAN/OVS） | 控制 + 计算 |
| 07 | **Horizon** | 80 | Web 管理界面 (Dashboard) | 控制节点 |
| 08 | **Cinder** | 8776 | 块存储（LVM/iSCSI） | 控制 + 存储 |
| 09 | **Swift** | 8080 | 对象存储（S3 兼容） | 控制 + 存储 |

### 技术栈

| 类别 | 技术 | 说明 |
|------|------|------|
| 数据库 | MariaDB 10.5+ | 10个数据库，最大连接数500 |
| 消息队列 | RabbitMQ 3.9+ | openstack用户，.*权限 |
| 缓存 | Memcached | Token和Dashboard缓存 |
| Web服务器 | Apache HTTPD + mod_wsgi | Keystone/Placement WSGI |
| 虚拟化 | KVM (硬件加速) / QEMU | 自动检测并fallback |
| 网络 | Open vSwitch + ML2 + VXLAN | br-provider/br-int/br-tun |
| 块存储 | LVM2 + iSCSI (lioadm) | loopback文件或物理磁盘 |
| 对象存储 | Swift (XFS + rsyncd) | Ring冗余 + TempURL |

---

## ⚡ 快速开始

### 在线部署（推荐）

```bash
# 在控制节点以 root 执行
bash <(curl -sSL "https://raw.githubusercontent.com/Townrain/openstack-centos-stream9-dual-node/main/v5/openstack_all.sh")
```

→ 选择 `[A]` 一键部署全部 9 个模块，脚本自动完成所有配置。

> 加 `--keep` 保留脚本到本地：
> ```bash
> bash <(curl -sSL "...") --keep
> ```

### 离线部署（无互联网环境）

**第1步** — 在联网机器上构建离线 ISO：

```bash
bash build-openstack-offline-iso.sh
# 输出: /root/openstack-dalmatian-offline.iso (~600 MB)
```

**第2步** — 将 ISO 复制到控制节点，运行部署：

```bash
bash openstack_all.sh
# 选择 [01] 基础环境 → 选择 [2] 离线部署 → 输入 ISO 路径
# 然后选择 [A] 一键部署全部
```

脚本自动完成：ISO 挂载 → 本地 yum 源配置 → 网络源备份 → 部署全部组件 → **自动恢复网络源**。

### 模块选择

```bash
bash openstack_all.sh
# [01] 基础环境     [04] Placement    [07] Horizon
# [02] Keystone      [05] Nova         [08] Cinder
# [03] Glance        [06] Neutron      [09] Swift
# [A]  一键全部      [V]  验证全部      [Q]  退出
```

### 非交互模式（批量部署）

```bash
NON_INTERACTIVE_ENV=1 bash openstack_all.sh → [A]
```

非交互模式下，所有配置自动从 `/root/openstack_env.conf` 读取，无需人工输入。

---

## 🔄 部署流程

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│ 1.前置检测 │ →  │ 2.环境准备 │ →  │ 3.核心安装 │ →  │ 4.服务启动 │ →  │ 5.结果验证 │
│           │    │           │    │           │    │           │    │           │
│ root权限   │    │ 主机名设置  │    │ MySQL创建  │    │ systemctl  │    │ 100+检查项 │
│ CPU虚拟化  │    │ 双网卡配置  │    │ Keystone   │    │ enable     │    │ 服务状态   │
│ 网络检测   │    │ 防火墙关闭  │    │ 8组件安装  │    │ --now      │    │ API可达性  │
│ SSH连通    │    │ SELinux禁用 │    │ 配置文件    │    │ OVS网桥    │    │ PASS/FAIL  │
│ env.conf   │    │ hosts/仓库  │    │ db_sync    │    │ 开机自启   │    │ 汇总报告   │
└──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
        └── 失败 → 明确报错退出 ──┘                              └── 失败 → 列出重试命令 ──┘
```

### 各模块安装标准流程

每个服务模块遵循统一的 7 步安装模式：

```
MySQL数据库创建 → Keystone用户/服务/端点注册 → dnf安装软件包
→ 配置文件备份+写入 → 数据库同步(db_sync) → systemctl启动 → CLI/curl验证
```

所有操作均为**幂等**——可安全重复执行，已存在的配置自动跳过。配置文件写入使用 `safe_ini_write()` 进行键值级 upsert（crudini + sed 回退），确保密码变更时配置自动更新而非静默跳过。关键状态（Fernet 密钥、cell 映射、compute_id）均有无损检测保护。

---

## ⚙ 配置说明

首次运行 `[01]` 基础环境时，一次性收集全部配置：

| 类别 | 选项 | 默认值 |
|------|------|--------|
| 主机名 | 控制节点/计算节点 hostname | controller-63 / compute-63 |
| 管理网络 | 管理网卡 IP/子网/网关 | 自动检测 |
| 内部网络 | 内部网卡 IP（VXLAN 隧道） | 自动检测 |
| 外部网络 | br-provider 外部 IP | 可选，用于实例外网 |
| 数据库 | MySQL root 密码 | 123456 |
| 管理密码 | admin 密码 (Keystone/Dashboard) | 123456 |
| 服务密码 | 统一密码 或 逐服务独立设置 | 默认统一 |
| Metadata | Metadata 共享密钥 | 自动生成(24位随机) |
| Cinder 存储 | Loopback文件 / 物理磁盘 / 跳过 | Loopback 5GB |
| Swift 存储 | Loopback文件 / 物理磁盘 / 跳过 | Loopback 5GB |

所有配置保存至 `/root/openstack_env.conf`，后续模块和验证脚本自动读取。

---

## 🔧 高级用法

### 环境变量控制

```bash
# 使用自定义仓库/分支
GITHUB_REPO=myuser/myfork GITHUB_REF=dev GITHUB_PATH=v4 \
  bash <(curl -sSL "https://raw.githubusercontent.com/.../openstack_all.sh")
```

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `GITHUB_REPO` | GitHub 仓库 | `Townrain/openstack-centos-stream9-dual-node` |
| `GITHUB_REF` | 分支/标签 | `main` |
| `GITHUB_PATH` | 脚本目录 | `v4` |
| `NON_INTERACTIVE_ENV` | 非交互模式（设为1） | 未设置 |

### 重试失败的模块

```bash
bash openstack_all.sh → 选择对应编号（如 [05] 重试 Nova）
```

### 上传测试镜像

```bash
source /root/admin-openrc
openstack image create "cirros" \
    --file /root/cirros.img \
    --disk-format qcow2 \
    --container-format bare \
    --architecture x86_64 \
    --public
```

### 验证部署

```bash
bash openstack_all.sh → [V]   # 验证全部已部署模块

# 或手动验证
source /root/admin-openrc
openstack compute service list    # Nova 计算服务
openstack network agent list      # Neutron 网络代理
openstack volume service list     # Cinder 块存储
swift stat                        # Swift 对象存储
```

### 非 root 部署支持

所有脚本内置 root 权限检查，非 root 用户执行时自动拒绝并提示，避免权限不足导致的半成品状态。

---

## ❓ 常见问题

<details>
<summary><b>部署失败如何排查？</b></summary>

```bash
# 查看服务日志
journalctl -u <服务名> --no-pager -n 50
tail -100 /var/log/nova/nova-api.log
tail -100 /var/log/neutron/server.log

# 查看部署结果
bash openstack_all.sh → [V]
```
</details>

<details>
<summary><b>如何重新运行失败的模块？</b></summary>

```bash
bash openstack_all.sh → 选择对应编号（如 [05] Nova）
```
所有模块支持幂等重试，已完成的步骤自动跳过。
</details>

<details>
<summary><b>计算节点 OVS 端口 DOWN 怎么办？</b></summary>

```bash
# 在计算节点执行
ip link set <内部网卡> up
systemctl restart neutron-openvswitch-agent openstack-nova-compute
```
</details>

<details>
<summary><b>Horizon 上传镜像后创建实例失败？</b></summary>

需设置镜像架构属性：
```bash
source /root/admin-openrc
openstack image set --architecture x86_64 <镜像名>
```
</details>

<details>
<summary><b>离线部署时 ssh 报 OpenSSL version mismatch？</b></summary>

ISO 构建时已包含匹配的 `openssh-clients`。若使用旧 ISO 出现该错误，重启后即可恢复。
</details>

<details>
<summary><b>离线部署完成后网络源未恢复？</b></summary>

脚本在全部模块部署完成后**自动**调用 `restore_network_repos` 恢复原始仓库。如未自动恢复：
```bash
source /root/openstack_common.sh && restore_network_repos
```
</details>

---

## 📂 文件结构

```
📦 openstack/
├── 📜 openstack_all.sh                # 总控脚本（支持 curl 管道自举）
├── 📜 openstack_common.sh             # 公共库（日志、网络检测、离线管理、验证框架、幂等安全写入、统一清理）
│
├── 安装脚本（每模块含验证）
│   ├── 📜 openstack_base_env.sh       # [01] 基础环境（双节点配置 + SSH远程）
│   ├── 📜 openstack_keystone.sh       # [02] Keystone — 身份认证 (5000)
│   ├── 📜 openstack_glance.sh         # [03] Glance   — 镜像服务 (9292)
│   ├── 📜 openstack_placement.sh      # [04] Placement— 资源调度 (8778)
│   ├── 📜 openstack_nova.sh           # [05] Nova     — 计算服务 (8774)
│   ├── 📜 openstack_neutron.sh        # [06] Neutron  — 网络服务 (9696)
│   ├── 📜 openstack_horizon.sh        # [07] Horizon  — Web界面 (80)
│   ├── 📜 openstack_cinder.sh         # [08] Cinder   — 块存储 (8776)
│   └── 📜 openstack_swift.sh          # [09] Swift    — 对象存储 (8080)
│
├── 验证脚本
│   ├── 📜 openstack_verify.sh         # 基础环境验证（12类检查）
│   ├── 📜 openstack_keystone_verify.sh # Keystone 验证（10类检查）
│   ├── 📜 openstack_nova_verify.sh    # Nova 验证（7类检查）
│   ├── 📜 openstack_neutron_verify.sh # Neutron 验证（9类检查）
│   ├── 📜 openstack_glance_verify.sh
│   ├── 📜 openstack_placement_verify.sh
│   ├── 📜 openstack_horizon_verify.sh
│   ├── 📜 openstack_cinder_verify.sh
│   └── 📜 openstack_swift_verify.sh
│
├── 🛠  build-openstack-offline-iso.sh  # 离线 ISO 构建（60+包+全量依赖）
├── 💿 cirros.img                      # 测试镜像
├── 📖 README.md
```

**代码量**: ~6500 行 Shell | **配置项**: 30+ | **检查点**: 100+ | **支持8大OpenStack核心组件**

---

> 📌 **项目地址**: [Townrain/openstack-centos-stream9-dual-node](https://github.com/Townrain/openstack-centos-stream9-dual-node)
