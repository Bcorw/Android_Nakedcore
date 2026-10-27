#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - Wi-Fi 自动启停守护
#
#  连接信任 Wi-Fi -> 停止当前内核，并记住“暂停”状态
#  离开信任 Wi-Fi -> 自动启动当前激活内核
#  无法读取 SSID  -> 跳过本次，不做任何切换（fail-safe）
# ============================================================

NC_WIFI_INTERVAL="${NC_WIFI_INTERVAL:-5}"

nc_wifi_ensure() {
    mkdir -p "$NC_WIFI_DIR" 2>/dev/null
    chmod 700 "$NC_WIFI_DIR" 2>/dev/null
    [ -f "$NC_WIFI_SSIDS" ] || : >"$NC_WIFI_SSIDS" 2>/dev/null
    chmod 600 "$NC_WIFI_SSIDS" 2>/dev/null
}

nc_wifi_log() {
    nc_wifi_ensure
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$NC_WIFI_LOG" 2>/dev/null
}

nc_wifi_log_rotate() {
    nc_wifi_ensure
    if [ -f "$NC_WIFI_LOG" ] && [ "$(nc_file_size "$NC_WIFI_LOG" 2>/dev/null || echo 0)" -gt 131072 ]; then
        mv -f "$NC_WIFI_LOG" "$NC_WIFI_LOG.1" 2>/dev/null
    fi
}

# 输出当前 SSID；未连接时输出空并通过；无法检测时返回 1。
nc_wifi_current_ssid() {
    local _if _link _out _ssid

    # 测试钩子：仅用于本地验证，不影响正常运行
    if [ -n "${NC_WIFI_SSID_OVERRIDE:-}" ]; then
        printf '%s' "$NC_WIFI_SSID_OVERRIDE"
        return 0
    fi

    # 1) iw：root 下最快、最稳定的已连接 SSID 来源
    if command -v iw >/dev/null 2>&1; then
        # 优先 wlan0；iw dev 还会列出 p2p0 / wifi-aware0，不能取第一个接口
        _if="wlan0"
        if ! iw dev "$_if" link >/dev/null 2>&1; then
            _if=$(iw dev 2>/dev/null | awk '/^[[:space:]]*Interface / { print $2 }' | grep -E '^wlan' | head -n 1)
        fi
        [ -n "$_if" ] || _if="wlan0"
        _link=$(iw dev "$_if" link 2>/dev/null)
        case "$_link" in
            *"Not connected"*)
                return 0
                ;;
            *"SSID:"*)
                _ssid=$(printf '%s\n' "$_link" | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p' | head -n 1)
                _ssid=$(printf '%s' "$_ssid" | tr -d '\r')
                case "$_ssid" in
                    ""|"<unknown ssid>"|"<unknown>") return 0 ;;
                esac
                printf '%s' "$_ssid"
                return 0
                ;;
        esac
    fi

    # 2) cmd wifi status：Android 10+ 的公开 shell 接口
    if command -v cmd >/dev/null 2>&1; then
        _out=$(cmd wifi status 2>/dev/null)
        _ssid=$(printf '%s\n' "$_out" | sed -n 's/^Wifi is connected to "\(.*\)"$/\1/p' | head -n 1)
        if [ -z "$_ssid" ]; then
            _ssid=$(printf '%s\n' "$_out" | sed -n 's/^WifiInfo: SSID: "\([^"]*\)".*/\1/p' | head -n 1)
        fi
        if [ -n "$_ssid" ]; then
            _ssid=$(printf '%s' "$_ssid" | tr -d '\r')
            case "$_ssid" in
                "<unknown ssid>"|"<unknown>") return 0 ;;
            esac
            printf '%s' "$_ssid"
            return 0
        fi
        case "$_out" in
            *"Wifi is disabled"*|*"Wifi is enabled"*)
                return 0
                ;;
        esac
    fi

    # 3) dumpsys 兜底
    if command -v dumpsys >/dev/null 2>&1; then
        _out=$(dumpsys wifi 2>/dev/null | grep -m 1 'mWifiInfo SSID:' 2>/dev/null)
        if [ -n "$_out" ]; then
            _ssid=$(printf '%s\n' "$_out" | sed -n 's/.*mWifiInfo SSID: "\([^"]*\)".*/\1/p' | head -n 1)
            _ssid=$(printf '%s' "$_ssid" | tr -d '\r')
            case "$_ssid" in
                ""|"<unknown ssid>"|"<unknown>") return 0 ;;
            esac
            printf '%s' "$_ssid"
            return 0
        fi
    fi

    # 所有接口都失败：调用方必须跳过本轮，不能把 unknown 当作“离家”
    return 1
}

nc_wifi_is_trusted() {
    local _ssid _line
    _ssid=$1
    [ -n "$_ssid" ] || return 1
    nc_wifi_ensure
    [ -f "$NC_WIFI_SSIDS" ] || return 1
    while IFS= read -r _line; do
        _line=$(printf '%s' "$_line" | tr -d '\r')
        [ -n "$_line" ] || continue
        [ "$_line" = "$_ssid" ] && return 0
    done <"$NC_WIFI_SSIDS"
    return 1
}

nc_wifi_ssids_json() {
    local _first _line _ssid
    nc_wifi_ensure
    _first=1
    printf '['
    if [ -f "$NC_WIFI_SSIDS" ]; then
        while IFS= read -r _line; do
            _line=$(printf '%s' "$_line" | tr -d '\r')
            [ -n "$_line" ] || continue
            [ "$_first" = "1" ] || printf ','
            _first=0
            _ssid=$(nc_json_escape "$_line")
            printf '"%s"' "$_ssid"
        done <"$NC_WIFI_SSIDS"
    fi
    printf ']'
}

nc_wifi_add_ssid() {
    local _ssid
    _ssid=$1
    [ -n "$_ssid" ] || return 2
    case "$_ssid" in
        *'
'*) nc_err "SSID 不能包含换行"; return 2 ;;
    esac
    nc_wifi_ensure
    nc_wifi_is_trusted "$_ssid" && return 0
    printf '%s\n' "$_ssid" >>"$NC_WIFI_SSIDS" 2>/dev/null || return 1
    nc_wifi_log "添加信任 Wi-Fi: $_ssid"
    return 0
}

nc_wifi_remove_ssid() {
    local _line _ssid _tmp
    _ssid=$1
    [ -n "$_ssid" ] || return 2
    nc_wifi_ensure
    _tmp="$NC_WIFI_SSIDS.tmp.$$"
    : >"$_tmp" 2>/dev/null || return 1
    while IFS= read -r _line; do
        _line=$(printf '%s' "$_line" | tr -d '\r')
        [ -n "$_line" ] || continue
        [ "$_line" = "$_ssid" ] && continue
        printf '%s\n' "$_line" >>"$_tmp" 2>/dev/null
    done <"$NC_WIFI_SSIDS"
    mv -f "$_tmp" "$NC_WIFI_SSIDS" 2>/dev/null || { rm -f "$_tmp"; return 1; }
    chmod 600 "$NC_WIFI_SSIDS" 2>/dev/null
    nc_wifi_log "移除信任 Wi-Fi: $_ssid"
    return 0
}

nc_wifi_suspended() {
    [ -f "$NC_WIFI_STATE" ]
}

nc_wifi_set_suspended() {
    local _ssid
    _ssid=$1
    nc_wifi_ensure
    printf '%s\n' "$_ssid" >"$NC_WIFI_STATE" 2>/dev/null
    chmod 600 "$NC_WIFI_STATE" 2>/dev/null
}

nc_wifi_clear_suspended() {
    rm -f "$NC_WIFI_STATE" 2>/dev/null
}

nc_wifi_manual_stopped() {
    [ -f "$NC_WIFI_MANUAL" ]
}

nc_wifi_mark_manual_stop() {
    nc_wifi_ensure
    nc_wifi_clear_suspended
    rm -f "$NC_WIFI_DIR/next_try" 2>/dev/null
    printf '%s	%s
' "$(date +%s)" "${NC_ACTIVE_CORE:-}" >"$NC_WIFI_MANUAL" 2>/dev/null
    chmod 600 "$NC_WIFI_MANUAL" 2>/dev/null
    nc_wifi_log "手动停止内核，暂停 Wi-Fi 自动恢复（手动停止优先）"
}

nc_wifi_clear_manual_stop() {
    rm -f "$NC_WIFI_MANUAL" 2>/dev/null
}

# 用户主动恢复自动逻辑，不直接启动内核
nc_wifi_resume() {
    nc_load_settings
    nc_wifi_clear_manual_stop
    rm -f "$NC_WIFI_DIR/next_try" 2>/dev/null
    nc_wifi_log "用户恢复 Wi-Fi 自动启停逻辑"
    nc_wifi_tick
    nc_wifi_status_json
    printf '\n'
}

nc_wifi_write_last() {
    local _ssid
    _ssid=$1
    nc_wifi_ensure
    printf '%s\t%s\n' "$(date +%s)" "$_ssid" >"$NC_WIFI_LAST" 2>/dev/null
    chmod 600 "$NC_WIFI_LAST" 2>/dev/null
}

nc_wifi_daemon_running() {
    local _pid _p
    # pidfile 快路径
    if [ -f "$NC_WIFI_PID" ]; then
        IFS= read -r _pid <"$NC_WIFI_PID" 2>/dev/null
        if [ -n "$_pid" ] && nc_pid_matches "$_pid" "nakedcore wifi _daemon"; then
            return 0
        fi
    fi
    # 兜底：兼容旧 pidfile 或重启前遗留的守护
    for _p in $(nc_pids_by_pattern "nakedcore wifi _daemon" 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        nc_pid_matches "$_p" "nakedcore wifi _daemon" && return 0
    done
    return 1
}

nc_wifi_start_daemon() {
    nc_wifi_ensure
    if nc_wifi_daemon_running; then
        return 0
    fi
    nc_wifi_log_rotate
    nc_spawn_detached "$NC_WIFI_LOG" "$NC_WIFI_PID" "$NC_SELF" wifi _daemon
    sleep 1
    nc_wifi_daemon_running
}

nc_wifi_stop_daemon() {
    local _pid _p
    # 先按 pidfile
    if [ -f "$NC_WIFI_PID" ]; then
        IFS= read -r _pid <"$NC_WIFI_PID" 2>/dev/null
        if [ -n "$_pid" ] && nc_pid_matches "$_pid" "nakedcore wifi _daemon"; then
            kill "$_pid" 2>/dev/null
        fi
    fi
    # 再清理所有本模块的 daemon（兼容旧 pidfile / 同名遗留）
    for _p in $(nc_pids_by_pattern "nakedcore wifi _daemon" 2>/dev/null); do
        [ "$_p" = "$$" ] && continue
        nc_pid_matches "$_p" "nakedcore wifi _daemon" && kill "$_p" 2>/dev/null
    done

    # 等待 shell 从 sleep/trap 中退出，避免紧接着 start 时误判仍在运行
    sleep 1
    if nc_wifi_daemon_running; then
        for _p in $(nc_pids_by_pattern "nakedcore wifi _daemon" 2>/dev/null); do
            [ "$_p" = "$$" ] && continue
            nc_pid_matches "$_p" "nakedcore wifi _daemon" && kill -9 "$_p" 2>/dev/null
        done
        sleep 1
    fi

    rm -f "$NC_WIFI_PID" 2>/dev/null
    nc_wifi_log "守护已停止"
    return 0
}

# 0 = 允许内核启动；1 = 当前在信任 Wi-Fi 或无法判断，应跳过启动
nc_wifi_gate() {
    local _ssid
    nc_load_settings
    [ "$NC_WIFI_GUARD" = "true" ] || return 0
    nc_wifi_manual_stopped && return 1
    _ssid=$(nc_wifi_current_ssid) || return 1
    [ -n "$_ssid" ] || return 0
    nc_wifi_is_trusted "$_ssid" && return 1
    return 0
}

# 单次检测。所有失败都只记录，不让守护退出。
nc_wifi_tick() {
    local _core _next _now _rc _ssid
    nc_load_settings
    [ "$NC_WIFI_GUARD" = "true" ] || return 0
    nc_wifi_ensure

    _ssid=$(nc_wifi_current_ssid)
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        nc_wifi_log "无法读取当前 SSID，跳过本轮（不做切换）"
        return 0
    fi
    nc_wifi_write_last "$_ssid"
    _core="$NC_ACTIVE_CORE"

    if [ -n "$_ssid" ] && nc_wifi_is_trusted "$_ssid"; then
        if [ "$(nc_core_running "$_core" && printf true || printf false)" = "true" ]; then
            # 只有守护亲自停止的内核才拥有“离开后自动启动”的资格
            if nc_wifi_manual_stopped; then
                nc_wifi_clear_suspended
                nc_wifi_log "信任 Wi-Fi 下检测到内核运行，但手动停止优先；停止内核且不安排自动恢复"
            elif ! nc_wifi_suspended; then
                nc_wifi_set_suspended "$_ssid"
                nc_wifi_log "进入信任 Wi-Fi: $_ssid，暂停内核"
            fi
            nc_wifi_log "信任 Wi-Fi 下停止内核: $_core"
            nc_core_stop_one "$_core" >/dev/null 2>&1
            if nc_wifi_manual_stopped; then
                nc_wifi_clear_suspended
                nc_wifi_log "停止过程中检测到手动停止，清除自动恢复标记"
            fi
            if ! nc_core_running "$_core"; then
                nc_wifi_log "已停止 $_core"
            else
                nc_wifi_log "停止 $_core 失败，下一轮重试"
            fi
        else
            # 内核本来就没运行：手动停止优先；否则记录离开后恢复，
            # 这样“开机就在家”也能在出门时自动启动。
            if nc_wifi_manual_stopped; then
                nc_wifi_clear_suspended
            elif ! nc_wifi_suspended; then
                nc_wifi_set_suspended "$_ssid"
                nc_wifi_log "信任 Wi-Fi 下内核未运行，记录离开后恢复"
            fi
        fi
        return 0
    fi

    # 离家 / 移动数据 / 其他 Wi-Fi
    if ! nc_wifi_suspended; then
        return 0
    fi
    if nc_wifi_manual_stopped; then
        nc_wifi_clear_suspended
        nc_wifi_log "手动停止优先，取消自动恢复"
        return 0
    fi
    if nc_core_running "$_core"; then
        nc_wifi_clear_suspended
        nc_wifi_log "内核已在运行，清除暂停标记"
        return 0
    fi

    _now=$(date +%s)
    _next=0
    if [ -f "$NC_WIFI_DIR/next_try" ]; then
        IFS= read -r _next <"$NC_WIFI_DIR/next_try" 2>/dev/null
    fi
    case "$_next" in *[!0-9]*|"") _next=0 ;; esac
    if [ "$_now" -lt "$_next" ]; then
        return 0
    fi

    if ! nc_core_installed "$_core"; then
        printf '%s\n' "$((_now + 300))" >"$NC_WIFI_DIR/next_try" 2>/dev/null
        nc_wifi_log "离开信任 Wi-Fi，但 $_core 未安装，5 分钟后重试"
        return 0
    fi

    nc_wifi_log "离开信任 Wi-Fi（当前: ${_ssid:-无 Wi-Fi}），自动启动 $_core"
    if nc_core_start "$_core" >>"$NC_WIFI_LOG" 2>&1; then
        if nc_wifi_manual_stopped; then
            nc_wifi_log "自动启动过程中检测到手动停止，撤销本次启动"
            nc_core_stop_one "$_core" >/dev/null 2>&1
            nc_wifi_clear_suspended
            return 0
        fi
        nc_wifi_clear_suspended
        rm -f "$NC_WIFI_DIR/next_try" 2>/dev/null
        nc_wifi_log "$_core 自动启动成功"
    else
        printf '%s\n' "$((_now + 300))" >"$NC_WIFI_DIR/next_try" 2>/dev/null
        nc_wifi_log "$_core 自动启动失败，5 分钟后重试"
    fi
    return 0
}

nc_wifi_daemon() {
    nc_wifi_ensure
    nc_wifi_log_rotate
    printf '%s\n' "$$" >"$NC_WIFI_PID" 2>/dev/null
    trap 'rm -f "$NC_WIFI_PID" 2>/dev/null; exit 0' INT TERM EXIT
    nc_wifi_log "网络守护启动（间隔 ${NC_WIFI_INTERVAL}s）"

    _idle_logged=0
    while :; do
        nc_load_settings
        if [ "$NC_WIFI_GUARD" != "true" ] && [ "$NC_HOTSPOT_ENABLED" != "true" ]; then
            # 保持守护常驻：KernelSU WebUI / 管理器进程退出时，
            # 由 service.sh 启动的守护仍在后台，重新开启功能无需再拉起。
            if [ "$_idle_logged" = "0" ]; then
                nc_wifi_log "Wi-Fi 与热点均关闭，网络守护待命"
                _idle_logged=1
            fi
            sleep "$NC_WIFI_INTERVAL"
            continue
        fi
        _idle_logged=0
        if [ "$NC_HOTSPOT_ENABLED" = "true" ]; then
            nc_hotspot_sync
        fi
        if [ "$NC_WIFI_GUARD" = "true" ]; then
            nc_wifi_tick
        fi
        sleep "$NC_WIFI_INTERVAL"
    done

    rm -f "$NC_WIFI_PID" 2>/dev/null
    return 0
}

nc_wifi_enable() {
    nc_load_settings
    NC_WIFI_GUARD="true"
    nc_save_settings || return 1
    nc_wifi_clear_manual_stop
    nc_wifi_start_daemon
    nc_wifi_log "已启用 Wi-Fi 自动启停"
    nc_wifi_tick
    return 0
}

nc_wifi_disable() {
    nc_load_settings
    NC_WIFI_GUARD="false"
    nc_save_settings || return 1
    # 保留常驻网络守护，避免下次在 WebUI 内重新拉起后被管理器进程回收
    nc_wifi_clear_suspended
    nc_wifi_clear_manual_stop
    rm -f "$NC_WIFI_DIR/next_try" 2>/dev/null
    nc_wifi_log "已关闭 Wi-Fi 自动启停"
    return 0
}

nc_wifi_status_json() {
    local _daemon _detect_ok _manual _ssid _suspended _trusted
    nc_load_settings
    nc_wifi_ensure

    _ssid=$(nc_wifi_current_ssid)
    if [ $? -ne 0 ]; then
        _detect_ok=false
        _ssid=""
    else
        _detect_ok=true
    fi
    _trusted=false
    [ -n "$_ssid" ] && nc_wifi_is_trusted "$_ssid" && _trusted=true
    _suspended=false
    nc_wifi_suspended && _suspended=true
    _manual=false
    nc_wifi_manual_stopped && _manual=true
    _daemon=false
    nc_wifi_daemon_running && _daemon=true

    printf '{"guard":%s,"ssids":%s,"current_ssid":"%s","trusted":%s,"suspended":%s,"manual_stop":%s,"daemon":%s,"detect_ok":%s,"interval":%s}' \
        "$([ "$NC_WIFI_GUARD" = "true" ] && printf true || printf false)" \
        "$(nc_wifi_ssids_json)" \
        "$(nc_json_escape "$_ssid")" \
        "$_trusted" "$_suspended" "$_manual" "$_daemon" "$_detect_ok" "$NC_WIFI_INTERVAL"
}
