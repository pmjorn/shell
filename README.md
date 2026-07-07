# proxy.sh

> 多内核代理服务端管理工具 · Alpine Linux / OpenRC 专用

一键安装、配置、管理 sing-box / mihomo 双内核，支持 5 种主流协议，提供交互式 TUI 菜单和命令行模式。

## 特性

### 🔄 双内核支持（可切换）
- **sing-box** — SagerNet 出品
- **mihomo** — MetaCubeX 出品（原 Clash.Meta）
- 两个内核可同时安装运行，互不干扰，随时切换管理

### 📡 五种协议
| 协议 | 说明 |
|------|------|
| Shadowsocks | 2022-blake3-aes-128-gcm |
| Trojan | TLS 加密代理 |
| VLESS + Reality | 无需域名/证书，Reality 伪装 |
| AnyTLS | TLS 指纹代理 |
| Hysteria2 | 基于 QUIC 的高速协议 |

### 🏗️ 架构
采用**数据驱动的协议引擎**架构，协议层与内核实现完全解耦：

```
§0  常量定义
§1  输出 & 交互
§2  通用工具
§3  内核调度层（KERNEL=sb|mh，统一分发）
§4  sing-box 内核实现
§5  mihomo 内核实现
§6  协议元数据（路径 / 显示名 / 传输层）
§7  协议数据钩子（各协议差异化逻辑）
§8  通用引擎（安装 / 配置 / 卸载，5 协议共用）
§9  菜单（数据驱动，遍历 PROTO_IDS 生成）
§10 入口
```

新增协议只需在 §6/§7 的 `case` 里加一个分支，无需碰引擎和菜单代码。

## 快速开始

### 环境要求
- Alpine Linux (aarch64 / x86_64)
- OpenRC init 系统
- root 权限

### 安装

```bash
# 下载到 VPS
wget -O proxy.sh https://raw.githubusercontent.com/pmjorn/shell/main/proxy.sh
chmod +x proxy.sh

# 交互式运行
./proxy.sh

# 一键安装全部协议（需先通过菜单安装内核）
./proxy.sh install-all
```

### 使用流程

1. **安装内核** — 菜单 `[6]` → 选择 sing-box 或 mihomo
2. **安装协议** — 菜单 `[1]` → 选择协议 → 指定端口 → 自动生成密钥
3. **查看节点** — 安装完成后自动输出 URI，可导入客户端
4. **修改配置** — 菜单 `[2]` → 改端口 / 重新生成密码
5. **切换内核** — 菜单 `[6]` → 切换 sing-box ↔ mihomo

## 功能清单

- ✅ 内核安装 / 卸载 / 切换（完全删除，无残留）
- ✅ 协议安装 / 配置修改 / 卸载（自动备份 + 失败回滚）
- ✅ install-all 一键部署全部 5 个协议
- ✅ 自动生成密钥（SS 密码 / Trojan 密码 / VLESS UUID + Reality 密钥对）
- ✅ 节点 URI 输出（ss:// / trojan:// / vless:// / hysteria2://）
- ✅ 日志轮转配置（logrotate）
- ✅ 开机自启（OpenRC rc-update）
- ✅ 并发锁保护（防止多实例冲突）
- ✅ 公网 IP 显示（运行期缓存，不重复请求）
- ✅ TLS 自签证书自动生成（Trojan / AnyTLS / Hysteria2）

## 技术细节

- **Shell**: BusyBox ash（POSIX 兼容）
- **加密**: SS-2022 / Reality / TLS 1.3
- **端口**: 支持自定义端口，默认随机分配
- **权限**: 配置文件 600，目录 700

## License

MIT
