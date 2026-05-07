# OpenStack CentOS Stream 9 双节点部署脚本

> 🚀 一套完整的 OpenStack 双节点自动化部署脚本，基于 CentOS Stream 9 环境。

## 📋 项目简介

本项目提供了一套完整的 Shell 脚本集合，用于在 **CentOS Stream 9** 上自动化部署 **OpenStack** 双节点集群环境。所有脚本按照 OpenStack 官方文档的安装步骤进行编排，结构清晰、易于定制。

## 🏗️ 架构概览

```
┌─────────────────────────────────────────────────────────┐
│                    双节点架构                              │
├─────────────────────────┬───────────────────────────────┤
│       Controller 节点    │        Compute 节点            │
│  ┌─────────────────────┐ │  ┌─────────────────────────┐  │
│  │ Keystone (身份认证)  │ │  │ Nova Compute (计算)     │  │
│  │ Glance (镜像服务)    │ │  │ Neutron Agent (网络)    │  │
│  │ Placement (资源调度) │ │  │ Cinder Volume (存储)    │  │
│  │ Nova (计算管理)      │ │  └─────────────────────────┘  │
│  │ Neutron (网络管理)   │ │                                │
│  │ Cinder (块存储)      │ │                                │
│  │ Swift (对象存储)     │ │                                │
│  │ Horizon (Web界面)    │ │                                │
│  └─────────────────────┘ │                                │
└─────────────────────────┴───────────────────────────────┘
```

## 📦 脚本列表

### 🎯 主控脚本

| 脚本 | 说明 |
|------|------|
| `openstack_all.sh` | **一键部署主脚本**，按顺序调用所有组件安装脚本 |
| `openstack_verify.sh` | **总体验证脚本**，验证所有组件是否正常工作 |

### 🔧 基础环境

| 脚本 | 说明 |
|------|------|
| `openstack_base_env.sh` | 基础环境配置（网络、NTP、数据库、消息队列、Memcached 等） |

### 🧩 核心组件

| 组件 | 安装脚本 | 验证脚本 |
|------|----------|----------|
| **Keystone** (身份认证) | `openstack_keystone.sh` | `openstack_keystone_verify.sh` |
| **Glance** (镜像服务) | `openstack_glance.sh` | `openstack_glance_verify.sh` |
| **Placement** (资源调度) | `openstack_placement.sh` | `openstack_placement_verify.sh` |
| **Nova** (计算服务) | `openstack_nova.sh` | `openstack_nova_verify.sh` |
| **Neutron** (网络服务) | `openstack_neutron.sh` | `openstack_neutron_verify.sh` |
| **Cinder** (块存储) | `openstack_cinder.sh` | `openstack_cinder_verify.sh` |
| **Swift** (对象存储) | `openstack_swift.sh` | `openstack_swift_verify.sh` |
| **Horizon** (Web 仪表盘) | `openstack_horizon.sh` | `openstack_horizon_verify.sh` |

## 🚀 快速开始

### 前提条件

- **操作系统**: CentOS Stream 9 (两台节点)
- **网络**: 管理网络 +  provider 网络
- **硬件要求**:
  - Controller 节点: 4GB+ RAM, 2 vCPU
  - Compute 节点: 2GB+ RAM, 2 vCPU
- **root 权限**: 所有脚本需以 root 用户执行

### 节点规划

| 节点 | 主机名 | IP 地址 (管理网络) |
|------|--------|---------------------|
| Controller | controller | 10.0.0.11 |
| Compute | compute | 10.0.0.31 |

### 一键部署

```bash
# 1. 将脚本复制到 Controller 节点
scp -r * root@10.0.0.11:/root/openstack/

# 2. 登录 Controller 节点
ssh root@10.0.0.11

# 3. 执行一键部署
cd /root/openstack
chmod +x *.sh
./openstack_all.sh
```

### 分步部署

如果需要分步安装和排错，可以按以下顺序执行：

```bash
# 1. 基础环境配置
./openstack_base_env.sh

# 2. Keystone 身份服务
./openstack_keystone.sh
./openstack_keystone_verify.sh

# 3. Glance 镜像服务
./openstack_glance.sh
./openstack_glance_verify.sh

# 4. Placement 资源调度
./openstack_placement.sh
./openstack_placement_verify.sh

# 5. Nova 计算服务
./openstack_nova.sh
./openstack_nova_verify.sh

# 6. Neutron 网络服务
./openstack_neutron.sh
./openstack_neutron_verify.sh

# 7. Cinder 块存储
./openstack_cinder.sh
./openstack_cinder_verify.sh

# 8. Swift 对象存储 (可选)
./openstack_swift.sh
./openstack_swift_verify.sh

# 9. Horizon Web 仪表盘
./openstack_horizon.sh
./openstack_horizon_verify.sh

# 10. 总体验证
./openstack_verify.sh
```

## 📝 部署顺序

```
openstack_base_env.sh        ← 基础环境（数据库、MQ、缓存等）
        ↓
openstack_keystone.sh        ← 身份认证服务
        ↓
openstack_glance.sh          ← 镜像服务
        ↓
openstack_placement.sh       ← 资源调度服务
        ↓
openstack_nova.sh            ← 计算服务
        ↓
openstack_neutron.sh         ← 网络服务
        ↓
openstack_cinder.sh          ← 块存储服务
        ↓
openstack_swift.sh           ← 对象存储服务（可选）
        ↓
openstack_horizon.sh         ← Web 管理界面
        ↓
openstack_verify.sh          ← 总体验证
```

## ⚙️ 配置说明

所有脚本的变量配置集中在脚本文件头部，主要配置项包括：

- `MANAGEMENT_INTERFACE_IP`: 管理网络 IP
- `PROVIDER_INTERFACE_NAME`: Provider 网络接口名
- `CONTROLLER_HOSTNAME`: Controller 节点主机名
- `COMPUTE_HOSTNAME`: Compute 节点主机名
- 各类密码和 Token

请根据实际环境修改相应配置。

## 🧪 验证

每个组件脚本都配有对应的 `*_verify.sh` 验证脚本，用于检查该组件是否正确安装和运行。最终可通过 `openstack_verify.sh` 进行全面验证。

## 📄 许可证

MIT License

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

---

**⚠️ 注意**: 本脚本集适用于学习和测试环境，生产环境部署请参考 [OpenStack 官方文档](https://docs.openstack.org/)。
