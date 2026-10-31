#!/system/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# ============================================================
# Android Nakedcore - 状态 JSON 与更新检查
# ============================================================

nc_update_env_load() {
    SB_STABLE=""
    SB_ALPHA=""
    MH_STABLE=""
    MH_ALPHA=""
    SUB_BACKEND=""
    SUB_FRONTEND=""
    CHECKED_AT=""
    [ -f "$NC_UPDATE_ENV" ] || return 0
    # 文件由本模块写入，内容为受控键值
    # shellcheck disable=SC1090
    . "$NC_UPDATE_ENV" 2>/dev/null
    return 0
}

nc_github_latest_tag() {
    local _file _repo _tag
    _repo=$1

    # 1) Atom feed（推荐，体积小）
    _tag=$(nc_github_atom_tag "$_repo" stable 2>/dev/null)
    if [ -n "$_tag" ]; then
        printf '%s' "${_tag#v}"
        return 0
    fi

    # 2) GitHub API（可能 403，文件方式解析）
    _file="$NC_TMP/latest-api.$$.json"
    if nc_fetch_file "https://api.github.com/repos/$_repo/releases/latest" "$_file" 20; then
        _tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_file" 2>/dev/null | head -n 1)
    fi
    rm -f "$_file" 2>/dev/null
    if [ -n "$_tag" ]; then
        printf '%s' "${_tag#v}"
        return 0
    fi

    # 3) release HTML（文件方式，避免 argv 超限）
    _file="$NC_TMP/latest-html.$$.html"
    if nc_fetch_file "https://github.com/$_repo/releases" "$_file" 30; then
        _tag=$(grep -oE "/$_repo/releases/tag/[^\"/]+" "$_file" 2>/dev/null | head -n 1 | sed 's#.*/tag/##')
    fi
    rm -f "$_file" 2>/dev/null

    [ -n "$_tag" ] || return 1
    printf '%s' "${_tag#v}"
}

nc_checkup() {
    local _tmp _v
    nc_update_env_load
    date +%s >"$NC_RUN/checkup.started" 2>/dev/null
    nc_info "检查上游最新版本..."

    _v=$(nc_singbox_latest stable 2>/dev/null) && SB_STABLE="$_v"
    [ -n "$SB_STABLE" ] && nc_info "sing-box 稳定版: $SB_STABLE" || nc_warn "sing-box 稳定版检查失败"
    _v=$(nc_singbox_latest alpha 2>/dev/null) && SB_ALPHA="$_v"
    [ -n "$SB_ALPHA" ] && nc_info "sing-box 预览版: $SB_ALPHA" || nc_warn "sing-box 预览版检查失败"

    _v=$(nc_mihomo_latest stable 2>/dev/null) && MH_STABLE="$_v"
    [ -n "$MH_STABLE" ] && nc_info "mihomo 稳定版: $MH_STABLE" || nc_warn "mihomo 稳定版检查失败"
    _v=$(nc_mihomo_latest alpha 2>/dev/null) && MH_ALPHA="$_v"
    [ -n "$MH_ALPHA" ] && nc_info "mihomo 预览版: $MH_ALPHA" || nc_warn "mihomo 预览版检查失败"

    _v=$(nc_github_latest_tag sub-store-org/Sub-Store 2>/dev/null) && SUB_BACKEND="${_v#v}"
    [ -n "$SUB_BACKEND" ] && nc_info "Sub-Store 后端: $SUB_BACKEND" || nc_warn "Sub-Store 后端检查失败"
    _v=$(nc_github_latest_tag sub-store-org/Sub-Store-Front-End 2>/dev/null) && SUB_FRONTEND="${_v#v}"
    [ -n "$SUB_FRONTEND" ] && nc_info "Sub-Store 前端: $SUB_FRONTEND" || nc_warn "Sub-Store 前端检查失败"

    CHECKED_AT=$(nc_now)
    _tmp="$NC_UPDATE_ENV.tmp.$$"
    {
        printf 'SB_STABLE="%s"\n' "$SB_STABLE"
        printf 'SB_ALPHA="%s"\n' "$SB_ALPHA"
        printf 'MH_STABLE="%s"\n' "$MH_STABLE"
        printf 'MH_ALPHA="%s"\n' "$MH_ALPHA"
        printf 'SUB_BACKEND="%s"\n' "$SUB_BACKEND"
        printf 'SUB_FRONTEND="%s"\n' "$SUB_FRONTEND"
        printf 'CHECKED_AT="%s"\n' "$CHECKED_AT"
    } >"$_tmp" 2>/dev/null
    mv -f "$_tmp" "$NC_UPDATE_ENV" 2>/dev/null
    rm -f "$NC_RUN/checkup.started" 2>/dev/null
    nc_info "检查完成"
    return 0
}

nc_status_core() {
    local _bin _cfg _cfg_exists _cfg_size _channel _check _core _dirty _installed _latest _log _marker _pid _rest _rollback _running _state _version _vf
    _core=$1
    case "$_core" in
        sing-box)
            _bin="$NC_SB_BIN"; _cfg="$NC_SB_CONFIG"; _vf="$NC_BIN/sing-box.version"
            _log="$NC_RUN/sing-box.log"
            _check="$NC_RUN/sing-box.check"; _marker="$NC_RUN/sing-box.started"
            ;;
        mihomo)
            _bin="$NC_MH_BIN"; _cfg="$NC_MH_CONFIG"; _vf="$NC_BIN/mihomo.version"
            _log="$NC_RUN/mihomo.log"
            _check="$NC_RUN/mihomo.check"; _marker="$NC_RUN/mihomo.started"
            ;;
        *) return 1 ;;
    esac

    _installed=false
    [ -x "$_bin" ] && _installed=true

    _running=false
    _pid=0
    # 用 nc_core_pid 校验 cmdline，避免重启后 PID 复用导致的「假运行中」
    _pid=$(nc_core_pid "$_core" 2>/dev/null)
    case "$_pid" in
        ""|*[!0-9]*) _pid=0 ;;
        *) _running=true ;;
    esac

    _version=""
    if [ -f "$_vf" ] && { [ ! -x "$_bin" ] || [ ! "$_bin" -nt "$_vf" ]; }; then
        IFS= read -r _version <"$_vf" 2>/dev/null
    elif [ -x "$_bin" ]; then
        if [ "$_core" = "sing-box" ]; then
            _version=$("$_bin" version 2>/dev/null | head -n 1 | awk '{print $3}' | tr -d '\r\n')
        else
            _version=$("$_bin" -v 2>/dev/null | head -n 1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -n 1 | tr -d '\r\n')
        fi
        _version=${_version#v}
    fi

    _cfg_exists=false
    _cfg_size=0
    if [ -f "$_cfg" ]; then
        _cfg_exists=true
        _cfg_size=$(nc_file_size "$_cfg")
    fi

    if [ ! -f "$_cfg" ]; then
        _state="none"
    elif [ ! -f "$_check" ] || [ "$_cfg" -nt "$_check" ]; then
        _state="unknown"
    else
        _state=""
        read -r _state _rest <"$_check" 2>/dev/null
        case "$_state" in ok|fail) ;; *) _state="unknown" ;; esac
    fi

    _dirty=false
    if [ "$_running" = "true" ] && [ -f "$_marker" ] && [ "$_cfg" -nt "$_marker" ]; then
        _dirty=true
    fi

    _rollback=false
    [ -x "$NC_BIN/$_core.old" ] && _rollback=true

    _latest=""
    case "$_core" in
        sing-box)
            if [ "$NC_SB_CHANNEL" = "alpha" ]; then _latest="$SB_ALPHA"; else _latest="$SB_STABLE"; fi
            ;;
        mihomo)
            if [ "$NC_MH_CHANNEL" = "alpha" ]; then _latest="$MH_ALPHA"; else _latest="$MH_STABLE"; fi
            ;;
    esac

    _channel=$(nc_core_channel "$_core")
    printf '{"id":"%s","installed":%s,"version":"%s","running":%s,"pid":%s,"config_exists":%s,"config_size":%s,"config_state":"%s","config_dirty":%s,"rollback":%s,"log":"%s","latest":"%s","channel":"%s"}' \
        "$_core" "$_installed" "$_version" "$_running" "$_pid" \
        "$_cfg_exists" "$_cfg_size" "$_state" "$_dirty" "$_rollback" \
        "$_log" "$_latest" "$_channel"
}

nc_status_substore() {
    local _autostart_json _backend_installed _backend_ver _direct _dirty _frontend_installed _frontend_ver _health _health_reason _merge_json _node _node_installed _node_ver _pid _running _started _sub_log
    nc_sub_load_env

    _running=false
    _pid=0
    # 同样校验 cmdline，避免 Node PID 被系统复用后误报运行中
    _pid=$(nc_sub_pid 2>/dev/null)
    case "$_pid" in
        ""|*[!0-9]*) _pid=0 ;;
        *) _running=true ;;
    esac

    _node=$(nc_sub_node 2>/dev/null)
    _node_ver=""
    [ -n "$_node" ] && _node_ver=$(nc_sub_node_version 2>/dev/null)
    _backend_ver=$(nc_sub_backend_version)
    _frontend_ver=$(nc_sub_frontend_version)
    _direct=$(nc_sub_direct_url)

    _health_reason=$(nc_sub_health_reason)
    _health=false
    [ "$_health_reason" = "正常" ] && _health=true

    _started="$NC_RUN/substore.started"
    _sub_log="$NC_RUN/substore.log"
    _dirty=false
    if [ "$_running" = "true" ] && [ -f "$NC_SUB_ENV" ] && [ -f "$_started" ] \
        && [ "$NC_SUB_ENV" -nt "$_started" ]; then
        _dirty=true
    fi

    _backend_installed=false
    [ -f "$NC_SUB_BUNDLE" ] && _backend_installed=true
    _frontend_installed=false
    [ -f "$NC_SUB_FE_PATH/index.html" ] && _frontend_installed=true
    _node_installed=false
    [ -n "$_node" ] && _node_installed=true
    if [ "$NC_SUB_MERGE" = "true" ]; then _merge_json=true; else _merge_json=false; fi
    if [ "$NC_SUB_AUTO_START" = "true" ]; then _autostart_json=true; else _autostart_json=false; fi

    printf '{"running":%s,"pid":%s,"health":%s,"health_reason":"%s","node":{"installed":%s,"version":"%s","path":"%s"},"backend":{"installed":%s,"version":"%s"},"frontend":{"installed":%s,"version":"%s"},"host":"%s","port":%s,"front_host":"%s","front_port":%s,"merge":%s,"backend_path":"%s","direct_url":"%s","open_url":"%s","autostart":%s,"dirty":%s,"data_dir":"%s","log":"%s","latest_backend":"%s","latest_frontend":"%s"}' \
        "$_running" "$_pid" "$_health" "$_health_reason" \
        "$_node_installed" "$_node_ver" "$_node" \
        "$_backend_installed" "$_backend_ver" \
        "$_frontend_installed" "$_frontend_ver" \
        "$NC_SUB_HOST" "$NC_SUB_PORT" \
        "$NC_SUB_FRONT_HOST" "$NC_SUB_FRONT_PORT" \
        "$_merge_json" \
        "$NC_SUB_PATH" \
        "$_direct" "$_direct" \
        "$_autostart_json" \
        "$_dirty" \
        "$NC_SUB_DATA_PATH" \
        "$_sub_log" \
        "$SUB_BACKEND" "$SUB_FRONTEND"
}


nc_status_json() {
    local _android _auto_json _checked _hotspot_json _kernel _last_task_json _manager _mh_json _mname _model _mvcode _mver _now _sb_json _sdk _sub_json _subauto_json _task_json _ui_json _wifi_json
    nc_update_env_load
    _sb_json=$(nc_status_core sing-box)
    _mh_json=$(nc_status_core mihomo)
    _sub_json=$(nc_status_substore)
    _ui_json=$(nc_ui_status_json)
    _hotspot_json=$(nc_hotspot_status_json)
    _wifi_json=$(nc_wifi_status_json)
    _task_json=$(nc_task_current_json)
    _last_task_json=$(nc_task_last_json)

    _model=$(nc_prop ro.product.model)
    [ -n "$_model" ] || _model=$(nc_prop ro.product.device)
    _android=$(nc_prop ro.build.version.release)
    _sdk=$(nc_prop ro.build.version.sdk)
    _kernel=$(uname -r 2>/dev/null)
    _manager=$(nc_manager)
    _mver=$(nc_module_version)
    _mvcode=$(nc_module_version_code)
    case "$_mvcode" in *[!0-9]*|"") _mvcode=0 ;; esac
    _mname=$(sed -n 's/^name=//p' "$NC_MODULE_PROP" 2>/dev/null | head -n 1 | tr -d '\r')

    _checked=${CHECKED_AT:-0}
    case "$_checked" in *[!0-9]*|"") _checked=0 ;; esac
    if [ "$NC_AUTO_START" = "true" ]; then _auto_json=true; else _auto_json=false; fi
    if [ "$NC_SUB_AUTO_START" = "true" ]; then _subauto_json=true; else _subauto_json=false; fi
    _now=$(nc_now)

    printf '{"ok":true,"time":%s,"module":{"id":"Android_Nakedcore","name":"%s","version":"%s","versionCode":%s},"device":{"model":"%s","android":"%s","sdk":"%s","abi":"%s","kernel":"%s","manager":"%s"},"settings":{"active_core":"%s","auto_start":%s,"sub_auto_start":%s,"gh_proxy":"%s","singbox_channel":"%s","mihomo_channel":"%s"},"cores":{"sing-box":%s,"mihomo":%s},"substore":%s,"ui":%s,"wifi":%s,"hotspot":%s,"task":%s,"last_task":%s,"update_check":{"checked_at":%s,"sb_stable":"%s","sb_alpha":"%s","mh_stable":"%s","mh_alpha":"%s","sub_backend":"%s","sub_frontend":"%s"}}\n' \
        "$_now" \
        "$_mname" "$_mver" "$_mvcode" \
        "$_model" "$_android" "$_sdk" \
        "$NC_ABI" "$_kernel" "$_manager" \
        "$NC_ACTIVE_CORE" \
        "$_auto_json" \
        "$_subauto_json" \
        "$NC_GH_PROXY" \
        "$NC_SB_CHANNEL" "$NC_MH_CHANNEL" \
        "$_sb_json" "$_mh_json" "$_sub_json" "$_ui_json" "$_wifi_json" "$_hotspot_json" \
        "$_task_json" "$_last_task_json" \
        "$_checked" \
        "$SB_STABLE" "$SB_ALPHA" \
        "$MH_STABLE" "$MH_ALPHA" \
        "$SUB_BACKEND" "$SUB_FRONTEND"
}
