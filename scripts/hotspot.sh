#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - Root 热点共享
#  - 检测热点 / USB 网络共享接口
#  - 将热点客户端流量策略路由到当前内核 TUN
#  - iptables 转发 / NAT / DNS 重定向
#  - 幂等清理，保留配置文件
# ============================================================

NC_HS_FWD_CHAIN="NC_HS_FWD"
NC_HS_IN_CHAIN="NC_HS_IN"
NC_HS_NAT_CHAIN="NC_HS_NAT"
NC_HS_DNS_CHAIN="NC_HS_DNS"

nc_hotspot_log() {
    mkdir -p "$NC_RUN" 2>/dev/null
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$NC_HOTSPOT_LOG" 2>/dev/null
}

nc_hotspot_ipt() {
    if iptables -w "$@" 2>/dev/null; then
        return 0
    fi
    iptables "$@" 2>/dev/null
}

# 列出有 IPv4 地址的热点接口；USB 接口由设置决定是否包含
nc_hotspot_ifaces() {
    local _if _usb _want_usb
    _usb=${1:-$NC_HOTSPOT_USB}
    ip -4 -o addr show 2>/dev/null | while IFS= read -r _line; do
        _if=$(printf '%s\n' "$_line" | sed -n 's/^[0-9][0-9]*: \([^ ]*\) .*/\1/p')
        [ -n "$_if" ] || continue
        case "$_if" in
            ap*|softap*|swlan*|wlan[1-9]*) ;;
            rndis*|ncm*)
                [ "$_usb" = "true" ] || continue
                ;;
            *) continue ;;
        esac
        printf '%s\n' "$_if"
    done
}

nc_hotspot_normalize_cidr() {
    local _a _b _c _d _cidr _i _ip _mask _net _num _oldifs _pfx _shift
    _cidr=$1
    _ip=${_cidr%/*}
    _pfx=${_cidr#*/}
    case "$_pfx" in *[!0-9]*|"") return 1 ;; esac
    [ "$_pfx" -ge 0 ] && [ "$_pfx" -le 32 ] || return 1
    _oldifs=$IFS
    IFS='.'
    # shellcheck disable=SC2086
    set -- $_ip
    IFS=$_oldifs
    [ "$#" -eq 4 ] || return 1
    _a=$1; _b=$2; _c=$3; _d=$4
    for _i in "$_a" "$_b" "$_c" "$_d"; do
        case "$_i" in *[!0-9]*|"") return 1 ;; esac
        [ "$_i" -le 255 ] || return 1
    done
    _num=$((_a * 16777216 + _b * 65536 + _c * 256 + _d))
    _mask=0
    _i=0
    while [ "$_i" -lt "$_pfx" ]; do
        _mask=$((_mask * 2 + 1))
        _i=$((_i + 1))
    done
    _shift=$((32 - _pfx))
    [ "$_shift" -gt 0 ] && _mask=$((_mask << _shift))
    _net=$((_num & _mask))
    printf '%d.%d.%d.%d/%d' \
        "$(((_net / 16777216) & 255))" \
        "$(((_net / 65536) & 255))" \
        "$(((_net / 256) & 255))" \
        "$((_net & 255))" \
        "$_pfx"
}

nc_hotspot_iface_subnet() {
    local _cidr _if _route
    _if=$1
    _route=$(ip -4 route show dev "$_if" 2>/dev/null | sed -n 's/^\([0-9.]*\/[0-9][0-9]*\) .*/\1/p' | head -n 1)
    [ -n "$_route" ] && { printf '%s' "$_route"; return 0; }
    _cidr=$(ip -4 -o addr show dev "$_if" 2>/dev/null | sed -n 's/.* inet \([0-9.]*\/[0-9][0-9]*\).*/\1/p' | head -n 1)
    [ -n "$_cidr" ] || return 1
    nc_hotspot_normalize_cidr "$_cidr"
}

nc_hotspot_tun_table() {
    local _best _default _line _table _tun _tmp
    _tun=$1
    _best=""
    _default=""
    _tmp="$NC_TMP/hotspot-routes.$$"
    ip -4 route show table all >"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    while IFS= read -r _line; do
        case "$_line" in
            *"dev $_tun"*) ;;
            *) continue ;;
        esac
        _table=254
        case "$_line" in
            *" table "*)
                _table=$(printf '%s\n' "$_line" | awk '{for(i=1;i<=NF;i++) if($i=="table"){print $(i+1); exit}}')
                ;;
        esac
        [ -n "$_table" ] || _table=254
        case "$_table" in
            main) _table=254 ;;
            local) _table=255 ;;
        esac
        case "$_line" in
            *"default "*) _default=$_table ;;
        esac
        [ -n "$_best" ] || _best=$_table
    done <"$_tmp"
    rm -f "$_tmp" 2>/dev/null
    [ -n "$_default" ] && { printf '%s' "$_default"; return 0; }
    [ -n "$_best" ] && { printf '%s' "$_best"; return 0; }
    return 1
}

# 输出 "接口 表号"
nc_hotspot_find_tun() {
    local _if _table
    for _if in $(ip -4 -o addr show 2>/dev/null | sed -n 's/^[0-9][0-9]*: \([^ ]*\) .*/\1/p' | grep -E '^(tun|Meta|utun|mihomo|sing-box)' 2>/dev/null); do
        _table=$(nc_hotspot_tun_table "$_if") || continue
        printf '%s %s\n' "$_if" "$_table"
        return 0
    done
    return 1
}

nc_hotspot_chain_ok() {
    command -v iptables >/dev/null 2>&1 || return 1
    nc_hotspot_ipt -C FORWARD -j "$NC_HS_FWD_CHAIN" || return 1
    nc_hotspot_ipt -C INPUT -j "$NC_HS_IN_CHAIN" || return 1
    nc_hotspot_ipt -t nat -C POSTROUTING -j "$NC_HS_NAT_CHAIN" || return 1
    nc_hotspot_ipt -t nat -C PREROUTING -j "$NC_HS_DNS_CHAIN" || return 1
    return 0
}

nc_hotspot_cleanup_rules() {
    local _hook _p
    if command -v iptables >/dev/null 2>&1; then
        for _hook in FORWARD INPUT; do
            while nc_hotspot_ipt -C "$_hook" -j "$NC_HS_FWD_CHAIN"; do
                nc_hotspot_ipt -D "$_hook" -j "$NC_HS_FWD_CHAIN"
            done
            while nc_hotspot_ipt -C "$_hook" -j "$NC_HS_IN_CHAIN"; do
                nc_hotspot_ipt -D "$_hook" -j "$NC_HS_IN_CHAIN"
            done
        done
        while nc_hotspot_ipt -t nat -C POSTROUTING -j "$NC_HS_NAT_CHAIN"; do
            nc_hotspot_ipt -t nat -D POSTROUTING -j "$NC_HS_NAT_CHAIN"
        done
        while nc_hotspot_ipt -t nat -C PREROUTING -j "$NC_HS_DNS_CHAIN"; do
            nc_hotspot_ipt -t nat -D PREROUTING -j "$NC_HS_DNS_CHAIN"
        done
        for _hook in "$NC_HS_FWD_CHAIN" "$NC_HS_IN_CHAIN"; do
            nc_hotspot_ipt -F "$_hook"
            nc_hotspot_ipt -X "$_hook"
        done
        for _hook in "$NC_HS_NAT_CHAIN" "$NC_HS_DNS_CHAIN"; do
            nc_hotspot_ipt -t nat -F "$_hook"
            nc_hotspot_ipt -t nat -X "$_hook"
        done
    fi

    # 清理本模块自己的策略路由规则和本地网络表
    while ip rule del pref "$NC_HOTSPOT_RULE_PREF" 2>/dev/null; do :; done
    while ip rule del pref "$NC_HOTSPOT_IIF_PREF" 2>/dev/null; do :; done
    ip route flush table "$NC_HOTSPOT_LOCAL_TABLE" 2>/dev/null
    return 0
}

nc_hotspot_restore_forwarding() {
    local _prev4 _prev6
    [ -f "$NC_HOTSPOT_STATE" ] || return 0
    _prev4=$(sed -n 's/^prev4=//p' "$NC_HOTSPOT_STATE" 2>/dev/null | head -n 1)
    _prev6=$(sed -n 's/^prev6=//p' "$NC_HOTSPOT_STATE" 2>/dev/null | head -n 1)
    case "$_prev4" in 0|1) sysctl -w net.ipv4.ip_forward="$_prev4" >/dev/null 2>&1 ;; esac
    case "$_prev6" in 0|1) sysctl -w net.ipv6.conf.all.forwarding="$_prev6" >/dev/null 2>&1 ;; esac
}

nc_hotspot_cleanup() {
    local _had
    _had=0
    [ -f "$NC_HOTSPOT_STATE" ] && _had=1
    nc_hotspot_cleanup_rules
    nc_hotspot_restore_forwarding
    rm -f "$NC_HOTSPOT_STATE" 2>/dev/null
    [ "$_had" = "1" ] && nc_hotspot_log "热点代理已清理"
    return 0
}

nc_hotspot_state_value() {
    local _v
    _v=$(sed -n "s/^$1=//p" "$NC_HOTSPOT_STATE" 2>/dev/null | head -n 1)
    _v=${_v#\"}
    _v=${_v%\"}
    printf '%s' "$_v"
}

nc_hotspot_active() {
    nc_load_settings
    [ "$NC_HOTSPOT_ENABLED" = "true" ] || return 1
    [ -f "$NC_HOTSPOT_STATE" ] || return 1
    [ "$(nc_hotspot_state_value active)" = "1" ] || return 1
    nc_core_running "$NC_ACTIVE_CORE" || return 1
    nc_hotspot_chain_ok || return 1
    return 0
}

nc_hotspot_status_json() {
    local _active _enabled _if _ifaces _ifaces_json _subnet _usb
    nc_load_settings
    _enabled=false
    [ "$NC_HOTSPOT_ENABLED" = "true" ] && _enabled=true
    _usb=false
    [ "$NC_HOTSPOT_USB" = "true" ] && _usb=true
    _ifaces=$(nc_hotspot_ifaces "$NC_HOTSPOT_USB")
    _ifaces_json=""
    for _if in $_ifaces; do
        _ifaces_json="${_ifaces_json}${_ifaces_json:+,}\"$(nc_json_escape "$_if")\""
    done
    _subnet=""
    for _if in $_ifaces; do
        _subnet=$(nc_hotspot_iface_subnet "$_if")
        [ -n "$_subnet" ] && break
    done
    _active=false
    nc_hotspot_active && _active=true
    printf '{"enabled":%s,"active":%s,"usb":%s,"ifaces":[%s],"subnet":"%s"}' \
        "$_enabled" "$_active" "$_usb" "$_ifaces_json" "$(nc_json_escape "$_subnet")"
}

nc_hotspot_sync() {
    if command -v flock >/dev/null 2>&1; then
        (
            flock -n 9 2>/dev/null || exit 0
            nc_hotspot_sync_locked
        ) 9>"$NC_RUN/hotspot.lock"
    else
        nc_hotspot_sync_locked
    fi
}

nc_hotspot_sync_locked() {
    local _active_state _if _if_subnet _ifaces _ifaces_sp _prev4 _prev6 _state _subnet _topology_subnet _tun _tun_info _table _topology
    nc_load_settings

    if [ "$NC_HOTSPOT_ENABLED" != "true" ] || ! nc_core_running "$NC_ACTIVE_CORE"; then
        nc_hotspot_cleanup
        return 0
    fi

    _ifaces=$(nc_hotspot_ifaces "$NC_HOTSPOT_USB")
    _ifaces_sp=$(printf '%s' "$_ifaces" | tr '\n' ' ')
    _ifaces_sp=${_ifaces_sp% }
    if [ -z "$_ifaces_sp" ]; then
        nc_hotspot_cleanup
        return 0
    fi

    _subnet=""
    for _if in $_ifaces; do
        _subnet=$(nc_hotspot_iface_subnet "$_if")
        [ -n "$_subnet" ] && break
    done
    [ -n "$_subnet" ] || { nc_hotspot_cleanup; nc_hotspot_log "热点接口没有 IPv4 子网，跳过"; return 0; }
    _topology_subnet=$_subnet

    _tun_info=$(nc_hotspot_find_tun 2>/dev/null)
    if [ -z "$_tun_info" ]; then
        nc_hotspot_cleanup
        nc_hotspot_log "未找到内核 TUN 路由表，热点暂不接管"
        return 0
    fi
    _tun=${_tun_info%% *}
    _table=${_tun_info#* }
    [ -n "$_tun" ] && [ -n "$_table" ] || { nc_hotspot_cleanup; return 0; }

    _topology="ifaces=$_ifaces_sp;tun=$_tun;table=$_table;subnet=$_topology_subnet"
    if [ -f "$NC_HOTSPOT_STATE" ] && [ "$(nc_hotspot_state_value topology)" = "$_topology" ] && nc_hotspot_chain_ok; then
        return 0
    fi

    nc_hotspot_cleanup_rules

    # 保存一次 forwarding 原值，清理时恢复
    if [ -f "$NC_HOTSPOT_STATE" ]; then
        _prev4=$(nc_hotspot_state_value prev4)
        _prev6=$(nc_hotspot_state_value prev6)
    else
        _prev4=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
        _prev6=$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)
    fi
    case "$_prev4" in 0|1) ;; *) _prev4=0 ;; esac
    case "$_prev6" in 0|1) ;; *) _prev6=0 ;; esac
    # 先写临时状态，规则注入失败时也能恢复 forwarding
    {
        printf 'active=0\n'
        printf 'prev4="%s"\n' "$_prev4"
        printf 'prev6="%s"\n' "$_prev6"
    } >"$NC_HOTSPOT_STATE" 2>/dev/null
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1

    if command -v iptables >/dev/null 2>&1; then
        nc_hotspot_ipt -N "$NC_HS_FWD_CHAIN"
        nc_hotspot_ipt -N "$NC_HS_IN_CHAIN"
        nc_hotspot_ipt -t nat -N "$NC_HS_NAT_CHAIN"
        nc_hotspot_ipt -t nat -N "$NC_HS_DNS_CHAIN"
        for _if in $_ifaces; do
            nc_hotspot_ipt -A "$NC_HS_FWD_CHAIN" -i "$_if" -o "$_tun" -j ACCEPT
            nc_hotspot_ipt -A "$NC_HS_FWD_CHAIN" -i "$_tun" -o "$_if" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
            nc_hotspot_ipt -A "$NC_HS_IN_CHAIN" -i "$_if" -p udp --dport 53 -j ACCEPT
            nc_hotspot_ipt -A "$NC_HS_IN_CHAIN" -i "$_if" -p tcp --dport 53 -j ACCEPT
            nc_hotspot_ipt -t nat -A "$NC_HS_DNS_CHAIN" -i "$_if" -p udp --dport 53 -j REDIRECT --to-ports 53
            nc_hotspot_ipt -t nat -A "$NC_HS_DNS_CHAIN" -i "$_if" -p tcp --dport 53 -j REDIRECT --to-ports 53
            _if_subnet=$(nc_hotspot_iface_subnet "$_if")
            [ -n "$_if_subnet" ] && nc_hotspot_ipt -t nat -A "$NC_HS_NAT_CHAIN" -s "$_if_subnet" -o "$_tun" -j MASQUERADE
            [ -n "$_if_subnet" ] && ip route replace "$_if_subnet" dev "$_if" table "$NC_HOTSPOT_LOCAL_TABLE" 2>/dev/null
            [ -n "$_if_subnet" ] && ip rule add pref "$NC_HOTSPOT_RULE_PREF" to "$_if_subnet" lookup "$NC_HOTSPOT_LOCAL_TABLE" 2>/dev/null
            ip rule add pref "$NC_HOTSPOT_IIF_PREF" iif "$_if" lookup "$_table" 2>/dev/null
        done
        nc_hotspot_ipt -I FORWARD 1 -j "$NC_HS_FWD_CHAIN"
        nc_hotspot_ipt -I INPUT 1 -j "$NC_HS_IN_CHAIN"
        nc_hotspot_ipt -t nat -I POSTROUTING 1 -j "$NC_HS_NAT_CHAIN"
        nc_hotspot_ipt -t nat -I PREROUTING 1 -j "$NC_HS_DNS_CHAIN"
    else
        nc_hotspot_log "iptables 不可用，热点共享无法接管"
        nc_hotspot_cleanup
        return 1
    fi

    _state="$NC_HOTSPOT_STATE"
    {
        printf 'active=1\n'
        printf 'ifaces="%s"\n' "$_ifaces_sp"
        printf 'subnet="%s"\n' "$_subnet"
        printf 'tun="%s"\n' "$_tun"
        printf 'table="%s"\n' "$_table"
        printf 'topology="%s"\n' "$_topology"
        printf 'prev4="%s"\n' "$_prev4"
        printf 'prev6="%s"\n' "$_prev6"
    } >"$_state" 2>/dev/null
    chmod 600 "$_state" 2>/dev/null

    if nc_hotspot_chain_ok; then
        nc_hotspot_log "热点代理已接管: ${_ifaces_sp} -> ${_tun} (table ${_table}, subnet ${_subnet})"
    else
        nc_hotspot_log "热点规则注入不完整，请检查 iptables/ip rule"
        nc_hotspot_cleanup
        return 1
    fi
    return 0
}

nc_hotspot_enable() {
    nc_load_settings
    NC_HOTSPOT_ENABLED="true"
    nc_save_settings || return 1
    nc_hotspot_sync || return 1
    nc_wifi_start_daemon 2>/dev/null || true
    nc_hotspot_log "热点代理共享已开启"
    return 0
}

nc_hotspot_disable() {
    nc_load_settings
    NC_HOTSPOT_ENABLED="false"
    nc_save_settings || return 1
    nc_hotspot_sync
    nc_hotspot_log "热点代理共享已关闭"
    return 0
}

nc_hotspot_usb() {
    nc_load_settings
    case "$1" in true|false) ;; *) nc_err "usb 只能是 true 或 false"; return 2 ;; esac
    NC_HOTSPOT_USB=$1
    nc_save_settings || return 1
    nc_hotspot_sync || return 1
    return 0
}
