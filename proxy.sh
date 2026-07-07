#!/bin/sh
# shellcheck disable=SC2059
# proxy.sh · 多内核代理服务端管理工具 · 支持 Alpine Linux(OpenRC) 与 Debian/Ubuntu(systemd)
#   内核：sing-box / mihomo（可切换，二选一管理；可同时安装，但同一时间只保留激活的
#   那个真正运行，切换时自动停止/启动对应服务，避免双份常驻占用内存）
#   协议：Shadowsocks(2022) · Trojan · VLESS+Reality · AnyTLS · Hysteria2 · Snell
#
#   架构：协议层不再为每个协议手写 install/configure/uninstall，而是由
#   §7 的通用引擎（proto_install/proto_configure/proto_uninstall）驱动；
#   每个协议只需在 §8 的若干"钩子函数"里用 case "$id" 分支提供自己的
#   差异化数据（json 结构/URI 格式/展示字段），架构和内核细节完全解耦。
#
#   Snell：sing-box(1.14.0-alpha 原生 inbound) 与 mihomo(官方稳定原生 listener) 均已原生支持，
#   与其余 5 个协议一样纳入 §7/§8 的通用引擎，无特判分支。两边字段均已对照官方文档核实
#   （sing-box: sing-box.sagernet.org/configuration/inbound/snell/；
#     mihomo: wiki.metacubex.one/en/config/inbound/listeners/snell/）。
#
#   系统适配：包管理器(apk/apt)、服务管理(OpenRC/systemd) 均已抽象为
#   ensure_pkgs() / svc_*() 系列函数，§0 顶部 detect_os 探测结果决定行为。

###############################################################################
# §0  系统探测（必须在其余常量之前执行，因部分路径常量依赖 $OS_FAMILY）
###############################################################################
OS_FAMILY=""
detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS_FAMILY="alpine"
    elif [ -f /etc/debian_version ]; then
        OS_FAMILY="debian"
    else
        printf "\n  \033[0;38;2;244;54;6m✗ 不支持的系统：仅支持 Alpine Linux 或 Debian/Ubuntu（未检测到 /etc/alpine-release 或 /etc/debian_version）\033[0m\n" >&2
        exit 1
    fi
}
detect_os

###############################################################################
# §0  常量
###############################################################################
# ── 服务文件路径：OpenRC(Alpine) 用 /etc/init.d 脚本，systemd(Debian) 用 .service 单元 ──
if [ "$OS_FAMILY" = "debian" ]; then
    readonly SB_INIT="/etc/systemd/system/sing-box.service"
    readonly MH_INIT="/etc/systemd/system/mihomo.service"
else
    readonly SB_INIT="/etc/init.d/sing-box"
    readonly MH_INIT="/etc/init.d/mihomo"
fi

# ── sing-box 内核 ──
readonly SB_BIN="/usr/local/bin/sing-box"
readonly SB_DIR="/etc/sing-box"
readonly SB_INFO_DIR="${SB_DIR}/info"
readonly SB_CERT="${SB_DIR}/cert.pem"
readonly SB_KEY="${SB_DIR}/private.key"
readonly SB_SVC="sing-box"
readonly SB_LOG="/var/log/sing-box.log"
readonly SB_LOGROTATE="/etc/logrotate.d/sing-box"
readonly SB_API="https://api.github.com/repos/SagerNet/sing-box/releases"
readonly LOG_JSON="${SB_DIR}/00-log.json"

# ── mihomo 内核 ──
readonly MH_BIN="/usr/local/bin/mihomo"
readonly MH_DIR="/etc/mihomo"
readonly MH_FRAG_DIR="${MH_DIR}/fragments"
readonly MH_INFO_DIR="${MH_DIR}/info"
readonly MH_YAML="${MH_DIR}/config.yaml"
readonly MH_CERT="${MH_DIR}/cert.pem"
readonly MH_KEY="${MH_DIR}/private.key"
readonly MH_SVC="mihomo"
readonly MH_LOG="/var/log/mihomo.log"
readonly MH_LOGROTATE="/etc/logrotate.d/mihomo"
readonly MH_API="https://api.github.com/repos/MetaCubeX/mihomo/releases"

# ── 通用 ──
readonly DEFAULT_SNI="www.speedtest.net"
readonly DEFAULT_CERT_CN="www.bing.com"
readonly SS_METHOD="2022-blake3-aes-128-gcm"
readonly KERNEL_STATE="/etc/proxy-kernel.conf"
readonly LOCK_FILE="/var/run/proxy.sh.lock"
readonly PROTO_IDS="ss tj vl at hy sn"

# ── ACME 真实域名证书（可选，供 tj/at/hy 三个基于 TLS 的协议使用；不启用则沿用默认自签证书）──
readonly ACME_DIR="/etc/proxy-acme"
readonly ACME_BIN="/root/.acme.sh/acme.sh"

# ── 配置备份 ──
readonly BACKUP_DIR_DEFAULT="/root"

# ── 脚本自更新 ──
readonly SELF_UPDATE_URL="https://raw.githubusercontent.com/pmjorn/shell/refs/heads/main/proxy.sh"

# ── ANSI（三色方案：R/Y 是功能语义色，其余 C/D/W/K 目前共用同一主题绿 G，
#     保留各自变量名是为了在调用点表达语义（强调/装饰/标签/键名），并非真的四种颜色，
#     故只在此处定义一次颜色值，其余通过赋值复用，避免同一转义序列重复书写 5 遍）──
R='\033[0;38;2;244;54;6m' Y='\033[0;38;2;156;125;33m' G='\033[0;38;2;31;147;89m'
C="$G" D="$G" W="$G" K="$G"
B='\033[1m' N='\033[0m'

###############################################################################
# §1  输出 & 交互
###############################################################################
die()  { printf "\n  ${R}✗ %s${N}\n" "$*" >&2; exit 1; }
warn() { printf "  ${Y}⚠ %s${N}\n" "$*" >&2; }
info() { printf "  ${C}! %s${N}\n" "$*" >&2; }
ok()   { printf "  ${G}✓ %s${N}\n" "$*"; }
hr()   { printf "${K}  ──────────────────────────────────────────────${N}\n"; }

confirm() {
    local msg="$1" def="${2:-no}" ans hint
    [ "$def" = "yes" ] && hint="${B}yes${N}/no" || hint="yes/${B}no${N}"
    while true; do
        printf "${Y}  %s${N} [%b]: " "$msg" "$hint"
        read -r ans || die "输入流已结束（EOF），无法继续交互"
        [ -z "$ans" ] && ans="$def"
        case "$ans" in
            yes) return 0 ;;
            no)  return 1 ;;
            *)   warn "请输入 yes 或 no" ;;
        esac
    done
}

ask() {
    local msg="$1" def="$2"
    if [ -n "$def" ]; then
        printf "${C}  %s${N}  ${K}[%s]${N}: " "$msg" "$def"
    else
        printf "${C}  %s${N}: " "$msg"
    fi
    read -r REPLY || die "输入流已结束（EOF），无法继续交互"
    [ -z "$REPLY" ] && REPLY="$def"
}

_st=0; _st_n=0
steps_init() { _st_n="$1"; _st=0; }
step() { _st=$((_st+1)); printf "  ${C}[%d/%d]${N} %s\n" "$_st" "$_st_n" "$1"; }

_box() {
    printf "\n"
    if [ -n "$2" ]; then
        printf "  ${C}╭───${N} ${W}${B}%s${N}  ${K}%s${N}\n" "$1" "$2"
    else
        printf "  ${C}╭───${N} ${W}${B}%s${N}\n" "$1"
    fi
}
_kv() { printf "    ${K}%s${N}   %s\n" "$1" "$2"; }
# $1=端口 $2=协议(tcp/udp)：提示云厂商安全组/防火墙可能需要放行
_fw_hint() {
    warn "若云厂商配置了安全组/防火墙（如阿里云/腾讯云/AWS 等），需自行放行 ${2:-tcp} 端口 $1，否则客户端无法连接"
}

###############################################################################
# §2  通用工具
###############################################################################
check_root()   { [ "$(id -u)" = "0" ] || die "请以 root 权限运行此脚本（sudo -i 或直接切换到 root 用户后重试）"; }
check_arch()   {
    case "$(uname -m)" in
        aarch64|x86_64|amd64) ;;
        *) die "不支持的系统架构: $(uname -m)（仅支持 x86_64 / aarch64）" ;;
    esac
}
# 内核发行包命名用的架构标识，sing-box / mihomo 下载函数共用（原来两内核各有一份完全相同的实现）
_bin_arch() {
    case "$(uname -m)" in
        aarch64) echo "arm64" ;;
        x86_64|amd64) echo "amd64" ;;
        *) die "不支持的系统架构: $(uname -m)" ;;
    esac
}

# yq（mikefarah 版，用于 mihomo 的 json→yaml 转换）：Alpine 有 apk 包 yq-go；
# Debian/Ubuntu 官方仓库没有对应包（apt 的 yq 是不兼容的 python-yq），改为直接下载静态二进制。
# 全程显式记录验证过的可执行文件绝对路径到 $YQ_BIN，后续一律用 "$YQ_BIN" 调用而不是裸 `yq`，
# 避免系统 PATH 里可能存在的另一个同名但不兼容的 yq（如 python-yq）抢先被解析到、
# 传入 -p/-o 这类 mikefarah 专属参数后行为异常甚至卡死
YQ_BIN=""
ensure_yq() {
    if command -v yq > /dev/null 2>&1; then
        local existing; existing=$(command -v yq)
        if "$existing" --version 2>/dev/null | grep -qi mikefarah; then
            YQ_BIN="$existing"; return 0
        fi
    fi
    if [ "$OS_FAMILY" = "alpine" ]; then
        apk info -e yq-go > /dev/null 2>&1 || {
            apk update -q > /dev/null 2>&1 || true
            apk add -q yq-go > /dev/null 2>&1 || die "安装 yq-go 失败（请检查 apk 仓库源是否可访问）"
        }
        YQ_BIN=$(command -v yq) || die "yq-go 安装后仍未找到 yq 可执行文件，请检查 apk 包是否正常安装"
    else
        local arch
        case "$(uname -m)" in aarch64) arch=arm64 ;; x86_64|amd64) arch=amd64 ;; *) die "不支持的系统架构: $(uname -m)" ;; esac
        curl -fLs --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 \
            -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
            || die "下载 yq 失败，请检查网络"
        chmod +x /usr/local/bin/yq
        YQ_BIN="/usr/local/bin/yq"
    fi
}

# 统一包安装入口：按 $OS_FAMILY 分发到 apk 或 apt；调用方无需关心具体发行版
ensure_pkgs() {
    [ "$OS_FAMILY" = "debian" ] && { _ensure_pkgs_apt "$@"; return; }
    _ensure_pkgs_apk "$@"
}
_ensure_pkgs_apk() {
    local pkgs="" p
    for p in "$@"; do
        [ "$p" = "yq-go" ] && { ensure_yq; continue; }
        pkgs="$pkgs $p"
    done
    [ -z "$pkgs" ] && return 0
    # 一次性批量检查是否已全部安装（成功则直接跳过，不产生任何网络请求）；
    # 只有确实缺失时才 fork apk update/add，此时顺带把已装的也带上，无害且省去逐个精确定位缺失项的开销
    # shellcheck disable=SC2086
    apk info -e $pkgs > /dev/null 2>&1 && return 0
    apk update -q > /dev/null 2>&1 || true
    # shellcheck disable=SC2086
    apk add -q $pkgs > /dev/null 2>&1 || die "安装依赖失败：${pkgs}（请检查 apk 仓库源是否可访问，或手动执行 apk add${pkgs} 查看详细报错）"
}
_ensure_pkgs_apt() {
    local pkgs="" p
    for p in "$@"; do
        case "$p" in
            yq-go) ensure_yq; continue ;;
        esac
        pkgs="$pkgs $p"
    done
    [ -z "$pkgs" ] && return 0
    # shellcheck disable=SC2086
    dpkg -s $pkgs > /dev/null 2>&1 && return 0
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq > /dev/null 2>&1 || true
    # shellcheck disable=SC2086
    apt-get install -y -qq $pkgs > /dev/null 2>&1 || die "安装依赖失败：${pkgs}（请检查 apt 仓库源是否可访问，或手动执行 apt-get install${pkgs} 查看详细报错）"
}

###############################################################################
# §2b  服务管理抽象层（OpenRC(Alpine) 用 rc-service/rc-update，systemd(Debian) 用 systemctl）
#      统一封装后，§4/§5 的业务逻辑无需再关心具体发行版
###############################################################################
# 调用 rc-service 时须在子 shell 里关闭锁 fd（9），否则 supervise-daemon 会继承并永久占用该 fd；
# systemctl 无此问题，但为保持行为一致仍统一走子 shell
# stop/restart/reload 三个动作对 systemctl/rc-service 的分发逻辑完全一致，统一到一处；
# 子 shell 内关闭锁 fd(9) 避免 supervise-daemon(OpenRC) 继承并永久占用该 fd
_svc_action() {
    local action="$1" svc="$2"
    if [ "$OS_FAMILY" = "debian" ]; then
        (exec 9>&-; timeout 15 systemctl "$action" "$svc" > /dev/null 2>&1)
    else
        (exec 9>&-; timeout 15 rc-service "$svc" "$action" > /dev/null 2>&1)
    fi
}
svc_stop()    { _svc_action stop    "$1"; }
svc_restart() { _svc_action restart "$1"; }
svc_reload()  { _svc_action reload  "$1"; }
svc_is_active() {
    if [ "$OS_FAMILY" = "debian" ]; then timeout 10 systemctl is-active --quiet "$1"
    else timeout 10 rc-service "$1" status 2>/dev/null | grep -q started; fi
}
svc_enable()  { if [ "$OS_FAMILY" = "debian" ]; then timeout 10 systemctl enable "$1" > /dev/null 2>&1 || true; else timeout 10 rc-update add "$1" default > /dev/null 2>&1 || true; fi; }
svc_disable() { if [ "$OS_FAMILY" = "debian" ]; then timeout 10 systemctl disable "$1" > /dev/null 2>&1 || true; else timeout 10 rc-update del "$1" default > /dev/null 2>&1 || true; fi; }
svc_daemon_reload() { [ "$OS_FAMILY" = "debian" ] && timeout 10 systemctl daemon-reload > /dev/null 2>&1; return 0; }
# 通用"等待服务就绪"轮询，供 sb_restart/mh_restart 共用
_svc_wait_ready() {
    local i=0
    printf "${C}  等待服务启动${N}"
    while [ $i -lt 10 ]; do
        svc_is_active "$1" && { printf " ${G}就绪${N}\n"; return 0; }
        printf "${C}.${N}"; sleep 1; i=$((i+1))
    done
    printf " ${Y}超时${N}\n"; return 1
}

# 单次 jq 调用取 2/3/5 个字段（jq 内部用 join("|") 拼成一行，避免每个字段各 fork 一次
# jq 子进程）。用 "|" 而非空格/制表符/换行做分隔，因为后者属于 IFS 的"空白类"字符，
# 连续出现时会被 shell 自动折叠、丢失空字段；"|" 是普通 IFS 字符，能正确保留空字段。
# 结果写入 JP1..JPn，调用方需在函数内立即取走（无重入/递归调用，全局变量足够安全）。
_jq_pipe2() {
    local f="$1" line oldifs
    line=$(jq -r "[$2, $3] | join(\"|\")" "$f")
    oldifs="$IFS"; IFS='|'; set -- $line; IFS="$oldifs"
    JP1="$1"; JP2="$2"
}
_jq_pipe3() {
    local f="$1" line oldifs
    line=$(jq -r "[$2, $3, $4] | join(\"|\")" "$f")
    oldifs="$IFS"; IFS='|'; set -- $line; IFS="$oldifs"
    JP1="$1"; JP2="$2"; JP3="$3"
}
_jq_pipe5() {
    local f="$1" line oldifs
    line=$(jq -r "[$2, $3, $4, $5, $6] | join(\"|\")" "$f")
    oldifs="$IFS"; IFS='|'; set -- $line; IFS="$oldifs"
    JP1="$1"; JP2="$2"; JP3="$3"; JP4="$4"; JP5="$5"
}

fetch_public_ip() {
    local trace
    trace=$(curl -s --connect-timeout 5 --max-time 10 "https://www.cloudflare.com/cdn-cgi/trace")
    PUB_IP=$(echo "$trace" | grep '^ip=' | sed 's/^ip=//' | tr -d '[:space:]')
    if [ -z "$PUB_IP" ]; then
        PUB_IP=$(curl -s --connect-timeout 5 --max-time 10 "https://api.ipify.org" | tr -d '[:space:]')
    fi
    PUB_IP="${PUB_IP:-未知}"
}
# 菜单显示用：脚本运行期内只请求一次公网 IP 并缓存，避免每次刷新菜单都发网络请求卡顿
fetch_public_ip_cached() {
    [ -n "$_PUB_IP_CACHE" ] && { PUB_IP="$_PUB_IP_CACHE"; return; }
    fetch_public_ip
    _PUB_IP_CACHE="$PUB_IP"
}

# 取一次系统监听端口快照（ss 优先，退化到 netstat），供 gen_port/_port_in_use 复用，
# 避免 gen_port 内部最多 20 次随机重试时，每次重试都重新 fork 一次 ss/netstat 扫描全量端口表
_listening_snapshot() {
    if   command -v ss      > /dev/null 2>&1; then ss -tuln 2>/dev/null
    elif command -v netstat > /dev/null 2>&1; then netstat -tuln 2>/dev/null
    fi
}
# $1=端口 $2=可选：预先取好的快照（未传则临时取一次，仅用于单次查询场景如 _chk_port_free）
_port_in_use() {
    local snap="${2:-$(_listening_snapshot)}"
    [ -z "$snap" ] && return 1
    printf '%s\n' "$snap" | grep -qE ":${1}( |$)"
}

# $1=已用端口排除列表（空格分隔） $2=可选：预先取好的监听端口快照（install-all 批量选端口时
# 传入同一份快照复用，避免每个协议都各自重新 fork 一次 ss/netstat）
gen_port() {
    local exclude=" $1 " port seed attempts=0 snap="$2"
    [ -z "$snap" ] && snap=$(_listening_snapshot)
    while [ $attempts -lt 20 ]; do
        seed=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
        port=$(awk -v s="$seed" 'BEGIN{srand(s+0); print int(rand()*35000)+20000}')
        if ! printf '%s\n' "$snap" | grep -qE ":${port}( |$)" && [ "${exclude#* "$port" }" = "$exclude" ]; then
            echo "$port"; return 0
        fi
        attempts=$((attempts + 1))
    done
    warn "随机尝试 20 次仍未找到可用端口，请手动指定"
    return 1
}

_chk_port() {
    case "$1" in ''|*[!0-9]*) warn "端口须为纯数字，操作取消"; return 1 ;; esac
    case "$1" in 0*) [ "$1" != "0" ] && { warn "端口不能有前导零（如 0080 请写 80），操作取消"; return 1; } ;; esac
    [ "${#1}" -gt 5 ] && { warn "端口范围 1–65535，操作取消"; return 1; }
    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        warn "端口范围 1–65535，操作取消"; return 1
    fi
    return 0
}
_chk_port_free() {
    _chk_port "$1" || return 1
    _port_in_use "$1" && { warn "端口 $1 已被占用，操作取消"; return 1; }
    return 0
}

gen_b64_16() { openssl rand -base64 16; }
gen_hex()    { openssl rand -hex "$1"; }
gen_pass()   { gen_hex 16; }

# 自签证书生成，sing-box/mihomo 两个内核复用同一份逻辑（原来各有一份完全相同的实现）
# $1=证书输出路径 $2=私钥输出路径 $3=可选 CN（默认 $DEFAULT_CERT_CN）
_gen_selfsigned_cert() {
    local cert="$1" key="$2" cn="${3:-$DEFAULT_CERT_CN}"
    [ -f "$cert" ] && [ -f "$key" ] && return 0
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key" -out "$cert" -days 3650 -nodes \
        -subj "/CN=${cn}" -addext "subjectAltName=DNS:${cn}" > /dev/null 2>&1
    [ -f "$cert" ] || die "生成自签证书失败"
    chmod 600 "$key"
}

###############################################################################
# §2c  ACME 真实域名证书（可选，供 trojan/anytls/hysteria2 使用；不启用则保持原有自签证书行为）
#      判定"某协议是否用了真实证书"不额外存状态字段，而是直接看已写入配置的 certificate_path
#      是否落在 $ACME_DIR 下——见 _derive_cert_domain，读取时反推，避免维护冗余状态
###############################################################################
# 安装官方 acme.sh 客户端（若已安装则跳过）；$1=注册账户邮箱（可选，默认 admin@域名）
ensure_acme() {
    [ -x "$ACME_BIN" ] && return 0
    ensure_pkgs curl socat
    info "首次使用真实证书功能，正在安装 acme.sh..."
    curl -fLs --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 60 https://get.acme.sh \
        | sh -s email="${1:-admin@example.com}" > /dev/null 2>&1
    [ -x "$ACME_BIN" ] || die "acme.sh 安装失败，请检查网络后重试"
}
# 通过 HTTP-01 standalone 校验签发证书；要求域名已解析到本机公网 IP，且校验期间 80 端口空闲
# （若被其他服务占用会签发失败，属预期行为，此脚本不会代为抢占/关闭其他服务）
# $1=域名 $2=可选邮箱
acme_issue_cert() {
    local domain="$1" email="${2:-admin@$1}" out_dir="${ACME_DIR}/${domain}"
    ensure_acme "$email"
    mkdir -p "$out_dir"; chmod 700 "$ACME_DIR" "$out_dir" 2>/dev/null
    info "正在通过 ACME 校验签发 ${domain} 的证书（standalone 模式，需 80 端口当前空闲）..."
    if ! "$ACME_BIN" --issue -d "$domain" --standalone --keylength ec-256 \
            --accountemail "$email" > /tmp/acme-issue.log 2>&1; then
        warn "证书签发失败，常见原因：域名未解析到本机 / 80 端口被占用 / 触发 CA 签发频率限制；详细日志见 /tmp/acme-issue.log"
        return 1
    fi
    if ! "$ACME_BIN" --install-cert -d "$domain" --ecc \
            --fullchain-file "${out_dir}/fullchain.pem" \
            --key-file "${out_dir}/privkey.pem" > /dev/null 2>&1; then
        warn "证书签发成功但安装到目标路径失败"
        return 1
    fi
    chmod 600 "${out_dir}/privkey.pem"
    ok "证书已签发：${out_dir}/fullchain.pem（acme.sh 自带定时任务，到期前会自动续签，无需手动干预）"
    return 0
}
# 从已存的 certificate_path 反推该协议是使用真实证书还是默认自签证书，设置 CONF_DOMAIN/CONF_KEY/CONF_SNI
_derive_cert_domain() {
    local cert="$1"
    case "$cert" in
        "$ACME_DIR"/*)
            CONF_DOMAIN=$(echo "$cert" | sed -E "s#^${ACME_DIR}/([^/]+)/.*#\1#")
            CONF_KEY="${ACME_DIR}/${CONF_DOMAIN}/privkey.pem"
            CONF_SNI="$CONF_DOMAIN" ;;
        *)
            CONF_DOMAIN=""; CONF_KEY=""; CONF_SNI="$DEFAULT_CERT_CN" ;;
    esac
}
# 交互询问 tj/at/hy 安装/修改证书时用自签还是真实域名证书；调用即表示"从头决定证书模式"，
# 结果写入 F_DOMAIN（非空=真实证书）/F_CERT/F_KEY，留空 F_CERT/F_KEY 由 proto_write_cfg 兜底填默认自签路径
_ask_cert_mode() {
    F_DOMAIN=""; F_CERT=""; F_KEY=""
    confirm "是否使用真实域名证书（ACME 自动签发，需域名已解析到本机且 80 端口空闲）？" "no" || return 0
    ask "域名（已解析到本机公网 IP）" ""
    [ -z "$REPLY" ] && { warn "域名不能为空，已回退为自签证书"; return 0; }
    F_DOMAIN="$REPLY"
    if acme_issue_cert "$F_DOMAIN"; then
        F_CERT="${ACME_DIR}/${F_DOMAIN}/fullchain.pem"
        F_KEY="${ACME_DIR}/${F_DOMAIN}/privkey.pem"
    else
        warn "已回退为自签证书"
        F_DOMAIN=""
    fi
}

###############################################################################
# §3  内核调度层（KERNEL=sb|mh，全部协议操作通过此层间接调用具体内核实现）
###############################################################################
kernel_read_active() {
    KERNEL=$(cat "$KERNEL_STATE" 2>/dev/null)
    case "$KERNEL" in sb|mh) ;; *) KERNEL="sb" ;; esac
}
kernel_write_active() { echo "$1" > "$KERNEL_STATE"; }
# 若两内核均已卸载（不再安装），清除内核状态文件，避免残留指向"已不存在内核"的过期标记
_kernel_cleanup_state_if_none() {
    [ -x "$SB_BIN" ] || [ -x "$MH_BIN" ] || rm -f "$KERNEL_STATE"
}
# 卸载某内核后，若它正是当前激活内核、且另一内核已安装，则自动切换过去接管服务；
# sb_uninstall/mh_uninstall 原来各手写一份对称逻辑（仅内核字母互换），在此合并
# $1=被卸载内核字母(sb/mh) $2=另一内核字母 $3=另一内核二进制路径 $4=另一内核展示名
# $5=另一内核服务名 $6=另一内核的 restart 函数名
_switch_kernel_after_uninstall() {
    local uninstalled="$1" other="$2" other_bin="$3" other_name="$4" other_svc="$5" other_restart_fn="$6"
    [ "$KERNEL" = "$uninstalled" ] || return 0
    [ -x "$other_bin" ] || return 0
    kernel_write_active "$other"; kernel_read_active
    svc_enable "$other_svc"
    if "$other_restart_fn"; then
        info "已自动切换激活内核为 ${other_name}（服务已启动）"
    else
        warn "已自动切换激活内核为 ${other_name}，但服务启动失败，请检查上面的报错信息"
    fi
}

k_name()  { [ "$KERNEL" = "mh" ] && echo "mihomo" || echo "sing-box"; }
k_bin()   { [ "$KERNEL" = "mh" ] && echo "$MH_BIN" || echo "$SB_BIN"; }
k_installed() { [ -x "$(k_bin)" ]; }
k_version()    { if [ "$KERNEL" = "mh" ]; then mh_version;     else sb_version; fi; }
k_ensure()     { if [ "$KERNEL" = "mh" ]; then ensure_mihomo;   else ensure_singbox; fi; }
k_update()     { if [ "$KERNEL" = "mh" ]; then mh_update;       else sb_update; fi; }
k_restart()    { if [ "$KERNEL" = "mh" ]; then mh_restart;      else sb_restart; fi; }
k_is_running() { if [ "$KERNEL" = "mh" ]; then mh_is_running;   else sb_is_running; fi; }
k_gen_cert()   { if [ "$KERNEL" = "mh" ]; then mh_gen_cert;     else sb_gen_cert; fi; }
k_version_disp() { if [ "$KERNEL" = "mh" ]; then k_version; else echo "v$(k_version)"; fi; }
k_gen_uuid() { "$(k_bin)" generate uuid; }
k_gen_reality_keypair() {
    local keys
    keys=$("$(k_bin)" generate reality-keypair)
    REALITY_PRIV=$(echo "$keys" | grep '^PrivateKey:' | awk '{print $2}')
    REALITY_PUB=$(echo "$keys"  | grep '^PublicKey:'  | awk '{print $2}')
}
###############################################################################
# §4  sing-box 内核实现
###############################################################################
# 注：因 Snell 原生支持目前只存在于尚未发布正式版的 1.14.0-alpha 系列，这里改为拉取
# releases 列表（含预发布版）取最新一个，而不是 GitHub `/latest`（后者只返回稳定版，
# 会拿到不含 Snell 的 1.13.x）。这意味着装出来的 sing-box 长期跟随 alpha 通道，
# 其余协议也会用到 alpha 构建，请知悉这一权衡。
_sb_latest_tag() {
    curl -sf --connect-timeout 5 --max-time 10 "${SB_API}?per_page=5" \
        | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}
sb_download() {
    local ver="$1" arch tmp url variant=""
    arch=$(_bin_arch)
    if [ -z "$ver" ]; then
        ver=$(_sb_latest_tag)
        [ -z "$ver" ] && { warn "无法获取 sing-box 最新版本号，请检查网络"; return 1; }
    fi
    tmp="/tmp/sing-box-$$"
    [ "$OS_FAMILY" = "alpine" ] && variant="-musl"
    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-${arch}${variant}.tar.gz"
    info "下载 sing-box ${ver} (linux-${arch}${variant})..."
    mkdir -p "$tmp"
    curl -fLs --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 -o "${tmp}.tar.gz" "$url" \
        || { rm -rf "$tmp" "${tmp}.tar.gz"; warn "下载失败：$url"; return 1; }
    tar xzf "${tmp}.tar.gz" -C "$tmp" --strip-components=1 || { rm -rf "$tmp" "${tmp}.tar.gz"; warn "解压失败"; return 1; }
    [ -x "${tmp}/sing-box" ] || { rm -rf "$tmp" "${tmp}.tar.gz"; warn "解压后未找到可执行文件"; return 1; }
    install -m 755 "${tmp}/sing-box" "$SB_BIN"
    rm -rf "$tmp" "${tmp}.tar.gz"
}
sb_write_init() {
    if [ "$OS_FAMILY" = "debian" ]; then
        cat > "$SB_INIT" << EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStartPre=${SB_BIN} check -D /var/lib/sing-box -C ${SB_DIR}
ExecStart=${SB_BIN} run --disable-color -D /var/lib/sing-box -C ${SB_DIR}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        svc_daemon_reload
    else
        cat > "$SB_INIT" << 'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
supervisor="supervise-daemon"
command="/usr/local/bin/sing-box"
extra_started_commands="reload checkconfig"
command_args="run --disable-color -D /var/lib/sing-box -C /etc/sing-box"

depend() {
    after net dns
}

checkconfig() {
    ebegin "Checking $RC_SVCNAME configuration"
    /usr/local/bin/sing-box check -C /etc/sing-box
    eend $?
}

start_pre() {
    checkconfig
}

reload() {
    ebegin "Reloading $RC_SVCNAME"
    checkconfig && $supervisor "$RC_SVCNAME" --signal HUP
    eend $?
}
EOF
        chmod +x "$SB_INIT"
    fi
}
sb_write_logrotate() { _write_logrotate "$SB_LOG" "$SB_LOGROTATE"; }
sb_write_base() {
    cat > "$LOG_JSON" << EOF
{
  "log": { "level": "info", "timestamp": true, "output": "${SB_LOG}" },
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
}
ensure_singbox() {
    ensure_pkgs jq openssl curl tar logrotate
    if [ ! -x "$SB_BIN" ]; then
        sb_download "" || die "sing-box 安装失败，请检查网络后重试"
        ok "sing-box 已安装：$(sb_version)"
    fi
    [ -f "$SB_INIT" ] || sb_write_init
    mkdir -p "$SB_DIR" "$SB_INFO_DIR" /var/lib/sing-box
    # 兼容旧版本已安装环境：目录及内含文件权限统一收紧为仅 owner 可读写
    chmod 700 "$SB_DIR" "$SB_INFO_DIR" 2>/dev/null
    find "$SB_DIR" -maxdepth 2 -type f ! -perm 600 -exec chmod 600 {} + 2>/dev/null
    if [ -f "$LOG_JSON" ]; then
        if ! grep -q '"output"' "$LOG_JSON" 2>/dev/null; then
            jq --arg out "$SB_LOG" '.log.output = $out' "$LOG_JSON" > "${LOG_JSON}.tmp" && mv "${LOG_JSON}.tmp" "$LOG_JSON"
            sb_is_running && svc_reload "$SB_SVC"
        fi
    else
        sb_write_base
    fi
    [ -f "$SB_LOGROTATE" ] || sb_write_logrotate
    svc_enable "$SB_SVC"
}
sb_version() { "$SB_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?' | head -1; }
sb_update() {
    local cur latest
    cur=$(sb_version)
    latest=$(_sb_latest_tag)
    [ -z "$latest" ] && { warn "无法获取 sing-box 最新版本号，请检查网络后重试"; return 1; }
    if [ "v${cur}" = "$latest" ]; then
        ok "已是最新版本 v${cur}，无需更新"
        return 0
    fi
    info "发现新版本：当前 v${cur} → 最新 ${latest}（更新过程会保留现有协议配置，仅替换二进制）"
    confirm "确认更新？" "yes" || { ok "已取消"; return 0; }
    cp "$SB_BIN" "${SB_BIN}.bak"
    if sb_download "$latest"; then
        if sb_restart; then
            rm -f "${SB_BIN}.bak"; ok "sing-box 已更新至 $(sb_version)，所有协议配置未受影响"
        else
            mv "${SB_BIN}.bak" "$SB_BIN"; sb_restart; warn "新版本启动失败，已自动回滚至 v${cur}"
        fi
    else
        warn "新版本下载失败，已保留当前版本 v${cur}"
        rm -f "${SB_BIN}.bak"
    fi
}
sb_gen_cert() { _gen_selfsigned_cert "$SB_CERT" "$SB_KEY" "$1"; }
sb_checkconfig() { timeout 20 "$SB_BIN" check -C "$SB_DIR" 2>&1; }
# 优先热重载（HUP，不打断其他协议现有连接）；服务未运行或reload失败时降级为完整重启
sb_restart() {
    local out rc
    out=$(sb_checkconfig); rc=$?
    if [ "$rc" -eq 124 ]; then
        warn "配置校验超时（20秒未返回，已强制终止），服务未重启：sing-box check 卡住通常是 alpha 版本某个协议实现的已知问题，建议先执行菜单重启服务确认当前运行状态，或反馈具体是哪个协议触发的"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        warn "配置校验失败，服务未重启："
        printf "%s\n" "$out" >&2
        return 1
    fi
    if sb_is_running && svc_reload "$SB_SVC"; then
        ok "配置已热重载（其他协议连接未受影响）"
        return 0
    fi
    svc_restart "$SB_SVC"
    _svc_wait_ready "$SB_SVC"
}
sb_is_running() { svc_is_active "$SB_SVC"; }

# ── sing-box 各协议 json schema（写配置：用 $PORT/$F_xxx 全局变量；读配置：$1=配置文件路径）──
sb_cfg_ss() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg method "$SS_METHOD" \
        '{ inbounds: [{ type: "shadowsocks", tag: "shadowsocks-in", listen: "::", listen_port: $port, method: $method, password: $pass }] }' \
        > "$(proto_cfg_file ss)"
}
sb_read_ss() { _jq_pipe2 "$1" '.inbounds[0].listen_port' '.inbounds[0].password'; CONF_PORT="$JP1"; CONF_PASS="$JP2"; }

sb_cfg_tj() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$F_CERT" --arg key "$F_KEY" \
        '{ inbounds: [{ type: "trojan", tag: "trojan-in", listen: "::", listen_port: $port,
           users: [{ name: "user", password: $pass }], tls: { enabled: true, certificate_path: $cert, key_path: $key } }] }' \
        > "$(proto_cfg_file tj)"
}
sb_read_tj() {
    _jq_pipe3 "$1" '.inbounds[0].listen_port' '.inbounds[0].users[0].password' '.inbounds[0].tls.certificate_path'
    CONF_PORT="$JP1"; CONF_PASS="$JP2"; CONF_CERT="$JP3"; _derive_cert_domain "$CONF_CERT"
}

sb_cfg_vl() {
    jq -n --argjson port "$PORT" --arg uuid "$F_UUID" --arg sni "$F_SNI" --arg priv "$F_REALITY_PRIV" --arg sid "$F_SHORT_ID" \
        '{ inbounds: [{ type: "vless", tag: "vless-in", listen: "::", listen_port: $port,
           users: [{ name: "user", uuid: $uuid, flow: "xtls-rprx-vision" }],
           tls: { enabled: true, server_name: $sni,
             reality: { enabled: true, handshake: { server: $sni, server_port: 443 }, private_key: $priv, short_id: [$sid] } } }] }' \
        > "$(proto_cfg_file vl)"
}
sb_read_vl() {
    _jq_pipe5 "$1" '.inbounds[0].listen_port' '.inbounds[0].users[0].uuid' '.inbounds[0].tls.server_name' \
        '.inbounds[0].tls.reality.private_key' '.inbounds[0].tls.reality.short_id[0]'
    CONF_PORT="$JP1"; CONF_UUID="$JP2"; CONF_SNI="$JP3"; CONF_REALITY_PRIV="$JP4"; CONF_SHORT_ID="$JP5"
}

sb_cfg_at() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$F_CERT" --arg key "$F_KEY" \
        '{ inbounds: [{ type: "anytls", tag: "anytls-in", listen: "::", listen_port: $port,
           users: [{ name: "user", password: $pass }], tls: { enabled: true, certificate_path: $cert, key_path: $key } }] }' \
        > "$(proto_cfg_file at)"
}
sb_read_at() {
    _jq_pipe3 "$1" '.inbounds[0].listen_port' '.inbounds[0].users[0].password' '.inbounds[0].tls.certificate_path'
    CONF_PORT="$JP1"; CONF_PASS="$JP2"; CONF_CERT="$JP3"; _derive_cert_domain "$CONF_CERT"
}

sb_cfg_hy() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$F_CERT" --arg key "$F_KEY" \
        '{ inbounds: [{ type: "hysteria2", tag: "hy2-in", listen: "::", listen_port: $port,
           users: [{ name: "user", password: $pass }], tls: { enabled: true, certificate_path: $cert, key_path: $key } }] }' \
        > "$(proto_cfg_file hy)"
}
sb_read_hy() {
    _jq_pipe3 "$1" '.inbounds[0].listen_port' '.inbounds[0].users[0].password' '.inbounds[0].tls.certificate_path'
    CONF_PORT="$JP1"; CONF_PASS="$JP2"; CONF_CERT="$JP3"; _derive_cert_domain "$CONF_CERT"
}

sb_cfg_sn() {
    # 官方文档 https://sing-box.sagernet.org/configuration/inbound/snell/ 核实的真实 schema：
    # - psk 是顶层字段（不是嵌套在 users[] 里；users[] 是可选的多用户模式，每个 entry 是
    #   name+userkey，跟顶层 psk 语义不同，这里不使用）
    # - version 只支持 5/6（不支持 4；官方说明 v5 线路协议本就与 v4 等价，故 v5 客户端可兼容 v4）
    # - 混淆字段叫 obfs_mode（纯字符串，不是嵌套对象），version 5 下只支持 none/http，没有 tls
    local obfs="none"
    [ "${F_OBFS:-off}" = "http" ] && obfs="http"
    jq -n --argjson port "$PORT" --arg psk "$F_PASS" --arg obfs "$obfs" \
        '{ inbounds: [ { type: "snell", tag: "snell-in", listen: "::", listen_port: $port,
             version: 5, psk: $psk, obfs_mode: $obfs } ] }' \
        > "$(proto_cfg_file sn)"
}
sb_read_sn() {
    _jq_pipe3 "$1" '.inbounds[0].listen_port' '.inbounds[0].psk' '.inbounds[0].obfs_mode // "none"'
    CONF_PORT="$JP1"; CONF_PASS="$JP2"
    CONF_OBFS="$JP3"; [ "$CONF_OBFS" = "none" ] && CONF_OBFS="off"
}

# 卸载 sing-box 内核：完全删除（停服务/移除开机自启/删二进制+init脚本+conf.d+日志轮转配置+
# 全部日志文件(含logrotate轮转产生的历史.gz)+协议配置目录+运行时目录），不校验其他内核状态，两内核完全独立
sb_uninstall() {
    printf "\n"; _box "卸载 sing-box 内核"; hr
    [ -x "$SB_BIN" ] || { warn "sing-box 尚未安装，无需卸载"; return 1; }
    warn "此操作将完全删除 sing-box 相关的全部文件：内核二进制、服务脚本、日志轮转配置、"
    warn "协议配置目录 ${SB_DIR}（含全部节点密钥/证书）、运行时目录 /var/lib/sing-box、全部日志文件，且不可撤销"
    confirm "确认完全卸载 sing-box 内核？" "no" || { ok "已取消"; return 1; }
    svc_stop "$SB_SVC"
    svc_disable "$SB_SVC"
    rm -f "$SB_BIN" "$SB_INIT" "/etc/conf.d/sing-box" "$SB_LOGROTATE"
    rm -f "$SB_LOG" "$SB_LOG".*
    rm -rf "$SB_DIR" /var/lib/sing-box
    svc_daemon_reload
    ok "sing-box 内核已完全卸载（二进制、配置、密钥、日志已全部清除）"
    _switch_kernel_after_uninstall sb mh "$MH_BIN" mihomo "$MH_SVC" mh_restart
    _kernel_cleanup_state_if_none
}

###############################################################################
# §5  mihomo 内核实现
###############################################################################
_mh_latest_tag() {
    curl -sf --connect-timeout 5 --max-time 10 "${MH_API}/latest" | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1
}
mh_download() {
    local ver="$1" arch tmp url
    arch=$(_bin_arch)
    if [ -z "$ver" ]; then
        ver=$(_mh_latest_tag)
        [ -z "$ver" ] && { warn "无法获取 mihomo 最新版本号，请检查网络"; return 1; }
    fi
    tmp="/tmp/mihomo-$$"
    url="https://github.com/MetaCubeX/mihomo/releases/download/${ver}/mihomo-linux-${arch}-${ver}.gz"
    info "下载 mihomo ${ver} (linux-${arch})..."
    curl -fLs --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 -o "${tmp}.gz" "$url" \
        || { rm -f "${tmp}.gz"; warn "下载失败：$url"; return 1; }
    gunzip -f "${tmp}.gz" || { rm -f "${tmp}.gz" "$tmp"; warn "解压失败"; return 1; }
    [ -f "$tmp" ] || { warn "解压后未找到可执行文件"; return 1; }
    install -m 755 "$tmp" "$MH_BIN"
    rm -f "$tmp"
}
mh_write_init() {
    if [ "$OS_FAMILY" = "debian" ]; then
        cat > "$MH_INIT" << EOF
[Unit]
Description=Mihomo (Clash Meta) service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStartPre=${MH_BIN} -t -d ${MH_DIR}
ExecStart=${MH_BIN} -d ${MH_DIR}
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        svc_daemon_reload
    else
        cat > "$MH_INIT" << 'EOF'
#!/sbin/openrc-run
name="mihomo"
description="Mihomo (Clash Meta) service"
supervisor="supervise-daemon"
command="/usr/local/bin/mihomo"
extra_started_commands="checkconfig"
command_args="-d /etc/mihomo"
output_log="/var/log/mihomo.log"
error_log="/var/log/mihomo.log"

depend() {
    after net dns
}

checkconfig() {
    ebegin "Checking $RC_SVCNAME configuration"
    /usr/local/bin/mihomo -t -d /etc/mihomo
    eend $?
}

start_pre() {
    checkconfig
}
EOF
        chmod +x "$MH_INIT"
    fi
}
mh_write_logrotate() { _write_logrotate "$MH_LOG" "$MH_LOGROTATE"; }
# logrotate 配置模板，两内核除日志路径外完全一致（原来各有一份重复的 heredoc）
# $1=日志文件路径 $2=logrotate 配置输出路径
_write_logrotate() {
    cat > "$2" << EOF
${1} {
    daily
    rotate 7
    size 10M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}
mh_base_json() {
    timeout 15 jq -n '
    {
      "allow-lan": false,
      "mode": "rule",
      "log-level": "info",
      "ipv6": true,
      "unified-delay": true,
      "proxies": [],
      "proxy-groups": [{ "name": "GLOBAL", "type": "select", "proxies": ["DIRECT"] }],
      "rules": ["MATCH,DIRECT"],
      "listeners": []
    }'
}
# mihomo 仅支持单一 config.yaml，每协议独立存成 fragment json 便于单独增删改，
# 每次改动后统一合并全部 fragment 重建整份 yaml
mh_rebuild_yaml() {
    local listeners="[]" id f base tmp
    [ -z "$YQ_BIN" ] && ensure_yq
    for id in $PROTO_IDS; do
        f=$(proto_cfg_file "$id")
        [ -f "$f" ] && listeners=$(echo "$listeners" | timeout 15 jq --slurpfile l "$f" '. + $l')
    done
    base=$(mh_base_json)
    tmp="${MH_YAML}.tmp"
    echo "$base" | timeout 15 jq --argjson listeners "$listeners" '.listeners = $listeners' \
        | timeout 20 "$YQ_BIN" -p json -o yaml '.' - > "$tmp" 2>/dev/null
    [ -s "$tmp" ] || { rm -f "$tmp"; warn "生成 config.yaml 失败（jq/yq 转换出错或超时，请确认 $YQ_BIN 是 mikefarah/yq：执行 $YQ_BIN --version 确认输出含 mikefarah 字样，若不是请删除后重新运行本脚本自动重装）"; return 1; }
    mv "$tmp" "$MH_YAML"
}
ensure_mihomo() {
    ensure_pkgs jq yq-go openssl curl logrotate
    if [ ! -x "$MH_BIN" ]; then
        mh_download "" || die "mihomo 安装失败，请检查网络后重试"
        ok "mihomo 已安装：$(mh_version)"
    fi
    [ -f "$MH_INIT" ] || mh_write_init
    mkdir -p "$MH_DIR" "$MH_FRAG_DIR" "$MH_INFO_DIR"
    chmod 700 "$MH_DIR" "$MH_FRAG_DIR" "$MH_INFO_DIR" 2>/dev/null
    find "$MH_DIR" -maxdepth 2 -type f ! -perm 600 -exec chmod 600 {} + 2>/dev/null
    [ -f "$MH_YAML" ] || mh_rebuild_yaml
    [ -f "$MH_LOGROTATE" ] || mh_write_logrotate
    svc_enable "$MH_SVC"
}
mh_version() { "$MH_BIN" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
mh_update() {
    local cur latest
    cur=$(mh_version)
    latest=$(_mh_latest_tag)
    [ -z "$latest" ] && { warn "无法获取 mihomo 最新版本号，请检查网络后重试"; return 1; }
    if [ "$cur" = "$latest" ]; then
        ok "已是最新版本 ${cur}，无需更新"
        return 0
    fi
    info "发现新版本：当前 ${cur} → 最新 ${latest}（更新过程会保留现有协议配置，仅替换二进制）"
    confirm "确认更新？" "yes" || { ok "已取消"; return 0; }
    cp "$MH_BIN" "${MH_BIN}.bak"
    if mh_download "$latest"; then
        if mh_restart; then
            rm -f "${MH_BIN}.bak"; ok "mihomo 已更新至 $(mh_version)，所有协议配置未受影响"
        else
            mv "${MH_BIN}.bak" "$MH_BIN"; mh_restart; warn "新版本启动失败，已自动回滚至 ${cur}"
        fi
    else
        warn "新版本下载失败，已保留当前版本 ${cur}"
        rm -f "${MH_BIN}.bak"
    fi
}
mh_gen_cert() { _gen_selfsigned_cert "$MH_CERT" "$MH_KEY" "$1"; }
mh_checkconfig() { timeout 20 "$MH_BIN" -t -d "$MH_DIR" 2>&1; }
mh_is_running() { svc_is_active "$MH_SVC"; }

# ── mihomo 各协议 fragment schema（写配置：用 $PORT/$F_xxx 全局变量；读配置：$1=配置文件路径）──
# 每次写完 fragment 都需重建整份 config.yaml，因此写函数末尾统一调用 mh_rebuild_yaml
mh_cfg_ss() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg method "$SS_METHOD" \
        '{ name: "shadowsocks-in", type: "shadowsocks", port: $port, listen: "::", cipher: $method, password: $pass, udp: true }' \
        > "$(proto_cfg_file ss)"
    mh_rebuild_yaml
}
mh_read_ss() { _jq_pipe2 "$1" '.port' '.password'; CONF_PORT="$JP1"; CONF_PASS="$JP2"; }

mh_cfg_tj() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$F_CERT" --arg key "$F_KEY" \
        '{ name: "trojan-in", type: "trojan", port: $port, listen: "::",
           users: [{ username: "user", password: $pass }], certificate: $cert, "private-key": $key }' \
        > "$(proto_cfg_file tj)"
    mh_rebuild_yaml
}
mh_read_tj() {
    _jq_pipe3 "$1" '.port' '.users[0].password' '.certificate'
    CONF_PORT="$JP1"; CONF_PASS="$JP2"; CONF_CERT="$JP3"; _derive_cert_domain "$CONF_CERT"
}

mh_cfg_vl() {
    jq -n --argjson port "$PORT" --arg uuid "$F_UUID" --arg sni "$F_SNI" --arg priv "$F_REALITY_PRIV" --arg sid "$F_SHORT_ID" \
        '{ name: "vless-in", type: "vless", port: $port, listen: "::",
           users: [{ username: "user", uuid: $uuid, flow: "xtls-rprx-vision" }],
           "reality-config": { dest: ($sni + ":443"), "private-key": $priv, "short-id": [$sid], "server-names": [$sni] } }' \
        > "$(proto_cfg_file vl)"
    mh_rebuild_yaml
}
mh_read_vl() {
    _jq_pipe5 "$1" '.port' '.users[0].uuid' '."reality-config"."server-names"[0]' \
        '."reality-config"."private-key"' '."reality-config"."short-id"[0]'
    CONF_PORT="$JP1"; CONF_UUID="$JP2"; CONF_SNI="$JP3"; CONF_REALITY_PRIV="$JP4"; CONF_SHORT_ID="$JP5"
}

mh_cfg_at() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$F_CERT" --arg key "$F_KEY" \
        '{ name: "anytls-in", type: "anytls", port: $port, listen: "::",
           users: { user: $pass }, certificate: $cert, "private-key": $key }' \
        > "$(proto_cfg_file at)"
    mh_rebuild_yaml
}
mh_read_at() {
    _jq_pipe3 "$1" '.port' '.users.user' '.certificate'
    CONF_PORT="$JP1"; CONF_PASS="$JP2"; CONF_CERT="$JP3"; _derive_cert_domain "$CONF_CERT"
}

mh_cfg_hy() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$F_CERT" --arg key "$F_KEY" \
        '{ name: "hy2-in", type: "hysteria2", port: $port, listen: "::",
           users: { user: $pass }, alpn: ["h3"], certificate: $cert, "private-key": $key }' \
        > "$(proto_cfg_file hy)"
    mh_rebuild_yaml
}
mh_read_hy() {
    _jq_pipe3 "$1" '.port' '.users.user' '.certificate'
    CONF_PORT="$JP1"; CONF_PASS="$JP2"; CONF_CERT="$JP3"; _derive_cert_domain "$CONF_CERT"
}

# Snell：mihomo 官方稳定支持的原生 listener（非独立二进制），完全并入通用引擎
mh_cfg_sn() {
    local obfs_json="null"
    if [ "${F_OBFS:-off}" != "off" ]; then
        obfs_json=$(jq -n --arg mode "$F_OBFS" --arg host "$DEFAULT_CERT_CN" '{mode: $mode, host: $host}')
    fi
    jq -n --argjson port "$PORT" --arg psk "$F_PASS" --argjson obfs "$obfs_json" \
        '{ name: "snell-in", type: "snell", port: $port, listen: "0.0.0.0", psk: $psk, version: 5, udp: true }
         + (if $obfs != null then {"obfs-opts": $obfs} else {} end)' \
        > "$(proto_cfg_file sn)"
    mh_rebuild_yaml
}
mh_read_sn() {
    _jq_pipe3 "$1" '.port' '.psk' '."obfs-opts".mode // "off"'
    CONF_PORT="$JP1"; CONF_PASS="$JP2"; CONF_OBFS="$JP3"
}

# 卸载 mihomo 内核：完全删除（停服务/移除开机自启/删二进制+init脚本+日志轮转配置+
# 全部日志文件(含logrotate轮转产生的历史.gz)+协议配置目录）
mh_uninstall() {
    printf "\n"; _box "卸载 mihomo 内核"; hr
    [ -x "$MH_BIN" ] || { warn "mihomo 尚未安装，无需卸载"; return 1; }
    warn "此操作将完全删除 mihomo 相关的全部文件：内核二进制、服务脚本、日志轮转配置、"
    warn "协议配置目录 ${MH_DIR}（含全部节点密钥/证书）、全部日志文件，且不可撤销"
    confirm "确认完全卸载 mihomo 内核？" "no" || { ok "已取消"; return 1; }
    svc_stop "$MH_SVC"
    svc_disable "$MH_SVC"
    rm -f "$MH_BIN" "$MH_INIT" "$MH_LOGROTATE"
    rm -f "$MH_LOG" "$MH_LOG".*
    rm -rf "$MH_DIR"
    svc_daemon_reload
    ok "mihomo 内核已完全卸载（二进制、配置、密钥、日志已全部清除）"
    _switch_kernel_after_uninstall mh sb "$SB_BIN" sing-box "$SB_SVC" sb_restart
    _kernel_cleanup_state_if_none
}
mh_restart() {
    local out rc
    out=$(mh_checkconfig); rc=$?
    if [ "$rc" -eq 124 ]; then
        warn "配置校验超时（20秒未返回，已强制终止），服务未重启"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        warn "配置校验失败，服务未重启："
        printf "%s\n" "$out" >&2
        return 1
    fi
    svc_restart "$MH_SVC"
    _svc_wait_ready "$MH_SVC"
}

###############################################################################
# §6  协议元数据（路径 / 显示名 / 传输层，按 id 分发：ss tj vl at hy sn）
###############################################################################
proto_name() {
    case "$1" in
        ss) echo "Shadowsocks 2022" ;; tj) echo "Trojan" ;; vl) echo "VLESS + Reality" ;;
        at) echo "AnyTLS" ;; hy) echo "Hysteria2" ;; sn) echo "Snell" ;;
    esac
}
proto_transport() {
    case "$1" in ss) echo "tcp+udp" ;; hy) echo "udp" ;; *) echo "tcp" ;; esac
}
# sing-box 用独立 confdir json，mihomo 用单文件 fragment json，按 $KERNEL 分发（Snell 现已在
# 两个内核下都是原生协议：sing-box 用 1.14.0-alpha 的原生 snell inbound，mihomo 用官方稳定支持
# 的原生 snell listener，因此和其他协议一样纳入同一套按 $KERNEL:$id 分发的路径表）
proto_cfg_file() {
    case "$KERNEL:$1" in
        sb:ss) echo "$SB_DIR/10-shadowsocks.json" ;; mh:ss) echo "$MH_FRAG_DIR/shadowsocks.json" ;;
        sb:tj) echo "$SB_DIR/20-trojan.json" ;;     mh:tj) echo "$MH_FRAG_DIR/trojan.json" ;;
        sb:vl) echo "$SB_DIR/30-vless.json" ;;      mh:vl) echo "$MH_FRAG_DIR/vless.json" ;;
        sb:at) echo "$SB_DIR/40-anytls.json" ;;     mh:at) echo "$MH_FRAG_DIR/anytls.json" ;;
        sb:hy) echo "$SB_DIR/50-hysteria2.json" ;;  mh:hy) echo "$MH_FRAG_DIR/hysteria2.json" ;;
        sb:sn) echo "$SB_DIR/60-snell.json" ;;      mh:sn) echo "$MH_FRAG_DIR/snell.json" ;;
    esac
}
proto_info_file() {
    local dir; dir=$([ "$KERNEL" = "mh" ] && echo "$MH_INFO_DIR" || echo "$SB_INFO_DIR")
    case "$1" in
        ss) echo "$dir/shadowsocks.txt" ;; tj) echo "$dir/trojan.txt" ;; vl) echo "$dir/vless.txt" ;;
        at) echo "$dir/anytls.txt" ;;      hy) echo "$dir/hysteria2.txt" ;; sn) echo "$dir/snell.txt" ;;
    esac
}
# 仅 VLESS 需要额外的 reality 公钥文件（客户端连接需要，但服务端配置不存公钥本身）
proto_pub_file() {
    [ "$1" = "vl" ] || return 0
    [ "$KERNEL" = "mh" ] && echo "$MH_DIR/.vless-pubkey" || echo "$SB_DIR/.vless-pubkey"
}
proto_has_prep()   { [ "$1" != "ss" ] && [ "$1" != "sn" ]; }
proto_prep_label() { [ "$1" = "vl" ] && echo "生成 Reality 密钥对" || echo "生成自签证书"; }

###############################################################################
# §7  协议数据钩子（各协议的唯一差异化逻辑：读写配置 / URI / 展示字段）
#     统一参数变量（按语义命名，非全部协议都用到）：
#       F_PASS/CONF_PASS               : 密码（ss/tj/at/hy 用）
#       F_UUID/CONF_UUID                : UUID（vl 用）
#       F_SNI/CONF_SNI                  : 伪装域名 SNI（vl 用）
#       F_REALITY_PRIV/CONF_REALITY_PRIV: Reality 私钥（vl 用）
#       F_REALITY_PUB/CONF_REALITY_PUB  : Reality 公钥（vl 用，单独存公钥文件）
#       F_SHORT_ID/CONF_SHORT_ID        : Reality short_id（vl 用）
#       F_OBFS/CONF_OBFS                : 混淆方式 off/http/tls（sn 用）
#       F_DOMAIN/CONF_DOMAIN             : 真实域名证书的域名，空=使用默认自签证书（tj/at/hy 用）
#       F_CERT/F_KEY, CONF_CERT/CONF_KEY : 证书/私钥实际路径（tj/at/hy 用，proto_write_cfg 兜底默认值）
###############################################################################
# 读取已安装配置到 CONF_PORT / CONF_*
# 纯分发：具体读取逻辑完全下沉到 §4/§5 的 sb_read_xx / mh_read_xx，本函数不感知内核差异
proto_read_conf() {
    local id="$1" f; f=$(proto_cfg_file "$id")
    [ -f "$f" ] || return 1
    "${KERNEL}_read_${id}" "$f"
    [ "$id" = "vl" ] && CONF_REALITY_PUB=$(cat "$(proto_pub_file vl)" 2>/dev/null)
}
# 交互收集"全新安装"所需参数：询问端口 + 协议专属参数，静默生成简单密钥
# （耗时的证书/reality密钥对生成放到 proto_prep，作为安装流程里独立展示的步骤）
# 询问 Snell 混淆方式：mihomo 支持 off/http/tls，sing-box 目前只支持 off/http（无 tls），
# 按当前激活内核调整提示文案与校验，避免生成一个当前内核实际不支持的混淆值
_ask_sn_obfs() {
    local def="$1" hint="off/http/tls" allowed="off http tls"
    if [ "$KERNEL" != "mh" ]; then
        hint="off/http，sing-box 暂不支持 tls"
        allowed="off http"
    fi
    while true; do
        ask "混淆方式 obfs（${hint}）" "$def"
        F_OBFS="$REPLY"
        case " $allowed " in
            *" $F_OBFS "*) break ;;
            *)
                if [ "$KERNEL" != "mh" ] && [ "$F_OBFS" = "tls" ]; then
                    warn "当前内核 sing-box 的 Snell 不支持 tls 混淆，已自动改为 off"
                    F_OBFS="off"; break
                fi
                warn "请输入 ${allowed}（用空格分隔的可选值之一）" ;;
        esac
    done
}
proto_collect_new() {
    local id="$1"
    ask "监听端口（留空随机${2:+，$2}）" ""
    if [ -z "$REPLY" ]; then PORT=$(gen_port) || return 1; else PORT="$REPLY"; _chk_port_free "$PORT" || return 1; fi
    case "$id" in
        ss) F_PASS=$(gen_b64_16) ;;
        tj|at|hy) F_PASS=$(gen_pass); _ask_cert_mode ;;
        sn)
            F_PASS=$(gen_pass)
            _ask_sn_obfs "off" ;;
        vl)
            ask "伪装目标 SNI（用于 Reality 握手伪装的真实网站，建议选支持 TLS1.3 且证书较小的站点；注意：此处仅做语法校验，握手是否成功需连接后实测）" "$DEFAULT_SNI"
            F_SNI="$REPLY"; F_UUID=$(k_gen_uuid); F_SHORT_ID=$(gen_hex 8) ;;
    esac
    return 0
}
# 交互收集"修改配置"所需参数：默认值取自已加载的 CONF_*，可选择重新生成密钥
proto_collect_edit() {
    local id="$1"
    ask "监听端口" "$CONF_PORT"; PORT="$REPLY"
    [ "$PORT" != "$CONF_PORT" ] && { _chk_port_free "$PORT" || return 1; }
    case "$id" in
        ss) F_PASS="$CONF_PASS"; confirm "重新生成密码？" "no" && F_PASS=$(gen_b64_16) ;;
        tj|at|hy)
            F_PASS="$CONF_PASS"; confirm "重新生成密码？" "no" && F_PASS=$(gen_pass)
            F_DOMAIN="$CONF_DOMAIN"; F_CERT="$CONF_CERT"; F_KEY="$CONF_KEY"
            if [ -n "$CONF_DOMAIN" ]; then
                confirm "当前使用真实域名证书（${CONF_DOMAIN}），是否重新签发/更换？" "no" && _ask_cert_mode
            else
                confirm "当前使用自签证书，是否改为真实域名证书（ACME）？" "no" && _ask_cert_mode
            fi ;;
        sn)
            F_PASS="$CONF_PASS"; confirm "重新生成 PSK？" "no" && F_PASS=$(gen_pass)
            _ask_sn_obfs "${CONF_OBFS:-off}" ;;
        vl)
            ask "伪装目标 SNI" "$CONF_SNI"; F_SNI="$REPLY"
            F_UUID="$CONF_UUID"; confirm "重新生成 UUID？" "no" && F_UUID=$(k_gen_uuid)
            F_REALITY_PRIV="$CONF_REALITY_PRIV"; F_REALITY_PUB="$CONF_REALITY_PUB"; F_SHORT_ID="$CONF_SHORT_ID"
            confirm "重新生成 Reality 密钥对？" "no" && { k_gen_reality_keypair; F_REALITY_PRIV="$REALITY_PRIV"; F_REALITY_PUB="$REALITY_PUB"; } ;;
    esac
    return 0
}
# 安装流程里独立展示的"准备步骤"：证书生成（幂等）或 Reality 密钥对生成
proto_prep() {
    local id="$1"
    if [ "$id" = "vl" ]; then k_gen_reality_keypair; F_REALITY_PRIV="$REALITY_PRIV"; F_REALITY_PUB="$REALITY_PUB"
    else k_gen_cert; fi
}
# 写入协议配置文件：纯分发到 §4/§5 的 sb_cfg_xx / mh_cfg_xx，VLESS 额外写公钥文件
# （公钥文件内核无关，统一由本函数处理，不下沉到内核实现层）
# tj/at/hy 在此统一兜底 F_CERT/F_KEY/F_SNI：F_DOMAIN 非空（真实证书）沿用已签发的路径与域名作 SNI，
# 否则回退到当前激活内核的默认自签证书路径与 $DEFAULT_CERT_CN，调用方（安装/修改/一键安装）都不必关心这层默认值
proto_write_cfg() {
    local id="$1"
    case "$id" in
        tj|at|hy)
            if [ -z "$F_DOMAIN" ]; then
                F_CERT="${F_CERT:-$([ "$KERNEL" = "mh" ] && echo "$MH_CERT" || echo "$SB_CERT")}"
                F_KEY="${F_KEY:-$([ "$KERNEL" = "mh" ] && echo "$MH_KEY" || echo "$SB_KEY")}"
                F_SNI="$DEFAULT_CERT_CN"
            else
                F_SNI="$F_DOMAIN"
            fi ;;
    esac
    "${KERNEL}_cfg_${id}"
    [ "$id" = "vl" ] && echo "$F_REALITY_PUB" > "$(proto_pub_file vl)"
}
# 客户端 URI（分享链接），使用 PORT / F_* / PUB_IP
proto_uri() {
    local id="$1"
    case "$id" in
        ss)
            local b64; b64=$(printf '%s:%s' "$SS_METHOD" "$F_PASS" | base64 -w0 2>/dev/null || printf '%s:%s' "$SS_METHOD" "$F_PASS" | base64)
            printf 'ss://%s@%s:%s#SS-2022' "$b64" "$PUB_IP" "$PORT" ;;
        tj) printf 'trojan://%s@%s:%s?security=tls&allowInsecure=%s&sni=%s&type=tcp#Trojan' \
                "$F_PASS" "$PUB_IP" "$PORT" "$([ -n "$F_DOMAIN" ] && echo 0 || echo 1)" "$F_SNI" ;;
        vl) printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#VLESS-Reality' \
                "$F_UUID" "$PUB_IP" "$PORT" "$F_SNI" "$F_REALITY_PUB" "$F_SHORT_ID" ;;
        at) printf 'anytls://%s@%s:%s/?insecure=%s&sni=%s#AnyTLS' \
                "$F_PASS" "$PUB_IP" "$PORT" "$([ -n "$F_DOMAIN" ] && echo 0 || echo 1)" "$F_SNI" ;;
        hy) printf 'hysteria2://%s@%s:%s/?insecure=%s&sni=%s#Hysteria2' \
                "$F_PASS" "$PUB_IP" "$PORT" "$([ -n "$F_DOMAIN" ] && echo 0 || echo 1)" "$F_SNI" ;;
        sn) printf 'Snell = snell, %s, %s, psk=%s, obfs=%s, version=5, tfo=true' "$PUB_IP" "$PORT" "$F_PASS" "${F_OBFS:-off}" ;;
    esac
}
# 展示字段列表（"标签|值"，一行一个），供节点信息文件与摘要框共用渲染
_cert_mode_label() { [ -n "$F_DOMAIN" ] && echo "真实证书 (${F_DOMAIN})" || echo "自签证书"; }
proto_fields() {
    local id="$1"
    case "$id" in
        ss) printf '端口|%s (%s)\n加密|%s\n密码|%s\n' "$PORT" "$(proto_transport ss)" "$SS_METHOD" "$F_PASS" ;;
        tj) printf '端口|%s (TCP, TLS)\n密码|%s\nSNI |%s\n证书|%s\n' "$PORT" "$F_PASS" "$F_SNI" "$(_cert_mode_label)" ;;
        vl) printf '端口|%s (TCP)\nUUID|%s\nSNI |%s\n公钥|%s\nSID |%s\n' "$PORT" "$F_UUID" "$F_SNI" "$F_REALITY_PUB" "$F_SHORT_ID" ;;
        at) printf '端口|%s (TCP, TLS)\n密码|%s\nSNI |%s\n证书|%s\n' "$PORT" "$F_PASS" "$F_SNI" "$(_cert_mode_label)" ;;
        hy) printf '端口|%s (UDP, TLS)\n密码|%s\nSNI |%s\n证书|%s\n' "$PORT" "$F_PASS" "$F_SNI" "$(_cert_mode_label)" ;;
        sn) printf '端口|%s (TCP)\nPSK |%s\n混淆|%s\n' "$PORT" "$F_PASS" "${F_OBFS:-off}" ;;
    esac
}

###############################################################################
# §8  协议通用引擎（安装 / 配置修改 / 卸载，驱动 §7 的钩子，6 个协议共用同一套流程）
###############################################################################
proto_is_installed() { [ -f "$(proto_cfg_file "$1")" ]; }

_proto_backup() { [ -f "$1" ] && { cp "$1" "$1.bak"; echo 1; } || echo 0; }
_proto_restore() {
    local f="$1" bak="$2"
    if [ "$bak" = "1" ] && [ -f "$f.bak" ]; then mv "$f.bak" "$f"; else rm -f "$f" "$f.bak"; fi
    [ "$KERNEL" = "mh" ] && mh_rebuild_yaml
}
_proto_restore_pub() {
    local pubf="$1" had_bak="$2"
    if [ "$had_bak" = "1" ]; then mv "$pubf.bak" "$pubf"; else rm -f "$pubf" "$pubf.bak"; fi
}

# 写节点信息文件 + 打印摘要框，共用 proto_fields 渲染，避免每协议各写一份格式
_proto_write_info() {
    local id="$1" f
    f=$(proto_info_file "$id")
    {
        echo "[$(proto_name "$id")] ($(k_name))"
        echo "  服务器 : $PUB_IP"
        proto_fields "$id" | while IFS='|' read -r label val; do printf "  %s : %s\n" "$label" "$val"; done
        echo "  URI : $(proto_uri "$id")"
    } > "$f"
}
_proto_show_summary() {
    local id="$1"
    printf "\n"; _box "$(proto_name "$id")" "配置摘要"; hr
    _kv "IP  " "$PUB_IP"
    proto_fields "$id" | while IFS='|' read -r label val; do _kv "$label" "$val"; done
    hr; printf "  ${C}%s${N}\n" "$(proto_uri "$id")"; hr; printf "\n"
}

proto_install() {
    local id="$1" f bak pubf bak_pub
    k_installed || { warn "内核 $(k_name) 尚未安装，请先在主菜单 [7] 安装/切换内核 中安装"; return 1; }
    f=$(proto_cfg_file "$id"); pubf=$(proto_pub_file "$id")
    printf "\n"; _box "安装 $(proto_name "$id") ($(k_name))"; hr
    if proto_is_installed "$id"; then
        warn "$(proto_name "$id") 已安装，重装将生成全新端口/密钥并覆盖现有配置（若新配置校验失败会自动还原）"
        confirm "确认重装？" "no" || { ok "已取消"; return; }
    fi
    PORT=""; F_PASS=""; F_UUID=""; F_SNI=""; F_REALITY_PRIV=""; F_REALITY_PUB=""; F_SHORT_ID=""; F_OBFS=""; F_DOMAIN=""; F_CERT=""; F_KEY=""
    proto_collect_new "$id" "$([ "$id" = "hy" ] && echo UDP)" || return 1
    bak=$(_proto_backup "$f")
    [ -n "$pubf" ] && bak_pub=$([ -f "$pubf" ] && cp "$pubf" "$pubf.bak" && echo 1 || echo 0)
    if proto_has_prep "$id"; then
        steps_init 4; step "$(proto_prep_label "$id")"; proto_prep "$id"
    else
        steps_init 3
    fi
    step "写入配置"; proto_write_cfg "$id"
    step "校验并重启服务"
    if ! k_restart; then
        _proto_restore "$f" "$bak"
        [ -n "$pubf" ] && _proto_restore_pub "$pubf" "$bak_pub"
        k_restart > /dev/null 2>&1
        warn "安装失败，配置已还原为之前状态"
        return 1
    fi
    step "生成节点信息"
    fetch_public_ip
    _proto_write_info "$id"
    rm -f "$f.bak"; [ -n "$pubf" ] && rm -f "$pubf.bak"
    ok "$(proto_name "$id") 安装完成"
    _fw_hint "$PORT" "$(proto_transport "$id")"
    _proto_show_summary "$id"
}

proto_configure() {
    local id="$1" f pubf bak bak_pub
    f=$(proto_cfg_file "$id"); pubf=$(proto_pub_file "$id")
    proto_is_installed "$id" || { warn "尚未安装，请先选择菜单 [1] 安装"; return; }
    proto_read_conf "$id"
    printf "\n"; _box "配置 $(proto_name "$id") ($(k_name))"; hr
    PORT=""; F_PASS=""; F_UUID=""; F_SNI=""; F_REALITY_PRIV=""; F_REALITY_PUB=""; F_SHORT_ID=""; F_OBFS=""; F_DOMAIN=""; F_CERT=""; F_KEY=""
    proto_collect_edit "$id" || return 1
    local old_port="$CONF_PORT"
    bak=$(_proto_backup "$f")
    [ -n "$pubf" ] && bak_pub=$([ -f "$pubf" ] && cp "$pubf" "$pubf.bak" && echo 1 || echo 0)
    proto_write_cfg "$id"
    if ! k_restart; then
        _proto_restore "$f" "$bak"
        [ -n "$pubf" ] && _proto_restore_pub "$pubf" "$bak_pub"
        k_restart > /dev/null 2>&1
        warn "修改失败，配置已还原为修改前状态（原端口 $old_port 仍在使用）"
        return 1
    fi
    fetch_public_ip
    _proto_write_info "$id"
    rm -f "$f.bak"; [ -n "$pubf" ] && rm -f "$pubf.bak"
    ok "配置已更新"
    [ "$PORT" != "$old_port" ] && _fw_hint "$PORT" "$(proto_transport "$id")"
    _proto_show_summary "$id"
}

proto_uninstall() {
    local id="$1" f pubf
    f=$(proto_cfg_file "$id"); pubf=$(proto_pub_file "$id")
    printf "\n"; _box "卸载 $(proto_name "$id") ($(k_name))"; hr
    [ -f "$f" ] || { warn "$(proto_name "$id") 未安装，无需卸载"; return 1; }
    warn "此操作将删除 $(proto_name "$id") 的配置和节点信息，且不可撤销"
    confirm "确认卸载？" "no" || { ok "已取消"; return 1; }
    rm -f "$f" "$(proto_info_file "$id")"
    [ -n "$pubf" ] && rm -f "$pubf"
    [ "$KERNEL" = "mh" ] && mh_rebuild_yaml
    if k_restart; then
        ok "$(proto_name "$id") 已卸载"
    else
        warn "$(proto_name "$id") 的配置文件已删除，但服务重载/重启失败——其他协议可能存在配置问题（如证书缺失），旧进程可能仍在监听旧端口。请检查其他协议配置后重试，或手动执行菜单重启服务"
        return 1
    fi
}

###############################################################################
# §9  菜单（数据驱动：遍历 $PROTO_IDS，不再为每个协议手写菜单分支）
###############################################################################
_status_line() {
    if [ "$1" = "1" ]; then printf "${G}● 已装${N}  ${K}端口 %s${N}" "$2"
    else printf "${K}○ 未安装${N}"; fi
}
_proto_status() {
    local id="$1" f; f=$(proto_cfg_file "$id")
    if [ -f "$f" ]; then
        PROTO_INST=1
        "${KERNEL}_read_${id}" "$f"
        PROTO_PORT="$CONF_PORT"
    else
        PROTO_INST=0; PROTO_PORT=""
    fi
}

_svc_menu_items() {
    printf "\n"
    printf "    ${C}[1]${N}  ${K}安装 / 重装${N}\n"
    printf "    ${C}[2]${N}  ${K}配置修改${N}\n"
    printf "    ${C}[3]${N}  ${K}查看节点信息${N}\n"
    printf "    ${C}[4]${N}  ${K}卸载${N}\n"
    printf "    ${D}[0]  返回${N}\n\n"
    hr
    printf "   ${C}❯${N} ${K}请选择${N} "
}

show_main_menu() {
    clear
    local running="" n=0 id
    k_is_running && running="${G}● 运行中${N}" || running="${Y}● 已停止${N}"
    fetch_public_ip_cached
    _box "多协议代理服务管理" "内核 $(k_name) $(k_version_disp)"
    hr
    printf "    ${K}服务状态${N}   %b\n" "$running"
    printf "    ${K}IP${N}         %s\n" "$PUB_IP"
    hr
    for id in $PROTO_IDS; do
        n=$((n+1))
        _proto_status "$id"
        printf "    ${C}[%d]${N}  ${W}%-20s${N}%b\n" "$n" "$(proto_name "$id")" "$(_status_line $PROTO_INST "$PROTO_PORT")"
    done
    printf "\n"
    printf "    ${C}[7]${N}  ${K}安装 / 切换内核${N}   ${K}(当前: $(k_name))${N}\n"
    printf "    ${C}[8]${N}  ${K}更新 $(k_name) 内核${N}\n"
    printf "    ${C}[9]${N}  ${K}重启 $(k_name) 服务${N}\n"
    printf "    ${C}[10]${N} ${K}查看全部节点信息${N}\n"
    printf "    ${C}[11]${N} ${K}查看最近日志${N}\n"
    printf "    ${C}[12]${N} ${K}导出配置备份${N}\n"
    printf "    ${C}[13]${N} ${K}导入配置备份${N}\n"
    printf "    ${C}[14]${N} ${K}更新脚本自身${N}\n"
    printf "    ${D}[0]  退出${N}\n"
    printf "\n"
    hr
    printf "   ${C}❯${N} ${K}请选择${N} ${K}[0-14]${N} "
    read -r CHOICE || { printf "\n"; exit 0; }
}

# 序号 -> 协议 id（主菜单 [1]-[6] 按 PROTO_IDS 顺序对应，含 Snell）
_proto_by_index() {
    local n=0 id
    for id in $PROTO_IDS; do
        n=$((n+1))
        [ "$n" = "$1" ] && { echo "$id"; return 0; }
    done
    return 1
}

show_svc_menu() {
    clear
    local id="$1"
    _proto_status "$id"
    _box "$(proto_name "$id")" "管理 ($(k_name))"
    hr
    printf "    ${K}状态${N}   %b\n" "$(_status_line $PROTO_INST "$PROTO_PORT")"
    _svc_menu_items
    read -r CHOICE || CHOICE=0
}

_run_submenu() {
    local id="$1"
    while true; do
        show_svc_menu "$id"; printf "\n"
        case "$CHOICE" in
            1) proto_install "$id" ;;
            2) proto_configure "$id" ;;
            3) cat "$(proto_info_file "$id")" 2>/dev/null || warn "未安装" ;;
            4) proto_uninstall "$id" ;;
            0) return ;;
            *) warn "无效选项：${CHOICE}（请输入 0-4）" ;;
        esac
        printf "\n${K}  按 Enter 继续...${N}"; read -r _
    done
}

show_all_info() {
    printf "\n"; _box "全部节点信息" "内核 $(k_name)"; hr
    local id f
    for id in $PROTO_IDS; do
        f=$(proto_info_file "$id")
        [ -f "$f" ] && { cat "$f"; printf "\n"; }
    done
}

# 安装/切换内核子菜单：可分别单独安装/卸载 sing-box / mihomo，切换激活内核不影响另一内核已装协议
show_kernel_menu() {
    clear
    _box "安装 / 切换内核"; hr
    printf "    ${K}当前激活内核${N}   ${G}%s${N}\n" "$(k_name)"
    hr
    local sb_st mh_st
    if [ -x "$SB_BIN" ]; then
        sb_is_running && sb_st="${G}已安装 v$(sb_version) · 运行中${N}" || sb_st="${Y}已安装 v$(sb_version) · 已停止${N}"
    else
        sb_st="${K}未安装${N}"
    fi
    if [ -x "$MH_BIN" ]; then
        mh_is_running && mh_st="${G}已安装 $(mh_version) · 运行中${N}" || mh_st="${Y}已安装 $(mh_version) · 已停止${N}"
    else
        mh_st="${K}未安装${N}"
    fi
    printf "    ${C}[1]${N}  ${W}安装 sing-box 内核${N}       %b\n" "$sb_st"
    printf "    ${C}[2]${N}  ${W}安装 mihomo 内核${N}         %b\n" "$mh_st"
    printf "\n"
    printf "    ${C}[3]${N}  ${K}切换为 sing-box 内核${N}\n"
    printf "    ${C}[4]${N}  ${K}切换为 mihomo 内核${N}\n"
    printf "\n"
    printf "    ${C}[5]${N}  ${K}卸载 sing-box 内核${N}\n"
    printf "    ${C}[6]${N}  ${K}卸载 mihomo 内核${N}\n"
    printf "    ${D}[0]  返回${N}\n\n"
    hr
    printf "   ${C}❯${N} ${K}请选择${N} "
    read -r CHOICE || CHOICE=0
    case "$CHOICE" in
        1) ensure_singbox
           # 若装的不是当前激活内核，装完立刻取消其开机自启，防止重启后两个内核一起自启常驻
           [ "$KERNEL" != "sb" ] && svc_disable "$SB_SVC"
           ok "sing-box 内核已就绪：v$(sb_version)" ;;
        2) ensure_mihomo
           [ "$KERNEL" != "mh" ] && svc_disable "$MH_SVC"
           ok "mihomo 内核已就绪：$(mh_version)" ;;
        3) [ -x "$SB_BIN" ] || { warn "sing-box 尚未安装，请先执行 [1] 安装"; return; }
           kernel_write_active sb; kernel_read_active
           # 两个内核可以都装着，但同一时间只让当前激活的一个真正跑起来，避免双份常驻占内存；
           # mihomo 只停服务、取消开机自启，二进制/配置/协议数据完全保留，随时可切回来恢复运行
           if [ -x "$MH_BIN" ]; then svc_stop "$MH_SVC"; svc_disable "$MH_SVC"; fi
           svc_enable "$SB_SVC"
           if sb_restart; then
               ok "已切换为 sing-box 内核（mihomo 服务已停止，配置保留，可随时切回）"
           else
               warn "已切换为 sing-box 内核，但服务启动失败，请检查上面的报错信息"
           fi ;;
        4) [ -x "$MH_BIN" ] || { warn "mihomo 尚未安装，请先执行 [2] 安装"; return; }
           kernel_write_active mh; kernel_read_active
           if [ -x "$SB_BIN" ]; then svc_stop "$SB_SVC"; svc_disable "$SB_SVC"; fi
           svc_enable "$MH_SVC"
           if mh_restart; then
               ok "已切换为 mihomo 内核（sing-box 服务已停止，配置保留，可随时切回）"
           else
               warn "已切换为 mihomo 内核，但服务启动失败，请检查上面的报错信息"
           fi ;;
        5) sb_uninstall ;;
        6) mh_uninstall ;;
        0) return ;;
        *) warn "无效选项：${CHOICE}（请输入 0-6）" ;;
    esac
    printf "\n${K}  按 Enter 继续...${N}"; read -r _
}

###############################################################################
# §9b  日志查看 / 配置备份与恢复
###############################################################################
k_log() { [ "$KERNEL" = "mh" ] && echo "$MH_LOG" || echo "$SB_LOG"; }
show_recent_log() {
    local f; f=$(k_log)
    printf "\n"; _box "最近日志" "$(k_name) · $f"; hr
    if [ -f "$f" ]; then tail -n 50 "$f"; else warn "日志文件不存在：$f（服务可能尚未启动过）"; fi
    printf "\n"
}

# 导出：把两个内核各自已安装的配置目录(密钥/证书/协议配置)+内核选择状态打包成一个 tar.gz，
# 用 -C / 保存相对路径，恢复时同样以 / 为根解压即可原样落回原位置
backup_export() {
    printf "\n"; _box "导出配置备份"; hr
    local paths="" ts out
    [ -d "$SB_DIR" ] && paths="$paths etc/sing-box"
    [ -d "$MH_DIR" ] && paths="$paths etc/mihomo"
    [ -d "$ACME_DIR" ] && paths="$paths ${ACME_DIR#/}"
    [ -f "$KERNEL_STATE" ] && paths="$paths ${KERNEL_STATE#/}"
    if [ -z "$paths" ]; then warn "未检测到任何已安装内核的配置，无需备份"; return 1; fi
    ts=$(date +%Y%m%d-%H%M%S)
    ask "备份文件保存路径" "${BACKUP_DIR_DEFAULT}/proxy-backup-${ts}.tar.gz"
    out="$REPLY"
    # shellcheck disable=SC2086
    if tar czf "$out" -C / $paths 2>/dev/null; then
        chmod 600 "$out"
        ok "备份已导出：${out}"
        warn "该文件明文包含全部协议的密钥/密码/证书私钥，请妥善保管，不要上传到不受信任的地方"
    else
        warn "备份导出失败"; return 1
    fi
}

# 导入：整体覆盖式解压到 /（同名文件覆盖，不会清空当前目录下备份未包含的其它文件），
# 随后收紧权限、重新读取激活内核、按需重启服务
backup_import() {
    printf "\n"; _box "导入配置备份"; hr
    warn "此操作将用备份文件中的内容覆盖当前 sing-box/mihomo 配置目录及内核选择状态，且不可撤销"
    ask "备份文件路径" ""
    local f="$REPLY"
    [ -z "$f" ] && { warn "路径不能为空，已取消"; return 1; }
    [ -f "$f" ] || { warn "文件不存在：$f"; return 1; }
    tar tzf "$f" > /dev/null 2>&1 || { warn "不是有效的备份文件（tar 格式校验失败）"; return 1; }
    confirm "确认导入并覆盖当前配置？" "no" || { ok "已取消"; return 1; }
    tar xzf "$f" -C / || { warn "解压失败"; return 1; }
    if [ -d "$SB_DIR" ]; then
        chmod 700 "$SB_DIR" "$SB_INFO_DIR" 2>/dev/null
        find "$SB_DIR" -maxdepth 2 -type f ! -perm 600 -exec chmod 600 {} + 2>/dev/null
    fi
    if [ -d "$MH_DIR" ]; then
        chmod 700 "$MH_DIR" "$MH_FRAG_DIR" "$MH_INFO_DIR" 2>/dev/null
        find "$MH_DIR" -maxdepth 2 -type f ! -perm 600 -exec chmod 600 {} + 2>/dev/null
    fi
    [ -d "$ACME_DIR" ] && chmod -R go-rwx "$ACME_DIR" 2>/dev/null
    kernel_read_active
    if k_installed; then
        if k_restart; then ok "配置已导入并重启服务成功"; else warn "配置已导入，但服务重启失败，请检查配置"; fi
    else
        ok "配置已导入（当前激活内核 $(k_name) 尚未安装二进制，请先在 [7] 安装/切换内核 中安装后再重启服务）"
    fi
}

# 更新脚本自身：从 $SELF_UPDATE_URL 下载最新版本覆盖当前正在运行的脚本文件
# 校验顺序：下载成功 → 非空且是 shell 脚本（防止网络异常/404 页面把脚本自身覆盖成垃圾内容）
# → 与当前内容不同（内容相同则跳过）→ sh -n 语法自检通过，才真正替换；旧版本保留一份 .bak
self_update() {
    printf "\n"; _box "更新脚本自身"; hr
    local self_path tmp
    self_path=$(readlink -f "$0" 2>/dev/null); [ -n "$self_path" ] || self_path="$0"
    tmp="/tmp/proxy.sh.new.$$"
    info "正在从 ${SELF_UPDATE_URL} 下载最新版本..."
    if ! curl -fLs --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 -o "$tmp" "$SELF_UPDATE_URL"; then
        rm -f "$tmp"; warn "下载失败，请检查网络或链接是否有效"; return 1
    fi
    if [ ! -s "$tmp" ] || ! head -1 "$tmp" | grep -q '^#!.*sh'; then
        rm -f "$tmp"; warn "下载内容不是有效的 shell 脚本（可能是网络异常或链接已失效），已取消更新"; return 1
    fi
    if cmp -s "$tmp" "$self_path" 2>/dev/null; then
        rm -f "$tmp"; ok "当前已是最新版本，无需更新"; return 0
    fi
    if ! sh -n "$tmp" 2>/tmp/proxy-selfupdate-err.log; then
        rm -f "$tmp"; warn "下载的新版本语法校验未通过，已放弃更新（详情见 /tmp/proxy-selfupdate-err.log，不影响当前正在运行的版本）"; return 1
    fi
    cp "$self_path" "${self_path}.bak" 2>/dev/null
    chmod 755 "$tmp"
    if mv "$tmp" "$self_path"; then
        ok "脚本已更新（旧版本已备份为 ${self_path}.bak），请重新运行 ${self_path} 以使用新版本"
        exit 0
    else
        rm -f "$tmp"; warn "替换脚本文件失败（请检查 ${self_path} 所在目录的写入权限）"; return 1
    fi
}

###############################################################################
# §10  入口
###############################################################################
main() {
    check_root
    check_arch

    # 收紧文件权限基线：全部内容（json配置/info明文密码/密钥/公钥）均含敏感信息，
    # 统一让新建文件默认仅 owner 可读写
    umask 077

    # 并发保护：同时只允许一个实例操作配置，避免两个会话同时改配置互相覆盖损坏
    exec 9> "$LOCK_FILE" || die "无法创建锁文件 $LOCK_FILE"
    if ! flock -n 9; then
        die "已有 proxy.sh 实例正在运行，请等待其结束后重试（锁文件：$LOCK_FILE）"
    fi

    kernel_read_active
    # 不自动下载安装内核——是否安装由用户在 [7] 安装/切换内核 菜单中自行决定；
    # 若当前激活内核已安装，则做一次幂等的运行环境检查（目录/服务文件/权限），不涉及下载
    if k_installed; then
        k_ensure
    else
        warn "当前激活内核 $(k_name) 尚未安装，请先在菜单 [7] 安装/切换内核 中安装"
    fi

    if [ "$1" = "install-all" ]; then
        k_installed || die "当前激活内核 $(k_name) 尚未安装，请先执行 ./proxy.sh 进入菜单 [7] 安装/切换内核 完成安装后再使用 install-all"
        printf "\n"; _box "一键安装全部协议（随机端口，内核 $(k_name)）"; hr
        local id used_ports="" port_snap
        port_snap=$(_listening_snapshot)
        k_gen_cert
        for id in $PROTO_IDS; do
            PORT=""; F_PASS=""; F_UUID=""; F_SNI=""; F_REALITY_PRIV=""; F_REALITY_PUB=""; F_SHORT_ID=""; F_OBFS=""; F_DOMAIN=""; F_CERT=""; F_KEY=""
            PORT=$(gen_port "$used_ports" "$port_snap") || die "无法找到可用端口"
            used_ports="$used_ports $PORT"
            case "$id" in
                ss) F_PASS=$(gen_b64_16) ;;
                tj|at|hy) F_PASS=$(gen_pass) ;;
                sn) F_PASS=$(gen_pass); F_OBFS="off" ;;
                vl) F_SNI="$DEFAULT_SNI"; F_UUID=$(k_gen_uuid); F_SHORT_ID=$(gen_hex 8)
                    k_gen_reality_keypair; F_REALITY_PRIV="$REALITY_PRIV"; F_REALITY_PUB="$REALITY_PUB" ;;
            esac
            proto_write_cfg "$id"
            ok "$(proto_name "$id") 配置已写入 (端口 $PORT)"
        done
        k_restart || die "服务启动失败"
        fetch_public_ip
        for id in $PROTO_IDS; do
            proto_read_conf "$id"
            PORT="$CONF_PORT"; F_PASS="$CONF_PASS"; F_UUID="$CONF_UUID"; F_SNI="$CONF_SNI"
            F_REALITY_PRIV="$CONF_REALITY_PRIV"; F_REALITY_PUB="$CONF_REALITY_PUB"; F_SHORT_ID="$CONF_SHORT_ID"
            F_OBFS="$CONF_OBFS"; F_DOMAIN="$CONF_DOMAIN"; F_CERT="$CONF_CERT"; F_KEY="$CONF_KEY"
            _proto_write_info "$id"
        done
        show_all_info
        warn "若云厂商配置了安全组/防火墙，需自行放行以上全部端口，否则客户端无法连接"
        exit 0
    fi

    while true; do
        show_main_menu
        case "$CHOICE" in
            1|2|3|4|5|6) _run_submenu "$(_proto_by_index "$CHOICE")" ;;
            7) show_kernel_menu ;;
            8) k_update; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            9) k_restart; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            10) show_all_info; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            11) show_recent_log; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            12) backup_export; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            13) backup_import; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            14) self_update; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            0) printf "\n"; exit 0 ;;
            *) warn "无效选项：${CHOICE}（请输入 0-14）" ;;
        esac
    done
}

main "$@"



