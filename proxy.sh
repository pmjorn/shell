#!/bin/ash
# shellcheck disable=SC2059
# proxy.sh · 多内核代理服务端管理工具 · Alpine Linux / OpenRC 专用
#   内核：sing-box / mihomo（可切换，二选一管理，互不干扰，可同时安装运行）
#   协议：Shadowsocks(2022) · Trojan · VLESS+Reality · AnyTLS · Hysteria2
#
#   架构：协议层不再为每个协议手写 install/configure/uninstall，而是由
#   §7 的通用引擎（proto_install/proto_configure/proto_uninstall）驱动；
#   每个协议只需在 §8 的若干"钩子函数"里用 case "$id" 分支提供自己的
#   差异化数据（json 结构/URI 格式/展示字段），架构和内核细节完全解耦。

###############################################################################
# §0  常量
###############################################################################
# ── sing-box 内核 ──
readonly SB_BIN="/usr/local/bin/sing-box"
readonly SB_DIR="/etc/sing-box"
readonly SB_INFO_DIR="${SB_DIR}/info"
readonly SB_CERT="${SB_DIR}/cert.pem"
readonly SB_KEY="${SB_DIR}/private.key"
readonly SB_SVC="sing-box"
readonly SB_INIT="/etc/init.d/sing-box"
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
readonly MH_INIT="/etc/init.d/mihomo"
readonly MH_LOG="/var/log/mihomo.log"
readonly MH_LOGROTATE="/etc/logrotate.d/mihomo"
readonly MH_API="https://api.github.com/repos/MetaCubeX/mihomo/releases"

# ── 通用 ──
readonly DEFAULT_SNI="www.speedtest.net"
readonly DEFAULT_CERT_CN="www.bing.com"
readonly SS_METHOD="2022-blake3-aes-128-gcm"
readonly KERNEL_STATE="/etc/proxy-kernel.conf"
readonly LOCK_FILE="/var/run/proxy.sh.lock"
readonly PROTO_IDS="ss tj vl at hy"

# ── ANSI（三色方案：功能语义色独立，其余统一）──
R='\033[0;38;2;244;54;6m' G='\033[0;38;2;31;147;89m' Y='\033[0;38;2;156;125;33m' C='\033[0;38;2;31;147;89m'
B='\033[1m'    D='\033[0;38;2;31;147;89m'    W='\033[0;38;2;31;147;89m' N='\033[0m'
K='\033[0;38;2;31;147;89m'

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
check_alpine() { [ -f /etc/alpine-release ] || die "此脚本仅支持 Alpine Linux（依赖 apk / rc-service / rc-update）"; }
check_arch()   {
    case "$(uname -m)" in
        aarch64|x86_64|amd64) ;;
        *) die "不支持的系统架构: $(uname -m)（仅支持 x86_64 / aarch64）" ;;
    esac
}

ensure_pkgs() {
    local missing="" p
    for p in "$@"; do
        apk info -e "$p" > /dev/null 2>&1 || missing="$missing $p"
    done
    [ -z "$missing" ] && return 0
    apk update -q > /dev/null 2>&1 || true
    # shellcheck disable=SC2086
    apk add -q $missing > /dev/null 2>&1 || die "安装依赖失败：${missing}（请检查 apk 仓库源是否可访问，或手动执行 apk add${missing} 查看详细报错）"
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

_port_in_use() {
    if   command -v ss      > /dev/null 2>&1; then
        ss -tulnp 2>/dev/null | grep -qE ":${1}( |$)"
    elif command -v netstat > /dev/null 2>&1; then
        netstat -tulnp 2>/dev/null | grep -qE ":${1}( |$)"
    else
        return 1
    fi
}

gen_port() {
    local exclude=" $1 " port seed attempts=0
    while [ $attempts -lt 20 ]; do
        seed=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
        port=$(awk -v s="$seed" 'BEGIN{srand(s+0); print int(rand()*35000)+20000}')
        if ! _port_in_use "$port" && [ "${exclude#* "$port" }" = "$exclude" ]; then
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

k_name()  { [ "$KERNEL" = "mh" ] && echo "mihomo" || echo "sing-box"; }
k_bin()   { [ "$KERNEL" = "mh" ] && echo "$MH_BIN" || echo "$SB_BIN"; }
k_installed() { [ -x "$(k_bin)" ]; }
k_version() {
    if [ "$KERNEL" = "mh" ]; then
        "$MH_BIN" -v 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1
    else
        "$SB_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}
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
_sb_arch() {
    case "$(uname -m)" in
        aarch64) echo "arm64" ;;
        x86_64|amd64) echo "amd64" ;;
        *) die "不支持的系统架构: $(uname -m)" ;;
    esac
}
_sb_latest_tag() {
    curl -sf --connect-timeout 5 --max-time 10 "${SB_API}/latest" | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1
}
sb_download() {
    local ver="$1" arch tmp url
    arch=$(_sb_arch)
    if [ -z "$ver" ]; then
        ver=$(_sb_latest_tag)
        [ -z "$ver" ] && { warn "无法获取 sing-box 最新版本号，请检查网络"; return 1; }
    fi
    tmp="/tmp/sing-box-$$"
    url="https://github.com/SagerNet/sing-box/releases/download/${ver}/sing-box-${ver#v}-linux-${arch}-musl.tar.gz"
    info "下载 sing-box ${ver} (linux-${arch}-musl)..."
    mkdir -p "$tmp"
    curl -fLs --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 -o "${tmp}.tar.gz" "$url" \
        || { rm -rf "$tmp" "${tmp}.tar.gz"; warn "下载失败：$url"; return 1; }
    tar xzf "${tmp}.tar.gz" -C "$tmp" --strip-components=1 || { rm -rf "$tmp" "${tmp}.tar.gz"; warn "解压失败"; return 1; }
    [ -x "${tmp}/sing-box" ] || { rm -rf "$tmp" "${tmp}.tar.gz"; warn "解压后未找到可执行文件"; return 1; }
    install -m 755 "${tmp}/sing-box" "$SB_BIN"
    rm -rf "$tmp" "${tmp}.tar.gz"
}
sb_write_init() {
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
}
sb_write_logrotate() {
    cat > "$SB_LOGROTATE" << EOF
${SB_LOG} {
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
            sb_is_running && (exec 9>&-; rc-service "$SB_SVC" reload > /dev/null 2>&1)
        fi
    else
        sb_write_base
    fi
    [ -f "$SB_LOGROTATE" ] || sb_write_logrotate
    rc-update add sing-box default > /dev/null 2>&1 || true
}
sb_version() { "$SB_BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
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
sb_gen_cert() {
    local cn="${1:-$DEFAULT_CERT_CN}"
    [ -f "$SB_CERT" ] && [ -f "$SB_KEY" ] && return 0
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$SB_KEY" -out "$SB_CERT" -days 3650 -nodes \
        -subj "/CN=${cn}" -addext "subjectAltName=DNS:${cn}" > /dev/null 2>&1
    [ -f "$SB_CERT" ] || die "生成自签证书失败"
    chmod 600 "$SB_KEY"
}
sb_checkconfig() { "$SB_BIN" check -C "$SB_DIR" 2>&1; }
# 优先热重载（HUP，不打断其他协议现有连接）；服务未运行或reload失败时降级为完整重启
# 调用 rc-service 时须在子 shell 里关闭锁 fd（9），否则 supervise-daemon 会继承并永久占用该 fd
sb_restart() {
    local out
    out=$(sb_checkconfig)
    if [ -n "$out" ]; then
        warn "配置校验失败，服务未重启："
        printf "%s\n" "$out" >&2
        return 1
    fi
    if sb_is_running && (exec 9>&-; rc-service "$SB_SVC" reload > /dev/null 2>&1); then
        ok "配置已热重载（其他协议连接未受影响）"
        return 0
    fi
    (exec 9>&-; rc-service "$SB_SVC" restart > /dev/null 2>&1)
    local i=0
    printf "${C}  等待服务启动${N}"
    while [ $i -lt 10 ]; do
        rc-service "$SB_SVC" status 2>/dev/null | grep -q started && { printf " ${G}就绪${N}\n"; return 0; }
        printf "${C}.${N}"; sleep 1; i=$((i+1))
    done
    printf " ${Y}超时${N}\n"; return 1
}
sb_is_running() { rc-service "$SB_SVC" status 2>/dev/null | grep -q started; }

# ── sing-box 各协议 json schema（写配置：用 $PORT/$F_xxx 全局变量；读配置：$1=配置文件路径）──
sb_cfg_ss() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg method "$SS_METHOD" \
        '{ inbounds: [{ type: "shadowsocks", tag: "shadowsocks-in", listen: "::", listen_port: $port, method: $method, password: $pass }] }' \
        > "$(proto_cfg_file ss)"
}
sb_read_ss() { CONF_PORT=$(jq -r '.inbounds[0].listen_port' "$1"); CONF_PASS=$(jq -r '.inbounds[0].password' "$1"); }

sb_cfg_tj() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$SB_CERT" --arg key "$SB_KEY" \
        '{ inbounds: [{ type: "trojan", tag: "trojan-in", listen: "::", listen_port: $port,
           users: [{ name: "user", password: $pass }], tls: { enabled: true, certificate_path: $cert, key_path: $key } }] }' \
        > "$(proto_cfg_file tj)"
}
sb_read_tj() { CONF_PORT=$(jq -r '.inbounds[0].listen_port' "$1"); CONF_PASS=$(jq -r '.inbounds[0].users[0].password' "$1"); }

sb_cfg_vl() {
    jq -n --argjson port "$PORT" --arg uuid "$F_UUID" --arg sni "$F_SNI" --arg priv "$F_REALITY_PRIV" --arg sid "$F_SHORT_ID" \
        '{ inbounds: [{ type: "vless", tag: "vless-in", listen: "::", listen_port: $port,
           users: [{ name: "user", uuid: $uuid, flow: "xtls-rprx-vision" }],
           tls: { enabled: true, server_name: $sni,
             reality: { enabled: true, handshake: { server: $sni, server_port: 443 }, private_key: $priv, short_id: [$sid] } } }] }' \
        > "$(proto_cfg_file vl)"
}
sb_read_vl() {
    CONF_PORT=$(jq -r '.inbounds[0].listen_port' "$1"); CONF_UUID=$(jq -r '.inbounds[0].users[0].uuid' "$1")
    CONF_SNI=$(jq -r '.inbounds[0].tls.server_name'         "$1")
    CONF_REALITY_PRIV=$(jq -r '.inbounds[0].tls.reality.private_key' "$1")
    CONF_SHORT_ID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$1")
}

sb_cfg_at() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$SB_CERT" --arg key "$SB_KEY" \
        '{ inbounds: [{ type: "anytls", tag: "anytls-in", listen: "::", listen_port: $port,
           users: [{ name: "user", password: $pass }], tls: { enabled: true, certificate_path: $cert, key_path: $key } }] }' \
        > "$(proto_cfg_file at)"
}
sb_read_at() { CONF_PORT=$(jq -r '.inbounds[0].listen_port' "$1"); CONF_PASS=$(jq -r '.inbounds[0].users[0].password' "$1"); }

sb_cfg_hy() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$SB_CERT" --arg key "$SB_KEY" \
        '{ inbounds: [{ type: "hysteria2", tag: "hy2-in", listen: "::", listen_port: $port,
           users: [{ name: "user", password: $pass }], tls: { enabled: true, certificate_path: $cert, key_path: $key } }] }' \
        > "$(proto_cfg_file hy)"
}
sb_read_hy() { CONF_PORT=$(jq -r '.inbounds[0].listen_port' "$1"); CONF_PASS=$(jq -r '.inbounds[0].users[0].password' "$1"); }

# 卸载 sing-box 内核：完全删除（停服务/移除开机自启/删二进制+init脚本+conf.d+日志轮转配置+
# 全部日志文件(含logrotate轮转产生的历史.gz)+协议配置目录+运行时目录），不校验其他内核状态，两内核完全独立
sb_uninstall() {
    printf "\n"; _box "卸载 sing-box 内核"; hr
    [ -x "$SB_BIN" ] || { warn "sing-box 尚未安装，无需卸载"; return 1; }
    warn "此操作将完全删除 sing-box 相关的全部文件：内核二进制、服务脚本、日志轮转配置、"
    warn "协议配置目录 ${SB_DIR}（含全部节点密钥/证书）、运行时目录 /var/lib/sing-box、全部日志文件，且不可撤销"
    confirm "确认完全卸载 sing-box 内核？" "no" || { ok "已取消"; return 1; }
    (exec 9>&-; rc-service "$SB_SVC" stop > /dev/null 2>&1)
    rc-update del sing-box default > /dev/null 2>&1 || true
    rm -f "$SB_BIN" "$SB_INIT" "/etc/conf.d/sing-box" "$SB_LOGROTATE"
    rm -f "$SB_LOG" "$SB_LOG".*
    rm -rf "$SB_DIR" /var/lib/sing-box
    ok "sing-box 内核已完全卸载（二进制、配置、密钥、日志已全部清除）"
    if [ "$KERNEL" = "sb" ]; then
        [ -x "$MH_BIN" ] && { kernel_write_active mh; kernel_read_active; info "已自动切换激活内核为 mihomo"; }
    fi
    _kernel_cleanup_state_if_none
}

###############################################################################
# §5  mihomo 内核实现
###############################################################################
_mh_arch() {
    case "$(uname -m)" in
        aarch64) echo "arm64" ;;
        x86_64|amd64) echo "amd64" ;;
        *) die "不支持的系统架构: $(uname -m)" ;;
    esac
}
_mh_latest_tag() {
    curl -sf --connect-timeout 5 --max-time 10 "${MH_API}/latest" | grep '"tag_name"' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1
}
mh_download() {
    local ver="$1" arch tmp url
    arch=$(_mh_arch)
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
}
mh_write_logrotate() {
    cat > "$MH_LOGROTATE" << EOF
${MH_LOG} {
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
    jq -n '
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
    for id in $PROTO_IDS; do
        f=$(proto_cfg_file "$id")
        [ -f "$f" ] && listeners=$(echo "$listeners" | jq --slurpfile l "$f" '. + $l')
    done
    base=$(mh_base_json)
    tmp="${MH_YAML}.tmp"
    echo "$base" | jq --argjson listeners "$listeners" '.listeners = $listeners' \
        | yq -p json -o yaml '.' - > "$tmp" 2>/dev/null
    [ -s "$tmp" ] || { rm -f "$tmp"; warn "生成 config.yaml 失败（yq 转换出错）"; return 1; }
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
    rc-update add mihomo default > /dev/null 2>&1 || true
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
mh_gen_cert() {
    local cn="${1:-$DEFAULT_CERT_CN}"
    [ -f "$MH_CERT" ] && [ -f "$MH_KEY" ] && return 0
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$MH_KEY" -out "$MH_CERT" -days 3650 -nodes \
        -subj "/CN=${cn}" -addext "subjectAltName=DNS:${cn}" > /dev/null 2>&1
    [ -f "$MH_CERT" ] || die "生成自签证书失败"
    chmod 600 "$MH_KEY"
}
mh_checkconfig() { "$MH_BIN" -t -d "$MH_DIR" 2>&1; }
mh_is_running() { rc-service "$MH_SVC" status 2>/dev/null | grep -q started; }

# ── mihomo 各协议 fragment schema（写配置：用 $PORT/$F_xxx 全局变量；读配置：$1=配置文件路径）──
# 每次写完 fragment 都需重建整份 config.yaml，因此写函数末尾统一调用 mh_rebuild_yaml
mh_cfg_ss() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg method "$SS_METHOD" \
        '{ name: "shadowsocks-in", type: "shadowsocks", port: $port, listen: "::", cipher: $method, password: $pass, udp: true }' \
        > "$(proto_cfg_file ss)"
    mh_rebuild_yaml
}
mh_read_ss() { CONF_PORT=$(jq -r '.port' "$1"); CONF_PASS=$(jq -r '.password' "$1"); }

mh_cfg_tj() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$MH_CERT" --arg key "$MH_KEY" \
        '{ name: "trojan-in", type: "trojan", port: $port, listen: "::",
           users: [{ username: "user", password: $pass }], certificate: $cert, "private-key": $key }' \
        > "$(proto_cfg_file tj)"
    mh_rebuild_yaml
}
mh_read_tj() { CONF_PORT=$(jq -r '.port' "$1"); CONF_PASS=$(jq -r '.users[0].password' "$1"); }

mh_cfg_vl() {
    jq -n --argjson port "$PORT" --arg uuid "$F_UUID" --arg sni "$F_SNI" --arg priv "$F_REALITY_PRIV" --arg sid "$F_SHORT_ID" \
        '{ name: "vless-in", type: "vless", port: $port, listen: "::",
           users: [{ username: "user", uuid: $uuid, flow: "xtls-rprx-vision" }],
           "reality-config": { dest: ($sni + ":443"), "private-key": $priv, "short-id": [$sid], "server-names": [$sni] } }' \
        > "$(proto_cfg_file vl)"
    mh_rebuild_yaml
}
mh_read_vl() {
    CONF_PORT=$(jq -r '.port' "$1"); CONF_UUID=$(jq -r '.users[0].uuid' "$1")
    CONF_SNI=$(jq -r '."reality-config"."server-names"[0]' "$1")
    CONF_REALITY_PRIV=$(jq -r '."reality-config"."private-key"'     "$1")
    CONF_SHORT_ID=$(jq -r '."reality-config"."short-id"[0]'     "$1")
}

mh_cfg_at() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$MH_CERT" --arg key "$MH_KEY" \
        '{ name: "anytls-in", type: "anytls", port: $port, listen: "::",
           users: { user: $pass }, certificate: $cert, "private-key": $key }' \
        > "$(proto_cfg_file at)"
    mh_rebuild_yaml
}
mh_read_at() { CONF_PORT=$(jq -r '.port' "$1"); CONF_PASS=$(jq -r '.users.user' "$1"); }

mh_cfg_hy() {
    jq -n --argjson port "$PORT" --arg pass "$F_PASS" --arg cert "$MH_CERT" --arg key "$MH_KEY" \
        '{ name: "hy2-in", type: "hysteria2", port: $port, listen: "::",
           users: { user: $pass }, alpn: ["h3"], certificate: $cert, "private-key": $key }' \
        > "$(proto_cfg_file hy)"
    mh_rebuild_yaml
}
mh_read_hy() { CONF_PORT=$(jq -r '.port' "$1"); CONF_PASS=$(jq -r '.users.user' "$1"); }

# 卸载 mihomo 内核：完全删除（停服务/移除开机自启/删二进制+init脚本+日志轮转配置+
# 全部日志文件(含logrotate轮转产生的历史.gz)+协议配置目录）
mh_uninstall() {
    printf "\n"; _box "卸载 mihomo 内核"; hr
    [ -x "$MH_BIN" ] || { warn "mihomo 尚未安装，无需卸载"; return 1; }
    warn "此操作将完全删除 mihomo 相关的全部文件：内核二进制、服务脚本、日志轮转配置、"
    warn "协议配置目录 ${MH_DIR}（含全部节点密钥/证书）、全部日志文件，且不可撤销"
    confirm "确认完全卸载 mihomo 内核？" "no" || { ok "已取消"; return 1; }
    (exec 9>&-; rc-service "$MH_SVC" stop > /dev/null 2>&1)
    rc-update del mihomo default > /dev/null 2>&1 || true
    rm -f "$MH_BIN" "$MH_INIT" "$MH_LOGROTATE"
    rm -f "$MH_LOG" "$MH_LOG".*
    rm -rf "$MH_DIR"
    ok "mihomo 内核已完全卸载（二进制、配置、密钥、日志已全部清除）"
    if [ "$KERNEL" = "mh" ]; then
        [ -x "$SB_BIN" ] && { kernel_write_active sb; kernel_read_active; info "已自动切换激活内核为 sing-box"; }
    fi
    _kernel_cleanup_state_if_none
}
mh_restart() {
    local out
    out=$(mh_checkconfig)
    if ! echo "$out" | grep -qi "configuration file .* test is successful"; then
        warn "配置校验失败，服务未重启："
        printf "%s\n" "$out" >&2
        return 1
    fi
    (exec 9>&-; rc-service "$MH_SVC" restart > /dev/null 2>&1)
    local i=0
    printf "${C}  等待服务启动${N}"
    while [ $i -lt 10 ]; do
        rc-service "$MH_SVC" status 2>/dev/null | grep -q started && { printf " ${G}就绪${N}\n"; return 0; }
        printf "${C}.${N}"; sleep 1; i=$((i+1))
    done
    printf " ${Y}超时${N}\n"; return 1
}

###############################################################################
# §6  协议元数据（路径 / 显示名 / 传输层，按 id 分发：ss tj vl at hy）
###############################################################################
proto_name() {
    case "$1" in
        ss) echo "Shadowsocks 2022" ;; tj) echo "Trojan" ;; vl) echo "VLESS + Reality" ;;
        at) echo "AnyTLS" ;; hy) echo "Hysteria2" ;;
    esac
}
proto_transport() {
    case "$1" in ss) echo "tcp+udp" ;; hy) echo "udp" ;; *) echo "tcp" ;; esac
}
# sing-box 用独立 confdir json，mihomo 用单文件 fragment json，按 $KERNEL 分发
proto_cfg_file() {
    case "$KERNEL:$1" in
        sb:ss) echo "$SB_DIR/10-shadowsocks.json" ;; mh:ss) echo "$MH_FRAG_DIR/shadowsocks.json" ;;
        sb:tj) echo "$SB_DIR/20-trojan.json" ;;     mh:tj) echo "$MH_FRAG_DIR/trojan.json" ;;
        sb:vl) echo "$SB_DIR/30-vless.json" ;;      mh:vl) echo "$MH_FRAG_DIR/vless.json" ;;
        sb:at) echo "$SB_DIR/40-anytls.json" ;;     mh:at) echo "$MH_FRAG_DIR/anytls.json" ;;
        sb:hy) echo "$SB_DIR/50-hysteria2.json" ;;  mh:hy) echo "$MH_FRAG_DIR/hysteria2.json" ;;
    esac
}
proto_info_file() {
    local dir; dir=$([ "$KERNEL" = "mh" ] && echo "$MH_INFO_DIR" || echo "$SB_INFO_DIR")
    case "$1" in
        ss) echo "$dir/shadowsocks.txt" ;; tj) echo "$dir/trojan.txt" ;; vl) echo "$dir/vless.txt" ;;
        at) echo "$dir/anytls.txt" ;;      hy) echo "$dir/hysteria2.txt" ;;
    esac
}
# 仅 VLESS 需要额外的 reality 公钥文件（客户端连接需要，但服务端配置不存公钥本身）
proto_pub_file() {
    [ "$1" = "vl" ] || return 0
    [ "$KERNEL" = "mh" ] && echo "$MH_DIR/.vless-pubkey" || echo "$SB_DIR/.vless-pubkey"
}
proto_has_prep()   { [ "$1" != "ss" ]; }
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
proto_collect_new() {
    local id="$1"
    ask "监听端口（留空随机${2:+，$2}）" ""
    if [ -z "$REPLY" ]; then PORT=$(gen_port) || return 1; else PORT="$REPLY"; _chk_port_free "$PORT" || return 1; fi
    case "$id" in
        ss) F_PASS=$(gen_b64_16) ;;
        tj|at|hy) F_PASS=$(gen_pass) ;;
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
        tj|at|hy) F_PASS="$CONF_PASS"; confirm "重新生成密码？" "no" && F_PASS=$(gen_pass) ;;
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
proto_write_cfg() {
    local id="$1"
    "${KERNEL}_cfg_${id}"
    [ "$id" = "vl" ] && echo "$F_REALITY_PUB" > "$(proto_pub_file vl)"
}
# 客户端 URI（分享链接），使用 PORT / F_* / PUB_IP
proto_uri() {
    local id="$1"
    case "$id" in
        ss)
            local b64; b64=$(printf '%s:%s' "$SS_METHOD" "$F_PASS" | base64 -w0 2>/dev/null || printf '%s:%s' "$SS_METHOD" "$F_PASS" | base64)
            printf 'shadowsocks://%s@%s:%s#SS-2022' "$b64" "$PUB_IP" "$PORT" ;;
        tj) printf 'trojan://%s@%s:%s?security=tls&allowInsecure=1&sni=%s&type=tcp#Trojan' "$F_PASS" "$PUB_IP" "$PORT" "$DEFAULT_CERT_CN" ;;
        vl) printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#VLESS-Reality' \
                "$F_UUID" "$PUB_IP" "$PORT" "$F_SNI" "$F_REALITY_PUB" "$F_SHORT_ID" ;;
        at) printf 'anytls://%s@%s:%s/?insecure=1&sni=%s#AnyTLS' "$F_PASS" "$PUB_IP" "$PORT" "$DEFAULT_CERT_CN" ;;
        hy) printf 'hysteria2://%s@%s:%s/?insecure=1&sni=%s#Hysteria2' "$F_PASS" "$PUB_IP" "$PORT" "$DEFAULT_CERT_CN" ;;
    esac
}
# 展示字段列表（"标签|值"，一行一个），供节点信息文件与摘要框共用渲染
proto_fields() {
    local id="$1"
    case "$id" in
        ss) printf '端口|%s (%s)\n加密|%s\n密码|%s\n' "$PORT" "$(proto_transport ss)" "$SS_METHOD" "$F_PASS" ;;
        tj) printf '端口|%s (TCP, TLS 自签证书)\n密码|%s\nSNI |%s\n' "$PORT" "$F_PASS" "$DEFAULT_CERT_CN" ;;
        vl) printf '端口|%s (TCP)\nUUID|%s\nSNI |%s\n公钥|%s\nSID |%s\n' "$PORT" "$F_UUID" "$F_SNI" "$F_REALITY_PUB" "$F_SHORT_ID" ;;
        at) printf '端口|%s (TCP, TLS 自签证书)\n密码|%s\nSNI |%s\n' "$PORT" "$F_PASS" "$DEFAULT_CERT_CN" ;;
        hy) printf '端口|%s (UDP, TLS 自签证书)\n密码|%s\nSNI |%s\n' "$PORT" "$F_PASS" "$DEFAULT_CERT_CN" ;;
    esac
}

###############################################################################
# §8  协议通用引擎（安装 / 配置修改 / 卸载，驱动 §7 的钩子，5 个协议共用同一套流程）
###############################################################################
proto_is_installed() { [ -f "$(proto_cfg_file "$1")" ]; }

_proto_backup() { [ -f "$1" ] && { cp "$1" "$1.bak"; echo 1; } || echo 0; }
_proto_restore() {
    if [ "$2" = "1" ] && [ -f "$1.bak" ]; then mv "$1.bak" "$1"; else rm -f "$1" "$1.bak"; fi
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
    k_installed || { warn "内核 $(k_name) 尚未安装，请先在主菜单 [6] 安装/切换内核 中安装"; return 1; }
    f=$(proto_cfg_file "$id"); pubf=$(proto_pub_file "$id")
    printf "\n"; _box "安装 $(proto_name "$id") ($(k_name))"; hr
    if proto_is_installed "$id"; then
        warn "$(proto_name "$id") 已安装，重装将生成全新端口/密钥并覆盖现有配置（若新配置校验失败会自动还原）"
        confirm "确认重装？" "no" || { ok "已取消"; return; }
    fi
    PORT=""; F_PASS=""; F_UUID=""; F_SNI=""; F_REALITY_PRIV=""; F_REALITY_PUB=""; F_SHORT_ID=""
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
    PORT=""; F_PASS=""; F_UUID=""; F_SNI=""; F_REALITY_PRIV=""; F_REALITY_PUB=""; F_SHORT_ID=""
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
        "${KERNEL}_read_${id}" "$f"; PROTO_PORT="$CONF_PORT"
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
    printf "    ${C}[6]${N}  ${K}安装 / 切换内核${N}   ${K}(当前: $(k_name))${N}\n"
    printf "    ${C}[7]${N}  ${K}更新 $(k_name) 内核${N}\n"
    printf "    ${C}[8]${N}  ${K}重启 $(k_name) 服务${N}\n"
    printf "    ${C}[9]${N}  ${K}查看全部节点信息${N}\n"
    printf "    ${D}[0]  退出${N}\n"
    printf "\n"
    hr
    printf "   ${C}❯${N} ${K}请选择${N} ${K}[0-9]${N} "
    read -r CHOICE || { printf "\n"; exit 0; }
}

# 序号 -> 协议 id（主菜单 [1]-[5] 按 PROTO_IDS 顺序对应）
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
    [ -x "$SB_BIN" ] && sb_st="${G}已安装 v$(sb_version)${N}" || sb_st="${K}未安装${N}"
    [ -x "$MH_BIN" ] && mh_st="${G}已安装 $(mh_version)${N}" || mh_st="${K}未安装${N}"
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
        1) ensure_singbox; ok "sing-box 内核已就绪：v$(sb_version)" ;;
        2) ensure_mihomo;  ok "mihomo 内核已就绪：$(mh_version)" ;;
        3) [ -x "$SB_BIN" ] || { warn "sing-box 尚未安装，请先执行 [1] 安装"; return; }
           kernel_write_active sb; kernel_read_active
           ok "已切换为 sing-box 内核（协议菜单现在操作 sing-box 的配置）" ;;
        4) [ -x "$MH_BIN" ] || { warn "mihomo 尚未安装，请先执行 [2] 安装"; return; }
           kernel_write_active mh; kernel_read_active
           ok "已切换为 mihomo 内核（协议菜单现在操作 mihomo 的配置）" ;;
        5) sb_uninstall ;;
        6) mh_uninstall ;;
        0) return ;;
        *) warn "无效选项：${CHOICE}（请输入 0-6）" ;;
    esac
    printf "\n${K}  按 Enter 继续...${N}"; read -r _
}

###############################################################################
# §10  入口
###############################################################################
main() {
    check_root
    check_alpine
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
    # 不自动下载安装内核——是否安装由用户在 [6] 安装/切换内核 菜单中自行决定；
    # 若当前激活内核已安装，则做一次幂等的运行环境检查（目录/服务文件/权限），不涉及下载
    if k_installed; then
        k_ensure
    else
        warn "当前激活内核 $(k_name) 尚未安装，请先在菜单 [6] 安装/切换内核 中安装"
    fi

    if [ "$1" = "install-all" ]; then
        k_installed || die "当前激活内核 $(k_name) 尚未安装，请先执行 ./proxy.sh 进入菜单 [6] 安装/切换内核 完成安装后再使用 install-all"
        printf "\n"; _box "一键安装全部协议（随机端口，内核 $(k_name)）"; hr
        local id used_ports=""
        k_gen_cert
        for id in $PROTO_IDS; do
            PORT=""; F_PASS=""; F_UUID=""; F_SNI=""; F_REALITY_PRIV=""; F_REALITY_PUB=""; F_SHORT_ID=""
            PORT=$(gen_port "$used_ports") || die "无法找到可用端口"
            used_ports="$used_ports $PORT"
            case "$id" in
                ss) F_PASS=$(gen_b64_16) ;;
                tj|at|hy) F_PASS=$(gen_pass) ;;
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
            _proto_write_info "$id"
        done
        show_all_info
        warn "若云厂商配置了安全组/防火墙，需自行放行以上全部端口，否则客户端无法连接"
        exit 0
    fi

    while true; do
        show_main_menu
        case "$CHOICE" in
            1|2|3|4|5) _run_submenu "$(_proto_by_index "$CHOICE")" ;;
            6) show_kernel_menu ;;
            7) k_update; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            8) k_restart; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            9) show_all_info; printf "\n${K}  按 Enter 继续...${N}"; read -r _ ;;
            0) printf "\n"; exit 0 ;;
            *) warn "无效选项：${CHOICE}（请输入 0-9）" ;;
        esac
    done
}

main "$@"



