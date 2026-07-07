# proxy.sh

> 多内核代理服务端管理工具 · Alpine Linux / OpenRC 专用

一键安装、配置、管理 sing-box / mihomo 双内核，支持 5 种协议，提供交互式 CLI 菜单和命令行模式。

## 特性

- **双内核可切换** — sing-box / mihomo，可同时安装运行，互不干扰
- **五种协议** — Shadowsocks 2022 · Trojan · VLESS+Reality · AnyTLS · Hysteria2
- **数据驱动架构** — 新增协议在元数据和钩子函数的 `case` 中添加分支即可
- **一键部署** — `install-all` 随机端口 + 自动生成密钥，一次装完全部协议
- **安全可靠** — 配置文件 600 / 目录 700，自动备份 + 失败回滚 + 并发锁

## 协议一览

| 协议 | 加密/传输 | TLS | SNI 可自定义 |
|------|-----------|-----|:------------:|
| Shadowsocks 2022 | 2022-blake3-aes-128-gcm | — | — |
| Trojan | TCP | 自签证书（CN: www.bing.com） | ✗ |
| VLESS + Reality | TCP | Reality 握手伪装 | ✓ |
| AnyTLS | TCP | 自签证书（CN: www.bing.com） | ✗ |
| Hysteria2 | UDP（QUIC） | 自签证书（CN: www.bing.com） | ✗ |

> VLESS+Reality 借用目标网站的 TLS 握手做流量伪装，用户无需拥有域名或申请证书。
> 其余协议使用自签证书，客户端需开启 `allowInsecure` / `insecure` 跳过验证。

## 快速开始

### 环境要求

- Alpine Linux（aarch64 / x86_64）
- OpenRC init 系统
- root 权限

### 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/pmjorn/shell/main/proxy.sh -o proxy.sh && chmod +x proxy.sh && ./proxy.sh
```

### 命令行模式

```bash
# 一键部署全部 5 个协议（需先通过菜单 [6] 安装内核）
./proxy.sh install-all
```

## 使用流程

### 主菜单

```
[1]-[5]  协议管理（Shadowsocks / Trojan / VLESS / AnyTLS / Hysteria2）
[6]      安装 / 切换内核（sing-box ↔ mihomo）
[7]      更新内核
[8]      重启服务
[9]      查看全部节点信息
[0]      退出
```

### 协议子菜单（选择某协议后进入）

```
[1]  安装 / 重装    →  指定端口（留空随机）→ 自动生成密钥
[2]  配置修改      →  见下方可改项
[3]  查看节点信息  →  输出 URI，导入客户端
[4]  卸载
[0]  返回
```

### 配置修改可选项

| 协议 | 可修改项 |
|------|---------|
| Shadowsocks | 端口、重新生成密码 |
| Trojan | 端口、重新生成密码 |
| AnyTLS | 端口、重新生成密码 |
| Hysteria2 | 端口、重新生成密码 |
| VLESS + Reality | 端口、改 SNI、重新生成 UUID、重新生成 Reality 密钥对 |

## 架构

```
§0  常量
§1  输出 & 交互
§2  通用工具
§3  内核调度层    KERNEL=sb|mh，统一分发
§4  sing-box 实现  cfg/read，json schema
§5  mihomo 实现    cfg/read，yaml 合成
§6  协议元数据    路径 / 显示名 / 传输层
§7  协议数据钩子  各协议差异化逻辑（case 分发）
§8  通用引擎      install / configure / uninstall
§9  菜单          遍历 PROTO_IDS 数据驱动生成
§10 入口
```

协议层不感知内核差异——`proto_write_cfg` 只做一行分发 `"${KERNEL}_cfg_${id}"`，json/yaml 的 schema 细节完全下沉到 §4/§5 的内核实现层。

## 功能清单

- 内核安装 / 卸载 / 切换（完全删除，零残留）
- 协议安装 / 修改 / 卸载（自动备份 + 失败回滚）
- install-all 一键部署 5 协议（随机端口 + 自动生成密钥）
- 节点 URI 输出（`shadowsocks://` / `trojan://` / `vless://` / `anytls://` / `hysteria2://`）
- 日志轮转（logrotate）
- 开机自启（OpenRC rc-update）
- 并发锁保护（`/var/run/proxy.sh.lock`）
- 公网 IP 显示（运行期缓存，不重复请求）
- TLS 自签证书自动生成（EC prime256v1，有效期 3650 天）
- 文件权限基线（配置 600 / 目录 700）
