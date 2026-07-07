# proxy.sh

> 多内核代理服务端管理工具 · Alpine Linux / OpenRC 专用

一键安装、配置、管理 sing-box / mihomo 双内核，支持 5 种主流协议，提供交互式 TUI 菜单和命令行模式。

## 特性

- **双内核可切换** — sing-box / mihomo，可同时安装运行，互不干扰
- **五种协议** — Shadowsocks 2022 · Trojan · VLESS+Reality · AnyTLS · Hysteria2
- **数据驱动架构** — 新增协议只需加一个 `case` 分支，无需碰引擎和菜单
- **一键部署** — `install-all` 自动安装全部协议，随机端口 + 自动生成密钥
- **安全可靠** — 配置文件 600 / 目录 700，自动备份 + 失败回滚 + 并发锁

## 协议一览

| 协议 | 加密/传输 | 说明 |
|------|-----------|------|
| Shadowsocks | 2022-blake3-aes-128-gcm | 现代加密，向后兼容 |
| Trojan | TLS 1.3 | 伪装 HTTPS 流量 |
| VLESS + Reality | Reality | 无需域名/证书，SNI 伪装 |
| AnyTLS | TLS 指纹 | 抗主动探测 |
| Hysteria2 | QUIC | 高速，适合弱网环境 |

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
# 一键部署全部 5 个协议（需先通过菜单安装内核）
./proxy.sh install-all
```

## 使用流程

1. **安装内核** — 菜单 `[6]` → 选择 sing-box 或 mihomo
2. **安装协议** — 菜单 `[1]` → 选择协议 → 指定端口（留空随机）→ 自动生成密钥
   - VLESS 安装时可自定义伪装 SNI（默认 `www.speedtest.net`）
3. **查看节点** — 菜单 `[4]` → 输出 URI，导入客户端
4. **修改配置** — 菜单 `[2]` → 可改端口、重新生成密钥
   - SS / Trojan / AnyTLS / Hysteria2：改端口、重新生成密码
   - VLESS：改端口、改 SNI、重新生成 UUID、重新生成 Reality 密钥对
5. **切换内核** — 菜单 `[6]` → sing-box ↔ mihomo，可同时运行

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

- ✅ 内核安装 / 卸载 / 切换（完全删除，零残留）
- ✅ 协议安装 / 修改 / 卸载（自动备份 + 失败回滚）
- ✅ install-all 一键部署 5 协议
- ✅ 自动生成密钥（SS 密码 / Trojan 密码 / VLESS UUID + Reality 密钥对）
- ✅ 节点 URI 输出（`ss://` / `trojan://` / `vless://` / `hysteria2://`）
- ✅ 日志轮转（logrotate）
- ✅ 开机自启（OpenRC rc-update）
- ✅ 并发锁保护
- ✅ 公网 IP 显示（运行期缓存）
- ✅ TLS 自签证书自动生成

## License

MIT
